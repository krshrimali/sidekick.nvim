---@module 'luassert'

local Config = require("sidekick.config")
local Fixture = require("tests.review_fixture")

--- Run a health function with the report handles captured.
---
--- `sidekick.health` binds `vim.health.*` at load time, so the module has to be
--- reloaded inside the stub for the capture to take.
---@param fn fun(health:table)
---@return string
local function report(fn)
  local out = {}
  local function cap(kind)
    return function(msg)
      out[#out + 1] = kind .. ": " .. tostring(msg)
    end
  end
  local saved = {
    start = vim.health.start,
    ok = vim.health.ok,
    warn = vim.health.warn,
    error = vim.health.error,
  }
  vim.health.start, vim.health.ok, vim.health.warn, vim.health.error =
    cap("start"), cap("ok"), cap("warn"), cap("error")
  package.loaded["sidekick.health"] = nil
  local ok, err = pcall(fn, require("sidekick.health"))
  vim.health.start, vim.health.ok, vim.health.warn, vim.health.error =
    saved.start, saved.ok, saved.warn, saved.error
  assert(ok, err)
  return table.concat(out, "\n")
end

---@param haystack string
---@param needle string
local function has(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

describe("review health", function()
  local fx ---@type sidekick.test.ReviewFixture
  local cwd

  before_each(function()
    fx = Fixture.setup()
    cwd = vim.uv.cwd()
    vim.uv.chdir(fx.cwd)
  end)

  after_each(function()
    vim.uv.chdir(cwd)
    fx.cleanup()
    Config.setup({ nes = { enabled = false } })
    vim.wait(20)
  end)

  it("reports a healthy project", function()
    local r = report(function(h)
      h.review()
    end)
    assert.is_true(has(r, "`Claude Code`: 1 session for this directory"))
    assert.is_true(has(r, "Newest session parses: 2 turns"))
    assert.is_true(has(r, "No pending review comments"))
    assert.is_false(has(r, "error:"))
  end)

  it("says when the CLI has never run on this machine", function()
    local claude = require("sidekick.review.provider.claude")
    local codex = require("sidekick.review.provider.codex")
    local a, b = claude.root, codex.root
    claude.root, codex.root = fx.root .. "/absent", fx.root .. "/absent"
    local r = report(function(h)
      h.review()
    end)
    claude.root, codex.root = a, b

    assert.is_true(has(r, "no session storage"))
    assert.is_true(has(r, "has the CLI run on this machine?"))
    -- and explains the rule that actually trips people up
    assert.is_true(has(r, "cwd recorded inside the transcript"))
  end)

  it("distinguishes empty storage from missing storage", function()
    local claude = require("sidekick.review.provider.claude")
    local prev = claude.root
    local empty = fx.root .. "/other-projects"
    Fixture.write(
      empty .. "/-elsewhere/s.jsonl",
      '{"type":"user","uuid":"a","cwd":"/elsewhere","message":{"role":"user","content":"hi"}}\n'
    )
    claude.root = empty
    local r = report(function(h)
      h.review()
    end)
    claude.root = prev

    assert.is_true(has(r, "no session for this directory"))
    assert.is_false(has(r, "no session storage"))
  end)

  it("survives a corrupt transcript alongside a good one", function()
    Fixture.write(vim.fs.dirname(fx.transcript) .. "/broken.jsonl", "{ not json\n")
    local r = report(function(h)
      h.review()
    end)
    assert.is_false(has(r, "failed to scan"))
    assert.is_true(has(r, "session"))
  end)

  it("flags an invalid layout", function()
    Config.setup({ nes = { enabled = false }, review = { layout = "sideways" } })
    vim.wait(20)
    local r = report(function(h)
      h.validate_layout()
    end)
    assert.is_true(has(r, "Invalid `opts.review.layout"))
    assert.is_true(has(r, "`float`, `tab` or `split`"))
  end)

  it("stops early when review is disabled", function()
    Config.setup({ nes = { enabled = false }, review = { enabled = false } })
    vim.wait(20)
    local r = report(function(h)
      h.review()
    end)
    assert.is_true(has(r, "Review is disabled"))
    assert.is_false(has(r, "Newest session parses"))
  end)

  it("surfaces pending comments", function()
    local store = require("sidekick.review.store").get(fx.cwd)
    store:add({ turn = "t", target = "response", anchor_key = "b1:1", anchor = {}, body = "x" })
    local r = report(function(h)
      h.review()
    end)
    assert.is_true(has(r, "1 comment pending"))
  end)

  it("is part of the full check", function()
    local r = report(function(h)
      h.check()
    end)
    assert.is_true(has(r, "start: Sidekick Review"))
  end)
end)
