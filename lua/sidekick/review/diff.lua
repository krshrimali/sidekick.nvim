---@brief Reconstruct per-turn file diffs from recorded tool calls.
---
--- The transcript stores each `Edit` as `old_string` -> `new_string`, which is
--- enough to rebuild what a file looked like before and after a turn:
---
---   * start from the file as it is on disk *now*
---   * walk turns newest -> oldest, undoing each edit (`new` -> `old`)
---
--- The state right before we undo a turn's edits is that turn's "after"
--- content; the state right after is its "before". When the chain breaks
--- (the file was hand-edited since, or a `Write` wiped unknown content) we
--- degrade to showing each recorded edit as a standalone hunk instead of
--- inventing line numbers.

local M = {}

---@class sidekick.review.DiffLine
---@field kind "context"|"add"|"del"
---@field text string
---@field old_lnum? integer
---@field new_lnum? integer

---@class sidekick.review.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines sidekick.review.DiffLine[]

---@class sidekick.review.FileDiff
---@field path string
---@field rel string
---@field hunks sidekick.review.Hunk[]
---@field added integer
---@field removed integer
---@field created boolean
---@field deleted boolean the file was removed by this turn
---@field approx boolean line numbers could not be verified against disk
---@field binary boolean
---@field missing boolean file is not on disk
---@field filetype? string

M.ctxlen = 3

---@param path string
---@return string?
function M.read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data
end

--- Replace the *last* occurrence of `needle` in `hay` with `sub`.
--- Undoing edits newest-first means the trailing match is the right one.
---@param hay string
---@param needle string
---@param sub string
---@return string?
local function replace_last(hay, needle, sub)
  if needle == "" then
    return nil
  end
  local at ---@type integer?
  local from = 1
  while true do
    local s, e = hay:find(needle, from, true)
    if not s then
      break
    end
    at = s
    from = e + 1
    -- guard against zero-width progress
    if e < s then
      break
    end
  end
  if not at then
    return nil
  end
  return hay:sub(1, at - 1) .. sub .. hay:sub(at + #needle)
end

---@param content string
---@return string[]
local function to_lines(content)
  local lines = vim.split(content, "\n", { plain = true })
  -- a trailing newline yields a phantom empty line; drop it
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Undo the changes a turn made to a file.
---@param content string
---@param changes sidekick.review.Change[]
---@return string? nil when the content no longer matches what was recorded
local function undo(content, changes)
  for i = #changes, 1, -1 do
    local c = changes[i]
    if c.kind == "write" then
      -- a full write destroys whatever came before; the chain ends here
      return nil
    elseif c.old == c.new then
      -- no-op edit, nothing to undo
    elseif c.replace_all then
      local before = content
      content = content:gsub(vim.pesc(c.new), (c.old:gsub("%%", "%%%%")))
      if content == before then
        return nil
      end
    else
      local next_content = replace_last(content, c.new, c.old)
      if not next_content then
        return nil
      end
      content = next_content
    end
  end
  return content
end

--- Compute before/after content for `path` in every turn that touched it.
---
--- One walk yields the state at *every* turn, so callers diffing a whole
--- session should pass a `cache` and pay for each file once. Without it,
--- diffing T turns across F files costs T*F walks and T*F reads of the same
--- files — quadratic in the length of the session.
---@param turns sidekick.review.Turn[] oldest -> newest
---@param path string
---@param cache? table<string, table> reuse across calls for the same turn list
---@return table<string, {before?:string, after?:string}> keyed by turn id
function M.reconstruct(turns, path, cache)
  local states = cache and M.states(cache)
  if states and states[path] then
    return states[path]
  end
  local ret = {} ---@type table<string, {before?:string, after?:string}>
  local state = M.content(path, cache) ---@type string?

  for i = #turns, 1, -1 do
    local turn = turns[i]
    local file ---@type sidekick.review.FileChange?
    for _, f in ipairs(turn.files) do
      if f.path == path then
        file = f
        break
      end
    end
    if file then
      local entry = { after = state } ---@type {before?:string, after?:string}
      if state then
        if file.created then
          entry.before = ""
          state = nil -- nothing existed before; stop walking back
        else
          state = undo(state, file.changes)
          entry.before = state
        end
      end
      ret[turn.id] = entry
    end
  end
  if states then
    states[path] = ret
  end
  return ret
end

---@class sidekick.review.Block minimal change block: old[sa..sa+ca) -> new[sb..sb+cb)
---@field sa integer
---@field ca integer
---@field sb integer
---@field cb integer

--- Minimal change blocks, with insertion/deletion starts normalised so that
--- `sa` is always the first affected line rather than "the line before".
---@param sa string
---@param sb string
---@return sidekick.review.Block[]?
local function blocks(sa, sb)
  local ok, indices = pcall(vim.text.diff, sa, sb, {
    result_type = "indices",
    ctxlen = 0,
    algorithm = "histogram",
  })
  if not ok or type(indices) ~= "table" then
    return nil
  end
  local ret = {} ---@type sidekick.review.Block[]
  for _, idx in ipairs(indices) do
    ret[#ret + 1] = {
      sa = idx[2] > 0 and idx[1] or idx[1] + 1,
      ca = idx[2],
      sb = idx[4] > 0 and idx[3] or idx[3] + 1,
      cb = idx[4],
    }
  end
  return ret
end

---@param before string
---@param after string
---@return sidekick.review.Hunk[]
function M.hunks(before, after)
  local a = before == "" and {} or to_lines(before)
  local b = after == "" and {} or to_lines(after)
  local sa = #a > 0 and (table.concat(a, "\n") .. "\n") or ""
  local sb = #b > 0 and (table.concat(b, "\n") .. "\n") or ""
  if sa == sb then
    return {}
  end

  local blks = blocks(sa, sb)
  if not blks or #blks == 0 then
    return {}
  end

  -- group blocks that are close enough for their context windows to touch, so
  -- the lines between them stay context instead of being re-emitted as changes
  local groups = {} ---@type sidekick.review.Block[][]
  for _, blk in ipairs(blks) do
    local last = groups[#groups] and groups[#groups][#groups[#groups]]
    if last and blk.sa - (last.sa + last.ca) <= M.ctxlen * 2 then
      table.insert(groups[#groups], blk)
    else
      groups[#groups + 1] = { blk }
    end
  end

  local ret = {} ---@type sidekick.review.Hunk[]
  for _, group in ipairs(groups) do
    local first, last = group[1], group[#group]
    local from_a = math.max(1, first.sa - M.ctxlen)
    local from_b = math.max(1, first.sb - M.ctxlen)
    local end_a = math.min(#a, last.sa + last.ca - 1 + M.ctxlen)
    local end_b = math.min(#b, last.sb + last.cb - 1 + M.ctxlen)

    local lines = {} ---@type sidekick.review.DiffLine[]
    local cur_a, cur_b = from_a, from_b

    ---@param upto_a integer exclusive
    local function context(upto_a)
      while cur_a < upto_a do
        lines[#lines + 1] = { kind = "context", text = a[cur_a], old_lnum = cur_a, new_lnum = cur_b }
        cur_a, cur_b = cur_a + 1, cur_b + 1
      end
    end

    for _, blk in ipairs(group) do
      context(blk.sa)
      for k = 0, blk.ca - 1 do
        lines[#lines + 1] = { kind = "del", text = a[blk.sa + k] or "", old_lnum = blk.sa + k }
      end
      for k = 0, blk.cb - 1 do
        lines[#lines + 1] = { kind = "add", text = b[blk.sb + k] or "", new_lnum = blk.sb + k }
      end
      cur_a, cur_b = blk.sa + blk.ca, blk.sb + blk.cb
    end
    context(end_a + 1)

    ret[#ret + 1] = {
      old_start = #a > 0 and from_a or 0,
      old_count = math.max(end_a - from_a + 1, 0),
      new_start = #b > 0 and from_b or 0,
      new_count = math.max(end_b - from_b + 1, 0),
      lines = lines,
    }
  end
  return ret
end

--- Build hunks straight from the recorded edits.
---
--- Used when the file on disk no longer matches the transcript, so absolute
--- line numbers are unknowable. The *shape* of each edit still is, though:
--- diffing the recorded old against the recorded new keeps unchanged lines as
--- context instead of listing every line twice, once as a deletion and once as
--- an addition. Only the line numbers are dropped.
---@param file sidekick.review.FileChange
---@return sidekick.review.Hunk[]
function M.raw_hunks(file)
  local ret = {} ---@type sidekick.review.Hunk[]
  for _, c in ipairs(file.changes) do
    local lines = {} ---@type sidekick.review.DiffLine[]
    for _, hunk in ipairs(M.hunks(c.old, c.new)) do
      for _, l in ipairs(hunk.lines) do
        lines[#lines + 1] = { kind = l.kind, text = l.text }
      end
    end
    if #lines == 0 and (c.old ~= "" or c.new ~= "") then
      -- identical old/new produces no diff; show the content so the edit is
      -- still visible rather than silently vanishing
      for _, l in ipairs(to_lines(c.new ~= "" and c.new or c.old)) do
        lines[#lines + 1] = { kind = "context", text = l }
      end
    end
    if #lines > 0 then
      ret[#ret + 1] = { old_start = 0, old_count = 0, new_start = 0, new_count = 0, lines = lines }
    end
  end
  return ret
end

---@class sidekick.review.DiffCache
---@field states table<string, table> reconstructed history per file
---@field content table<string, string|false> file contents, `false` when absent

---@param cache table
---@return table<string, table>
function M.states(cache)
  cache.states = cache.states or {}
  return cache.states
end

--- Read a file at most once per cache.
---
--- The same file is looked at from every turn that touched it — for its
--- reconstruction, to see whether it still exists, and to check whether it is
--- binary. Reading it once keeps that from scaling with the length of the
--- session.
---@param path string
---@param cache? table
---@return string?
function M.content(path, cache)
  if not cache then
    return M.read(path)
  end
  cache.content = cache.content or {}
  local hit = cache.content[path]
  if hit ~= nil then
    return hit or nil
  end
  local data = M.read(path)
  cache.content[path] = data or false
  return data
end

---@param path string
---@param cache? table
---@return boolean
local function is_binary(path, cache)
  local data = M.content(path, cache)
  return data ~= nil and data:find("\0", 1, true) ~= nil
end

--- Diff a single file for a single turn.
---@param turns sidekick.review.Turn[] full turn list, oldest -> newest
---@param turn sidekick.review.Turn
---@param file sidekick.review.FileChange
---@param cache? table<string, table> shared reconstruction cache
---@return sidekick.review.FileDiff
function M.file(turns, turn, file, cache)
  ---@type sidekick.review.FileDiff
  local ret = {
    path = file.path,
    rel = file.rel,
    hunks = {},
    added = 0,
    removed = 0,
    created = file.created,
    deleted = file.deleted == true,
    approx = false,
    binary = false,
    missing = M.content(file.path, cache) == nil,
    filetype = vim.filetype.match({ filename = file.path }) or nil,
  }

  if not ret.missing and is_binary(file.path, cache) then
    ret.binary = true
    return ret
  end

  if ret.deleted then
    -- a `Delete File` section carries no body, so the content that was lost is
    -- only recoverable when a later turn put the file back. Show it when we
    -- have it; say plainly that it is gone when we do not.
    local states = M.reconstruct(turns, file.path, cache)[turn.id]
    local before = states and states.before or nil
    if before and before ~= "" then
      ret.hunks = M.hunks(before, "")
      ret.approx = false
    else
      ret.approx = true
    end
    for _, h in ipairs(ret.hunks) do
      ret.removed = ret.removed + #h.lines
    end
    return ret
  end

  local states = M.reconstruct(turns, file.path, cache)[turn.id]
  if states and states.before and states.after then
    ret.hunks = M.hunks(states.before, states.after)
  else
    ret.approx = true
    ret.hunks = M.raw_hunks(file)
  end

  for _, h in ipairs(ret.hunks) do
    for _, l in ipairs(h.lines) do
      if l.kind == "add" then
        ret.added = ret.added + 1
      elseif l.kind == "del" then
        ret.removed = ret.removed + 1
      end
    end
  end
  return ret
end

--- The cumulative change a whole session made to every file it touched.
---
--- A turn is the unit of *conversation*, not of change: a file edited across
--- turns 3, 5 and 7 has no single place showing what actually happened to it.
--- This is the diff you would look at before committing — from the file as it
--- was when the session started, to how it is now.
---@param turns sidekick.review.Turn[] oldest -> newest
---@param cache? table<string, table> shared reconstruction cache
---@return sidekick.review.FileDiff[]
function M.session(turns, cache)
  local order = {} ---@type string[]
  local touched = {} ---@type table<string, sidekick.review.FileChange[]>

  for _, turn in ipairs(turns) do
    for _, file in ipairs(turn.files) do
      if not touched[file.path] then
        touched[file.path] = {}
        order[#order + 1] = file.path
      end
      table.insert(touched[file.path], file)
    end
  end

  local ret = {} ---@type sidekick.review.FileDiff[]
  for _, path in ipairs(order) do
    local files = touched[path]
    local first, last = files[1], files[#files]
    local states = M.reconstruct(turns, path, cache)

    -- oldest recorded "before" -> the file as it stands now
    local before ---@type string?
    if first.created then
      -- a file this session created started empty, whatever happened to the
      -- undo chain in between
      before = ""
    else
      for _, turn in ipairs(turns) do
        local st = states[turn.id]
        if st then
          before = st.before
          break
        end
      end
    end
    local after = M.content(path, cache)

    ---@type sidekick.review.FileDiff
    local diff = {
      path = path,
      rel = first.rel,
      hunks = {},
      added = 0,
      removed = 0,
      created = first.created,
      deleted = last.deleted == true,
      approx = false,
      binary = false,
      missing = after == nil,
      filetype = vim.filetype.match({ filename = path }) or nil,
    }

    if diff.deleted then
      diff.approx = true
    elseif after and is_binary(path, cache) then
      diff.binary = true
    elseif before and after then
      diff.hunks = M.hunks(before, after)
    else
      -- the chain broke somewhere; per-edit hunks across every turn is still
      -- an honest account of what the session did, just without line numbers
      diff.approx = true
      for _, file in ipairs(files) do
        vim.list_extend(diff.hunks, M.raw_hunks(file))
      end
    end

    for _, h in ipairs(diff.hunks) do
      for _, l in ipairs(h.lines) do
        if l.kind == "add" then
          diff.added = diff.added + 1
        elseif l.kind == "del" then
          diff.removed = diff.removed + 1
        end
      end
    end
    ret[#ret + 1] = diff
  end

  return ret
end

--- Diff every file a turn touched.
---@param turns sidekick.review.Turn[]
---@param turn sidekick.review.Turn
---@param cache? table<string, table> shared reconstruction cache
---@return sidekick.review.FileDiff[]
function M.turn(turns, turn, cache)
  local ret = {} ---@type sidekick.review.FileDiff[]
  for _, file in ipairs(turn.files) do
    ret[#ret + 1] = M.file(turns, turn, file, cache)
  end
  return ret
end

--- Diff every turn in a session, reconstructing each file only once.
---@param turns sidekick.review.Turn[] oldest -> newest
---@return table<string, sidekick.review.FileDiff[]> turn id -> diffs
function M.all(turns)
  local cache = {}
  local ret = {} ---@type table<string, sidekick.review.FileDiff[]>
  for _, turn in ipairs(turns) do
    ret[turn.id] = M.turn(turns, turn, cache)
  end
  return ret, cache
end

return M
