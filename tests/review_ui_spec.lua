---@module 'luassert'

local Config = require("sidekick.config")
local Fixture = require("tests.review_fixture")
local Config = require("sidekick.config")
local Render = require("sidekick.review.render")
local Review = require("sidekick.review")
local Store = require("sidekick.review.store")
local Submit = require("sidekick.review.submit")
local UI = require("sidekick.review.ui")

---@param buf integer
---@return string
local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

--- First row in `pane` whose item satisfies `fn`.
---@param pane sidekick.review.Pane
---@param fn fun(item:sidekick.review.Item, line:sidekick.review.Line):boolean?
---@return integer?
local function row_where(pane, fn)
  for i, l in ipairs(pane.lines) do
    if l.item and fn(l.item, l) then
      return i
    end
  end
end

describe("review.ui", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_cli, restore_notify, sent, notices

  before_each(function()
    fx = Fixture.setup()
    sent, restore_cli = Fixture.stub_cli()
    notices, restore_notify = Fixture.stub_notify()
  end)

  after_each(function()
    UI.close()
    restore_cli()
    restore_notify()
    fx.cleanup()
  end)

  it("opens three panes and focuses the sidebar", function()
    local ui = Review.open({ cwd = fx.cwd })
    assert.is_not_nil(ui)
    assert.is_true(vim.api.nvim_win_is_valid(ui.sidebar.win))
    assert.is_true(vim.api.nvim_win_is_valid(ui.main.win))
    assert.is_true(vim.api.nvim_win_is_valid(ui.footer.win))
    assert.are.same(ui.sidebar.win, vim.api.nvim_get_current_win())
  end)

  it("selects the newest turn and expands it", function()
    local ui = Review.open({ cwd = fx.cwd })
    assert.are.same(ui.transcript.turns[2].id, ui.sel_turn)
    assert.are.same(Store.RESPONSE, ui.sel_key)
    local sb = text(ui.sidebar.buf)
    assert.is_not_nil(sb:find("Response", 1, true))
    assert.is_not_nil(sb:find("lua/greet.lua", 1, true))
    assert.is_not_nil(sb:find("+3 -2", 1, true))
  end)

  it("refuses to open without a transcript", function()
    local nowhere = vim.fn.tempname()
    vim.fn.mkdir(nowhere, "p")
    assert.is_nil(Review.open({ cwd = nowhere }))
    assert.is_nil(UI.current)
    local warned = false
    for _, n in ipairs(notices) do
      warned = warned or n:find("no agent transcript", 1, true) ~= nil
    end
    assert.is_true(warned)
  end)

  it("renders the response with tools and collapsed thinking", function()
    local ui = Review.open({ cwd = fx.cwd })
    local main = text(ui.main.buf)
    assert.is_not_nil(main:find("Use vim.notify instead", 1, true))
    assert.is_not_nil(main:find("Switching both call sites", 1, true))
    assert.is_not_nil(main:find("thinking (2 lines", 1, true))
    assert.is_nil(main:find("print() is not great", 1, true))
    -- tool paths are shown relative to the project
    assert.is_not_nil(main:find("lua/greet.lua", 1, true))
    assert.is_nil(main:find(fx.cwd, 1, true))
  end)

  it("toggles thinking with t", function()
    local ui = Review.open({ cwd = fx.cwd })
    vim.api.nvim_set_current_win(ui.main.win)
    feed("T")
    assert.is_not_nil(text(ui.main.buf):find("print() is not great", 1, true))
    feed("T")
    assert.is_nil(text(ui.main.buf):find("print() is not great", 1, true))
  end)

  it("opens a file diff from the sidebar with <CR>", function()
    local ui = Review.open({ cwd = fx.cwd })
    local row = row_where(ui.sidebar, function(it)
      return it.file and it.file:find("greet.lua") ~= nil
    end)
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(ui.sidebar.win, { row, 0 })
    feed("<CR>")
    assert.are.same(fx.file, ui.sel_key)
    assert.are.same(ui.main.win, vim.api.nvim_get_current_win())

    local main = text(ui.main.buf)
    assert.is_not_nil(main:find("@@ -1,11 +1,12 @@", 1, true))
    assert.is_not_nil(main:find("vim.notify('hi ", 1, true))
    assert.is_not_nil(main:find("print('hi ", 1, true))
  end)

  it("anchors a comment to the diff line under the cursor", function()
    local ui = Review.open({ cwd = fx.cwd })
    ui.sel_key = fx.file
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    local row = row_where(ui.main, function(it, l)
      return it.kind == "diff" and l.text:find("vim.notify('hi", 1, true) ~= nil
    end)
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(ui.main.win, { row, 0 })

    local captured, restore = Fixture.stub_composer("respect vim.log.levels?")
    feed("c")
    restore()

    assert.is_not_nil(captured.opts.title:find("greet.lua:4", 1, true))
    assert.is_not_nil(captured.opts.context[1]:find("vim.notify", 1, true))

    local comments = Store.get(fx.cwd):for_turn(ui.sel_turn, { target = "file" })
    assert.are.same(1, #comments)
    assert.are.same("c1", comments[1].id)
    assert.are.same(4, comments[1].lnum)
    assert.are.same("new", comments[1].side)
    assert.are.same("new:4", comments[1].anchor_key)
    assert.are.same("pending", comments[1].status)
  end)

  it("renders a thread directly under its anchor line", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:add({
      turn = ui.sel_turn,
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 4,
      side = "new",
      anchor_key = "new:4",
      anchor = { "  vim.notify('hi ' .. name)" },
      body = "respect vim.log.levels?",
    })
    ui.sel_key = fx.file
    ui:render()

    local anchor = row_where(ui.main, function(it)
      return it.kind == "diff" and it.anchor_key == "new:4"
    end)
    local thread = row_where(ui.main, function(it)
      return it.kind == "comment"
    end)
    assert.are.same(anchor + 1, thread)
    local out = text(ui.main.buf)
    assert.is_not_nil(out:find("[c1]", 1, true))
    assert.is_not_nil(out:find("respect vim.log.levels?", 1, true))
  end)

  it("keeps a comment visible when its anchor is gone", function()
    local ui = Review.open({ cwd = fx.cwd })
    Store.get(fx.cwd):add({
      turn = ui.sel_turn,
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 999,
      side = "new",
      anchor_key = "new:999",
      anchor = { "gone" },
      body = "orphaned",
    })
    ui.sel_key = fx.file
    ui:render()
    local main = text(ui.main.buf)
    assert.is_not_nil(main:find("outside the current diff", 1, true))
    assert.is_not_nil(main:find("orphaned", 1, true))
  end)

  it("discards an empty comment body", function()
    local ui = Review.open({ cwd = fx.cwd })
    ui.sel_key = fx.file
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    local row = row_where(ui.main, function(it)
      return it.kind == "diff"
    end)
    vim.api.nvim_win_set_cursor(ui.main.win, { row, 0 })

    local _, restore = Fixture.stub_composer("   \n\n  ")
    feed("c")
    restore()
    assert.are.same(0, #Store.get(fx.cwd):all())

    local _, restore2 = Fixture.stub_composer(nil) -- cancelled
    feed("c")
    restore2()
    assert.are.same(0, #Store.get(fx.cwd):all())
  end)

  it("comments on a visual range", function()
    local ui = Review.open({ cwd = fx.cwd })
    ui.sel_key = fx.file
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    local rows = {}
    for i, l in ipairs(ui.main.lines) do
      if l.item and l.item.kind == "diff" then
        rows[#rows + 1] = i
      end
    end
    vim.api.nvim_win_set_cursor(ui.main.win, { rows[1], 0 })

    local captured, restore = Fixture.stub_composer("this block needs a test")
    ui:comment({ from = rows[1], to = rows[4] })
    restore()

    local c = Store.get(fx.cwd):all()[1]
    assert.are.same(4, #c.anchor)
    assert.are.same(4, #captured.opts.context)
    assert.is_not_nil(c.end_lnum)
    assert.is_not_nil(Submit.render_comment(c):find("%d+%-%d+"))
  end)

  it("toggles viewed with x", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    feed("x")
    assert.is_true(store:is_viewed(ui.sel_turn, Store.RESPONSE))
    feed("x")
    assert.is_false(store:is_viewed(ui.sel_turn, Store.RESPONSE))
  end)

  it("warns instead of acting when there is nothing under the cursor", function()
    local ui = Review.open({ cwd = fx.cwd })
    vim.api.nvim_set_current_win(ui.main.win)
    vim.api.nvim_win_set_cursor(ui.main.win, { 3, 0 }) -- the rule under the header

    local function last()
      return notices[#notices] or ""
    end
    feed("r")
    assert.is_not_nil(last():find("cursor on a comment", 1, true))
    feed("c")
    assert.is_not_nil(last():find("nothing to comment on", 1, true))
    feed("S")
    assert.is_not_nil(last():find("no pending comments", 1, true))
  end)

  it("submits pending comments as one tagged message", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:add({
      turn = ui.sel_turn,
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 4,
      side = "new",
      anchor_key = "new:4",
      anchor = { "  vim.notify('hi ' .. name)" },
      body = "respect vim.log.levels?",
    })
    store:add({ turn = ui.sel_turn, target = "response", anchor_key = "b2:1", anchor = { "Switching" }, body = "add a test" })
    ui:render()
    assert.are.same(2, Review.pending(fx.cwd))

    vim.api.nvim_set_current_win(ui.main.win)
    local body
    local _, restore = Fixture.stub_composer(function(opts)
      body = opts.body
      return opts.body
    end)
    feed("S")
    restore()

    assert.is_not_nil(body:find("### [c1]", 1, true))
    assert.is_not_nil(body:find("### [c2]", 1, true))
    assert.is_not_nil(body:find("lua/greet.lua:4", 1, true))
    assert.is_not_nil(body:find("so my editor", 1, true))
    assert.are.same(1, #sent)
    assert.is_true(sent[1].submit)
    assert.are.same("sent", store:find("c1").status)
    assert.are.same(0, Review.pending(fx.cwd))
  end)

  it("keeps comments pending when the CLI send fails", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:add({ turn = ui.sel_turn, target = "response", anchor_key = "b2:1", anchor = {}, body = "retry me" })
    package.loaded["sidekick.cli"].send = function(opts)
      opts.on_send(false, "not attached")
    end
    Submit.send({ cwd = fx.cwd, turn = ui.transcript.turns[2] })
    assert.are.same("pending", store:find("c1").status)
  end)

  it("threads Claude's tagged replies back under the comments", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:add({
      turn = ui.sel_turn,
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 4,
      side = "new",
      anchor_key = "new:4",
      anchor = { "  vim.notify('hi ' .. name)" },
      body = "respect vim.log.levels?",
      status = "sent",
    })

    Fixture.append(fx, {
      {
        type = "user",
        uuid = "r1",
        timestamp = "2026-08-15T10:00:00.000Z",
        message = { role = "user", content = "Code review\n### [c1] lua/greet.lua:4\nrespect vim.log.levels?" },
      },
      {
        type = "assistant",
        uuid = "r2",
        timestamp = "2026-08-15T10:00:10.000Z",
        message = { role = "assistant", content = { { type = "text", text = "Sure.\n\n[c1]\nSwitched to vim.log.levels.INFO." } } },
      },
    })

    feed("R")

    local c1 = store:find("c1")
    assert.are.same(1, #c1.replies)
    assert.are.same("claude", c1.replies[1].role)
    assert.is_not_nil(c1.replies[1].body:find("vim.log.levels.INFO", 1, true))
    assert.are.same("resolved", c1.status)

    ui.sel_key = fx.file
    ui:render()
    -- answering a comment resolves it, so its thread folds to a summary line
    local main = text(ui.main.buf)
    assert.is_not_nil(main:find("resolved", 1, true))
    assert.is_nil(main:find("vim.log.levels.INFO", 1, true))

    ui.expanded_threads[c1.id] = true
    ui:render()
    main = text(ui.main.buf)
    assert.is_not_nil(main:find("claude", 1, true))
    assert.is_not_nil(main:find("vim.log.levels.INFO", 1, true))

    -- syncing again must not duplicate the reply
    require("sidekick.review.thread").sync(fx.cwd, ui.transcript)
    assert.are.same(1, #store:find("c1").replies)
  end)

  it("reopens a thread when the user replies again", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:add({
      turn = ui.sel_turn,
      target = "response",
      anchor_key = "b2:1",
      anchor = { "Switching" },
      body = "add a test",
      status = "sent",
      replies = { { role = "claude", body = "Added one.", ts = 0, turn = "x" } },
    })
    ui:render()

    vim.api.nvim_set_current_win(ui.main.win)
    local row = row_where(ui.main, function(it)
      return it.kind == "comment"
    end)
    vim.api.nvim_win_set_cursor(ui.main.win, { row, 0 })

    local _, restore = Fixture.stub_composer("it still does not cover the error path")
    feed("r")
    restore()

    local c = store:find("c1")
    assert.are.same(2, #c.replies)
    assert.are.same("user", c.replies[2].role)
    assert.are.same("pending", c.status)

    -- resubmitting carries the whole thread so Claude has the context
    local rendered = Submit.render_comment(c)
    assert.is_not_nil(rendered:find("you previously replied", 1, true))
    assert.is_not_nil(rendered:find("still does not cover", 1, true))
  end)

  it("survives a restart", function()
    local ui = Review.open({ cwd = fx.cwd })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b2:1", anchor = {}, body = "keep me" })
    UI.close()
    Store.reset()
    local reloaded = Store.get(fx.cwd)
    assert.are.same(1, #reloaded:all())
    assert.are.same("keep me", reloaded:all()[1].body)
    assert.is_nil(vim.uv.fs_stat(reloaded.file .. ".tmp"))
  end)

  it("keeps state separate for cwd names with the same Claude encoding", function()
    local first = fx.cwd .. "/a_b"
    local second = fx.cwd .. "/a-b"
    local a = Store.get(first)
    local b = Store.get(second)
    assert.are_not.same(a.file, b.file)
    a:add({ turn = "t", target = "response", anchor_key = "b1:1", anchor = {}, body = "first" })
    b:add({ turn = "t", target = "response", anchor_key = "b1:1", anchor = {}, body = "second" })
    Store.reset()
    assert.are.same("first", Store.get(first):all()[1].body)
    assert.are.same("second", Store.get(second):all()[1].body)
  end)

  it("recovers from corrupt state", function()
    local store = Store.get(fx.cwd)
    Fixture.write(store.file, "{{{ not json")
    Store.reset()
    local recovered = Store.get(fx.cwd)
    assert.are.same(0, #recovered:all())
    recovered:add({ turn = "t", target = "response", anchor_key = "b1:1", anchor = {}, body = "x" })
    assert.are.same(1, #recovered:all())
  end)

  it("toggles open and closed without leaking windows", function()
    local autocmds = #vim.api.nvim_get_autocmds({ group = Config.augroup })
    local function panes()
      local n = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if UI.pane_kind(w) then
          n = n + 1
        end
      end
      return n
    end
    local a = Review.toggle({ cwd = fx.cwd })
    assert.are.same(3, panes())
    assert.are.same(a, Review.open({ cwd = fx.cwd })) -- second open reuses it
    assert.are.same(3, panes())
    Review.toggle({ cwd = fx.cwd })
    assert.is_true(a.closed)
    assert.are.same(0, panes())
    assert.are.same(autocmds, #vim.api.nvim_get_autocmds({ group = Config.augroup }))
    a:close() -- idempotent
  end)

  it("keeps every pane inside a narrow window", function()
    local cols, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 60, 14
    local ui = Review.open({ cwd = fx.cwd })
    assert.is_not_nil(ui)
    local sw = vim.api.nvim_win_get_width(ui.sidebar.win)
    assert.is_true(sw >= 20)
    assert.is_true(vim.api.nvim_win_get_width(ui.main.win) >= 10)
    for _, l in ipairs(ui.sidebar.lines) do
      assert.is_true(vim.fn.strdisplaywidth(l.text) <= sw + 2)
    end
    vim.o.columns, vim.o.lines = cols, lines
  end)

  it("places the footer clear of the pane borders", function()
    local ui = Review.open({ cwd = fx.cwd })
    local main = vim.api.nvim_win_get_config(ui.main.win)
    local footer = vim.api.nvim_win_get_config(ui.footer.win)
    -- a bordered float owns `row` (top border) through `row + height + 1`
    assert.are.same(main.row + main.height + 2, footer.row)
    assert.is_true(footer.row + 1 <= vim.o.lines - vim.o.cmdheight)
  end)
end)

describe("review.ui sessions", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_cli, restore_notify, notices, prev_codex

  --- Give the same project a Codex rollout, newer than the Claude transcript.
  ---@return string session id
  local function add_codex()
    local root = fx.root .. "/codex/sessions"
    prev_codex = require("sidekick.review.provider.codex").root
    require("sidekick.review.provider.codex").root = root
    local file = fx.cwd .. "/CHANGELOG.md"
    Fixture.write(file, "# Changelog\n")
    local entries = {
      { type = "session_meta", timestamp = "2026-08-15T12:00:00.000Z", payload = { id = "codex-1", cwd = fx.cwd } },
      {
        type = "response_item",
        timestamp = "2026-08-15T12:00:01.000Z",
        payload = { type = "message", role = "user", content = { { type = "input_text", text = "add a changelog" } } },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T12:00:02.000Z",
        payload = { type = "message", role = "assistant", content = { { type = "output_text", text = "Adding it." } } },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T12:00:03.000Z",
        payload = {
          type = "custom_tool_call",
          name = "exec",
          call_id = "c1",
          input = 'const p = "*** Begin Patch\\n*** Add File: ' .. file .. '\\n+# Changelog\\n*** End Patch";',
        },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T12:00:04.000Z",
        payload = { type = "custom_tool_call_output", call_id = "c1", output = "Success." },
      },
    }
    local lines = vim.tbl_map(function(e)
      return vim.json.encode(e)
    end, entries)
    local path = root .. "/2026/08/15/rollout-codex.jsonl"
    Fixture.write(path, table.concat(lines, "\n") .. "\n")
    vim.uv.fs_utime(path, os.time(), os.time() + 100)
    return "codex-1"
  end

  before_each(function()
    fx = Fixture.setup()
    _, restore_cli = Fixture.stub_cli()
    notices, restore_notify = Fixture.stub_notify()
  end)

  after_each(function()
    UI.close()
    if prev_codex ~= nil then
      require("sidekick.review.provider.codex").root = prev_codex
      prev_codex = nil
    end
    restore_cli()
    restore_notify()
    fx.cleanup()
  end)

  it("lists sessions from every CLI, newest first", function()
    add_codex()
    local sources = Review.sessions(fx.cwd)
    assert.are.same(2, #sources)
    assert.are.same("codex", sources[1].provider)
    assert.are.same("claude", sources[2].provider)
  end)

  it("shows the whole repository by default, grouped by session", function()
    add_codex()
    local ui = Review.open({ cwd = fx.cwd })
    assert.are.same(2, #ui.transcripts)
    assert.is_nil(ui.session)
    -- the newest is the one selected, but both are in view
    assert.are.same("codex", ui.transcripts[1].provider)
    local sb = text(ui.sidebar.buf)
    assert.is_not_nil(sb:find("2 sessions", 1, true))
    assert.is_not_nil(sb:find("Codex CLI", 1, true))
    assert.is_not_nil(sb:find("Claude Code", 1, true))
  end)

  it("watches every session in view", function()
    add_codex()
    local ui = Review.open({ cwd = fx.cwd })
    assert.are.same(2, #ui.watchers)
  end)

  it("expands and collapses a session group", function()
    add_codex()
    local ui = Review.open({ cwd = fx.cwd })
    local row = row_where(ui.sidebar, function(it)
      return it.kind == "session"
    end)
    assert.is_not_nil(row)
    local id = ui.sidebar.lines[row].item.session
    local before = ui.expanded[id]
    vim.api.nvim_set_current_win(ui.sidebar.win)
    vim.api.nvim_win_set_cursor(ui.sidebar.win, { row, 0 })
    feed("<CR>")
    assert.are_not.same(before, ui.expanded[id])
  end)

  it("narrows to one session with s, and widens again", function()
    add_codex()
    local ui = Review.open({ cwd = fx.cwd })
    local offered
    local prev = vim.ui.select
    vim.ui.select = function(items, _, cb)
      offered = items
      for _, item in ipairs(items) do
        if item.src.provider == "claude" then
          return cb(item)
        end
      end
      cb(nil)
    end
    vim.api.nvim_set_current_win(ui.sidebar.win)
    feed("s")
    vim.ui.select = prev

    assert.are.same(2, #offered)
    assert.are.same("claude", ui.transcript.provider)
    assert.are.same(1, #ui.transcripts)
    assert.is_not_nil(text(ui.sidebar.buf):find("1 session (s: all)", 1, true))
    -- the old selection belonged to a different set of turns
    assert.are.same(ui.transcript.turns[#ui.transcript.turns].id, ui.sel_turn)

    -- pressing s while narrowed widens back, without a picker
    vim.ui.select = function()
      error("no picker when widening")
    end
    feed("s")
    vim.ui.select = prev
    assert.is_nil(ui.session)
    assert.are.same(2, #ui.transcripts)
  end)

  it("labels a session by its opening prompt, not its id", function()
    add_codex()
    local sources = Review.sessions(fx.cwd)
    local label = UI.describe(sources[1])
    assert.is_not_nil(label:find("Codex CLI", 1, true))
    assert.is_not_nil(label:find("add a changelog", 1, true))
    assert.is_not_nil(label:find("turn", 1, true))
    assert.is_not_nil(label:find("file", 1, true))
  end)

  it("keeps comments when narrowing, since they belong to the project", function()
    add_codex()
    local ui = Review.open({ cwd = fx.cwd })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b1:1", anchor = {}, body = "note" })
    local prev = vim.ui.select
    vim.ui.select = function(items, _, cb)
      for _, item in ipairs(items) do
        if item.src.provider == "claude" then
          return cb(item)
        end
      end
    end
    vim.api.nvim_set_current_win(ui.sidebar.win)
    feed("s")
    vim.ui.select = prev
    assert.are.same(1, Review.pending(fx.cwd))
  end)

  it("does not offer a picker for a lone session", function()
    local ui = Review.open({ cwd = fx.cwd })
    assert.are.same(1, #ui.sessions)
    -- a single session needs no grouping row
    assert.is_nil(text(ui.sidebar.buf):find("Claude Code", 1, true))
    local prev = vim.ui.select
    vim.ui.select = function()
      error("the picker must not open")
    end
    vim.api.nvim_set_current_win(ui.sidebar.win)
    feed("s")
    vim.ui.select = prev
    local said = false
    for _, n in ipairs(notices) do
      said = said or n:find("only session", 1, true) ~= nil
    end
    assert.is_true(said)
  end)

  it("leaves everything alone when the picker is cancelled", function()
    add_codex()
    local ui = Review.open({ cwd = fx.cwd })
    local before = ui.session
    local prev = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    vim.api.nvim_set_current_win(ui.sidebar.win)
    feed("s")
    vim.ui.select = prev
    assert.are.same(before, ui.session)
  end)
end)

describe("review marks", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_cli, restore_notify, notices
  local Marks = require("sidekick.review.marks")
  local ns = vim.api.nvim_create_namespace("sidekick.review.marks")

  ---@param buf integer
  local function marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end

  ---@param opts table
  local function comment(opts)
    return Store.get(fx.cwd):add(vim.tbl_extend("force", {
      turn = "t1",
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 4,
      side = "new",
      anchor_key = "new:4",
      -- anchor on the line's real text: a placeholder would read as drifted
      anchor = { (vim.split(Fixture.FILE_AFTER, "\n"))[4] },
      body = "why?",
    }, opts))
  end

  before_each(function()
    fx = Fixture.setup()
    _, restore_cli = Fixture.stub_cli()
    notices, restore_notify = Fixture.stub_notify()
    Marks.enable()
  end)

  after_each(function()
    Marks.disable()
    UI.close()
    restore_cli()
    restore_notify()
    fx.cleanup()
  end)

  it("shows an unresolved comment in the file it is about", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    local buf = vim.api.nvim_get_current_buf()
    assert.are.same(0, #marks(buf))

    comment({ body = "should this respect log levels?" })
    vim.wait(50)

    local m = marks(buf)
    assert.are.same(1, #m)
    assert.are.same(3, m[1][2]) -- 0-indexed line 4
    assert.is_not_nil(m[1][4].sign_text)
    assert.are.same("SidekickReviewPending", m[1][4].sign_hl_group)
    assert.is_not_nil(m[1][4].virt_text[1][1]:find("respect log levels", 1, true))
  end)

  it("distinguishes a sent comment from a draft", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    local buf = vim.api.nvim_get_current_buf()
    comment({ status = "sent" })
    vim.wait(50)
    local m = marks(buf)
    assert.are.same("SidekickReviewSent", m[1][4].sign_hl_group)
    assert.is_not_nil(m[1][4].virt_text[1][1]:find("awaiting reply", 1, true))
  end)

  it("stops showing a resolved comment", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    local buf = vim.api.nvim_get_current_buf()
    local c = comment({})
    vim.wait(50)
    assert.are.same(1, #marks(buf))
    Store.get(fx.cwd):set_status(c.id, "resolved")
    vim.wait(50)
    assert.are.same(0, #marks(buf))
  end)

  it("collapses several comments on one line", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    local buf = vim.api.nvim_get_current_buf()
    comment({ body = "one" })
    comment({ body = "two" })
    vim.wait(50)
    local m = marks(buf)
    assert.are.same(1, #m)
    assert.is_not_nil(m[1][4].virt_text[1][1]:find("2 comments:", 1, true))
  end)

  it("keeps other files' comments out of the buffer", function()
    comment({})
    Store.get(fx.cwd):add({
      turn = "t1",
      target = "file",
      file = fx.newfile,
      rel = "lua/brand.lua",
      lnum = 1,
      side = "new",
      anchor_key = "new:1",
      anchor = {},
      body = "elsewhere",
    })
    vim.wait(50)
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    assert.are.same(1, #marks(vim.api.nvim_get_current_buf()))
    vim.cmd.edit(vim.fn.fnameescape(fx.newfile))
    assert.are.same(1, #marks(vim.api.nvim_get_current_buf()))
  end)

  it("recovers a comment whose line is past the end but whose code is still there", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    comment({ lnum = 9999, anchor_key = "new:9999" })
    vim.wait(50)
    local m = marks(vim.api.nvim_get_current_buf())
    assert.are.same(1, #m)
    assert.are.same(3, m[1][2]) -- found by its anchor text, on line 4
  end)

  it("drops a comment that is past the end and unanchorable", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    comment({ lnum = 9999, anchor_key = "new:9999", anchor = { "-- never existed" } })
    vim.wait(50)
    assert.are.same(0, #marks(vim.api.nvim_get_current_buf()))
  end)

  it("marks nothing for a response comment", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    Store.get(fx.cwd):add({ turn = "t1", target = "response", anchor_key = "b1:1", anchor = {}, body = "general" })
    vim.wait(50)
    assert.are.same(0, #marks(vim.api.nvim_get_current_buf()))
  end)

  it("opens the review on the comment under the cursor", function()
    local turns = require("sidekick.review.model").load(fx.cwd).turns
    local turn = turns[#turns]
    comment({ turn = turn.id, body = "does this respect log levels?" })
    vim.wait(50)

    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    assert.are.same(1, #Review.at_cursor())
    assert.is_true(Review.open_at())

    local ui = UI.current
    assert.are.same(turn.id, ui.sel_turn)
    assert.are.same(fx.file, ui.sel_key)
    assert.are.same(ui.main.win, vim.api.nvim_get_current_win())
    -- the thread is opened, not left folded
    assert.is_not_nil(text(ui.main.buf):find("does this respect log levels?", 1, true))
  end)

  it("says so when there is no comment on the line", function()
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_false(Review.open_at())
    local said = false
    for _, n in ipairs(notices) do
      said = said or n:find("no review comment on this line", 1, true) ~= nil
    end
    assert.is_true(said)
  end)

  it("follows the code when the file shifts", function()
    local Diff = require("sidekick.review.diff")
    local body = Diff.read(fx.file)
    local src = vim.split(body, "\n")
    comment({ anchor = { src[4] }, body = "respect log levels?" })

    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.wait(30)
    assert.are.same(3, marks(vim.api.nvim_get_current_buf())[1][2])

    -- two lines inserted above push everything down
    Fixture.write(fx.file, "-- header\n-- more\n" .. body)
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.wait(30)

    local m = marks(vim.api.nvim_get_current_buf())
    assert.are.same(5, m[1][2]) -- 0-indexed line 6
    -- and the store is updated, so the review pane agrees with the buffer
    assert.are.same(6, Store.get(fx.cwd):find("c1").lnum)
    assert.are.same("new:6", Store.get(fx.cwd):find("c1").anchor_key)
  end)

  it("flags a comment whose code changed rather than moving it", function()
    comment({ anchor = { "-- a line that never existed" }, body = "was this needed?" })
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.wait(30)

    local m = marks(vim.api.nvim_get_current_buf())
    assert.are.same(1, #m)
    -- stays where it was recorded, but says the position is a guess
    assert.are.same(3, m[1][2])
    assert.is_not_nil(m[1][4].virt_text[1][1]:find("code changed since", 1, true))
    -- a guessed position is never written back
    assert.are.same(4, Store.get(fx.cwd):find("c1").lnum)
  end)

  it("drops a comment whose line no longer exists at all", function()
    comment({ anchor = { "-- gone" } })
    Fixture.write(fx.file, "local M = {}\nreturn M\n")
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.wait(30)
    assert.are.same(0, #marks(vim.api.nvim_get_current_buf()))
    -- the comment itself survives; it is just not shown against wrong code
    assert.is_not_nil(Store.get(fx.cwd):find("c1"))
  end)

  it("resolves a repeated anchor to the nearest match", function()
    local lines = { "x", "dup", "y", "z", "dup", "w" }
    local function at(lnum)
      return (Marks.locate(lines, { anchor = { "dup" }, lnum = lnum }))
    end
    assert.are.same(5, at(4))
    assert.are.same(2, at(3))
    assert.are.same(5, at(5)) -- an exact hit beats a nearer duplicate
  end)

  it("matches a multi-line anchor as a block", function()
    local lines = { "a", "start", "middle", "end", "b", "start", "nope", "end" }
    local found, exact = Marks.locate(lines, { anchor = { "start", "middle", "end" }, lnum = 6 })
    assert.are.same(2, found)
    assert.is_true(exact)
  end)

  it("can be turned off", function()
    comment({})
    vim.cmd.edit(vim.fn.fnameescape(fx.file))
    vim.wait(50)
    assert.are.same(1, #marks(vim.api.nvim_get_current_buf()))

    local prev = Config.review.signs.enabled
    Config.review.signs.enabled = false
    Marks.refresh()
    assert.are.same(0, #marks(vim.api.nvim_get_current_buf()))
    Config.review.signs.enabled = prev
  end)
end)

describe("review delivery", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_notify, notices, prev_cli

  --- A CLI whose delivery outcome the test controls.
  ---@param ok boolean
  ---@return table[] sent
  local function stub_cli(ok)
    local sent = {}
    prev_cli = prev_cli or package.loaded["sidekick.cli"]
    package.loaded["sidekick.cli"] = setmetatable({
      send = function(opts)
        sent[#sent + 1] = opts
        if opts.on_send then
          opts.on_send(ok, ok and nil or "channel closed")
        end
      end,
    }, {
      __index = function()
        return function() end
      end,
    })
    return sent
  end

  before_each(function()
    fx = Fixture.setup()
    notices, restore_notify = Fixture.stub_notify()
  end)

  after_each(function()
    UI.close()
    if prev_cli then
      package.loaded["sidekick.cli"] = prev_cli
      prev_cli = nil
    end
    restore_notify()
    fx.cleanup()
  end)

  it("keeps comments pending when delivery fails", function()
    local sent = stub_cli(false)
    local ui = Review.open({ cwd = fx.cwd })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b1:1", anchor = {}, body = "fix" })
    ui:render()

    vim.api.nvim_set_current_win(ui.main.win)
    local _, restore = Fixture.stub_composer(function(o)
      return o.body
    end)
    feed("S")
    restore()

    assert.are.same(1, #sent)
    -- a review marked sent before the CLI took it would silently disappear
    assert.are.same("pending", Store.get(fx.cwd):find("c1").status)
    local told = false
    for _, n in ipairs(notices) do
      told = told or n:find("could not deliver", 1, true) ~= nil
    end
    assert.is_true(told)
  end)

  it("does not record a verdict when delivery fails", function()
    stub_cli(false)
    local ui = Review.open({ cwd = fx.cwd })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b1:1", anchor = {}, body = "blocking" })
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    local _, restore = Fixture.stub_composer(function(o)
      return o.body
    end)
    feed("gr")
    restore()
    assert.is_nil(Store.get(fx.cwd):verdict(ui.sel_turn))
  end)

  it("addresses the review to the agent whose turn it is", function()
    local sent = stub_cli(true)
    local ui = Review.open({ cwd = fx.cwd })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b1:1", anchor = {}, body = "q" })
    ui:render()

    vim.api.nvim_set_current_win(ui.main.win)
    local title
    local _, restore = Fixture.stub_composer(function(o)
      title = o.title
      return o.body
    end)
    feed("S")
    restore()

    -- reviewing a Codex turn must not send the review to Claude
    assert.are.same("claude", sent[1].name)
    assert.is_not_nil(title:find("Claude Code", 1, true))
    assert.are.same("sent", Store.get(fx.cwd):find("c1").status)
  end)
end)

describe("review.ui verdicts", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_cli, restore_notify, sent, notices

  before_each(function()
    fx = Fixture.setup()
    sent, restore_cli = Fixture.stub_cli()
    notices, restore_notify = Fixture.stub_notify()
  end)

  after_each(function()
    UI.close()
    restore_cli()
    restore_notify()
    fx.cleanup()
  end)

  it("approves a turn with nothing pending", function()
    local ui = Review.open({ cwd = fx.cwd })
    vim.api.nvim_set_current_win(ui.main.win)
    local body
    local _, restore = Fixture.stub_composer(function(o)
      body = o.body
      return o.body
    end)
    feed("ga")
    restore()

    assert.is_not_nil(body:find("**Approved.**", 1, true))
    assert.is_nil(body:find("### [c", 1, true))
    assert.are.same(1, #sent)
    assert.are.same("approved", Store.get(fx.cwd):verdict(ui.sel_turn))
  end)

  it("refuses to request changes with nothing to block on", function()
    local ui = Review.open({ cwd = fx.cwd })
    vim.api.nvim_set_current_win(ui.main.win)
    feed("gr")
    local warned = false
    for _, n in ipairs(notices) do
      warned = warned or n:find("no pending comments", 1, true) ~= nil
    end
    assert.is_true(warned)
    assert.are.same(0, #sent)
  end)

  it("requests changes and carries the comments", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:add({
      turn = ui.sel_turn,
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 4,
      side = "new",
      anchor_key = "new:4",
      anchor = { "x" },
      body = "needs a test",
    })
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    local body
    local _, restore = Fixture.stub_composer(function(o)
      body = o.body
      return o.body
    end)
    feed("gr")
    restore()

    assert.is_not_nil(body:find("**Changes requested.**", 1, true))
    assert.is_not_nil(body:find("needs a test", 1, true))
    assert.is_not_nil(body:find("### [c1]", 1, true))
    assert.are.same("sent", store:find("c1").status)
    assert.are.same("changes", store:verdict(ui.sel_turn))
  end)

  it("marks the verdict in the sidebar", function()
    local ui = Review.open({ cwd = fx.cwd })
    local store = Store.get(fx.cwd)
    store:set_verdict(ui.transcript.turns[1].id, "approved")
    store:set_verdict(ui.transcript.turns[2].id, "changes")
    ui:render()
    local sb = text(ui.sidebar.buf)
    assert.is_not_nil(sb:find("✓", 1, true))
    assert.is_not_nil(sb:find("✗", 1, true))
  end)

  it("records nothing when the message is emptied", function()
    local ui = Review.open({ cwd = fx.cwd })
    vim.api.nvim_set_current_win(ui.main.win)
    local _, restore = Fixture.stub_composer("   \n  ")
    feed("ga")
    restore()
    assert.are.same(0, #sent)
    assert.is_nil(Store.get(fx.cwd):verdict(ui.sel_turn))
  end)

  it("persists a verdict and clears it with the turn", function()
    local ui = Review.open({ cwd = fx.cwd })
    local turn = ui.sel_turn
    Store.get(fx.cwd):set_verdict(turn, "approved")
    Store.reset()
    local reloaded = Store.get(fx.cwd)
    assert.are.same("approved", reloaded:verdict(turn))
    reloaded:clear(turn)
    assert.is_nil(reloaded:verdict(turn))
  end)
end)

describe("review.ui layouts", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_cli, restore_notify, sent

  local function panes()
    local n = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if UI.pane_kind(w) then
        n = n + 1
      end
    end
    return n
  end

  before_each(function()
    fx = Fixture.setup()
    sent, restore_cli = Fixture.stub_cli()
    _, restore_notify = Fixture.stub_notify()
  end)

  after_each(function()
    UI.close()
    restore_cli()
    restore_notify()
    fx.cleanup()
  end)

  it("floats by default, leaving the window layout alone", function()
    local before = #vim.api.nvim_list_wins()
    local ui = Review.open({ cwd = fx.cwd })
    assert.are.same("float", ui.layout)
    assert.are.same("editor", vim.api.nvim_win_get_config(ui.sidebar.win).relative)
    UI.close()
    assert.are.same(before, #vim.api.nvim_list_wins())
  end)

  it("opens in its own tabpage", function()
    local origin = vim.api.nvim_get_current_tabpage()
    local ui = Review.open({ cwd = fx.cwd, layout = "tab" })
    assert.are.same("tab", ui.layout)
    assert.are.same(2, #vim.api.nvim_list_tabpages())
    assert.are.same(ui.tabpage, vim.api.nvim_get_current_tabpage())
    assert.is_true(ui.owns_tab)
    assert.are.same(origin, ui.origin_tab)
    -- the panes are real windows there, only the status bar stays floating
    assert.are.same("", vim.api.nvim_win_get_config(ui.sidebar.win).relative)
    assert.are.same("", vim.api.nvim_win_get_config(ui.main.win).relative)
    assert.are.same("editor", vim.api.nvim_win_get_config(ui.footer.win).relative)
    assert.is_true(vim.api.nvim_win_get_width(ui.main.win) > vim.api.nvim_win_get_width(ui.sidebar.win))
  end)

  it("removes the tabpage it created and returns you home", function()
    local origin = vim.api.nvim_get_current_tabpage()
    local ui = Review.open({ cwd = fx.cwd, layout = "tab" })
    ui:close()
    assert.are.same(1, #vim.api.nvim_list_tabpages())
    assert.are.same(origin, vim.api.nvim_get_current_tabpage())
    assert.are.same(0, panes())
  end)

  it("splits the current tabpage without stealing a window", function()
    local before = #vim.api.nvim_list_wins()
    local ui = Review.open({ cwd = fx.cwd, layout = "split" })
    assert.are.same(1, #vim.api.nvim_list_tabpages())
    assert.is_falsy(ui.owns_tab)
    assert.are.same("", vim.api.nvim_win_get_config(ui.sidebar.win).relative)
    ui:close()
    assert.are.same(0, panes())
    assert.are.same(before, #vim.api.nvim_list_wins())
  end)

  it("sends from the tabpage the review was opened on", function()
    -- `cli.tab_scoped` binds a session to a tabpage; a review living in its own
    -- tab must not address (or spawn) a different agent
    local prev = Config.cli.tab_scoped
    Config.cli.tab_scoped = true
    local ui = Review.open({ cwd = fx.cwd, layout = "tab" })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b2:1", anchor = {}, body = "look here" })
    ui:render()

    local seen
    package.loaded["sidekick.cli"].send = function(o)
      seen = vim.api.nvim_get_current_tabpage()
      sent[#sent + 1] = o
    end
    vim.api.nvim_set_current_win(ui.main.win)
    local _, restore = Fixture.stub_composer(function(o)
      return o.body
    end)
    vim.api.nvim_feedkeys(vim.keycode("S"), "mx", false)
    restore()

    assert.are.same(ui.origin_tab, seen)
    assert.are.same(ui.tabpage, vim.api.nvim_get_current_tabpage())
    Config.cli.tab_scoped = prev
  end)

  it("falls back to floating for an unknown layout", function()
    local ui = Review.open({ cwd = fx.cwd, layout = "nonsense" })
    assert.are.same("float", ui.layout)
  end)

  it("resizes in every layout", function()
    for _, mode in ipairs({ "float", "tab", "split" }) do
      local ui = Review.open({ cwd = fx.cwd, layout = mode })
      assert.is_true(pcall(UI.resize, ui), mode)
      local footer = vim.api.nvim_win_get_config(ui.footer.win)
      assert.is_true(footer.row + 1 <= vim.o.lines - vim.o.cmdheight, mode)
      ui:close()
    end
  end)
end)

describe("review.ui threads", function()
  local fx ---@type sidekick.test.ReviewFixture
  local restore_cli, restore_notify

  ---@param ui sidekick.review.UI
  ---@param opts table
  local function comment(ui, opts)
    return Store.get(fx.cwd):add(vim.tbl_extend("force", {
      turn = ui.sel_turn,
      target = "file",
      file = fx.file,
      rel = "lua/greet.lua",
      lnum = 4,
      side = "new",
      anchor_key = "new:4",
      anchor = { "  vim.notify('hi ' .. name)" },
      body = "why?",
    }, opts))
  end

  before_each(function()
    fx = Fixture.setup()
    _, restore_cli = Fixture.stub_cli()
    _, restore_notify = Fixture.stub_notify()
  end)

  after_each(function()
    UI.close()
    restore_cli()
    restore_notify()
    fx.cleanup()
  end)

  it("folds a resolved thread and keeps an open one expanded", function()
    local ui = Review.open({ cwd = fx.cwd })
    comment(ui, { body = "still open", status = "pending" })
    comment(ui, { lnum = 9, anchor_key = "new:9", body = "already handled", status = "resolved",
      replies = { { role = "claude", body = "fixed", ts = 0, turn = "x" } } })
    ui.sel_key = fx.file
    ui:render()
    local out = text(ui.main.buf)
    assert.is_not_nil(out:find("still open", 1, true))
    -- resolved folds to a summary line carrying its reply count
    assert.is_not_nil(out:find("1 reply · resolved", 1, true))
    assert.is_nil(out:find("fixed", 1, true))
  end)

  it("unfolds and refolds a thread", function()
    local ui = Review.open({ cwd = fx.cwd })
    local c = comment(ui, { status = "resolved", replies = { { role = "claude", body = "because latency", ts = 0, turn = "x" } } })
    ui.sel_key = fx.file
    ui:render()
    assert.is_nil(text(ui.main.buf):find("because latency", 1, true))

    vim.api.nvim_set_current_win(ui.main.win)
    local row = row_where(ui.main, function(it)
      return it.kind == "comment"
    end)
    vim.api.nvim_win_set_cursor(ui.main.win, { row, 0 })
    feed("za")
    assert.is_not_nil(text(ui.main.buf):find("because latency", 1, true))
    assert.is_true(ui.expanded_threads[c.id])

    row = row_where(ui.main, function(it)
      return it.kind == "comment"
    end)
    vim.api.nvim_win_set_cursor(ui.main.win, { row, 0 })
    feed("za")
    assert.is_nil(text(ui.main.buf):find("because latency", 1, true))
  end)

  it("folds and unfolds every thread at once", function()
    local ui = Review.open({ cwd = fx.cwd })
    comment(ui, { body = "one" })
    comment(ui, { lnum = 9, anchor_key = "new:9", body = "two" })
    ui.sel_key = fx.file
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    feed("zM")
    local out = text(ui.main.buf)
    assert.is_not_nil(out:find("▸", 1, true))
    feed("zR")
    out = text(ui.main.buf)
    assert.is_not_nil(out:find("one", 1, true))
    assert.is_not_nil(out:find("two", 1, true))
  end)

  it("labels each message in a multi-round conversation", function()
    local ui = Review.open({ cwd = fx.cwd })
    local c = comment(ui, {
      body = "respect log levels?",
      status = "pending",
      replies = {
        { role = "claude", body = "now passes INFO", ts = os.time() - 3600, turn = "x" },
        { role = "user", body = "still noisy", ts = os.time() - 60 },
      },
    })
    ui.sel_key = fx.file
    ui.expanded_threads[c.id] = true
    ui:render()
    local out = text(ui.main.buf)
    assert.is_not_nil(out:find("respect log levels?", 1, true))
    assert.is_not_nil(out:find("claude", 1, true))
    assert.is_not_nil(out:find("now passes INFO", 1, true))
    assert.is_not_nil(out:find("still noisy", 1, true))
    assert.is_not_nil(out:find("2 replies", 1, true))
  end)

  it("lists every conversation in the threads view", function()
    local ui = Review.open({ cwd = fx.cwd })
    comment(ui, { body = "on the file" })
    Store.get(fx.cwd):add({ turn = ui.sel_turn, target = "response", anchor_key = "b2:1", anchor = {}, body = "on the response" })
    ui.sel_key = Store.THREADS
    ui:render()
    local out = text(ui.main.buf)
    assert.is_not_nil(out:find("2 conversations", 1, true))
    assert.is_not_nil(out:find("on the file", 1, true))
    assert.is_not_nil(out:find("on the response", 1, true))
    -- the threads view names where each one is anchored
    assert.is_not_nil(out:find("lua/greet.lua:4", 1, true))
  end)

  it("offers a threads node only once there is a conversation", function()
    local ui = Review.open({ cwd = fx.cwd })
    assert.is_nil(text(ui.sidebar.buf):find("Threads", 1, true))
    comment(ui, {})
    ui:render()
    assert.is_not_nil(text(ui.sidebar.buf):find("Threads (1)", 1, true))
  end)

  it("jumps from a thread to the line it annotates", function()
    local ui = Review.open({ cwd = fx.cwd })
    comment(ui, { lnum = 9, anchor_key = "new:9", body = "why a bool?" })
    ui.sel_key = Store.THREADS
    ui:render()
    vim.api.nvim_set_current_win(ui.main.win)
    local row = row_where(ui.main, function(it)
      return it.kind == "comment"
    end)
    vim.api.nvim_win_set_cursor(ui.main.win, { row, 0 })
    feed("o")
    assert.are.same(fx.file, ui.sel_key)
    local at = ui.main.lines[vim.api.nvim_win_get_cursor(ui.main.win)[1]]
    assert.are.same("new:9", at.item.anchor_key)
  end)
end)

describe("review.render", function()
  it("never emits an embedded newline or an out-of-range highlight", function()
    local fx = Fixture.setup()
    local ui = Review.open({ cwd = fx.cwd })
    for _, pane in ipairs({ ui.sidebar, ui.main, ui.footer }) do
      for _, l in ipairs(pane.lines) do
        assert.is_nil(l.text:find("\n"))
        for _, hl in ipairs(l.hl or {}) do
          assert.is_true(hl[1] >= 0 and hl[1] <= #l.text)
          assert.is_true(hl[2] == -1 or hl[2] <= #l.text)
        end
      end
    end
    UI.close()
    fx.cleanup()
  end)

  it("formats relative times", function()
    assert.are.same("now", Render.ago(os.time()))
    assert.are.same("5m", Render.ago(os.time() - 300))
    assert.are.same("2h", Render.ago(os.time() - 7200))
    assert.are.same("3d", Render.ago(os.time() - 86400 * 3))
    assert.are.same("", Render.ago(0))
  end)
end)
