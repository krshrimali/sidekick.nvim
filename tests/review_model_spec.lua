---@module 'luassert'

local Diff = require("sidekick.review.diff")
local Fixture = require("tests.review_fixture")
local Model = require("sidekick.review.model")
local Thread = require("sidekick.review.thread")
local Transcript = require("sidekick.review.transcript")

describe("review.transcript", function()
  it("encodes a cwd the way Claude Code does", function()
    assert.are.same("-home-user-Documents-sidekick-nvim", Transcript.encode("/home/user/Documents/sidekick.nvim"))
    assert.are.same("-home-user--claude", Transcript.encode("/home/user/.claude"))
  end)

  it("skips malformed and empty lines", function()
    local dir = vim.fn.tempname()
    local path = dir .. "/s.jsonl"
    Fixture.write(
      path,
      table.concat({
        '{"type":"user","uuid":"a","message":{"role":"user","content":"hi"}}',
        "not json at all",
        "{ truncated",
        '{"type":"assistant","uuid":"b","message":{"role":"assistant","content":[]}}',
      }, "\n") .. "\n"
    )
    local entries = Transcript.parse(path)
    assert.are.same(2, #entries)
    assert.are.same("user", entries[1].type)
    assert.are.same("assistant", entries[2].type)
    vim.fn.delete(dir, "rf")
  end)

  it("returns nothing for an unknown cwd", function()
    assert.are.same({}, Transcript.sources(vim.fn.tempname()))
  end)

  it("rejects transcripts from a cwd with the same encoded name", function()
    local root = vim.fn.tempname()
    local wanted = root .. "/a_b"
    local other = root .. "/a-b"
    local projects = root .. "/projects"
    local dir = projects .. "/" .. Transcript.encode(wanted)
    Fixture.write(dir .. "/other.jsonl", vim.json.encode({ type = "user", cwd = other }) .. "\n")
    local old_root = Transcript.root
    Transcript.root = projects
    assert.are.same({}, Transcript.sources(wanted))
    Transcript.root = old_root
    vim.fn.delete(root, "rf")
  end)
end)

describe("review.model", function()
  local fx ---@type sidekick.test.ReviewFixture

  before_each(function()
    fx = Fixture.setup()
  end)
  after_each(function()
    fx.cleanup()
  end)

  it("groups entries into turns", function()
    local tr = Model.load(fx.cwd)
    assert.is_not_nil(tr)
    assert.are.same(2, #tr.turns)
    assert.are.same("What does this module do?", tr.turns[1].title)
    assert.are.same(1, tr.turns[1].idx)
    assert.are.same(0, #tr.turns[1].files)
  end)

  it("marks only the last turn as pending", function()
    local tr = Model.load(fx.cwd)
    assert.is_false(tr.turns[1].pending)
    assert.is_true(tr.turns[2].pending)
  end)

  it("captures text, thinking and tool blocks", function()
    local tr = Model.load(fx.cwd)
    local kinds = vim.tbl_map(function(b)
      return b.kind
    end, tr.turns[2].blocks)
    assert.are.same("thinking", kinds[1])
    assert.are.same("text", kinds[2])
    assert.is_true(vim.tbl_contains(kinds, "tool"))
  end)

  it("ignores sidechain and meta entries", function()
    local tr = Model.load(fx.cwd)
    for _, turn in ipairs(tr.turns) do
      for _, b in ipairs(turn.blocks) do
        assert.is_nil((b.text or ""):find("SUBAGENT"))
      end
    end
  end)

  it("records tool errors from tool_result", function()
    local tr = Model.load(fx.cwd)
    local bash ---@type sidekick.review.Tool?
    for _, t in ipairs(tr.turns[2].tools) do
      if t.name == "Bash" then
        bash = t
      end
    end
    assert.is_not_nil(bash)
    assert.is_true(bash.error)
  end)

  it("collects the files a turn touched", function()
    local tr = Model.load(fx.cwd)
    local files = tr.turns[2].files
    assert.are.same(2, #files)
    assert.are.same("lua/greet.lua", files[1].rel)
    assert.are.same(2, #files[1].changes)
    assert.are.same("lua/brand.lua", files[2].rel)
    assert.is_true(files[2].created)
  end)

  it("folds slash commands into a readable prompt", function()
    local text = "<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship it</command-args>"
    assert.are.same("/goal ship it", Model.clean_prompt(text))
  end)

  it("strips system reminders from prompts", function()
    local text = "do the thing<system-reminder>ignore me</system-reminder>"
    assert.are.same("do the thing", Model.clean_prompt(text))
  end)
end)

describe("review.diff", function()
  local fx ---@type sidekick.test.ReviewFixture

  before_each(function()
    fx = Fixture.setup()
  end)
  after_each(function()
    fx.cleanup()
  end)

  it("keeps interior context between nearby changes", function()
    local hunks = Diff.hunks(Fixture.FILE_BEFORE, Fixture.FILE_AFTER)
    assert.are.same(1, #hunks)
    local kinds = vim.tbl_map(function(l)
      return l.kind
    end, hunks[1].lines)
    -- del/add for greet, then real context, then del/add/add for bye
    assert.are.same({
      "context",
      "context",
      "context",
      "del",
      "add",
      "context",
      "context",
      "context",
      "del",
      "add",
      "add",
      "context",
      "context",
      "context",
    }, kinds)
  end)

  it("splits changes that are far apart", function()
    local a = "a\n" .. string.rep("x\n", 20) .. "b\n"
    local b = "A\n" .. string.rep("x\n", 20) .. "B\n"
    assert.are.same(2, #Diff.hunks(a, b))
  end)

  it("handles creation and deletion of whole files", function()
    local created = Diff.hunks("", "x\ny\n")
    assert.are.same(1, #created)
    assert.are.same(2, #created[1].lines)
    assert.are.same("add", created[1].lines[1].kind)

    local removed = Diff.hunks("x\ny\n", "")
    assert.are.same(2, #removed[1].lines)
    assert.are.same("del", removed[1].lines[1].kind)
  end)

  it("returns no hunks for identical content", function()
    assert.are.same({}, Diff.hunks("same\n", "same\n"))
  end)

  it("reconstructs exact line numbers from the file on disk", function()
    local tr = Model.load(fx.cwd)
    local diffs = Diff.turn(tr.turns, tr.turns[2])
    local greet = diffs[1]
    assert.is_false(greet.approx)
    assert.are.same(3, greet.added)
    assert.are.same(2, greet.removed)
    assert.are.same("lua", greet.filetype)

    local disk = vim.split(Fixture.read(fx.file), "\n")
    for _, h in ipairs(greet.hunks) do
      for _, l in ipairs(h.lines) do
        if l.new_lnum then
          assert.are.same(disk[l.new_lnum], l.text)
        end
      end
    end
  end)

  it("keeps unchanged lines as context in an approximate diff", function()
    -- with no file to anchor to we lose line numbers, but not the shape of the
    -- edit: listing every line twice (once removed, once added) would be noise
    Fixture.write(fx.file, "something else entirely\n")
    local tr = Model.load(fx.cwd)
    local greet = Diff.turn(tr.turns, tr.turns[2])[1]
    assert.is_true(greet.approx)
    local kinds = {}
    for _, h in ipairs(greet.hunks) do
      for _, l in ipairs(h.lines) do
        kinds[l.kind] = (kinds[l.kind] or 0) + 1
      end
    end
    assert.are.same(3, kinds.add)
    assert.are.same(2, kinds.del)
  end)

  it("degrades instead of inventing line numbers when the file moved on", function()
    Fixture.write(fx.file, "something else entirely\n")
    local tr = Model.load(fx.cwd)
    local greet = Diff.turn(tr.turns, tr.turns[2])[1]
    assert.is_true(greet.approx)
    for _, h in ipairs(greet.hunks) do
      for _, l in ipairs(h.lines) do
        assert.is_nil(l.new_lnum)
        assert.is_nil(l.old_lnum)
      end
    end
  end)

  it("flags a file that is gone", function()
    vim.fn.delete(fx.newfile)
    local tr = Model.load(fx.cwd)
    local brand = Diff.turn(tr.turns, tr.turns[2])[2]
    assert.is_true(brand.missing)
    assert.is_true(#brand.hunks > 0)
  end)

  it("detects binary files", function()
    local bin = fx.cwd .. "/blob.bin"
    Fixture.write(bin, "\0\1\2binary")
    local turn = {
      id = "t",
      idx = 1,
      prompt = "",
      title = "",
      ts = 0,
      blocks = {},
      tools = {},
      cwd = fx.cwd,
      session = "s",
      pending = false,
      files = {
        { path = bin, rel = "blob.bin", created = false, added = 0, removed = 0, changes = { { kind = "write", old = "", new = "x", tool_id = "z" } } },
      },
    }
    local d = Diff.file({ turn }, turn, turn.files[1])
    assert.is_true(d.binary)
    assert.are.same(0, #d.hunks)
  end)

  it("shows each turn its own change when a file is edited twice", function()
    Fixture.append(fx, {
      { type = "user", uuid = "r1", timestamp = "2026-08-15T10:00:00.000Z", message = { role = "user", content = "also pass log levels" } },
      {
        type = "assistant",
        uuid = "r2",
        timestamp = "2026-08-15T10:00:10.000Z",
        message = {
          role = "assistant",
          content = {
            {
              type = "tool_use",
              id = "t9",
              name = "Edit",
              input = {
                file_path = fx.file,
                old_string = "  vim.notify('hi ' .. name)",
                new_string = "  vim.notify('hi ' .. name, vim.log.levels.INFO)",
              },
            },
          },
        },
      },
      { type = "user", uuid = "r3", message = { role = "user", content = { { type = "tool_result", tool_use_id = "t9", content = "ok" } } } },
    })
    Fixture.write(fx.file, (Fixture.FILE_AFTER:gsub("vim%.notify%('hi ' %.%. name%)", "vim.notify('hi ' .. name, vim.log.levels.INFO)")))

    local tr = Model.load(fx.cwd)
    assert.are.same(3, #tr.turns)

    local t3 = Diff.turn(tr.turns, tr.turns[3])[1]
    assert.is_false(t3.approx)
    assert.are.same(1, t3.added)
    assert.are.same(1, t3.removed)

    -- turn 2 must still show turn 2's edit, not turn 3's
    local t2 = Diff.turn(tr.turns, tr.turns[2])[1]
    assert.is_false(t2.approx)
    for _, h in ipairs(t2.hunks) do
      for _, l in ipairs(h.lines) do
        if l.kind == "add" then
          assert.is_nil(l.text:find("vim.log.levels", 1, true))
        end
      end
    end
  end)
end)

describe("review.thread", function()
  it("finds the tags a submitted review carried", function()
    local tags = Thread.submitted_tags("intro\n### [c1] a.lua:3\n### [c12] your response\n")
    assert.is_true(tags.c1)
    assert.is_true(tags.c12)
    assert.are.same(2, vim.tbl_count(tags))
  end)

  it("splits a reply on its tags", function()
    local answers, preamble = Thread.split(table.concat({
      "Both fair points.",
      "",
      "[c1]",
      "Switched to vim.log.levels.INFO.",
      "It keeps the default.",
      "",
      "**[c2]** removed the debug print.",
      "",
      "### [c3] not applicable",
    }, "\n"))
    assert.are.same("Both fair points.", preamble)
    assert.are.same("Switched to vim.log.levels.INFO.\nIt keeps the default.", answers.c1)
    assert.are.same("removed the debug print.", answers.c2)
    assert.are.same("not applicable", answers.c3)
  end)

  it("ignores a tag that is not at the start of a line", function()
    local answers = Thread.split("we should not treat [c1] mid-sentence as a tag")
    assert.is_nil(next(answers))
  end)

  it("accepts list and heading markers before a tag", function()
    assert.are.same("fixed", Thread.split("- [c9] fixed").c9)
    assert.are.same("fixed", Thread.split("## [c9] fixed").c9)
  end)
end)
