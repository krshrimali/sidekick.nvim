---@brief The review overlay: sidebar + main pane + footer, and all interaction.
---
--- Floating windows are used on purpose. `cli.tab_scoped` binds a CLI session to
--- a tabpage, so opening the review in a new tab would talk to the wrong Claude.
--- Floats keep us in the current tab and leave the user's window layout intact.
local Config = require("sidekick.config")
local Diff = require("sidekick.review.diff")
local Model = require("sidekick.review.model")
local Provider = require("sidekick.review.provider")
local Render = require("sidekick.review.render")
local Store = require("sidekick.review.store")
local Submit = require("sidekick.review.submit")
local Util = require("sidekick.util")

local M = {}

local ns = vim.api.nvim_create_namespace("sidekick.review")

--- Comment bodies always go through here: a body that is only whitespace is
--- treated as "changed my mind", never stored.
---@param body? string
---@return string?
local function clean(body)
  if type(body) ~= "string" then
    return nil
  end
  body = body:gsub("^%s+", ""):gsub("%s+$", "")
  return body ~= "" and body or nil
end

---@alias sidekick.review.LayoutKind "float"|"tab"|"split"

---@class sidekick.review.Pane
---@field buf integer
---@field win integer
---@field lines sidekick.review.Line[]

---@class sidekick.review.UI
---@field cwd string
---@field session? string
---@field transcript? sidekick.review.Transcript
---@field store sidekick.review.Store
---@field expanded table<string, boolean>
---@field collapsed table<string, boolean>
---@field expanded_threads table<string, boolean>
---@field show_thinking boolean
---@field sel_turn? string
---@field sel_key? string
---@field diffs table<string, sidekick.review.FileDiff[]>
---@field sessions sidekick.review.Source[]
---@field transcripts sidekick.review.Transcript[] every session in view, newest first
---@field sidebar sidekick.review.Pane
---@field main sidekick.review.Pane
---@field footer sidekick.review.Pane
---@field watcher? uv.uv_fs_event_t most recently armed watcher
---@field watchers uv.uv_fs_event_t[] one per transcript in view
---@field watch_refresh? function
---@field autocmds integer[]
---@field closed boolean
---@field focus "sidebar"|"main"
---@field layout sidekick.review.LayoutKind
---@field tabpage? integer tabpage the panes live in
---@field owns_tab? boolean true when we created that tabpage
---@field origin_tab integer tabpage the review was launched from
---@field origin_win? integer window to return to on close
local UI = {}
UI.__index = UI

---@type sidekick.review.UI?
M.current = nil

--------------------------------------------------------------------------------
-- geometry
--------------------------------------------------------------------------------

--- Layout of the overlay.
---
--- `height` counts every row the overlay owns, borders and footer included.
--- For a bordered float `row`/`col` address the *border*, so the content sits
--- one row/column inside:
---
--- ```
---   row              ╭─ turns ─╮╭─ review ─╮   <- top border (row)
---   row + 1          │         ││          │   <- pane content (pane_height)
---   …
---   row + h - 2      ╰─────────╯╰──────────╯   <- bottom border
---   row + h - 1       3 pending · S submit …   <- footer
--- ```
---@class sidekick.review.Geometry
---@field row integer
---@field col integer
---@field width integer total columns
---@field height integer total rows
---@field pane_row integer top border row of the panes
---@field pane_height integer content rows of the panes
---@field footer_row integer
---@field sidebar integer sidebar content width
---@field main integer main pane content width
---@field main_col integer

---@return sidekick.review.Geometry
local function geometry()
  local cfg = Config.review or {}
  local total_w = vim.o.columns
  local total_h = math.max(vim.o.lines - vim.o.cmdheight, 6)
  local width = math.floor(total_w * (cfg.width or 0.94))
  local height = math.floor(total_h * (cfg.height or 0.9))
  width = math.max(math.min(width, total_w - 2), 40)
  height = math.max(math.min(height, total_h), 8)

  -- the diff pane is where the work happens, so the sidebar yields to it first
  local sidebar = cfg.sidebar_width or 38
  sidebar = math.max(math.min(sidebar, math.floor(width * 0.35)), 20)
  -- two borders sit between the panes, so the main pane gets what is left
  local main = math.max(width - sidebar - 4, 10)

  local row = math.max(math.floor((total_h - height) / 2), 0)
  local col = math.max(math.floor((total_w - width) / 2), 0)
  return {
    row = row,
    col = col,
    width = width,
    height = height,
    pane_row = row,
    pane_height = math.max(height - 3, 3),
    footer_row = row + height - 1,
    sidebar = sidebar,
    main = main,
    main_col = col + sidebar + 2,
  }
end

--- Window configs for the three panes, so open and resize can never drift.
---@param geo sidekick.review.Geometry
---@return table<string, vim.api.keyset.win_config>
local function win_configs(geo)
  return {
    sidebar = {
      relative = "editor",
      row = geo.pane_row,
      col = geo.col,
      width = geo.sidebar,
      height = geo.pane_height,
    },
    main = {
      relative = "editor",
      row = geo.pane_row,
      col = geo.main_col,
      width = geo.main,
      height = geo.pane_height,
    },
    footer = {
      relative = "editor",
      row = geo.footer_row,
      col = geo.col + 1,
      width = math.max(geo.width - 2, 10),
      height = 1,
    },
  }
end

--------------------------------------------------------------------------------
-- buffers & windows
--------------------------------------------------------------------------------

--- Review buffers are identified by `b:sidekick_review`, never by name: the
--- name is free to be something that reads well in the tabline.
---@param kind "sidebar"|"main"|"footer"
---@param label string
---@return integer
local function make_buf(kind, label)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "sidekick_review"
  vim.b[buf].sidekick_review = kind
  -- free of slashes so the tabline stays legible; buffer names must be unique,
  -- so fall back to a suffixed one if a stale review buffer still holds it
  local name = "Review " .. label
  if not pcall(vim.api.nvim_buf_set_name, buf, name) then
    pcall(vim.api.nvim_buf_set_name, buf, ("%s (%d)"):format(name, buf))
  end
  return buf
end

--- True for any window showing part of the review UI.
---@param win integer
---@return string? kind
function M.pane_kind(win)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, kind = pcall(function()
    return vim.b[buf].sidekick_review
  end)
  return ok and kind or nil
end

---@param pane sidekick.review.Pane
---@param lines sidekick.review.Line[]
local function paint(pane, lines)
  if not vim.api.nvim_buf_is_valid(pane.buf) then
    return
  end
  pane.lines = lines
  local text = vim.tbl_map(function(l)
    return (l.text:gsub("\n", " "))
  end, lines) --[[@as string[] ]]
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, text)
  vim.bo[pane.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pane.buf, ns, 0, -1)
  for i, l in ipairs(lines) do
    for _, hl in ipairs(l.hl or {}) do
      local ok = pcall(vim.api.nvim_buf_set_extmark, pane.buf, ns, i - 1, hl[1], {
        end_col = hl[2] == -1 and #text[i] or math.min(hl[2], #text[i]),
        hl_group = hl[3],
        strict = false,
      })
      if not ok then
        break
      end
    end
  end
end

--------------------------------------------------------------------------------
-- layouts
--------------------------------------------------------------------------------

--- Options every review window gets, whatever the layout.
---@param win integer
---@param opts? {cursorline?:boolean}
local function setup_win(win, opts)
  opts = opts or {}
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].cursorline = opts.cursorline ~= false
  -- an empty review pane should read as empty, not as an unopened file
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].winhighlight =
    "Normal:SidekickReviewNormal,CursorLine:SidekickReviewCursorLine,FloatBorder:SidekickReviewBorder"
end

--- In split layouts there are no float borders to carry a title, so the panes
--- name themselves in a winbar instead.
---@param win integer
---@param label string
local function set_winbar(win, label)
  if vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winbar = ("%%#SidekickReviewTitle# %s%%*"):format(label)
  end
end

--- The footer is a pinned float in every layout: it always belongs at the
--- bottom of the screen, and a real window there would fight the split tree.
---@return vim.api.keyset.win_config
function M.footer_config()
  local total_h = math.max(vim.o.lines - vim.o.cmdheight, 4)
  return {
    relative = "editor",
    row = total_h - 1,
    col = 0,
    width = math.max(vim.o.columns, 10),
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 201,
  }
end

--- Floating overlay: leaves the user's window layout completely untouched.
function UI:layout_float()
  local cfgs = win_configs(geometry())
  self.sidebar.win = vim.api.nvim_open_win(
    self.sidebar.buf,
    false,
    vim.tbl_extend("force", cfgs.sidebar, {
      style = "minimal",
      border = "rounded",
      title = " turns ",
      title_pos = "center",
      zindex = 200,
    })
  )
  self.main.win = vim.api.nvim_open_win(
    self.main.buf,
    false,
    vim.tbl_extend("force", cfgs.main, {
      style = "minimal",
      border = "rounded",
      title = " review ",
      title_pos = "center",
      zindex = 200,
    })
  )
  self.footer.win = vim.api.nvim_open_win(
    self.footer.buf,
    false,
    vim.tbl_extend("force", cfgs.footer, { style = "minimal", border = "none", zindex = 201 })
  )
end

--- Real splits, either in a dedicated tabpage or in the current one.
---@param mode "tab"|"split"
function UI:layout_splits(mode)
  local geo = geometry()

  if mode == "tab" then
    -- `tabnew` hands us a fresh scratch window; that one is ours to take over
    vim.cmd("noautocmd tabnew")
    self.owns_tab = true
    vim.api.nvim_win_set_buf(0, self.sidebar.buf)
  else
    -- in the current tabpage, never hijack a window the user is using: make a
    -- new one so closing the review restores exactly what was there before
    vim.cmd("noautocmd topleft vsplit")
    vim.api.nvim_win_set_buf(0, self.sidebar.buf)
  end
  self.tabpage = vim.api.nvim_get_current_tabpage()
  self.sidebar.win = vim.api.nvim_get_current_win()

  -- review pane takes the rest
  vim.cmd("noautocmd vertical rightbelow split")
  self.main.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.main.win, self.main.buf)

  pcall(vim.api.nvim_win_set_width, self.sidebar.win, geo.sidebar)
  vim.wo[self.sidebar.win].winfixwidth = true
  set_winbar(self.sidebar.win, "turns")
  set_winbar(self.main.win, "review")

  self.footer.win = vim.api.nvim_open_win(self.footer.buf, false, M.footer_config())
end

--- Create the three panes according to `review.layout`.
function UI:open_windows()
  self.sidebar = { buf = make_buf("sidebar", "turns"), win = 0, lines = {} }
  self.main = { buf = make_buf("main", "diff"), win = 0, lines = {} }
  self.footer = { buf = make_buf("footer", "status"), win = 0, lines = {} }

  if self.layout == "float" then
    self:layout_float()
  else
    self:layout_splits(self.layout)
  end

  setup_win(self.sidebar.win)
  setup_win(self.main.win)
  setup_win(self.footer.win, { cursorline = false })
end

--------------------------------------------------------------------------------
-- data
--------------------------------------------------------------------------------

--- Load every session for the project, newest first.
---
--- The whole repository is in view by default: a directory accumulates
--- sessions (earlier `claude` runs, a `codex` run, a resumed one) and which of
--- them a change landed in is rarely what you remember. `self.session` narrows
--- to one when you ask for it.
function UI:reload()
  local prev_turn, prev_key = self.sel_turn, self.sel_key
  Diff.ctxlen = (Config.review or {}).context or Diff.ctxlen
  self.sessions = Model.sessions(self.cwd)
  self.diffs = {}
  self.transcripts = {}

  for _, src in ipairs(self.sessions) do
    if not self.session or src.session == self.session then
      local ok, tr = pcall(Model.build, src)
      if ok and tr and #tr.turns > 0 then
        self.transcripts[#self.transcripts + 1] = tr
      end
    end
  end

  -- the newest session is the one you almost always mean
  self.transcript = self.transcripts[1]
  if not self.transcript then
    return
  end

  for _, tr in ipairs(self.transcripts) do
    -- reconstruction walks a single session's history, so scope it to one
    for _, turn in ipairs(tr.turns) do
      self.diffs[turn.id] = Diff.turn(tr.turns, turn)
    end
    require("sidekick.review.thread").sync(self.cwd, tr)
  end

  -- keep the selection if it still exists, else fall back to the newest turn
  if prev_turn and self:turn(prev_turn) then
    self.sel_turn, self.sel_key = prev_turn, prev_key or Store.RESPONSE
  else
    local last = self.transcript.turns[#self.transcript.turns]
    self.sel_turn = last and last.id or nil
    self.sel_key = Store.RESPONSE
    if self.sel_turn then
      self.expanded[self.sel_turn] = true
      self.expanded[self.transcript.session] = true
    end
  end
end

--- The transcript a turn belongs to.
---@param turn_id? string
---@return sidekick.review.Transcript?
function UI:transcript_of(turn_id)
  for _, tr in ipairs(self.transcripts or {}) do
    for _, t in ipairs(tr.turns) do
      if t.id == turn_id then
        return tr
      end
    end
  end
end

---@return sidekick.review.Ctx
function UI:ctx(width)
  return {
    transcript = self.transcript,
    transcripts = self.transcripts,
    session = self.session,
    store = self.store,
    expanded = self.expanded,
    sessions = self.sessions,
    collapsed = self.collapsed,
    expanded_threads = self.expanded_threads,
    show_thinking = self.show_thinking,
    sel_turn = self.sel_turn,
    sel_key = self.sel_key,
    diffs = self.diffs,
    width = width,
  }
end

---@param turn_id? string defaults to the selected turn
---@return sidekick.review.Turn?
function UI:turn(turn_id)
  turn_id = turn_id or self.sel_turn
  for _, tr in ipairs(self.transcripts or {}) do
    for _, t in ipairs(tr.turns) do
      if t.id == turn_id then
        return t
      end
    end
  end
end

--------------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------------

---@param opts? {keep_cursor?:boolean}
function UI:render(opts)
  opts = opts or {}
  if self.closed then
    return
  end
  local geo = geometry()

  paint(self.sidebar, Render.sidebar(self:ctx(geo.sidebar)))
  paint(self.main, Render.main(self:ctx(geo.main)))
  paint(self.footer, { Render.footer(self:ctx(math.max(geo.width - 2, 10))) })

  if not opts.keep_cursor then
    self:sync_sidebar_cursor()
  end
end

--- Move the sidebar cursor onto the selected item.
function UI:sync_sidebar_cursor()
  if not vim.api.nvim_win_is_valid(self.sidebar.win) then
    return
  end
  local collapsed = not self.expanded[self.sel_turn or ""]
  for i, l in ipairs(self.sidebar.lines) do
    local it = l.item
    if it and it.turn == self.sel_turn and (it.key == self.sel_key or (it.kind == "turn" and collapsed)) then
      pcall(vim.api.nvim_win_set_cursor, self.sidebar.win, { i, 0 })
      return
    end
  end
end

--------------------------------------------------------------------------------
-- item lookup
--------------------------------------------------------------------------------

---@param pane sidekick.review.Pane
---@return sidekick.review.Item?, integer
local function item_at(pane)
  if not vim.api.nvim_win_is_valid(pane.win) then
    return nil, 0
  end
  local row = vim.api.nvim_win_get_cursor(pane.win)[1]
  return pane.lines[row] and pane.lines[row].item or nil, row
end

---@return sidekick.review.Item?
function UI:main_item()
  return (item_at(self.main))
end

--------------------------------------------------------------------------------
-- actions
--------------------------------------------------------------------------------

function UI:focus_pane(which)
  self.focus = which
  local pane = which == "sidebar" and self.sidebar or self.main
  if vim.api.nvim_win_is_valid(pane.win) then
    vim.api.nvim_set_current_win(pane.win)
  end
end

--- Select the sidebar item under the cursor.
---@param opts? {toggle?:boolean, focus_main?:boolean}
function UI:activate(opts)
  opts = opts or {}
  local item = item_at(self.sidebar)
  if not item then
    return
  end
  if item.kind == "session" then
    self.expanded[item.session] = not self.expanded[item.session]
    self:render({ keep_cursor = true })
    return
  end
  if item.kind == "turn" then
    if opts.toggle ~= false then
      self.expanded[item.turn] = not self.expanded[item.turn]
    end
    self.sel_turn = item.turn
    self.sel_key = Store.RESPONSE
    self:render({ keep_cursor = true })
  elseif item.kind == "response" or item.kind == "file" or item.kind == "threads" then
    self.sel_turn = item.turn
    self.sel_key = item.key
    self:render({ keep_cursor = true })
    if opts.focus_main then
      self:focus_pane("main")
      pcall(vim.api.nvim_win_set_cursor, self.main.win, { 1, 0 })
    end
  end
end

--- Move the selection to the next/previous sidebar entry and preview it.
---@param delta integer
function UI:cycle(delta)
  local win = self.sidebar.win
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local n = #self.sidebar.lines
  for i = row + delta, delta > 0 and n or 1, delta do
    local it = self.sidebar.lines[i] and self.sidebar.lines[i].item
    if it and (it.kind == "turn" or it.kind == "response" or it.kind == "file") then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      self:activate({ toggle = false })
      return
    end
  end
end

--- Toggle the "viewed" mark of the current item.
function UI:toggle_viewed()
  local turn, key = self.sel_turn, self.sel_key
  if self.focus == "sidebar" then
    local item = item_at(self.sidebar)
    if item and item.key then
      turn, key = item.turn, item.key
    end
  end
  if not turn or not key then
    return
  end
  local now = self.store:set_viewed(turn, key)
  self:render({ keep_cursor = true })
  local what = key == Store.RESPONSE and "response" or vim.fn.fnamemodify(key, ":t")
  Util.info(("%s marked as %s"):format(what, now and "viewed" or "not viewed"))
end

--- Jump to the real file at the line under the cursor.
function UI:goto_file()
  local item = self:main_item()
  local turn = self:turn()
  local path = item and item.file or (self.sel_key ~= Store.RESPONSE and self.sel_key or nil)
  if not path then
    if turn and #turn.files > 0 then
      path = turn.files[1].path
    end
  end
  if not path then
    Util.warn("no file under cursor")
    return
  end
  local lnum = item and (item.lnum or item.old_lnum) or nil
  self:close()
  vim.schedule(function()
    vim.cmd.edit(vim.fn.fnameescape(path))
    if lnum then
      pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
      vim.cmd("normal! zz")
    end
  end)
end

--- Collect the anchor for a comment at the cursor (or visual range).
---@param range? {from:integer, to:integer}
---@return sidekick.review.Item?, string[]
function UI:anchor(range)
  local item, row = item_at(self.main)
  if not item then
    return nil, {}
  end
  local from, to = range and range.from or row, range and range.to or row
  local anchors = {} ---@type string[]
  local first ---@type sidekick.review.Item?
  for i = from, to do
    local l = self.main.lines[i]
    if l and l.item and l.item.anchor then
      first = first or l.item
      anchors[#anchors + 1] = l.item.anchor
    end
  end
  return first or item, anchors
end

---@param range? {from:integer, to:integer}
function UI:comment(range)
  local turn = self:turn()
  if not turn then
    Util.warn("no turn selected")
    return
  end
  local item, anchors = self:anchor(range)
  if not item or not item.anchor_key then
    Util.warn("nothing to comment on here — put the cursor on a diff or response line")
    return
  end

  local loc ---@type string
  if item.file then
    loc = ("%s:%s"):format(vim.fn.fnamemodify(item.file, ":."), tostring(item.lnum or item.old_lnum or "?"))
  else
    loc = "response"
  end

  require("sidekick.review.comment").open({
    title = "Comment on " .. loc,
    context = anchors,
    on_submit = function(body)
      body = clean(body)
      if not body then
        return
      end
      local end_lnum ---@type integer?
      if range and range.to > range.from then
        local last = self.main.lines[range.to]
        end_lnum = last and last.item and (last.item.lnum or last.item.old_lnum) or nil
      end
      self.store:add({
        turn = turn.id,
        target = item.file and "file" or "response",
        file = item.file,
        rel = item.file and (vim.fs.relpath(self.cwd, item.file) or item.file) or nil,
        lnum = item.lnum or item.old_lnum,
        end_lnum = end_lnum,
        side = item.side,
        anchor_key = item.anchor_key,
        anchor = anchors,
        body = body,
      })
      self:render({ keep_cursor = true })
      Util.info("comment added — press S to submit the review")
    end,
  })
end

--- Reply to the thread under the cursor (a follow-up comment on the same anchor).
function UI:reply()
  local item = self:main_item()
  if not item or not item.comment then
    Util.warn("put the cursor on a comment to reply")
    return
  end
  local c = item.comment
  require("sidekick.review.comment").open({
    title = ("Reply to [%s]"):format(c.id),
    context = vim.split(c.body, "\n", { plain = true }),
    on_submit = function(body)
      body = clean(body)
      if not body then
        return
      end
      self.store:reply(c.id, { role = "user", body = body, ts = os.time() })
      -- a follow-up makes the thread pending again so it gets sent
      self.store:set_status(c.id, "pending")
      self:render({ keep_cursor = true })
    end,
  })
end

function UI:edit_comment()
  local item = self:main_item()
  if not item or not item.comment then
    Util.warn("put the cursor on a comment to edit")
    return
  end
  local c = item.comment
  require("sidekick.review.comment").open({
    title = ("Edit [%s]"):format(c.id),
    body = c.body,
    on_submit = function(body)
      body = clean(body)
      if body then
        self.store:edit(c.id, body)
        self:render({ keep_cursor = true })
      end
    end,
  })
end

function UI:delete_comment()
  local item = self:main_item()
  if not item or not item.comment then
    Util.warn("put the cursor on a comment to delete")
    return
  end
  local c = item.comment
  local n = #c.replies
  local msg = n > 0 and ("Delete [%s] and its %d repl%s?"):format(c.id, n, n == 1 and "y" or "ies")
    or ("Delete comment [%s]?"):format(c.id)
  vim.ui.select({ "yes", "no" }, { prompt = msg }, function(choice)
    if choice == "yes" then
      self.store:remove(c.id)
      self:render({ keep_cursor = true })
    end
  end)
end

--- From a thread, jump to the diff line it is anchored to.
function UI:goto_anchor()
  local item = self:main_item()
  local c = item and item.comment
  if not c then
    Util.warn("put the cursor on a comment first")
    return
  end
  self.sel_key = c.target == "file" and c.file or Store.RESPONSE
  self.expanded_threads[c.id] = true
  self.collapsed[c.id] = nil
  self:render({ keep_cursor = true })
  for i, l in ipairs(self.main.lines) do
    if l.item and l.item.anchor_key == c.anchor_key and l.item.kind ~= "comment" then
      pcall(vim.api.nvim_win_set_cursor, self.main.win, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
end

--- Fold or unfold the thread under the cursor.
---@param force? boolean explicitly collapse (true) or expand (false)
function UI:toggle_thread(force)
  local item = self:main_item()
  if not item or not item.comment then
    Util.warn("put the cursor on a comment to fold it")
    return
  end
  local c = item.comment
  local collapsed = force
  if collapsed == nil then
    collapsed = not Render.is_collapsed(self:ctx(1), c)
  end
  -- both tables are needed: the default depends on status, so "keep this one
  -- open" and "keep this one shut" are distinct from "no opinion"
  self.collapsed[c.id] = collapsed or nil
  self.expanded_threads[c.id] = (not collapsed) or nil
  self:render({ keep_cursor = true })
end

--- Fold every thread in the current view, or unfold them all.
---@param collapsed boolean
function UI:fold_all(collapsed)
  local turn = self:turn()
  if not turn then
    return
  end
  for _, c in ipairs(self.store:for_turn(turn.id)) do
    self.collapsed[c.id] = collapsed or nil
    self.expanded_threads[c.id] = (not collapsed) or nil
  end
  self:render({ keep_cursor = true })
end

function UI:resolve_comment()
  local item = self:main_item()
  if not item or not item.comment then
    Util.warn("put the cursor on a comment to resolve")
    return
  end
  local c = item.comment
  self.store:set_status(c.id, c.status == "resolved" and "pending" or "resolved")
  self:render({ keep_cursor = true })
end

---@param delta integer
---@param kind "comment"|"hunk"|"file"
function UI:jump(delta, kind)
  local win = self.main.win
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local n = #self.main.lines
  local seen_current = nil ---@type any
  for i = row + delta, delta > 0 and n or 1, delta do
    local it = self.main.lines[i] and self.main.lines[i].item
    if it then
      if kind == "comment" and it.comment and it.kind == "comment" then
        if seen_current ~= it.comment then
          vim.api.nvim_win_set_cursor(win, { i, 0 })
          vim.cmd("normal! zz")
          return
        end
      elseif kind == "hunk" and it.kind == "hunk" then
        vim.api.nvim_win_set_cursor(win, { i, 0 })
        vim.cmd("normal! zt")
        return
      end
    end
  end
  Util.info(("no %s %s here"):format(delta > 0 and "next" or "previous", kind))
end

--- Submit the pending comments of the selected turn.
---@param opts? {all?:boolean}
function UI:submit(opts)
  opts = opts or {}
  local turn = self:turn()
  local comments = opts.all and self.store:all("pending")
    or (turn and self.store:for_turn(turn.id, { status = "pending" }) or {})
  if #comments == 0 then
    Util.warn("no pending comments to submit")
    return
  end

  local preview = Submit.render(comments, { turn = turn })
  require("sidekick.review.comment").open({
    title = ("Submit %d comment%s to Claude"):format(#comments, #comments == 1 and "" or "s"),
    body = preview or "",
    height = 0.6,
    submit_label = "send",
    on_submit = function(body)
      body = clean(body)
      if not body then
        Util.warn("sidekick.review: empty message, nothing sent")
        return
      end
      self:at_origin(function()
        require("sidekick.cli").send({ msg = body, submit = true, focus = false })
      end)
      for _, c in ipairs(comments) do
        self.store:set_status(c.id, "sent")
      end
      self:render({ keep_cursor = true })
      Util.info(("sent %d comment%s to Claude"):format(#comments, #comments == 1 and "" or "s"))
    end,
  })
end

--- Describe a session the way you would recognise it: what you asked it, when,
--- and how much it did — not its uuid.
---@param src sidekick.review.Source
---@param opts? {current?:string}
---@return string label, sidekick.review.Transcript?
function M.describe(src, opts)
  opts = opts or {}
  local provider = Provider.get(src.provider)
  local ok, tr = pcall(Model.build, src)
  local turns = ok and tr and #tr.turns or 0

  local files = {} ---@type table<string, boolean>
  local title = "(no prompt yet)"
  if ok and tr and turns > 0 then
    -- the opening prompt is what you actually remember a session by
    title = tr.turns[1].title
    for _, t in ipairs(tr.turns) do
      for _, f in ipairs(t.files) do
        files[f.path] = true
      end
    end
  end

  local n_files = vim.tbl_count(files)
  local when = os.date("%b %d %H:%M", math.floor(src.mtime)) --[[@as string]]
  local meta = ("%d turn%s · %d file%s · %s"):format(
    turns,
    turns == 1 and "" or "s",
    n_files,
    n_files == 1 and "" or "s",
    when
  )

  return ("%s %-11s  %-52s  %s"):format(
    src.session == opts.current and "●" or " ",
    provider and provider.label or src.provider,
    #title > 52 and (title:sub(1, 51) .. "…") or title,
    meta
  ),
    ok and tr or nil
end

--- Choose among every session recorded for a project.
---
--- A directory collects them over time: earlier `claude` runs, a `codex` run, a
--- resumed session. Only the most recent opens by default, so this is how you
--- reach the rest — including how you review a Codex turn when a Claude
--- session happens to be newer.
---@param opts {cwd:string, sources?:sidekick.review.Source[], current?:string, on_choice:fun(src:sidekick.review.Source)}
function M.select_session(opts)
  local sources = opts.sources or Model.sessions(opts.cwd)
  if #sources == 0 then
    Util.warn("sidekick.review: no sessions recorded for " .. vim.fn.fnamemodify(opts.cwd, ":~"))
    return
  end

  local items = {} ---@type {src:sidekick.review.Source, label:string}[]
  for _, src in ipairs(sources) do
    items[#items + 1] = { src = src, label = (M.describe(src, { current = opts.current })) }
  end

  vim.ui.select(items, {
    prompt = ("Sessions in %s"):format(vim.fn.fnamemodify(opts.cwd, ":~")),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      opts.on_choice(choice.src)
    end
  end)
end

--- Narrow the review to one session, or widen it back to the whole project.
---
--- The default is the whole repository. Narrowing is for when a project has
--- accumulated enough history that one session's turns are all you care about.
function UI:pick_session()
  local sources = self.sessions or {}
  if #sources <= 1 then
    Util.info("sidekick.review: this is the only session for " .. vim.fn.fnamemodify(self.cwd, ":~"))
    return
  end
  if self.session then
    -- already narrowed: `s` widens back to everything
    self.session = nil
    self.sel_turn, self.sel_key = nil, nil
    self:reload()
    self:render()
    self:watch()
    Util.info(("sidekick.review: showing all %d sessions"):format(#sources))
    return
  end
  M.select_session({
    cwd = self.cwd,
    sources = sources,
    current = self.session,
    on_choice = function(src)
      if self.closed then
        return
      end
      self.session = src.session
      -- a different session has different turns; the old selection means nothing
      self.sel_turn, self.sel_key = nil, nil
      self:reload()
      self:render()
      self:watch()
      local provider = Provider.get(src.provider)
      Util.info(
        ("sidekick.review: narrowed to the %s session %s — press s again for all"):format(
          provider and provider.label or src.provider,
          src.session:sub(1, 8)
        )
      )
    end,
  })
end

--- Submit a review carrying a verdict, the way a PR review does.
---
--- Comment-only feedback and "this is blocking" read very differently to the
--- agent, and an approval with nothing attached is still a useful thing to be
--- able to say.
---@param verdict "approved"|"changes"|"comment"
function UI:verdict(verdict)
  local turn = self:turn()
  local comments = turn and self.store:for_turn(turn.id, { status = "pending" }) or {}

  if verdict ~= "approved" and #comments == 0 then
    Util.warn("sidekick.review: no pending comments — use `ga` to approve as is")
    return
  end

  local preview = Submit.render(comments, { turn = turn, verdict = verdict })
  local label = verdict == "approved" and "Approve" or (verdict == "changes" and "Request changes" or "Comment")
  require("sidekick.review.comment").open({
    title = ("%s%s"):format(label, #comments > 0 and (" · %d comment%s"):format(#comments, #comments == 1 and "" or "s") or ""),
    body = preview or "",
    height = 0.6,
    submit_label = "send",
    on_submit = function(body)
      body = clean(body)
      if not body then
        Util.warn("sidekick.review: empty message, nothing sent")
        return
      end
      self:at_origin(function()
        require("sidekick.cli").send({ msg = body, submit = true, focus = false })
      end)
      for _, c in ipairs(comments) do
        self.store:set_status(c.id, "sent")
      end
      if turn then
        self.store:set_verdict(turn.id, verdict)
      end
      self:render({ keep_cursor = true })
      Util.info(("sidekick.review: %s sent"):format(label:lower()))
    end,
  })
end

function UI:help()
  local lines = {
    "# Sidekick Review",
    "",
    "Every agent turn is a pull request: a prompt, a response, and changed files.",
    "Works with Claude Code and Codex.",
    "",
    "The whole repository is in view: every session for this project, newest",
    "first, grouped by the CLI that wrote it.",
    "",
    "## Navigation",
    "  <Tab>       switch between the sidebar and the review pane",
    "  <CR>        sidebar: fold a session group / expand a turn / open an item",
    "  o           sidebar: open without leaving the sidebar",
    "  J / K       next / previous item, previewing as you go",
    "  ]c / [c     next / previous comment",
    "  ]h / [h     next / previous hunk",
    "  gf          open the real file at this line",
    "",
    "## Reviewing",
    "  c           comment on the line under the cursor (works on a visual range)",
    "  r           reply to the thread under the cursor",
    "  e           edit the comment under the cursor",
    "  d           delete the comment under the cursor",
    "  <Space>     resolve / unresolve the comment under the cursor",
    "  x           toggle viewed for the response or file",
    "  t           expand / collapse the agent's thinking",
    "",
    "## Threads",
    "  The `Threads` node in the sidebar lists every conversation on a turn in",
    "  one place, which reads better than hunting through diffs once a review",
    "  has been round-tripped a few times.",
    "",
    "  <CR> / za   fold or unfold the thread under the cursor",
    "  zM / zR     fold or unfold every thread",
    "  o           from a thread, jump to the line it annotates",
    "",
    "  Resolved conversations fold away by default; anything still waiting on",
    "  someone stays open.",
    "",
    "## Submitting",
    "  S           submit this turn's pending comments",
    "  A           submit every pending comment across all turns",
    "  ga          approve this turn (with or without comments)",
    "  gr          request changes — the comments are blocking",
    "",
    "Replies are asked to carry their tag (`[c1]`, `[c2]`…) so they thread back",
    "under the comment they answer. The transcript is watched, so answers appear",
    "on their own; R forces a refresh.",
    "",
    "  s           narrow to one session, or widen back to the whole project",
    "              (`:Sidekick review sessions` picks one without opening first)",
    "  R           refresh from the transcript",
    "  q / <Esc>   close",
    "",
    "## Layouts",
    "  opts.review.layout = \"float\" | \"tab\" | \"split\"",
    "  or per call: require(\"sidekick.review\").open({ layout = \"tab\" })",
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  local width = 74
  local height = math.max(math.min(#lines, vim.o.lines - vim.o.cmdheight - 4), 5)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " help ",
    title_pos = "center",
    zindex = 260,
  })
  vim.wo[win].wrap = false
  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
end

--------------------------------------------------------------------------------
-- keymaps
--------------------------------------------------------------------------------

---@param buf integer
---@param which "sidebar"|"main"
function UI:keymaps(buf, which)
  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, function()
      if not self.closed then
        fn()
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "Sidekick Review: " .. desc })
  end

  map("n", "q", function()
    self:close()
  end, "close")
  map("n", "<Esc>", function()
    self:close()
  end, "close")
  map("n", "g?", function()
    self:help()
  end, "help")
  map("n", "R", function()
    self:reload()
    self:render()
    Util.info("review refreshed")
  end, "refresh")
  map("n", "<Tab>", function()
    self:focus_pane(which == "sidebar" and "main" or "sidebar")
  end, "switch pane")
  map("n", "x", function()
    self:toggle_viewed()
  end, "toggle viewed")
  map("n", "t", function()
    self.show_thinking = not self.show_thinking
    self:render({ keep_cursor = true })
  end, "toggle thinking")
  map("n", "S", function()
    self:submit()
  end, "submit turn")
  map("n", "A", function()
    self:submit({ all = true })
  end, "submit all")
  map("n", "s", function()
    self:pick_session()
  end, "pick a session")
  map("n", "ga", function()
    self:verdict("approved")
  end, "approve")
  map("n", "gr", function()
    self:verdict("changes")
  end, "request changes")
  map("n", "J", function()
    self:cycle(1)
  end, "next item")
  map("n", "K", function()
    self:cycle(-1)
  end, "previous item")

  if which == "sidebar" then
    map("n", "<CR>", function()
      self:activate({ focus_main = true })
    end, "open")
    map("n", "o", function()
      self:activate({ toggle = false })
    end, "preview")
    map("n", "<2-LeftMouse>", function()
      self:activate({ focus_main = true })
    end, "open")
    map("n", "l", function()
      self:focus_pane("main")
    end, "focus diff")
  else
    map("n", "h", function()
      self:focus_pane("sidebar")
    end, "focus sidebar")
    map("n", "c", function()
      self:comment()
    end, "comment")
    map("x", "c", function()
      local from = vim.fn.line("v")
      local to = vim.fn.line(".")
      if from > to then
        from, to = to, from
      end
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      vim.schedule(function()
        vim.api.nvim_win_set_cursor(self.main.win, { from, 0 })
        self:comment({ from = from, to = to })
      end)
    end, "comment on selection")
    map("n", "r", function()
      self:reply()
    end, "reply")
    map("n", "e", function()
      self:edit_comment()
    end, "edit comment")
    map("n", "d", function()
      self:delete_comment()
    end, "delete comment")
    map("n", "<Space>", function()
      self:resolve_comment()
    end, "resolve comment")
    map("n", "<CR>", function()
      local item = self:main_item()
      if item and item.comment then
        self:toggle_thread()
      else
        self:goto_file()
      end
    end, "fold thread or open file")
    map("n", "za", function()
      self:toggle_thread()
    end, "fold thread")
    map("n", "zM", function()
      self:fold_all(true)
    end, "fold all threads")
    map("n", "zR", function()
      self:fold_all(false)
    end, "unfold all threads")
    map("n", "gf", function()
      self:goto_file()
    end, "open file")
    map("n", "o", function()
      self:goto_anchor()
    end, "jump to the anchored line")
    map("n", "]c", function()
      self:jump(1, "comment")
    end, "next comment")
    map("n", "[c", function()
      self:jump(-1, "comment")
    end, "previous comment")
    map("n", "]h", function()
      self:jump(1, "hunk")
    end, "next hunk")
    map("n", "[h", function()
      self:jump(-1, "hunk")
    end, "previous hunk")
  end
end

--------------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------------

--- Watch the transcript so Claude's replies show up without pressing R.
function UI:watch()
  if not self.transcript then
    return
  end
  self:unwatch()
  -- with the whole project in view, any session can be the one still being
  -- written to, so watch them all
  for _, tr in ipairs(self.transcripts or {}) do
    self:watch_file(tr.file)
  end
end

--- Stop every file watcher.
function UI:unwatch()
  for _, handle in ipairs(self.watchers or {}) do
    pcall(handle.stop, handle)
    pcall(handle.close, handle)
  end
  self.watchers = {}
  self.watcher = nil
  if self.watch_refresh then
    Util.close_debounce(self.watch_refresh)
    self.watch_refresh = nil
  end
end

--- Watch one transcript file, refreshing the review when it grows.
---@param file string
function UI:watch_file(file)
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  -- one debounce shared by every watcher: several sessions changing at once
  -- should still cost a single reload
  self.watch_refresh = self.watch_refresh
    or Util.debounce(function()
      if self.closed then
        return
      end
      self:reload()
      self:render({ keep_cursor = true })
    end, 400)
  local refresh = self.watch_refresh

  local ok = pcall(handle.start, handle, file, {}, function()
    vim.schedule(refresh)
  end)
  if ok then
    self.watchers = self.watchers or {}
    self.watchers[#self.watchers + 1] = handle
    self.watcher = handle
  else
    pcall(handle.close, handle)
  end
end

function UI:close()
  if self.closed then
    return
  end
  self.closed = true
  self:unwatch()
  for _, id in ipairs(self.autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  self.autocmds = {}
  for _, pane in ipairs({ self.sidebar, self.main, self.footer }) do
    if pane and vim.api.nvim_win_is_valid(pane.win) then
      pcall(vim.api.nvim_win_close, pane.win, true)
    end
  end

  -- a tabpage we opened is ours to clean up; one the user already had stays
  if self.owns_tab and self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_get_win(self.tabpage), true)
    end
  end
  if self.origin_tab and vim.api.nvim_tabpage_is_valid(self.origin_tab) then
    pcall(vim.api.nvim_set_current_tabpage, self.origin_tab)
    if self.origin_win and vim.api.nvim_win_is_valid(self.origin_win) then
      pcall(vim.api.nvim_set_current_win, self.origin_win)
    end
  end

  if M.current == self then
    M.current = nil
  end
end

--- Run `fn` on the tabpage the review was opened from.
---
--- With `cli.tab_scoped` a CLI session belongs to a tabpage. The review can be
--- sitting in a tab of its own, so anything that talks to the CLI has to hop
--- back first or it would address the wrong agent (or spawn a new one).
---@generic T
---@param fn fun():T
---@return T
function UI:at_origin(fn)
  local tab = vim.api.nvim_get_current_tabpage()
  local skip = not Config.cli.tab_scoped
    or not self.origin_tab
    or tab == self.origin_tab
    or not vim.api.nvim_tabpage_is_valid(self.origin_tab)
  if skip then
    return fn()
  end
  vim.api.nvim_set_current_tabpage(self.origin_tab)
  local ok, res = pcall(fn)
  if vim.api.nvim_tabpage_is_valid(tab) then
    pcall(vim.api.nvim_set_current_tabpage, tab)
  end
  if not ok then
    error(res)
  end
  return res
end

---@param opts? sidekick.review.Open
---@return sidekick.review.UI?
function M.open(opts)
  opts = opts or {}
  if M.current and not M.current.closed then
    M.current:focus_pane(M.current.focus)
    return M.current
  end

  local cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd() or ".")
  local layout = opts.layout or Config.review.layout or "float"
  if layout ~= "float" and layout ~= "tab" and layout ~= "split" then
    Util.warn(("sidekick.review: unknown layout %q, falling back to `float`"):format(tostring(layout)))
    layout = "float"
  end

  local self = setmetatable({
    cwd = cwd,
    session = opts.session,
    store = Store.get(cwd),
    expanded = {},
    collapsed = {},
    expanded_threads = {},
    show_thinking = false,
    diffs = {},
    closed = false,
    focus = "sidebar",
    autocmds = {},
    layout = layout,
    -- a CLI session can be bound to a tabpage (`cli.tab_scoped`), so remember
    -- where we came from and send from there
    origin_tab = vim.api.nvim_get_current_tabpage(),
    origin_win = vim.api.nvim_get_current_win(),
  }, UI) --[[@as sidekick.review.UI]]

  self:reload()
  if not self.transcript then
    Util.warn(
      "sidekick.review: no agent transcript found for "
        .. cwd
        .. "\nStart a `claude` or `codex` session in this directory first."
    )
    return nil
  end
  if #self.transcript.turns == 0 then
    Util.warn("sidekick.review: the transcript has no turns yet")
    return nil
  end
  if opts.turn then
    self.sel_turn = opts.turn
  end
  if self.sel_turn then
    self.expanded[self.sel_turn] = true
  end

  self:open_windows()
  self:keymaps(self.sidebar.buf, "sidebar")
  self:keymaps(self.main.buf, "main")

  -- closing any pane tears the whole overlay down
  self.autocmds[#self.autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
    group = Config.augroup,
    pattern = tostring(self.sidebar.win) .. "," .. tostring(self.main.win),
    callback = function()
      self:close()
    end,
  })
  self.autocmds[#self.autocmds + 1] = vim.api.nvim_create_autocmd("VimResized", {
    group = Config.augroup,
    callback = function()
      if self.closed then
        return true
      end
      M.resize(self)
    end,
  })
  self.autocmds[#self.autocmds + 1] = vim.api.nvim_create_autocmd("WinEnter", {
    group = Config.augroup,
    callback = function()
      if self.closed then
        return true
      end
      local win = vim.api.nvim_get_current_win()
      if win == self.sidebar.win then
        self.focus = "sidebar"
      elseif win == self.main.win then
        self.focus = "main"
      end
    end,
  })

  M.current = self
  self:render()
  if Config.review.watch ~= false then
    self:watch()
  end
  self:focus_pane("sidebar")
  return self
end

---@param self sidekick.review.UI
function M.resize(self)
  local geo = geometry()
  if self.layout == "float" then
    local cfgs = win_configs(geo)
    for _, name in ipairs({ "sidebar", "main", "footer" }) do
      local pane = self[name]
      if pane and vim.api.nvim_win_is_valid(pane.win) then
        pcall(vim.api.nvim_win_set_config, pane.win, cfgs[name])
      end
    end
  else
    -- splits reflow on their own; only the sidebar width and the pinned footer
    -- need to be put back
    if vim.api.nvim_win_is_valid(self.sidebar.win) then
      pcall(vim.api.nvim_win_set_width, self.sidebar.win, geo.sidebar)
    end
    if vim.api.nvim_win_is_valid(self.footer.win) then
      pcall(vim.api.nvim_win_set_config, self.footer.win, M.footer_config())
    end
  end
  self:render({ keep_cursor = true })
end

function M.close()
  if M.current then
    M.current:close()
  end
end

function M.toggle(opts)
  if M.current and not M.current.closed then
    M.close()
    return nil
  end
  return M.open(opts)
end

M.UI = UI

return M
