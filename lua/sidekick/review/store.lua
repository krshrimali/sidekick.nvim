---@brief Persistent review state: comments, threads and viewed marks.
---
--- State lives in `stdpath("state")/sidekick/review/<encoded-cwd>.json` so a
--- review survives restarts and keeps its threads attached to the turn they
--- belong to.
local Config = require("sidekick.config")
local Transcript = require("sidekick.review.transcript")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.review.Reply
---@field role "claude"|"user"
---@field body string
---@field ts number
---@field turn? string turn the reply came from

---@class sidekick.review.Comment
---@field id string stable id, e.g. `c7`
---@field turn string turn id the comment was left on
---@field target "response"|"file"
---@field file? string absolute path (target == "file")
---@field rel? string display path
---@field lnum? integer first line of the anchor
---@field end_lnum? integer last line of the anchor
---@field side? "new"|"old" which side of the diff the anchor is on
---@field anchor_key? string stable anchor id: `new:42` for diffs, `b3:7` for a response block
---@field anchor string[] quoted source lines
---@field body string what the user wrote
---@field status "pending"|"sent"|"resolved"
---@field created number
---@field sent_at? number
---@field replies sidekick.review.Reply[]

---@class sidekick.review.Data
---@field version integer
---@field seq integer
---@field comments sidekick.review.Comment[]
---@field viewed table<string, table<string, boolean>> turn id -> item key -> viewed

---@class sidekick.review.Store
---@field cwd string
---@field file string
---@field data sidekick.review.Data
local Store = {}
Store.__index = Store

M.VERSION = 1

--- Key used for the "response" pseudo-file in `viewed`.
M.RESPONSE = "@response"

local cache = {} ---@type table<string, sidekick.review.Store>

--- Where review state is written. Overridable so tests stay off the real one.
---@type string?
M.root = nil

---@return string
local function dir()
  return M.root or Config.state("review")
end

---@param cwd string
---@return string
local function filename(cwd)
  -- Keep the readable prefix, but add the normalized path hash since Claude's
  -- directory encoding maps distinct paths such as `a_b` and `a-b` together.
  return ("%s-%s.json"):format(Transcript.encode(cwd), vim.fn.sha256(cwd):sub(1, 16))
end

---@param cwd? string
---@return sidekick.review.Store
function M.get(cwd)
  cwd = vim.fs.normalize(cwd or vim.uv.cwd() or ".")
  if cache[cwd] then
    return cache[cwd]
  end
  local self = setmetatable({
    cwd = cwd,
    file = dir() .. "/" .. filename(cwd),
  }, Store)
  self:load()
  cache[cwd] = self
  return self
end

--- Drop cached stores. Used by tests.
function M.reset()
  cache = {}
end

---@return sidekick.review.Data
local function empty()
  return { version = M.VERSION, seq = 0, comments = {}, viewed = {} }
end

function Store:load()
  self.data = empty()
  local fd = vim.uv.fs_open(self.file, "r", 438)
  if not fd then
    return
  end
  local stat = vim.uv.fs_fstat(fd)
  local raw = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  if not raw or raw == "" then
    return
  end
  local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    Util.warn("sidekick.review: ignoring corrupt review state at " .. self.file)
    return
  end
  data.version = data.version or M.VERSION
  data.seq = data.seq or 0
  data.comments = data.comments or {}
  data.viewed = data.viewed or {}
  for _, c in ipairs(data.comments) do
    c.replies = c.replies or {}
    c.anchor = c.anchor or {}
  end
  self.data = data
end

function Store:save()
  vim.fn.mkdir(dir(), "p")
  local ok, encoded = pcall(vim.json.encode, self.data)
  if not ok then
    Util.error("sidekick.review: failed to encode review state")
    return
  end
  local tmp = self.file .. ".tmp"
  local fd = vim.uv.fs_open(tmp, "w", 420)
  if not fd then
    Util.error("sidekick.review: cannot write " .. tmp)
    return
  end
  local written = vim.uv.fs_write(fd, encoded, 0)
  vim.uv.fs_close(fd)
  if written ~= #encoded then
    vim.uv.fs_unlink(tmp)
    Util.error("sidekick.review: incomplete write to " .. tmp)
    return
  end
  local ok_rename, err = vim.uv.fs_rename(tmp, self.file)
  if not ok_rename then
    vim.uv.fs_unlink(tmp)
    Util.error("sidekick.review: cannot replace " .. self.file .. ": " .. tostring(err))
  end
end

---@param comment sidekick.review.Comment|{id?:string, status?:string, replies?:sidekick.review.Reply[]}
---@return sidekick.review.Comment
function Store:add(comment)
  self.data.seq = self.data.seq + 1
  comment.id = comment.id or ("c" .. self.data.seq)
  comment.status = comment.status or "pending"
  comment.created = comment.created or os.time()
  comment.replies = comment.replies or {}
  comment.anchor = comment.anchor or {}
  self.data.comments[#self.data.comments + 1] = comment --[[@as sidekick.review.Comment]]
  self:save()
  return comment --[[@as sidekick.review.Comment]]
end

---@param id string
---@return sidekick.review.Comment?
function Store:find(id)
  for _, c in ipairs(self.data.comments) do
    if c.id == id then
      return c
    end
  end
end

---@param id string
---@return boolean
function Store:remove(id)
  for i, c in ipairs(self.data.comments) do
    if c.id == id then
      table.remove(self.data.comments, i)
      self:save()
      return true
    end
  end
  return false
end

---@param id string
---@param body string
---@return boolean
function Store:edit(id, body)
  local c = self:find(id)
  if not c then
    return false
  end
  c.body = body
  self:save()
  return true
end

---@param id string
---@param reply sidekick.review.Reply
function Store:reply(id, reply)
  local c = self:find(id)
  if not c then
    return false
  end
  c.replies[#c.replies + 1] = reply
  self:save()
  return true
end

---@param id string
---@param status "pending"|"sent"|"resolved"
function Store:set_status(id, status)
  local c = self:find(id)
  if not c then
    return false
  end
  c.status = status
  if status == "sent" then
    c.sent_at = os.time()
  end
  self:save()
  return true
end

--- All comments for a turn, optionally narrowed to a file (or the response).
---@param turn string
---@param opts? {file?:string, target?:"response"|"file", status?:string}
---@return sidekick.review.Comment[]
function Store:for_turn(turn, opts)
  opts = opts or {}
  local ret = {} ---@type sidekick.review.Comment[]
  for _, c in ipairs(self.data.comments) do
    if
      c.turn == turn
      and (opts.target == nil or c.target == opts.target)
      and (opts.file == nil or c.file == opts.file)
      and (opts.status == nil or c.status == opts.status)
    then
      ret[#ret + 1] = c
    end
  end
  -- response comments read like the PR description, so they come first; file
  -- comments then group by path and run top-to-bottom like a diff review
  table.sort(ret, function(a, b)
    if a.target ~= b.target then
      return a.target == "response"
    end
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    if (a.lnum or 0) ~= (b.lnum or 0) then
      return (a.lnum or 0) < (b.lnum or 0)
    end
    return a.created < b.created
  end)
  return ret
end

---@param status? string
---@return sidekick.review.Comment[]
function Store:all(status)
  if not status then
    return self.data.comments
  end
  return vim.tbl_filter(function(c)
    return c.status == status
  end, self.data.comments)
end

---@return integer
function Store:pending_count()
  return #self:all("pending")
end

---@param turn string
---@param key string file path or `@response`
---@return boolean
function Store:is_viewed(turn, key)
  return (self.data.viewed[turn] or {})[key] == true
end

---@param turn string
---@param key string
---@param value? boolean toggles when nil
---@return boolean new value
function Store:set_viewed(turn, key, value)
  self.data.viewed[turn] = self.data.viewed[turn] or {}
  if value == nil then
    value = not self.data.viewed[turn][key]
  end
  self.data.viewed[turn][key] = value or nil
  self:save()
  return value
end

--- Forget everything about a turn. Used by `:Sidekick review clear`.
---@param turn? string clears all turns when nil
function Store:clear(turn)
  if turn then
    self.data.comments = vim.tbl_filter(function(c)
      return c.turn ~= turn
    end, self.data.comments)
    self.data.viewed[turn] = nil
  else
    self.data = empty()
  end
  self:save()
end

M.Store = Store

return M
