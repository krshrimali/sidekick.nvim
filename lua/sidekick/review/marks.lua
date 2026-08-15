---@brief Show unresolved review comments in the real file.
---
--- A comment left in the review overlay is invisible the moment you close it:
--- you open `lua/greet.lua`, and nothing says line 4 has feedback waiting on
--- it. These marks close that loop — the file itself carries its open comments,
--- the way a diff view would.
---
--- Only unresolved comments are shown. A resolved thread is finished business
--- and would just be noise in the gutter.
local Config = require("sidekick.config")
local Store = require("sidekick.review.store")
local Util = require("sidekick.util")

local M = {}

local ns = vim.api.nvim_create_namespace("sidekick.review.marks")
local group ---@type integer?

M.SIGN = "SidekickReviewMark"

---@return sidekick.review.MarksConfig
local function opts()
  return (Config.review or {}).signs or {}
end

--- The review store that owns `path`.
---
--- Comments are keyed by project, and the editor's cwd is not necessarily that
--- project: you may have opened the file from somewhere else, or be working
--- above or below the root the agent ran in. So walk up from the file looking
--- for a project that has review state, and only fall back to the cwd.
---@param path string
---@return sidekick.review.Store?
function M.store_for(path)
  local dir = vim.fs.dirname(vim.fs.normalize(path))
  local seen = {} ---@type table<string, boolean>

  while dir and dir ~= "" and not seen[dir] do
    seen[dir] = true
    if Store.exists(dir) then
      return Store.get(dir)
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  local cwd = vim.fs.normalize(vim.uv.cwd() or ".")
  return Store.exists(cwd) and Store.get(cwd) or nil
end

--- Where a comment's anchor text sits in `lines` now.
---
--- Line numbers go stale the moment anyone edits the file, which is the normal
--- case: you comment, the agent fixes it, everything below shifts. A comment
--- pinned to a raw line number ends up pointing at unrelated code, which is
--- worse than not showing it at all. So the recorded anchor text is the source
--- of truth and the line number is only a hint about where to start looking.
---@param lines string[]
---@param c sidekick.review.Comment
---@param radius? integer how far to search (default: the whole file)
---@return integer? lnum, boolean exact whether the anchor text was actually found
function M.locate(lines, c, radius)
  local anchor = c.anchor or {}
  local want = anchor[1]
  local lnum = c.lnum

  ---@param at? integer
  ---@return integer?
  local function in_range(at)
    return at and at >= 1 and at <= #lines and at or nil
  end

  -- no anchor text recorded: the line number is all we have
  if not want or want == "" then
    return in_range(lnum), true
  end

  ---@param at integer
  ---@return boolean
  local function matches(at)
    for i, text in ipairs(anchor) do
      if lines[at + i - 1] ~= text then
        return false
      end
    end
    return true
  end

  if lnum and lnum >= 1 and lnum <= #lines and matches(lnum) then
    return lnum, true -- still where it was
  end

  -- search outward from the recorded line so the nearest match wins; an
  -- anchor that appears several times should resolve to the closest one.
  -- Clamp first: a line number well past the end of the file would otherwise
  -- send the search away from the buffer entirely.
  local from = math.min(math.max(lnum or 1, 1), math.max(#lines, 1))
  local limit = radius or #lines
  for offset = 1, limit do
    for _, at in ipairs({ from - offset, from + offset }) do
      if at >= 1 and at <= #lines and matches(at) then
        return at, true
      end
    end
  end

  -- the anchored text is gone. That often means the agent changed exactly what
  -- you asked about, so the comment is still worth seeing — but pinning it to a
  -- line whose contents we cannot vouch for has to be visible as a guess.
  return in_range(lnum), false
end

--- Comments that should be shown in `path`, keyed by line.
---@param path string
---@return table<integer, sidekick.review.Comment[]>
function M.for_file(path)
  local ret = {} ---@type table<integer, sidekick.review.Comment[]>
  path = vim.fs.normalize(path)
  if path == "" then
    return ret
  end

  local store = M.store_for(path)
  if not store then
    return ret
  end
  for _, c in ipairs(store:all()) do
    if c.target == "file" and c.file and c.lnum and c.status ~= "resolved" then
      if vim.fs.normalize(c.file) == path then
        local lnum = c.lnum
        ret[lnum] = ret[lnum] or {}
        table.insert(ret[lnum], c)
      end
    end
  end
  return ret
end

---@param comments sidekick.review.Comment[]
---@return string
local function summarise(comments)
  local c = comments[1]
  local body = (c.body:gsub("%s+", " "))
  local n_replies = 0
  for _, x in ipairs(comments) do
    n_replies = n_replies + #x.replies
  end

  local prefix = #comments > 1 and ("%d comments: "):format(#comments) or ""
  local suffix = ""
  if n_replies > 0 then
    suffix = (" · %d repl%s"):format(n_replies, n_replies == 1 and "y" or "ies")
  elseif c.status == "sent" then
    suffix = " · awaiting reply"
  end

  local max = opts().max_width or 60
  local room = math.max(max - #prefix - #suffix, 12)
  if vim.fn.strdisplaywidth(body) > room then
    body = vim.fn.strcharpart(body, 0, room - 1) .. "…"
  end
  return prefix .. body .. suffix
end

--- Redraw the marks for one buffer.
---@param buf? integer
function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or M.busy then
    return
  end
  -- relocating a comment writes to the store, which announces a change, which
  -- would re-enter this function mid-placement and double every mark
  M.busy = true
  local ok, err = pcall(M.place, buf)
  M.busy = false
  if not ok then
    error(err)
  end
end

---@param buf integer
function M.place(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  if opts().enabled == false or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return
  end

  local by_line = M.for_file(name)
  if next(by_line) == nil then
    return
  end

  -- re-anchor against the buffer as it is now, and regroup: two comments that
  -- were on different lines can end up on the same one, and vice versa
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local located = {} ---@type table<integer, sidekick.review.Comment[]>
  local drifted = {} ---@type table<integer, boolean>
  for _, comments in pairs(by_line) do
    for _, c in ipairs(comments) do
      local at, exact = M.locate(lines, c)
      if at then
        located[at] = located[at] or {}
        table.insert(located[at], c)
        if exact then
          -- keep the store in step so the review and the buffer agree; never
          -- persist a position we are only guessing at
          if c.lnum ~= at then
            M.relocate(c, at)
          end
        else
          drifted[at] = true
        end
      end
    end
  end

  local last = #lines
  for lnum, comments in pairs(located) do
    if lnum >= 1 and lnum <= last then
      local pending = false
      for _, c in ipairs(comments) do
        pending = pending or c.status == "pending"
      end
      local hl = pending and "SidekickReviewPending" or "SidekickReviewSent"
      local text = summarise(comments)
      if drifted[lnum] then
        hl = "SidekickReviewDim"
        text = text .. " · code changed since"
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, {
        sign_text = opts().text or "▌",
        sign_hl_group = hl,
        virt_text = opts().virtual_text ~= false and { { "  " .. text, "SidekickReviewMarkText" } } or nil,
        virt_text_pos = "eol",
        priority = opts().priority or 100,
      })
    end
  end
end

--- Persist a comment's new line, so the review pane agrees with the buffer.
---@param c sidekick.review.Comment
---@param lnum integer
function M.relocate(c, lnum)
  local store = c.file and M.store_for(c.file) or nil
  if not store then
    return
  end
  local shift = lnum - (c.lnum or lnum)
  c.lnum = lnum
  if c.end_lnum then
    c.end_lnum = c.end_lnum + shift
  end
  -- the diff anchor is keyed by line, so it moves too
  if c.anchor_key and c.side then
    c.anchor_key = ("%s:%d"):format(c.side, lnum)
  end
  store:save()
end

--- Redraw every listed buffer. Used when the comment set changes.
function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.refresh(buf)
    end
  end
end

--- Comments on the cursor line, if any.
---@return sidekick.review.Comment[]
function M.at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local ret = {} ---@type sidekick.review.Comment[]
  for _, comments in pairs(M.for_file(name)) do
    for _, c in ipairs(comments) do
      if M.locate(lines, c) == lnum then
        ret[#ret + 1] = c
      end
    end
  end
  return ret
end

--- Open the review on the comment under the cursor.
---@param opts_? sidekick.review.Open
---@return boolean opened
function M.open_at(opts_)
  local comments = M.at_cursor()
  if #comments == 0 then
    Util.warn("sidekick.review: no review comment on this line")
    return false
  end
  local c = comments[1]
  -- open the review for the project this file belongs to, which is not
  -- necessarily the editor's cwd
  local store = M.store_for(vim.api.nvim_buf_get_name(0))
  local ui = require("sidekick.review").open(vim.tbl_extend("force", opts_ or {}, {
    cwd = store and store.cwd or nil,
    turn = c.turn,
  }))
  if not ui then
    return false
  end
  -- land on the file the comment is about, with its thread open
  ui.sel_turn = c.turn
  ui.sel_key = c.file
  ui.expanded_threads[c.id] = true
  ui.collapsed[c.id] = nil
  ui:render()
  for i, l in ipairs(ui.main.lines) do
    if l.item and l.item.comment and l.item.comment.id == c.id then
      ui:focus_pane("main")
      pcall(vim.api.nvim_win_set_cursor, ui.main.win, { i, 0 })
      vim.cmd("normal! zz")
      break
    end
  end
  return true
end

function M.enable()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("sidekick_review_marks", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      M.refresh(ev.buf)
    end,
  })
  -- a file the agent rewrote is reloaded rather than re-read
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      M.refresh(ev.buf)
    end,
  })
  -- and redraw whenever the comment set changes
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "SidekickReviewChanged",
    callback = function()
      M.refresh_all()
    end,
  })

  M.refresh_all()
end

function M.disable()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    end
  end
end

return M
