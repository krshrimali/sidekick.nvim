---@brief Turn pending review comments into a message for the CLI.
local Store = require("sidekick.review.store")
local Util = require("sidekick.util")

local M = {}

--- Instruction appended so replies can be threaded back onto comments.
M.instructions = table.concat({
  "Please address each comment. Start every reply with its tag on its own line",
  "(for example `[c1]`) so my editor can thread your answer under the right comment.",
}, "\n")

---@param lines string[]
---@param n? integer
---@return string[]
local function clamp(lines, n)
  n = n or 12
  if #lines <= n then
    return lines
  end
  local ret = vim.list_slice(lines, 1, n)
  ret[#ret + 1] = ("… (%d more lines)"):format(#lines - n)
  return ret
end

---@param c sidekick.review.Comment
---@return string
function M.render_comment(c)
  local out = {} ---@type string[]
  local head ---@type string
  if c.target == "file" then
    local loc = c.rel or c.file or "?"
    if c.lnum then
      loc = c.end_lnum and c.end_lnum > c.lnum and ("%s:%d-%d"):format(loc, c.lnum, c.end_lnum)
        or ("%s:%d"):format(loc, c.lnum)
    end
    head = ("### [%s] %s"):format(c.id, loc)
  else
    head = ("### [%s] your response"):format(c.id)
  end
  out[#out + 1] = head

  if #c.anchor > 0 then
    for _, l in ipairs(clamp(c.anchor)) do
      out[#out + 1] = "> " .. l
    end
    out[#out + 1] = ""
  end

  for _, l in ipairs(vim.split(c.body, "\n", { plain = true })) do
    out[#out + 1] = l
  end

  -- earlier back-and-forth gives Claude the context of what it already answered
  for _, r in ipairs(c.replies) do
    out[#out + 1] = ""
    out[#out + 1] = r.role == "claude" and "_(you previously replied)_" or "_(follow-up)_"
    for _, l in ipairs(clamp(vim.split(r.body, "\n", { plain = true }), 6)) do
      out[#out + 1] = "> " .. l
    end
  end

  return table.concat(out, "\n")
end

--- Build the full review message.
---@param comments sidekick.review.Comment[]
---@param opts? {verdict?:string, note?:string, turn?:sidekick.review.Turn}
---@return string?
function M.render(comments, opts)
  opts = opts or {}
  if #comments == 0 and not opts.note and not opts.verdict then
    return nil
  end

  local out = {} ---@type string[]
  local n = #comments
  local subject = opts.turn and ("your response to `%s`"):format(opts.turn.title) or "your last response"

  if n > 0 then
    out[#out + 1] = ("Code review of %s — %d comment%s below."):format(subject, n, n == 1 and "" or "s")
  else
    out[#out + 1] = ("Code review of %s."):format(subject)
  end

  if opts.verdict then
    out[#out + 1] = ""
    out[#out + 1] = "**Verdict:** " .. opts.verdict
  end
  if opts.note and opts.note ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = opts.note
  end

  if n > 0 then
    out[#out + 1] = ""
    out[#out + 1] = M.instructions
    for _, c in ipairs(comments) do
      out[#out + 1] = ""
      out[#out + 1] = M.render_comment(c)
    end
  end

  return table.concat(out, "\n")
end

---@class sidekick.review.Submit
---@field cwd string
---@field turn? sidekick.review.Turn only this turn's comments (all turns when nil)
---@field comments? sidekick.review.Comment[] override which comments to send
---@field verdict? string e.g. "approved", "changes requested"
---@field note? string free-form text added above the comments
---@field submit? boolean press enter in the CLI (default true)
---@field name? string CLI tool to send to

--- Render and send the pending comments of a turn, then mark them as sent.
---@param opts sidekick.review.Submit
---@return boolean ok, string? msg
function M.send(opts)
  local store = Store.get(opts.cwd)
  local comments = opts.comments
  if not comments then
    comments = opts.turn and store:for_turn(opts.turn.id, { status = "pending" })
      or store:all("pending")
  end

  local msg = M.render(comments, { verdict = opts.verdict, note = opts.note, turn = opts.turn })
  if not msg then
    Util.warn("sidekick.review: nothing to submit")
    return false
  end

  require("sidekick.cli").send({
    msg = msg,
    submit = opts.submit ~= false,
    name = opts.name,
    focus = false,
  })

  for _, c in ipairs(comments) do
    store:set_status(c.id, "sent")
  end
  return true, msg
end

return M
