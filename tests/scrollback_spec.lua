---@module 'luassert'

local Scrollback = require("sidekick.cli.scrollback")

describe("cli scrollback", function()
  it("enables transcript scrollback for embedded Claude and Codex terminals", function()
    for _, name in ipairs({ "claude", "codex" }) do
      assert.is_true(Scrollback.is_enabled({ tool = { name = name } }))
    end
    assert.is_false(Scrollback.is_enabled({ tool = { name = "opencode", native_scroll = true } }))
    assert.is_false(Scrollback.is_enabled({ tool = { name = "aider" } }))
  end)

  it("renders the complete structured conversation as copyable text", function()
    local Model = require("sidekick.review.model")
    local Provider = require("sidekick.review.provider")
    local original_load, original_get = Model.load, Provider.get
    Model.load = function()
      return {
        turns = {
          {
            title = "first question",
            prompt = "first question",
            provider = "claude",
            blocks = { { kind = "text", text = "line one\nline two" } },
          },
          {
            title = "second question",
            prompt = "second question",
            provider = "claude",
            blocks = { { kind = "text", text = "the full final response" } },
          },
        },
      }
    end
    Provider.get = function()
      return { label = "Claude Code" }
    end

    local text = Scrollback.transcript_dump({ cwd = "/tmp/project", tool = { name = "claude" } })
    Model.load, Provider.get = original_load, original_get

    assert.is_not_nil(text:find("first question", 1, true))
    assert.is_not_nil(text:find("line one\nline two", 1, true))
    assert.is_not_nil(text:find("second question", 1, true))
    assert.is_not_nil(text:find("the full final response", 1, true))
  end)
end)
