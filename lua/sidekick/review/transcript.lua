---@brief Locate and read AI CLI session transcripts.
---
--- Every supported CLI persists its session as JSONL. Parsing that is far more
--- reliable than scraping the terminal scrollback: tool calls keep their
--- structured input, so exact file edits can be reconstructed instead of being
--- guessed from rendered output.
---
--- Where those files live and what the entries mean is provider specific; see
--- `sidekick.review.provider`.
local Provider = require("sidekick.review.provider")
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
---@field message? table Claude message
---@field payload? table Codex event payload

---@class sidekick.review.Source
---@field file string absolute path of the JSONL transcript
---@field session string session id
---@field cwd string project cwd the session belongs to
---@field provider string which CLI wrote it
---@field mtime number
---@field size number

---@param path string
---@param max? integer read at most this many bytes
---@return string?
function M.read(path, max)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local size = stat and stat.size or 0
  local data = size > 0 and vim.uv.fs_read(fd, math.min(size, max or size), 0) or nil
  vim.uv.fs_close(fd)
  return data
end

---@param line string
---@return sidekick.review.Entry?
local function decode(line)
  local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(entry) == "table" and entry.type then
    return entry
  end
  return nil
end

--- Read just the first line, growing the read only while it has to.
---
--- Identifying a transcript needs one line, but a session header can carry an
--- instruction blob, so the line is not always small. Reading a fixed large
--- chunk means scanning megabytes across a directory of past sessions to
--- learn which project each belongs to.
---@param path string
---@return string?
function M.first_line(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local size = (vim.uv.fs_fstat(fd) or {}).size or 0
  local out, offset, chunk = "", 0, 8192

  while offset < size do
    local data = vim.uv.fs_read(fd, math.min(chunk, size - offset), offset)
    if not data or data == "" then
      break
    end
    local nl = data:find("\n", 1, true)
    if nl then
      out = out .. data:sub(1, nl - 1)
      break
    end
    out = out .. data
    offset = offset + #data
    -- a header this long is pathological; stop rather than read the whole file
    if #out > 1048576 then
      break
    end
    chunk = chunk * 2
  end

  vim.uv.fs_close(fd)
  return out ~= "" and out or nil
end

--- Identity of a transcript, keyed by file and validated by size and mtime.
---
--- Which project a session belongs to never changes, so scanning a directory
--- of past sessions should cost one read per file, once — not on every refresh.
---@type table<string, {size:number, mtime:number, entry?:sidekick.review.Entry}>
local first_entries = {}

--- Forget cached transcript identities. Used by tests.
function M.clear_cache()
  first_entries = {}
  cwds = {}
end

--- Decode just the first entry. Used to identify a transcript cheaply.
---@param path string
---@param stat? uv.fs_stat.result
---@return sidekick.review.Entry?
function M.first_entry(path, stat)
  stat = stat or vim.uv.fs_stat(path)
  local size = stat and stat.size or 0
  local mtime = stat and (stat.mtime.sec + stat.mtime.nsec / 1e9) or 0

  local hit = first_entries[path]
  if hit and hit.size == size and hit.mtime == mtime then
    return hit.entry
  end

  local line = M.first_line(path)
  local entry = line and decode(line) or nil
  first_entries[path] = { size = size, mtime = mtime, entry = entry }
  return entry
end

--- The project a transcript belongs to.
---
--- Not every format puts it on the first line: Claude opens with session
--- metadata that carries no cwd, and only later entries have one. So scan a
--- bounded prefix rather than trusting the first entry, and cache the answer
--- -- which project a session belongs to never changes.
---@type table<string, {size:number, mtime:number, cwd?:string}>
local cwds = {}

---@param path string
---@param stat? uv.fs_stat.result
---@return string?
function M.cwd_of(path, stat)
  stat = stat or vim.uv.fs_stat(path)
  local size = stat and stat.size or 0
  local mtime = stat and (stat.mtime.sec + stat.mtime.nsec / 1e9) or 0

  local hit = cwds[path]
  if hit and hit.size == size and hit.mtime == mtime then
    return hit.cwd
  end

  local found ---@type string?
  local data = M.read(path, 262144)
  for line in (data or ""):gmatch("[^\n]+") do
    local entry = decode(line)
    -- Claude records it per entry; Codex puts it in the session header
    local c = entry and (entry.cwd or (type(entry.payload) == "table" and entry.payload.cwd))
    if type(c) == "string" and c ~= "" then
      found = vim.fs.normalize(c)
      break
    end
  end

  cwds[path] = { size = size, mtime = mtime, cwd = found }
  return found
end

--- Parse a transcript file into entries.
---
--- Malformed lines are skipped rather than aborting the parse: the CLI appends
--- to this file while we read it, so a torn final line is expected.
---@param path string
---@return sidekick.review.Entry[]
function M.parse(path)
  local data = M.read(path)
  if not data then
    Util.debug("review: could not read transcript " .. path)
    return {}
  end
  local ret = {} ---@type sidekick.review.Entry[]
  for line in data:gmatch("[^\n]+") do
    local entry = decode(line)
    if entry then
      ret[#ret + 1] = entry
    end
  end
  return ret
end

--- Find every transcript belonging to `cwd`, newest first.
---@param cwd? string
---@param opts? {provider?:string}
---@return sidekick.review.Source[]
function M.sources(cwd, opts)
  opts = opts or {}
  cwd = vim.fs.normalize(cwd or vim.uv.cwd() or ".")
  local ret = {} ---@type sidekick.review.Source[]

  for _, provider in ipairs(Provider.all()) do
    if not opts.provider or opts.provider == provider.name then
      local ok, sources = pcall(provider.sources, cwd)
      if ok and type(sources) == "table" then
        vim.list_extend(ret, sources)
      elseif not ok then
        Util.debug("review: provider " .. provider.name .. " failed: " .. tostring(sources))
      end
    end
  end

  table.sort(ret, function(a, b)
    return a.mtime > b.mtime
  end)
  return ret
end

--- Most recently updated transcript for `cwd`.
---@param cwd? string
---@param opts? {provider?:string}
---@return sidekick.review.Source?
function M.latest(cwd, opts)
  return M.sources(cwd, opts)[1]
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

--- Claude Code's cwd encoding. Kept here because the review state file reuses
--- it as a stable, readable project key for every provider.
---@param cwd string
---@return string
function M.encode(cwd)
  return (vim.fs.normalize(cwd):gsub("[^%w]", "-"))
end

return M
