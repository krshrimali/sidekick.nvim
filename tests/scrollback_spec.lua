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

  it("swaps a focused live terminal to the full transcript on normal mode", function()
    local Config = require("sidekick.config")
    local Model = require("sidekick.review.model")
    local Provider = require("sidekick.review.provider")
    local Session = require("sidekick.cli.session")
    local Terminal = require("sidekick.cli.terminal")
    local original_load, original_get = Model.load, Provider.get
    local watch = Config.cli.watch
    Config.cli.watch = false
    Model.load = function()
      return {
        turns = {
          {
            title = "question",
            prompt = "question",
            provider = "claude",
            blocks = { { kind = "text", text = "top of response\n" .. string.rep("history\n", 80) .. "bottom" } },
          },
        },
      }
    end
    Provider.get = function()
      return { label = "Claude Code" }
    end

    Session.setup()
    local terminal = Terminal.new({
      id = "scrollback-ui-test",
      cwd = vim.uv.cwd(),
      tool = {
        name = "claude",
        cmd = { "sh", "-c", "while :; do sleep 1; done" },
        config = {},
      },
    })
    terminal:start()
    terminal:focus()
    assert.is_not_nil(terminal.scrollback)
    vim.wait(100, function()
      return vim.fn.mode(true) == "t"
    end)
    assert.are.same("t", vim.fn.mode(true))
    vim.api.nvim_feedkeys(vim.keycode("<C-q>"), "tx", false)
    vim.wait(100, function()
      return terminal.scrollback:is_open()
    end)

    local active = vim.api.nvim_win_get_buf(terminal.win)
    local text = table.concat(vim.api.nvim_buf_get_lines(active, 0, -1, false), "\n")
    terminal:close()
    Model.load, Provider.get = original_load, original_get
    Config.cli.watch = watch

    assert.is_true(active ~= terminal.buf)
    assert.is_not_nil(text:find("top of response", 1, true))
    assert.is_not_nil(text:find("bottom", 1, true))
    assert.is_true(#vim.split(text, "\n", { plain = true }) > 80)
  end)
end)
