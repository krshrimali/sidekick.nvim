---@brief Locate and parse Claude Code session transcripts (JSONL).
---
--- Claude Code persists every session as a JSONL file under
--- `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Each line is a single
--- entry, most importantly:
---
--- ```json
--- { "type": "assistant", "uuid": "…", "parentUuid": "…", "timestamp": "…",
---   "cwd": "/path", "message": { "role": "assistant", "content": [ … ] } }
--- ```
---
--- Parsing the transcript is *much* more reliable than scraping the terminal
--- scrollback: tool calls keep their structured input, so we can reconstruct
--- exact file edits instead of guessing from rendered output.
local Util = require("sidekick.util")

local M = {}

---@class sidekick.review.Entry
---@field type string
---@field uuid? string
---@field parentUuid? string
---@field timestamp? string
---@field cwd? string
---@field isSidechain? boolean
---@field isMeta? boolean
---@field message? sidekick.review.Message
---@field toolUseResult? any

---@class sidekick.review.Message
---@field role? string
---@field content? string|sidekick.review.Content[]
---@field model? string

---@class sidekick.review.Content
---@field type string
---@field text? string
---@field thinking? string
---@field id? string
---@field name? string
---@field input? table<string, any>
---@field tool_use_id? string
---@field content? any
---@field is_error? boolean

---@class sidekick.review.Source
---@field file string absolute path of the JSONL transcript
---@field session string session id
---@field cwd string project cwd the session belongs to
---@field mtime number
---@field size number

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

---@param path string
---@return string? first non-empty line
local function first_line(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  -- entries are small; 8k is plenty for the first one
  local data = vim.uv.fs_read(fd, 8192, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil
  end
  return data:match("^([^\n]*)")
end

---@param path string
---@return string? cwd
local function transcript_cwd(path)
  local line = first_line(path)
  if not line or line == "" then
    return nil
  end
  local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(entry) ~= "table" then
    return nil
  end
  return entry.cwd
end

---@param dir string
---@param cwd string
---@param out sidekick.review.Source[]
---@param check_cwd boolean
local function collect(dir, cwd, out, check_cwd)
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:sub(-6) == ".jsonl" then
      local file = dir .. "/" .. name
      local stat = vim.uv.fs_stat(file)
      -- an empty transcript carries no turns; skip it early
      if stat and stat.size > 0 then
        local ok = true
        if check_cwd then
          local tcwd = transcript_cwd(file)
          ok = tcwd ~= nil and vim.fs.normalize(tcwd) == cwd
        end
        if ok then
          out[#out + 1] = {
            file = file,
            session = name:sub(1, -7),
            cwd = cwd,
            mtime = stat.mtime.sec + stat.mtime.nsec / 1e9,
            size = stat.size,
          }
        end
      end
    end
  end
end

--- Find all transcripts belonging to `cwd`, newest first.
---@param cwd? string
---@return sidekick.review.Source[]
function M.sources(cwd)
  cwd = vim.fs.normalize(cwd or vim.uv.cwd() or ".")
  local root = M.projects_dir()
  local ret = {} ---@type sidekick.review.Source[]

  local encoded = root .. "/" .. M.encode(cwd)
  if vim.uv.fs_stat(encoded) then
    -- Claude's encoding is lossy, so even the expected directory can contain
    -- transcripts for a different cwd. Always verify the cwd in the file.
    pcall(collect, encoded, cwd, ret, true)
  end

  if #ret == 0 then
    -- slow path: encoding is lossy (`_` and `.` both map to `-`), so fall back
    -- to reading the `cwd` recorded inside each transcript.
    local ok = pcall(function()
      for name, kind in vim.fs.dir(root) do
        if kind == "directory" then
          pcall(collect, root .. "/" .. name, cwd, ret, true)
        end
      end
    end)
    if not ok then
      return ret
    end
  end

  table.sort(ret, function(a, b)
    return a.mtime > b.mtime
  end)
  return ret
end

--- Most recently updated transcript for `cwd`.
---@param cwd? string
---@return sidekick.review.Source?
function M.latest(cwd)
  return M.sources(cwd)[1]
end

--- Find the transcript for a specific session id.
---@param session string
---@param cwd? string
---@return sidekick.review.Source?
function M.by_session(session, cwd)
  for _, src in ipairs(M.sources(cwd)) do
    if src.session == session then
      return src
    end
  end
end

---@param path string
---@return string?
local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

--- Parse a transcript file into entries.
---
--- Malformed lines are skipped rather than aborting the parse: Claude Code
--- appends to this file while we read it, so a torn final line is expected.
---@param path string
---@return sidekick.review.Entry[]
function M.parse(path)
  local data = read_file(path)
  if not data then
    Util.debug("review: could not read transcript " .. path)
    return {}
  end
  local ret = {} ---@type sidekick.review.Entry[]
  for line in data:gmatch("[^\n]+") do
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(entry) == "table" and entry.type then
      ret[#ret + 1] = entry
    end
  end
  return ret
end

return M
