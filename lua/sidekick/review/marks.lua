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
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
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

  local last = vim.api.nvim_buf_line_count(buf)
  for lnum, comments in pairs(by_line) do
    -- the file may have shrunk since the comment was left
    if lnum >= 1 and lnum <= last then
      local pending = false
      for _, c in ipairs(comments) do
        pending = pending or c.status == "pending"
      end
      local hl = pending and "SidekickReviewPending" or "SidekickReviewSent"
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, {
        sign_text = opts().text or "▌",
        sign_hl_group = hl,
        virt_text = opts().virtual_text ~= false and { { "  " .. summarise(comments), "SidekickReviewMarkText" } } or nil,
        virt_text_pos = "eol",
        priority = opts().priority or 100,
      })
    end
  end
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
  return M.for_file(name)[lnum] or {}
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
