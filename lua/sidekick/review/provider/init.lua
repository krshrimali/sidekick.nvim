---@brief Provider registry and the pieces every provider shares.
---
--- A provider knows two things: where a CLI keeps its session transcripts, and
--- how to turn one of those transcripts into `sidekick.review.Turn[]`.
--- Everything downstream — diffing, comments, threading, rendering — is
--- provider agnostic.
local Util = require("sidekick.util")

local M = {}

---@class sidekick.review.Provider
---@field name string tool name, matching `cli.tools`
---@field label string human readable
---@field sources fun(cwd:string):sidekick.review.Source[]
---@field build fun(src:sidekick.review.Source):sidekick.review.Turn[]

---@type string[]
M.names = { "claude", "codex" }

---@param name string
---@return sidekick.review.Provider?
function M.get(name)
  local ok, provider = pcall(require, "sidekick.review.provider." .. name)
  if not ok then
    Util.debug("review: no provider named " .. name)
    return nil
  end
  return provider
end

---@return sidekick.review.Provider[]
function M.all()
  local ret = {} ---@type sidekick.review.Provider[]
  for _, name in ipairs(M.names) do
    local p = M.get(name)
    if p then
      ret[#ret + 1] = p
    end
  end
  return ret
end

--------------------------------------------------------------------------------
-- shared turn construction
--------------------------------------------------------------------------------

--- Tools that mutate files, mapped to the input key holding the path.
M.EDIT_TOOLS = {
  Edit = "file_path",
  Write = "file_path",
  MultiEdit = "file_path",
  NotebookEdit = "notebook_path",
}

---@param ts? string ISO-8601
---@return number
function M.to_time(ts)
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

---@param text string
---@return integer
function M.count_lines(text)
  if text == "" then
    return 0
  end
  local n = 1
  for _ in text:gmatch("\n") do
    n = n + 1
  end
  return n
end

--- Strip the noise a CLI injects into user messages so the turn title reflects
--- what the user actually typed.
---@param text string
---@return string
function M.clean_prompt(text)
  text = text:gsub("<system%-reminder>.-</system%-reminder>", "")
  text = text:gsub("<local%-command%-stdout>.-</local%-command%-stdout>", "")
  text = text:gsub("<command%-message>.-</command%-message>", "")
  text = text:gsub("<environment_context>.-</environment_context>", "")
  text = text:gsub("<user_instructions>.-</user_instructions>", "")

  -- slash commands arrive as separate name/args tags; fold them onto one line
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

  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param prompt string
---@return string
function M.make_title(prompt)
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

--- Start a new turn.
---@param opts {id:string, idx:integer, prompt:string, ts:number, src:sidekick.review.Source}
---@return sidekick.review.Turn
function M.turn(opts)
  return {
    id = opts.id,
    idx = opts.idx,
    prompt = opts.prompt,
    title = M.make_title(opts.prompt),
    ts = opts.ts,
    blocks = {},
    tools = {},
    files = {},
    session = opts.src.session,
    cwd = opts.src.cwd,
    provider = opts.src.provider,
    pending = false,
  }
end

--- Find or create the file entry a change belongs to.
---@param turn sidekick.review.Turn
---@param path string
---@return sidekick.review.FileChange
function M.file(turn, path)
  path = vim.fs.normalize(path)
  if not path:match("^/") then
    path = vim.fs.normalize(turn.cwd .. "/" .. path)
  end
  for _, f in ipairs(turn.files) do
    if f.path == path then
      return f
    end
  end
  local file = {
    path = path,
    rel = vim.fs.relpath(turn.cwd, path) or path,
    changes = {},
    added = 0,
    removed = 0,
    created = false,
    deleted = false,
  } ---@type sidekick.review.FileChange
  turn.files[#turn.files + 1] = file
  return file
end

--- Record one `old -> new` replacement on a file.
---@param file sidekick.review.FileChange
---@param opts {old:string, new:string, kind?:"edit"|"write", replace_all?:boolean, tool_id?:string}
function M.change(file, opts)
  file.changes[#file.changes + 1] = {
    kind = opts.kind or "edit",
    old = opts.old,
    new = opts.new,
    replace_all = opts.replace_all,
    tool_id = opts.tool_id or "",
  }
  file.added = file.added + M.count_lines(opts.new)
  file.removed = file.removed + M.count_lines(opts.old)
end

--- Apply a Claude-style edit tool call to a turn.
---@param turn sidekick.review.Turn
---@param tool sidekick.review.Tool
function M.apply_tool(turn, tool)
  local key = M.EDIT_TOOLS[tool.name]
  if not key or tool.error then
    return -- a failed edit changed nothing
  end
  local path = tool.input and tool.input[key]
  if type(path) ~= "string" or path == "" then
    return
  end

  local file = M.file(turn, path)
  local input = tool.input or {}

  if tool.name == "Write" then
    local created = type(tool.result) == "string" and tool.result:lower():find("created", 1, true) ~= nil
    file.created = file.created or (created and #file.changes == 0)
    M.change(file, { old = "", new = input.content or "", kind = "write", tool_id = tool.id })
  elseif tool.name == "MultiEdit" then
    for _, e in ipairs(input.edits or {}) do
      if type(e) == "table" then
        M.change(file, {
          old = e.old_string or "",
          new = e.new_string or "",
          replace_all = e.replace_all,
          tool_id = tool.id,
        })
      end
    end
  elseif tool.name == "NotebookEdit" then
    M.change(file, { old = input.old_source or "", new = input.new_source or "", tool_id = tool.id })
  else -- Edit
    M.change(file, {
      old = input.old_string or "",
      new = input.new_string or "",
      replace_all = input.replace_all,
      tool_id = tool.id,
    })
  end
end

--- Apply a parsed Codex-style patch to a turn.
---@param turn sidekick.review.Turn
---@param files sidekick.review.PatchFile[]
---@param tool_id? string
function M.apply_patch(turn, files, tool_id)
  for _, pf in ipairs(files) do
    local file = M.file(turn, pf.path)
    if pf.action == "add" then
      file.created = file.created or #file.changes == 0
    elseif pf.action == "delete" then
      file.deleted = true
    end
    for _, c in ipairs(pf.changes) do
      M.change(file, { old = c.old, new = c.new, kind = pf.action == "add" and "write" or "edit", tool_id = tool_id })
    end
  end
end

return M
