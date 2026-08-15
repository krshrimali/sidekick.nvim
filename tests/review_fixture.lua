---@module 'luassert'
--- Shared fixture for the review specs: a throwaway project plus a synthetic
--- Claude Code transcript that edits it.
local M = {}

---@class sidekick.test.ReviewFixture
---@field root string
---@field cwd string project directory
---@field file string an edited file
---@field newfile string a created file
---@field transcript string path of the JSONL transcript
---@field cleanup fun()

M.FILE_BEFORE = table.concat({
  "local M = {}",
  "",
  "function M.greet(name)",
  "  print('hi ' .. name)",
  "end",
  "",
  "function M.bye()",
  "  print('bye')",
  "end",
  "",
  "return M",
}, "\n") .. "\n"

M.FILE_AFTER = table.concat({
  "local M = {}",
  "",
  "function M.greet(name)",
  "  vim.notify('hi ' .. name)",
  "end",
  "",
  "function M.bye()",
  "  vim.notify('bye')",
  "  return true",
  "end",
  "",
  "return M",
}, "\n") .. "\n"

M.NEW_FILE = "return {\n  name = 'sidekick',\n}\n"

---@param path string
---@param content string
function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

---@param path string
---@return string
function M.read(path)
  local fd = assert(io.open(path, "r"))
  local data = fd:read("*a")
  fd:close()
  return data
end

--- Create a project + transcript and point the review modules at them.
---@return sidekick.test.ReviewFixture
function M.setup()
  local Transcript = require("sidekick.review.transcript")
  local Store = require("sidekick.review.store")

  local root = vim.fn.tempname()
  local cwd = vim.fs.normalize(root .. "/project")
  local file = cwd .. "/lua/greet.lua"
  local newfile = cwd .. "/lua/brand.lua"

  M.write(file, M.FILE_AFTER)
  M.write(newfile, M.NEW_FILE)

  local entries = {}
  local n = 0
  local function uuid()
    n = n + 1
    return ("u%04d"):format(n)
  end
  local function push(t)
    entries[#entries + 1] = vim.json.encode(t)
  end
  local function user(text, ts)
    push({ type = "user", uuid = uuid(), timestamp = ts, cwd = cwd, message = { role = "user", content = text } })
  end
  local function assistant(content, ts)
    push({ type = "assistant", uuid = uuid(), timestamp = ts, cwd = cwd, message = { role = "assistant", content = content } })
  end
  local function result(id, text, is_error)
    push({
      type = "user",
      uuid = uuid(),
      cwd = cwd,
      message = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = text, is_error = is_error } } },
    })
  end

  -- turn 1: talk only
  user("What does this module do?", "2026-08-15T09:00:00.000Z")
  assistant({ { type = "text", text = "It exposes `greet` and `bye`." } }, "2026-08-15T09:00:05.000Z")

  -- turn 2: two edits, one new file, one failing command
  user("Use vim.notify instead of print, and add a brand module.", "2026-08-15T09:05:00.000Z")
  assistant({
    { type = "thinking", thinking = "print() is not great in a plugin.\nvim.notify respects the user's UI." },
    { type = "text", text = "Switching both call sites to `vim.notify`." },
    {
      type = "tool_use",
      id = "t1",
      name = "Edit",
      input = { file_path = file, old_string = "  print('hi ' .. name)", new_string = "  vim.notify('hi ' .. name)" },
    },
  }, "2026-08-15T09:05:10.000Z")
  result("t1", "The file has been updated.")
  assistant({
    {
      type = "tool_use",
      id = "t2",
      name = "Edit",
      input = { file_path = file, old_string = "  print('bye')", new_string = "  vim.notify('bye')\n  return true" },
    },
  }, "2026-08-15T09:05:20.000Z")
  result("t2", "The file has been updated.")
  assistant({
    { type = "tool_use", id = "t3", name = "Write", input = { file_path = newfile, content = M.NEW_FILE } },
  }, "2026-08-15T09:05:30.000Z")
  result("t3", "File created successfully at: " .. newfile)
  assistant({
    { type = "tool_use", id = "t4", name = "Bash", input = { command = "luacheck lua/", description = "Lint the module" } },
  }, "2026-08-15T09:05:40.000Z")
  result("t4", "sh: luacheck: not found", true)
  assistant({ { type = "text", text = "Done." } }, "2026-08-15T09:05:50.000Z")

  -- entries the model must ignore
  push({ type = "mode", mode = "normal" })
  push({ type = "file-history-snapshot", messageId = "x", snapshot = {} })
  push({ type = "attachment", uuid = uuid(), attachment = { type = "total_tokens_reminder" } })
  push({
    type = "assistant",
    uuid = uuid(),
    isSidechain = true,
    cwd = cwd,
    message = { role = "assistant", content = { { type = "text", text = "SUBAGENT NOISE" } } },
  })

  local projects = root .. "/claude/projects"
  local dir = projects .. "/" .. Transcript.encode(cwd)
  local transcript = dir .. "/sess-test01.jsonl"
  M.write(transcript, table.concat(entries, "\n") .. "\n")

  local prev_root, prev_state = Transcript.root, Store.root
  Transcript.root = projects
  Store.root = root .. "/state"
  Store.reset()

  return {
    root = root,
    cwd = cwd,
    file = file,
    newfile = newfile,
    transcript = transcript,
    cleanup = function()
      Transcript.root, Store.root = prev_root, prev_state
      Store.reset()
      vim.fn.delete(root, "rf")
    end,
  }
end

--- Append entries to the transcript, simulating Claude continuing the session.
---@param fx sidekick.test.ReviewFixture
---@param entries table[]
function M.append(fx, entries)
  local lines = {}
  for line in io.lines(fx.transcript) do
    lines[#lines + 1] = line
  end
  for _, e in ipairs(entries) do
    e.cwd = e.cwd or fx.cwd
    lines[#lines + 1] = vim.json.encode(e)
  end
  M.write(fx.transcript, table.concat(lines, "\n") .. "\n")
end

--- Replace `sidekick.cli` with a recorder, returning the captured sends.
---@return table[] sent, fun() restore
function M.stub_cli()
  local sent = {}
  local prev = package.loaded["sidekick.cli"]
  package.loaded["sidekick.cli"] = setmetatable({
    send = function(opts)
      sent[#sent + 1] = opts
    end,
  }, {
    __index = function()
      return function() end
    end,
  })
  return sent, function()
    package.loaded["sidekick.cli"] = prev
  end
end

--- Replace the comment composer so specs can answer it synchronously.
---@param answer string|fun(opts:table):string?
---@return table captured, fun() restore
function M.stub_composer(answer)
  local Comment = require("sidekick.review.comment")
  local prev = Comment.open
  local captured = {}
  Comment.open = function(opts)
    captured.opts = opts
    local body = type(answer) == "function" and answer(opts) or answer
    if body == nil then
      if opts.on_cancel then
        opts.on_cancel()
      end
    else
      opts.on_submit(body)
    end
    return 0, 0
  end
  return captured, function()
    Comment.open = prev
  end
end

--- Capture `Util.notify`, which defers through `vim.schedule`.
---@return string[] messages, fun() restore
function M.stub_notify()
  local Util = require("sidekick.util")
  local prev = Util.notify
  local msgs = {}
  Util.notify = function(msg)
    msgs[#msgs + 1] = type(msg) == "table" and table.concat(msg, "\n") or tostring(msg)
  end
  return msgs, function()
    Util.notify = prev
  end
end

return M
