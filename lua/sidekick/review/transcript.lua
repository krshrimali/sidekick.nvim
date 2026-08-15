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

--- Decode just the first entry. Used to identify a transcript cheaply.
---@param path string
---@return sidekick.review.Entry?
function M.first_entry(path)
  -- session headers are small, but Codex's `session_meta` carries an
  -- instruction blob, so read generously before giving up
  local data = M.read(path, 262144)
  if not data then
    return nil
  end
  local line = data:match("^([^\n]*)")
  return line and line ~= "" and decode(line) or nil
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
