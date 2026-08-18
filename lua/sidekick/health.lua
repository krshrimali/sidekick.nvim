local Config = require("sidekick.config")

local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local warn = vim.health.warn or vim.health.report_warn
local error = vim.health.error or vim.health.report_error

function M.check()
  start("Sidekick")

  if vim.fn.has("nvim-0.11.2") == 1 then
    ok("Using Neovim >= 0.11.2")
  else
    error("Neovim >= 0.11.2 is required")
    return
  end

  local clients = Config.get_clients()

  start("Sidekick Copilot LSP")

  local found = #clients > 0
  for name in pairs(vim.lsp.config._configs) do
    if Config.is_copilot(name) and vim.lsp.is_enabled(name) then
      ok(("Copilot LSP `%s` is enabled"):format(name))
      found = true
    end
  end
  if not found then
    error("No Copilot LSP server is enabled with `vim.lsp.enable(...)`")
  end

  local names = {} ---@type table<string,boolean>
  for _, client in ipairs(clients) do
    local cmd = vim.inspect(client.config.cmd):gsub("\\", "/")
    if cmd:find("/copilot.lua/", 0, true) then
      ok("Using `copilot.lua`'s bundled LSP server")
    elseif cmd:find("/copilot.vim/", 0, true) then
      ok("Using `copilot.vim`s bundled LSP server")
    end
    names[client.name] = true
    if client.handlers["didChangeStatus"] == require("sidekick.status").on_status then
      ok("Sidekick is handling Copilot LSP status notifications for client: " .. client.id)
    else
      error("Sidekick is not handling Copilot LSP status notifications for client: " .. client.id)
    end
  end
  if vim.tbl_count(names) > 1 then
    error("You have multiple different LSP servers running: " .. table.concat(vim.tbl_map(function(n)
      return "`" .. n .. "`"
    end, names)))
  end

  start("Sidekick AI CLI")
  if vim.o.autoread then
    ok("autoread is enabled")
  else
    warn("autoread is disabled, file changes from AI CLI tools will not be detected automatically")
  end

  if Config.cli.mux.enabled then
    ok("Terminal multiplexer integration is enabled")
  else
    ok("Terminal multiplexer integration is disabled")
  end

  for _, mux in ipairs({ "tmux", "zellij" }) do
    if vim.fn.executable(mux) == 1 then
      ok("`" .. mux .. "` is installed")
    elseif mux == Config.cli.mux.backend then
      error("Multiplexer backend `" .. mux .. "` is not installed")
    else
      ok("`" .. mux .. "` is not installed, but it's not the configured backend")
    end
  end

  if vim.fn.has("win32") == 0 then
    for _, c in ipairs({ "ps", "lsof" }) do
      if vim.fn.executable(c) == 1 then
        ok("`" .. c .. "` is installed")
      else
        warn("`" .. c .. "` is not installed, running processes and ports will not be detected")
      end
    end
  end

  M.review()

  start("Sidekick AI CLI Tools")
  local tools = require("sidekick.config").tools()
  local tool_names = vim.tbl_keys(tools) ---@type string[]
  table.sort(tool_names)
  for _, name in ipairs(tool_names) do
    local tool = tools[name]
    if vim.fn.executable(tool.cmd[1]) == 1 then
      ok("`" .. tool.name .. "` is installed")
    else
      warn("`" .. tool.name .. "` is not installed")
    end
  end
end

--- Diagnose the review feature.
---
--- The failure everyone hits is "no transcript found", and by itself that says
--- nothing about *why*: the CLI may never have run here, the storage directory
--- may be somewhere else, or the sessions may all belong to a different
--- project. So report each of those separately.
function M.review()
  start("Sidekick Review")

  local Config_ = require("sidekick.config")
  if Config_.review and Config_.review.enabled == false then
    warn("Review is disabled (`opts.review.enabled = false`)")
    return
  end

  local Provider = require("sidekick.review.provider")
  local Transcript = require("sidekick.review.transcript")
  local cwd = vim.fs.normalize(vim.uv.cwd() or ".")

  local total = 0
  for _, provider in ipairs(Provider.all()) do
    local dir = provider.name == "claude" and provider.projects_dir() or provider.sessions_dir()
    local short = vim.fn.fnamemodify(dir, ":~")

    if not vim.uv.fs_stat(dir) then
      warn(("`%s`: no session storage at `%s` — has the CLI run on this machine?"):format(provider.label, short))
    else
      local found, err = pcall(provider.sources, cwd)
      if not found then
        error(("`%s`: failed to scan `%s`: %s"):format(provider.label, short, tostring(err)))
      else
        local sources = err --[[@as sidekick.review.Source[] ]]
        total = total + #sources
        if #sources > 0 then
          ok(("`%s`: %d session%s for this directory"):format(provider.label, #sources, #sources == 1 and "" or "s"))
        else
          ok(("`%s`: storage found at `%s`, but no session for this directory"):format(provider.label, short))
        end
      end
    end
  end

  if total == 0 then
    warn(
      "No sessions for `"
        .. vim.fn.fnamemodify(cwd, ":~")
        .. "`.\nRun `claude` or `codex` from this directory, then `:Sidekick review`."
        .. "\nSessions are matched on the cwd recorded inside the transcript, so starting"
        .. "\nthe CLI from a subdirectory or a symlinked path will not match."
    )
    return
  end

  -- the newest session is what `:Sidekick review` opens, so verify it parses
  local src = Transcript.latest(cwd)
  if not src then
    return
  end
  local built, tr = pcall(require("sidekick.review.model").build, src)
  if not built then
    error(("Failed to parse `%s`: %s"):format(vim.fn.fnamemodify(src.file, ":~"), tostring(tr)))
  elseif #tr.turns == 0 then
    warn("The newest session has no reviewable turns yet")
  else
    ok(("Newest session parses: %d turn%s"):format(#tr.turns, #tr.turns == 1 and "" or "s"))
  end

  local store = require("sidekick.review.store").get(cwd)
  local pending = store:pending_count()
  if pending > 0 then
    ok(("%d comment%s pending in `%s`"):format(pending, pending == 1 and "" or "s", vim.fn.fnamemodify(store.file, ":~")))
  else
    ok("No pending review comments")
  end

  M.validate_layout()
end

--- `layout` is the one review option a typo makes silently wrong.
function M.validate_layout()
  local layout = (require("sidekick.config").review or {}).layout or "tab"
  if layout == "float" or layout == "tab" or layout == "split" then
    ok(("Layout is `%s`"):format(layout))
  else
    error(("Invalid `opts.review.layout = %q` — expected `float`, `tab` or `split`"):format(tostring(layout)))
  end
end

return M
