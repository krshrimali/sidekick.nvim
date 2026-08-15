---@brief Turn a flat transcript into reviewable "pull requests".
---
--- One **turn** = one user prompt plus everything Claude did in response to it.
--- That is the unit the review UI treats as a PR: it has a title (the prompt),
--- a description (Claude's prose), and a set of changed files.
local Transcript = require("sidekick.review.transcript")

local M = {}

---@class sidekick.review.Block
---@field kind "text"|"thinking"|"tool"
---@field text? string
---@field tool? sidekick.review.Tool
---@field uuid string

---@class sidekick.review.Tool
---@field id string
---@field name string
---@field input table<string, any>
---@field result? string
---@field error? boolean
---@field uuid string

---@class sidekick.review.Change a single edit applied to a file
---@field kind "edit"|"write"
---@field old string content that was replaced ("" for a new file)
---@field new string replacement content
---@field replace_all? boolean
---@field tool_id string

---@class sidekick.review.FileChange
---@field path string absolute path
---@field rel string path relative to cwd
---@field changes sidekick.review.Change[]
---@field added integer
---@field removed integer
---@field created boolean file did not exist before this turn

---@class sidekick.review.Turn
---@field id string uuid of the user prompt entry
---@field idx integer 1-based turn number within the session
---@field prompt string the user's message
---@field title string one-line summary of the prompt
---@field ts number unix timestamp (seconds)
---@field blocks sidekick.review.Block[]
---@field tools sidekick.review.Tool[]
---@field files sidekick.review.FileChange[]
---@field session string
---@field cwd string
---@field pending boolean true while Claude may still be appending to this turn

---@class sidekick.review.Transcript
---@field session string
---@field file string
---@field cwd string
---@field turns sidekick.review.Turn[]
---@field mtime number

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

--- Tools that mutate files, mapped to the input key holding the path.
M.EDIT_TOOLS = {
  Edit = "file_path",
  Write = "file_path",
  MultiEdit = "file_path",
  NotebookEdit = "notebook_path",
}

---@param ts? string ISO-8601
---@return number
local function to_time(ts)
  if type(ts) ~= "string" then
    return 0
  end
  local y, mo, d, h, mi, s = ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return 0
  end
  -- transcript timestamps are UTC; convert to a local epoch for display
  local utc = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  local offset = os.difftime(os.time(os.date("*t", utc)), os.time(os.date("!*t", utc)))
  return utc + offset
end

---@param content string|sidekick.review.Content[]|nil
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

--- Strip the noise Claude Code injects into user messages so the turn title
--- reflects what the user actually typed.
---@param text string
---@return string
function M.clean_prompt(text)
  text = text:gsub("<system%-reminder>.-</system%-reminder>", "")
  text = text:gsub("<local%-command%-stdout>.-</local%-command%-stdout>", "")
  text = text:gsub("<command%-message>.-</command%-message>", "")

  -- slash commands arrive as separate name/args tags; fold them onto one line
  -- so the turn title reads like what the user typed
  local name = text:match("<command%-name>%s*(.-)%s*</command%-name>")
  local args = text:match("<command%-args>%s*(.-)%s*</command%-args>")
  if name then
    local cmd = "/" .. (name:gsub("^/", ""))
    if args and args ~= "" then
      cmd = cmd .. " " .. args
    end
    text = text:gsub("<command%-name>.-</command%-name>", "", 1)
    text = text:gsub("<command%-args>.-</command%-args>", "", 1)
    text = cmd .. "\n" .. text
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

--- A user entry is a real prompt only when it carries prose the user wrote.
---@param entry sidekick.review.Entry
---@return boolean, string
local function user_prompt(entry)
  local msg = entry.message
  if not msg or msg.role ~= "user" then
    return false, ""
  end
  if entry.isMeta then
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
  local text = M.clean_prompt(content_text(content))
  if text == "" then
    return false, ""
  end
  return true, text
end

---@param text string
---@return integer
local function count_lines(text)
  if text == "" then
    return 0
  end
  local n = 1
  for _ in text:gmatch("\n") do
    n = n + 1
  end
  return n
end

---@param turn sidekick.review.Turn
---@param tool sidekick.review.Tool
local function add_change(turn, tool)
  local key = M.EDIT_TOOLS[tool.name]
  if not key then
    return
  end
  local path = tool.input and tool.input[key]
  if type(path) ~= "string" or path == "" then
    return
  end
  if tool.error then
    return -- a failed edit changed nothing
  end
  path = vim.fs.normalize(path)
  if not path:match("^/") then
    path = vim.fs.normalize(turn.cwd .. "/" .. path)
  end

  local file ---@type sidekick.review.FileChange?
  for _, f in ipairs(turn.files) do
    if f.path == path then
      file = f
      break
    end
  end
  if not file then
    file = {
      path = path,
      rel = vim.fs.relpath(turn.cwd, path) or path,
      changes = {},
      added = 0,
      removed = 0,
      created = false,
    }
    turn.files[#turn.files + 1] = file
  end

  ---@param old string
  ---@param new string
  ---@param kind "edit"|"write"
  ---@param replace_all? boolean
  local function push(old, new, kind, replace_all)
    file.changes[#file.changes + 1] = {
      kind = kind,
      old = old,
      new = new,
      replace_all = replace_all,
      tool_id = tool.id,
    }
    file.added = file.added + count_lines(new)
    file.removed = file.removed + count_lines(old)
  end

  local input = tool.input or {}
  if tool.name == "Write" then
    -- `Write` on a path that never existed is a file creation. The tool result
    -- says so; fall back to "not on disk before" being unknowable and treat a
    -- write as a full replacement.
    local created = type(tool.result) == "string" and tool.result:lower():find("created", 1, true) ~= nil
    file.created = file.created or (created and #file.changes == 0)
    push("", input.content or "", "write")
  elseif tool.name == "MultiEdit" then
    for _, e in ipairs(input.edits or {}) do
      if type(e) == "table" then
        push(e.old_string or "", e.new_string or "", "edit", e.replace_all)
      end
    end
  elseif tool.name == "NotebookEdit" then
    push(input.old_source or "", input.new_source or "", "edit")
  else -- Edit
    push(input.old_string or "", input.new_string or "", "edit", input.replace_all)
  end
end

---@param prompt string
---@return string
local function make_title(prompt)
  local line = prompt:match("^[^\n]*") or ""
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then
    line = (prompt:gsub("%s+", " "):gsub("^%s+", ""))
  end
  if vim.fn.strchars(line) > 72 then
    line = vim.fn.strcharpart(line, 0, 71) .. "…"
  end
  return line ~= "" and line or "(empty prompt)"
end

--- Build the turn list for a transcript source.
---@param src sidekick.review.Source
---@return sidekick.review.Transcript
function M.build(src)
  local entries = Transcript.parse(src.file)
  local turns = {} ---@type sidekick.review.Turn[]
  local by_tool_id = {} ---@type table<string, sidekick.review.Tool>
  local current ---@type sidekick.review.Turn?

  for _, entry in ipairs(entries) do
    if not SKIP_TYPES[entry.type] and not entry.isSidechain then
      local is_prompt, prompt = user_prompt(entry)
      if is_prompt then
        current = {
          id = entry.uuid or ("turn-" .. (#turns + 1)),
          idx = #turns + 1,
          prompt = prompt,
          title = make_title(prompt),
          ts = to_time(entry.timestamp),
          blocks = {},
          tools = {},
          files = {},
          session = src.session,
          cwd = src.cwd,
          pending = false,
        }
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
      add_change(turn, tool)
    end
  end

  if turns[#turns] then
    turns[#turns].pending = true
  end

  return {
    session = src.session,
    file = src.file,
    cwd = src.cwd,
    turns = turns,
    mtime = src.mtime,
  }
end

--- Load the newest transcript for `cwd`.
---@param cwd? string
---@param session? string
---@return sidekick.review.Transcript?
function M.load(cwd, session)
  local src = session and Transcript.by_session(session, cwd) or Transcript.latest(cwd)
  if not src then
    return nil
  end
  return M.build(src)
end

return M
