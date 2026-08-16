---@brief Codex CLI rollouts (`~/.codex/sessions/<y>/<m>/<d>/rollout-*.jsonl`).
---
--- Codex records a flat event log. The parts that matter here:
---
--- * `session_meta`  — `payload.cwd`, `payload.id`
--- * `turn_context`  — `payload.cwd` (a session can move between workspaces)
--- * `response_item` — `payload.type`:
---     * `message` with a `role` and `content[].text`
---     * `custom_tool_call` / `function_call` with `input` / `arguments`
---     * `custom_tool_call_output` / `function_call_output`
---     * `reasoning` (usually encrypted; only `summary` is readable)
---
--- File edits are not structured: they arrive as an `apply_patch` document,
--- either as the tool input directly or embedded in a JavaScript snippet.
--- `sidekick.review.patch` turns those into the same `old -> new` changes
--- Claude's `Edit` tool produces.
local P = require("sidekick.review.provider")
local Patch = require("sidekick.review.patch")
local Transcript = require("sidekick.review.transcript")

---@type sidekick.review.Provider
local M = {}

M.name = "codex"
M.label = "Codex CLI"

--- Root of Codex's session storage. Overridable for tests.
---@type string?
M.root = nil

function M.sessions_dir()
  if M.root then
    return M.root
  end
  local home = vim.env.CODEX_HOME or (vim.uv.os_homedir() .. "/.codex")
  return vim.fs.normalize(home .. "/sessions")
end

--- `developer` messages are the system prompt; they are never user input.
local SKIP_ROLES = { developer = true, system = true, tool = true }

---@param content any
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
    if type(c) == "table" and type(c.text) == "string" then
      parts[#parts + 1] = c.text
    elseif type(c) == "string" then
      parts[#parts + 1] = c
    end
  end
  return table.concat(parts, "\n")
end

--- Codex delivers project context as ordinary user messages: the environment
--- block, the skill list, and the repository's AGENTS.md wrapped in
--- `<INSTRUCTIONS>`. None of it is something the user typed, so none of it
--- should open a turn.
---@param text string
---@return boolean
local function is_noise(text)
  return text == ""
    or text:match("^%s*<environment_context>") ~= nil
    or text:match("^%s*<user_instructions>") ~= nil
    or text:match("^%s*<skills_instructions>") ~= nil
    or text:match("^%s*<multi_agent_mode>") ~= nil
    or text:match("^%s*<[%w_]+_instructions>") ~= nil
    or text:match("^%s*<INSTRUCTIONS>") ~= nil
    -- "# AGENTS.md instructions for /path" followed by the file's contents
    or text:match("^%s*#%s*[%w_.-]+%.md instructions for ") ~= nil
    or text:find("<INSTRUCTIONS>", 1, true) ~= nil
end

---@param dir string
---@param out string[]
local function walk(dir, out)
  local ok = pcall(function()
    for name, kind in vim.fs.dir(dir) do
      local path = dir .. "/" .. name
      if kind == "directory" then
        walk(path, out)
      elseif kind == "file" and name:sub(-6) == ".jsonl" then
        out[#out + 1] = path
      end
    end
  end)
  return ok
end

--- Whether a rollout later moved into `cwd` via a `turn_context`.
---
--- Cached per file, like the header lookup: a session that changed workspace
--- is uncommon, and re-reading every past rollout on every refresh is exactly
--- what the header scan exists to avoid.
---@type table<string, {size:number, moved:table<string, boolean>}>
local moved = {}

---@param file string
---@param cwd string
---@return boolean
function M.moved_into(file, cwd)
  local stat = vim.uv.fs_stat(file)
  local size = stat and stat.size or 0
  local hit = moved[file]
  if not hit or hit.size ~= size then
    hit = { size = size, moved = {} }
    -- one pass, collecting every workspace the session ever reported
    for _, entry in ipairs(Transcript.parse(file)) do
      if entry.type == "turn_context" and type(entry.payload) == "table" then
        local c = entry.payload.cwd
        if type(c) == "string" then
          hit.moved[vim.fs.normalize(c)] = true
        end
      end
    end
    moved[file] = hit
  end
  return hit.moved[cwd] == true
end

--- Forget cached workspace moves. Used by tests.
function M.clear_cache()
  moved = {}
end

---@param cwd? string
---@return sidekick.review.Source[]
function M.sources(cwd)
  local root = M.sessions_dir()
  if not vim.uv.fs_stat(root) then
    return {}
  end

  local files = {} ---@type string[]
  walk(root, files)

  local ret = {} ---@type sidekick.review.Source[]
  for _, file in ipairs(files) do
    local stat = vim.uv.fs_stat(file)
    if stat and stat.size > 0 then
      -- rollouts are not namespaced by project, so the cwd has to be read out
      -- of the session_meta on the first line
      local entry = Transcript.first_entry(file, stat)
      local meta = entry and entry.payload or nil
      local found = Transcript.cwd_of(file, stat)
      local match = cwd == nil and found ~= nil or found == cwd

      -- a session can move between workspaces mid-run, recording the new one in
      -- a `turn_context`. Reading the whole file to find that would undo the
      -- cheap scan, so only look when the header did not already match and the
      -- project is plausibly in there at all.
      if cwd and not match and M.moved_into(file, cwd) then
        match = true
      end

      if match then
        local name = vim.fn.fnamemodify(file, ":t:r")
        ret[#ret + 1] = {
          file = file,
          session = type(meta.id) == "string" and meta.id or name,
          cwd = found or cwd,
          provider = M.name,
          mtime = stat.mtime.sec + stat.mtime.nsec / 1e9,
          size = stat.size,
        }
      end
    end
  end
  return ret
end

---@param payload table
---@return string name, string input
local function tool_call(payload)
  local name = payload.name or "?"
  local input = payload.input or payload.arguments or ""
  if type(input) ~= "string" then
    input = vim.json.encode(input) or ""
  end
  return name, input
end

---@param src sidekick.review.Source
---@return sidekick.review.Turn[]
function M.build(src)
  local entries = Transcript.parse(src.file)
  local turns = {} ---@type sidekick.review.Turn[]
  local by_call_id = {} ---@type table<string, sidekick.review.Tool>
  local current ---@type sidekick.review.Turn?

  for _, entry in ipairs(entries) do
    -- `event_msg` duplicates `response_item` for the UI; ignore it entirely
    if entry.type == "response_item" and type(entry.payload) == "table" then
      local p = entry.payload
      local ts = P.to_time(entry.timestamp)

      if p.type == "message" and not SKIP_ROLES[p.role or ""] then
        local text = content_text(p.content)
        if p.role == "user" then
          local prompt = P.clean_prompt(text)
          if not is_noise(prompt) then
            current = P.turn({
              id = p.id or P.fallback_id(src, #turns + 1),
              idx = #turns + 1,
              prompt = prompt,
              ts = ts,
              src = src,
            })
            turns[#turns + 1] = current
          end
        elseif p.role == "assistant" and current and text ~= "" then
          current.blocks[#current.blocks + 1] = { kind = "text", text = text, uuid = p.id or "" }
        end
      elseif p.type == "reasoning" and current then
        -- `encrypted_content` is opaque; only the summary is ever readable
        local summary = content_text(p.summary)
        if summary ~= "" then
          current.blocks[#current.blocks + 1] = { kind = "thinking", text = summary, uuid = p.id or "" }
        end
      elseif (p.type == "custom_tool_call" or p.type == "function_call") and current then
        local name, input = tool_call(p)
        local files = Patch.files(input)
        local tool = {
          id = p.call_id or p.id or "",
          -- surface a patch as its own tool so the response reads clearly
          name = #files > 0 and "apply_patch" or name,
          input = { command = input, patch_files = #files > 0 and files or nil },
          uuid = p.id or "",
        } ---@type sidekick.review.Tool
        current.tools[#current.tools + 1] = tool
        current.blocks[#current.blocks + 1] = { kind = "tool", tool = tool, uuid = p.id or "" }
        if tool.id ~= "" then
          by_call_id[tool.id] = tool
        end
      elseif (p.type == "custom_tool_call_output" or p.type == "function_call_output") and p.call_id then
        local tool = by_call_id[p.call_id]
        if tool then
          local out = p.output
          tool.result = type(out) == "string" and out or content_text(out)
          tool.error = tool.result:match("^%s*error") ~= nil or p.status == "failed"
        end
      end
    end
  end

  for _, turn in ipairs(turns) do
    for _, tool in ipairs(turn.tools) do
      local files = tool.input and tool.input.patch_files
      if files and not tool.error then
        P.apply_patch(turn, files, tool.id)
      end
    end
  end

  return turns
end

return M
