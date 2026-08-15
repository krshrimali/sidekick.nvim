---@module 'luassert'

local Diff = require("sidekick.review.diff")
local Fixture = require("tests.review_fixture")
local Markdown = require("sidekick.review.markdown")
local Model = require("sidekick.review.model")
local Patch = require("sidekick.review.patch")
local Provider = require("sidekick.review.provider")
local Transcript = require("sidekick.review.transcript")

describe("review.patch", function()
  local PATCH = table.concat({
    "*** Begin Patch",
    "*** Add File: /tmp/proj/new.lua",
    "+return {",
    "+  a = 1,",
    "+}",
    "*** Update File: /tmp/proj/old.lua",
    "@@",
    " local M = {}",
    "-local x = 1",
    "+local x = 2",
    "@@ function M.run()",
    " function M.run()",
    "-  return false",
    "+  return true",
    "*** Delete File: /tmp/proj/gone.lua",
    "*** End Patch",
  }, "\n")

  it("parses add, update and delete sections", function()
    local files = Patch.parse(PATCH)
    assert.are.same(3, #files)
    assert.are.same("add", files[1].action)
    assert.are.same("/tmp/proj/new.lua", files[1].path)
    assert.are.same("update", files[2].action)
    assert.are.same("delete", files[3].action)
  end)

  it("collapses an added file into one write", function()
    local add = Patch.parse(PATCH)[1]
    assert.are.same(1, #add.changes)
    assert.are.same("", add.changes[1].old)
    assert.are.same("return {\n  a = 1,\n}", add.changes[1].new)
  end)

  it("turns each @@ section into an old -> new pair", function()
    local upd = Patch.parse(PATCH)[2]
    assert.are.same(2, #upd.changes)
    assert.are.same("local M = {}\nlocal x = 1", upd.changes[1].old)
    assert.are.same("local M = {}\nlocal x = 2", upd.changes[1].new)
    assert.are.same("function M.run()\n  return false", upd.changes[2].old)
    assert.are.same("function M.run()\n  return true", upd.changes[2].new)
  end)

  it("drops sections that only carry context", function()
    local files = Patch.parse(table.concat({
      "*** Begin Patch",
      "*** Update File: /tmp/a.lua",
      "@@",
      " untouched",
      " also untouched",
      "@@",
      " ctx",
      "-gone",
      "*** End Patch",
    }, "\n"))
    assert.are.same(1, #files[1].changes)
    assert.are.same("ctx\ngone", files[1].changes[1].old)
  end)

  it("follows a rename to its destination", function()
    local files = Patch.parse(table.concat({
      "*** Begin Patch",
      "*** Update File: /tmp/from.lua",
      "*** Move to: /tmp/to.lua",
      "@@",
      "-a",
      "+b",
      "*** End Patch",
    }, "\n"))
    assert.are.same("/tmp/to.lua", files[1].path)
  end)

  it("ignores text that is not a patch", function()
    assert.are.same({}, Patch.parse("just some output\nnothing to see"))
    assert.are.same({}, Patch.files("ls -la"))
  end)

  it("extracts a patch embedded in a JavaScript string", function()
    -- how newer Codex builds record edits: the patch is a JS string literal
    local js = 'const patch = "*** Begin Patch\\n*** Add File: /tmp/x.lua\\n+local x = 1\\n*** End Patch\\n";\n'
      .. "const r = await tools.apply_patch({patch}); text(r)\n"
    local files = Patch.files(js)
    assert.are.same(1, #files)
    assert.are.same("/tmp/x.lua", files[1].path)
    assert.are.same("local x = 1", files[1].changes[1].new)
  end)

  it("extracts a patch passed directly as tool input", function()
    local files = Patch.files(PATCH)
    assert.are.same(3, #files)
  end)

  it("survives a quote inside the patch body", function()
    local js = 'const p = "*** Begin Patch\\n*** Add File: /tmp/q.lua\\n+print(\\"hi\\")\\n*** End Patch";'
    local files = Patch.files(js)
    assert.are.same(1, #files)
    assert.are.same('print("hi")', files[1].changes[1].new)
  end)
end)

describe("review.provider", function()
  it("exposes both CLIs", function()
    local names = vim.tbl_map(function(p)
      return p.name
    end, Provider.all())
    assert.is_true(vim.tbl_contains(names, "claude"))
    assert.is_true(vim.tbl_contains(names, "codex"))
  end)

  it("returns nil for an unknown provider", function()
    assert.is_nil(Provider.get("not-a-cli"))
  end)
end)

describe("review.provider.codex", function()
  local root, cwd, file, prev

  ---@param entries table[]
  local function write(entries)
    local lines = vim.tbl_map(function(e)
      return vim.json.encode(e)
    end, entries)
    Fixture.write(root .. "/2026/08/15/rollout-test.jsonl", table.concat(lines, "\n") .. "\n")
  end

  before_each(function()
    local tmp = vim.fn.tempname()
    root = tmp .. "/sessions"
    cwd = vim.fs.normalize(tmp .. "/proj")
    file = cwd .. "/src/main.lua"
    Fixture.write(file, "local M = {}\nlocal x = 2\nreturn M\n")
    prev = require("sidekick.review.provider.codex").root
    require("sidekick.review.provider.codex").root = root
  end)

  after_each(function()
    require("sidekick.review.provider.codex").root = prev
  end)

  ---@return table[]
  local function session()
    return {
      { type = "session_meta", timestamp = "2026-08-15T09:00:00.000Z", payload = { session_id = "s1", id = "s1", cwd = cwd } },
      -- the system prompt must never look like a user turn
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:01.000Z",
        payload = { type = "message", role = "developer", content = { { type = "input_text", text = "You are an agent." } } },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:02.000Z",
        payload = { type = "message", role = "user", content = { { type = "input_text", text = "<environment_context>\n  <cwd>/x</cwd>\n</environment_context>" } } },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:03.000Z",
        payload = { type = "message", role = "user", content = { { type = "input_text", text = "bump x to 2" } } },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:04.000Z",
        payload = { type = "reasoning", id = "r1", summary = { { type = "summary_text", text = "a one line change" } }, encrypted_content = "opaque" },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:05.000Z",
        payload = { type = "message", role = "assistant", content = { { type = "output_text", text = "Bumping it now." } } },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:06.000Z",
        payload = {
          type = "custom_tool_call",
          name = "exec",
          call_id = "call_1",
          input = 'const patch = "*** Begin Patch\\n*** Update File: '
            .. file
            .. '\\n@@\\n local M = {}\\n-local x = 1\\n+local x = 2\\n*** End Patch\\n";\nawait tools.apply_patch({patch})',
        },
      },
      {
        type = "response_item",
        timestamp = "2026-08-15T09:00:07.000Z",
        payload = { type = "custom_tool_call_output", call_id = "call_1", output = "Success. Updated the file." },
      },
      -- the UI mirror of the same events must not be counted twice
      { type = "event_msg", timestamp = "2026-08-15T09:00:08.000Z", payload = { type = "item_completed", item = { type = "AgentMessage" } } },
    }
  end

  it("finds a rollout by the cwd in its session_meta", function()
    write(session())
    local sources = Transcript.sources(cwd)
    assert.are.same(1, #sources)
    assert.are.same("codex", sources[1].provider)
    assert.are.same("s1", sources[1].session)
  end)

  it("ignores rollouts from another project", function()
    write(session())
    assert.are.same({}, Transcript.sources(vim.fn.tempname()))
  end)

  it("builds one turn from the real user message", function()
    write(session())
    local tr = Model.load(cwd)
    assert.is_not_nil(tr)
    assert.are.same("codex", tr.provider)
    assert.are.same(1, #tr.turns)
    assert.are.same("bump x to 2", tr.turns[1].title)
  end)

  it("skips developer prompts and environment blocks", function()
    write(session())
    local tr = Model.load(cwd)
    for _, t in ipairs(tr.turns) do
      assert.is_nil(t.prompt:find("You are an agent", 1, true))
      assert.is_nil(t.prompt:find("environment_context", 1, true))
    end
  end)

  it("keeps assistant prose and reasoning summaries", function()
    write(session())
    local blocks = Model.load(cwd).turns[1].blocks
    local kinds = vim.tbl_map(function(b)
      return b.kind
    end, blocks)
    assert.is_true(vim.tbl_contains(kinds, "text"))
    assert.is_true(vim.tbl_contains(kinds, "thinking"))
    for _, b in ipairs(blocks) do
      assert.is_nil((b.text or ""):find("opaque", 1, true))
    end
  end)

  it("turns an apply_patch into a reviewable file change", function()
    write(session())
    local turn = Model.load(cwd).turns[1]
    assert.are.same(1, #turn.files)
    assert.are.same("src/main.lua", turn.files[1].rel)
    assert.are.same("apply_patch", turn.tools[1].name)
  end)

  it("reconstructs the diff exactly against the file on disk", function()
    write(session())
    local tr = Model.load(cwd)
    local d = Diff.turn(tr.turns, tr.turns[1])[1]
    assert.is_false(d.approx)
    assert.are.same(1, d.added)
    assert.are.same(1, d.removed)
    assert.are.same("lua", d.filetype)
    local hit = false
    for _, h in ipairs(d.hunks) do
      for _, l in ipairs(h.lines) do
        if l.kind == "add" then
          assert.are.same("local x = 2", l.text)
          assert.are.same(2, l.new_lnum)
          hit = true
        end
      end
    end
    assert.is_true(hit)
  end)

  it("does not apply a patch whose call failed", function()
    local entries = session()
    entries[#entries - 1].payload.output = "error: patch did not apply"
    write(entries)
    assert.are.same(0, #Model.load(cwd).turns[1].files)
  end)
end)

describe("review.markdown", function()
  it("emits exactly one line per source line", function()
    local src = table.concat({
      "## Heading",
      "",
      "text with `code` and **bold**",
      "- a bullet",
      "1. numbered",
      "> quoted",
      "```lua",
      "local x = 1",
      "```",
      "---",
    }, "\n")
    local lines = Markdown.render(src, { width = 60 })
    assert.are.same(10, #lines)
    for i, l in ipairs(lines) do
      assert.are.same(i, l.src)
    end
  end)

  it("marks fenced bodies as code", function()
    local lines = Markdown.render("```lua\nlocal x = 1\nlocal y = 2\n```", { width = 40 })
    assert.is_nil(lines[1].code)
    assert.is_true(lines[2].code)
    assert.is_true(lines[3].code)
    assert.is_nil(lines[4].code)
  end)

  it("handles an unterminated fence", function()
    local lines = Markdown.render("```lua\nlocal x = 1", { width = 40 })
    assert.are.same(2, #lines)
    assert.is_true(lines[2].code)
  end)

  it("renders task list markers", function()
    local lines = Markdown.render("- [x] done\n- [ ] todo", { width = 40 })
    assert.is_nil(lines[1].text:find("[x]", 1, true))
    assert.is_not_nil(lines[1].text:find("done", 1, true))
    assert.is_not_nil(lines[2].text:find("todo", 1, true))
  end)

  it("keeps highlight ranges inside the line", function()
    local lines = Markdown.render("a `b` **c** [d](e)\n```lua\nlocal x = 1\n```", { width = 40 })
    for _, l in ipairs(lines) do
      for _, hl in ipairs(l.hl) do
        assert.is_true(hl[1] >= 0 and hl[1] <= #l.text)
        assert.is_true(hl[2] == -1 or hl[2] <= #l.text)
      end
    end
  end)

  it("never emits an embedded newline", function()
    for _, l in ipairs(Markdown.render("a\n\nb\n```\nc\n```", { width = 40 })) do
      assert.is_nil(l.text:find("\n"))
    end
  end)
end)
