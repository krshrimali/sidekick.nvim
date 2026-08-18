---@module 'luassert'

local Sidekick = require("sidekick")

describe("init module", function()
  it("setup delegates to config", function()
    local called_opts
    local Config = require("sidekick.config")
    local original_setup = Config.setup
    Config.setup = function(opts)
      called_opts = opts
    end

    Sidekick.setup({ foo = true })
    Config.setup = original_setup

    assert.are.same({ foo = true }, called_opts)
  end)

  it("nes_jump_or_apply returns true only when actions succeed", function()
    local Nes = require("sidekick.nes")
    local original_have, original_jump, original_apply = Nes.have, Nes.jump, Nes.apply

    Nes.have = function()
      return true
    end
    Nes.jump = function()
      return false
    end
    Nes.apply = function()
      return true
    end

    assert.is_true(Sidekick.nes_jump_or_apply())

    Nes.have = function()
      return false
    end
    Nes.jump = function()
      return true
    end
    Nes.apply = function()
      return false
    end

    assert.is_false(Sidekick.nes_jump_or_apply())

    Nes.have, Nes.jump, Nes.apply = original_have, original_jump, original_apply
  end)

  it("allows setup to be called repeatedly without duplicate autocmds", function()
    local Config = require("sidekick.config")
    Config.setup({ nes = { enabled = false } })
    vim.wait(20)
    local first = #vim.api.nvim_get_autocmds({ group = Config.augroup })
    Config.setup({ nes = { enabled = false } })
    vim.wait(20)
    assert.are.same(first, #vim.api.nvim_get_autocmds({ group = Config.augroup }))
    assert.are.same(2, vim.fn.exists(":Sidekick"))
    Config.setup()
    vim.wait(20)
  end)
end)
