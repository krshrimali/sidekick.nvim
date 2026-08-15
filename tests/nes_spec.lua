---@module 'luassert'

local Config = require("sidekick.config")
local Nes = require("sidekick.nes")

describe("nes enabled option", function()
  local buf
  local original_enabled

  before_each(function()
    original_enabled = Config.nes.enabled
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local foo" })
    vim.api.nvim_set_current_buf(buf)
    vim.g.sidekick_nes = nil
    vim.b[buf].sidekick_nes = nil
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.g.sidekick_nes = nil
    vim.b.sidekick_nes = nil
    Config.nes.enabled = original_enabled
    Nes._edits = {}
  end)

  it("does not move a window after it switches to another buffer", function()
    local other = vim.api.nvim_create_buf(false, true)
    Nes._jump({ 0, 3 }, buf)
    vim.api.nvim_set_current_buf(other)
    vim.wait(20)
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("does not apply an edit after the buffer version changes", function()
    local version = vim.lsp.util.buf_versions[buf] or 0
    vim.lsp.util.buf_versions[buf] = version
    local applied = false
    local original_client = Config.get_client
    local original_apply = vim.lsp.util.apply_text_edits
    Config.get_client = function()
      return { id = 1, offset_encoding = "utf-16" }
    end
    vim.lsp.util.apply_text_edits = function()
      applied = true
    end
    Nes.enabled = true
    Nes._edits = {
      {
        buf = buf,
        from = { 0, 0 },
        to = { 0, 0 },
        text = "changed",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        textDocument = { uri = "", version = version },
        is_empty = function()
          return false
        end,
      },
    }
    assert.is_true(Nes.apply())
    vim.lsp.util.buf_versions[buf] = version + 1
    vim.wait(20)
    Config.get_client = original_client
    vim.lsp.util.apply_text_edits = original_apply
    assert.is_false(applied)
  end)

  it("is enabled by default", function()
    assert.is_true(Config.nes.enabled(buf))
  end)

  it("honors global toggle", function()
    vim.g.sidekick_nes = false
    assert.is_false(Config.nes.enabled(buf))
  end)

  it("honors buffer toggle", function()
    vim.b[buf].sidekick_nes = false
    assert.is_false(Config.nes.enabled(buf))
  end)

  it("filters pending edits when disabled", function()
    local version = vim.lsp.util.buf_versions[buf] or 0
    vim.lsp.util.buf_versions[buf] = version
    ---@type sidekick.NesEdit
    Nes._edits = {
      {
        buf = buf,
        from = { 0, 0 },
        to = { 0, 0 },
        text = "",
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 0 },
        },
        textDocument = { uri = "", version = version },
        command = { title = "", command = "" },
      },
    }

    vim.g.sidekick_nes = false
    assert.are.same({}, Nes.get(buf))
  end)
end)
