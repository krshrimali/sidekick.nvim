---@brief Claude Code transcripts (`~/.claude/projects/<cwd>/<session>.jsonl`).
local P = require("sidekick.review.provider")
local Transcript = require("sidekick.review.transcript")

---@type sidekick.review.Provider
local M = {}

M.name = "claude"
M.label = "Claude Code"

--- Root of Claude Code's project storage. Overridable for tests.
---@type string?
M.root = nil

function M.projects_dir()
  if M.root then
    return M.root
  end
  local home = vim.env.CLAUDE_CONFIG_DIR or (vim.uv.os_homedir() .. "/.claude")
  return vim.fs.normalize(home .. "/projects")
end

--- Claude Code encodes a cwd by replacing every non alphanumeric char with `-`.
---@param cwd string
---@return string
function M.encode(cwd)
  return (vim.fs.normalize(cwd):gsub("[^%w]", "-"))
end

--- Entry types that carry no reviewable content.
local SKIP_TYPES = {
  ["mode"] = true,
  ["permission-mode"] = true,
  ["bridge-session"] = true,
  ["last-prompt"] = true,
  ["attachment"] = true,
  ["summary"] = true,
  ["system"] = true,
  ["file-history-snapshot"] = true,
}

---@param content string|table|nil
---@return string
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end
  local parts = {} ---@type string[]
  for _, c in ipairs(content) do
    if type(c) == "table" and c.type == "text" and c.text then
      parts[#parts + 1] = c.text
    elseif type(c) == "string" then
      parts[#parts + 1] = c
    end
  end
  return table.concat(parts, "\n")
end

--- A user entry is a real prompt only when it carries prose the user wrote.
---@param entry table
---@return boolean, string
local function user_prompt(entry)
  local msg = entry.message
  if not msg or msg.role ~= "user" or entry.isMeta then
    return false, ""
  end
  local content = msg.content
  if type(content) == "table" then
    -- a list containing tool_result blocks is Claude Code replying to itself
    for _, c in ipairs(content) do
      if type(c) == "table" and c.type == "tool_result" then
        return false, ""
      end
    end
  end
  local text = P.clean_prompt(content_text(content))
  return text ~= "", text
end

---@param cwd string
---@param out sidekick.review.Source[]
---@param dir string
---@param check_cwd boolean
local function collect(dir, cwd, out, check_cwd)
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:sub(-6) == ".jsonl" then
      local file = dir .. "/" .. name
      local stat = vim.uv.fs_stat(file)
      if stat and stat.size > 0 then
        local ok = true
        if check_cwd then
          local entry = Transcript.first_entry(file, stat)
          ok = entry ~= nil and entry.cwd ~= nil and vim.fs.normalize(entry.cwd) == cwd
        end
        if ok then
          out[#out + 1] = {
            file = file,
            session = name:sub(1, -7),
            cwd = cwd,
            provider = M.name,
            mtime = stat.mtime.sec + stat.mtime.nsec / 1e9,
            size = stat.size,
          }
        end
      end
    end
  end
end

---@param cwd string
---@return sidekick.review.Source[]
function M.sources(cwd)
  local root = M.projects_dir()
  local ret = {} ---@type sidekick.review.Source[]

  local encoded = root .. "/" .. M.encode(cwd)
  if vim.uv.fs_stat(encoded) then
    -- fast path: the encoded directory name matches exactly
    pcall(collect, encoded, cwd, ret, false)
  end

  if #ret == 0 and vim.uv.fs_stat(root) then
    -- slow path: encoding is lossy (`_` and `.` both map to `-`), so fall back
    -- to reading the `cwd` recorded inside each transcript
    pcall(function()
      for name, kind in vim.fs.dir(root) do
        if kind == "directory" then
          pcall(collect, root .. "/" .. name, cwd, ret, true)
        end
      end
    end)
  end
  return ret
end

---@param src sidekick.review.Source
---@return sidekick.review.Turn[]
function M.build(src)
  local entries = Transcript.parse(src.file)
  local turns = {} ---@type sidekick.review.Turn[]
  local by_tool_id = {} ---@type table<string, sidekick.review.Tool>
  local current ---@type sidekick.review.Turn?

  for _, entry in ipairs(entries) do
    if not SKIP_TYPES[entry.type] and not entry.isSidechain then
      local is_prompt, prompt = user_prompt(entry)
      if is_prompt then
        current = P.turn({
          id = entry.uuid or ("turn-" .. (#turns + 1)),
          idx = #turns + 1,
          prompt = prompt,
          ts = P.to_time(entry.timestamp),
          src = src,
        })
        turns[#turns + 1] = current
      elseif current and entry.message then
        local msg = entry.message
        local content = msg.content
        if msg.role == "assistant" and type(content) == "table" then
          for _, c in ipairs(content) do
            if type(c) ~= "table" then
            -- ignore
            elseif c.type == "text" and c.text and c.text ~= "" then
              current.blocks[#current.blocks + 1] = { kind = "text", text = c.text, uuid = entry.uuid or "" }
            elseif c.type == "thinking" and c.thinking and c.thinking ~= "" then
              current.blocks[#current.blocks + 1] = { kind = "thinking", text = c.thinking, uuid = entry.uuid or "" }
            elseif c.type == "tool_use" then
              local tool = {
                id = c.id or "",
                name = c.name or "?",
                input = c.input or {},
                uuid = entry.uuid or "",
              } ---@type sidekick.review.Tool
              current.tools[#current.tools + 1] = tool
              current.blocks[#current.blocks + 1] = { kind = "tool", tool = tool, uuid = entry.uuid or "" }
              if tool.id ~= "" then
                by_tool_id[tool.id] = tool
              end
            end
          end
        elseif msg.role == "user" and type(content) == "table" then
          -- tool results arrive as user messages; attach them to their call
          for _, c in ipairs(content) do
            if type(c) == "table" and c.type == "tool_result" and c.tool_use_id then
              local tool = by_tool_id[c.tool_use_id]
              if tool then
                tool.error = c.is_error == true
                tool.result = type(c.content) == "string" and c.content or content_text(c.content)
              end
            end
          end
        end
      end
    end
  end

  -- resolve file changes only once tool results are known (errors matter)
  for _, turn in ipairs(turns) do
    for _, tool in ipairs(turn.tools) do
      P.apply_tool(turn, tool)
    end
  end

  return turns
end

return M
