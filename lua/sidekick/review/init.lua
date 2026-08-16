---@brief Review Claude's responses like pull requests.
---
--- Each turn (your prompt + Claude's answer + the files it touched) is treated
--- as a PR you can read, comment on line by line, and send back. Claude's
--- answers to those comments are threaded underneath them.
---
--- ```lua
--- require("sidekick.review").toggle()
--- ```
local Model = require("sidekick.review.model")
local Store = require("sidekick.review.store")
local Submit = require("sidekick.review.submit")
local UI = require("sidekick.review.ui")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.review.Open
---@field cwd? string project directory (defaults to the current one)
---@field session? string session id (defaults to the most recent)
---@field turn? string turn id to select
---@field layout? sidekick.review.LayoutKind overrides `opts.review.layout`

--- Open the review overlay.
---@param opts? sidekick.review.Open
function M.open(opts)
  return UI.open(opts)
end

--- Close the review overlay.
function M.close()
  UI.close()
end

--- Toggle the review overlay.
---@param opts? sidekick.review.Open
function M.toggle(opts)
  return UI.toggle(opts)
end

--- Send every pending comment to the CLI, without opening the UI.
---@param opts? {cwd?:string, all?:boolean, submit?:boolean, name?:string}
function M.submit(opts)
  opts = opts or {}
  local cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd() or ".")
  local transcript = Model.load(cwd)
  local turn = transcript and transcript.turns[#transcript.turns] or nil
  return Submit.send({
    cwd = cwd,
    turn = not opts.all and turn or nil,
    submit = opts.submit,
    name = opts.name,
  })
end

--- Open the review on the comment under the cursor in a normal buffer.
---
--- The counterpart to the marks: from the code, jump into the conversation
--- about it.
---@param opts? sidekick.review.Open
---@return boolean opened
function M.open_at(opts)
  return require("sidekick.review.marks").open_at(opts)
end

--- Unresolved comments on the cursor line, if any.
---@return sidekick.review.Comment[]
function M.at_cursor()
  return require("sidekick.review.marks").at_cursor()
end

--- Pick among every recorded session and open the review on it.
---
--- Unlike `open()`, which takes the most recent, this shows all of them —
--- earlier runs and other CLIs included — labelled by their opening prompt.
---@param opts? sidekick.review.Open
function M.pick(opts)
  opts = opts or {}
  local cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd() or ".")

  -- when a review is already open, switch it in place
  if UI.current and not UI.current.closed and UI.current.cwd == cwd then
    return UI.current:pick_session()
  end

  UI.select_session({
    cwd = cwd,
    all = true,
    on_choice = function(src)
      M.open(vim.tbl_extend("force", opts, { cwd = src.cwd, session = src.session }))
    end,
  })
end

--- Every agent session recorded for `cwd`, newest first.
---
--- Each entry names the CLI that wrote it, so a project with both a `claude`
--- and a `codex` history reports both.
---@param cwd? string
---@return sidekick.review.Source[]
function M.sessions(cwd)
  return Model.sessions(cwd)
end

--- Number of comments waiting to be sent. Useful in a statusline.
---@param cwd? string
---@return integer
function M.pending(cwd)
  return Store.get(cwd):pending_count()
end

--- Status text for a statusline, or nil when there is nothing to show.
---@param cwd? string
---@return string?
function M.status(cwd)
  local n = M.pending(cwd)
  return n > 0 and ("%s%d"):format(require("sidekick.review.render").icons.comment, n) or nil
end

--- Drop stored comments.
---@param opts? {cwd?:string, turn?:string, all?:boolean}
function M.clear(opts)
  opts = opts or {}
  local store = Store.get(opts.cwd)
  if opts.all then
    store:clear()
    Util.info("sidekick.review: cleared all comments")
  else
    local transcript = Model.load(opts.cwd)
    local last = transcript and transcript.turns[#transcript.turns] or nil
    local turn = opts.turn or (last and last.id)
    if not turn then
      Util.warn("sidekick.review: nothing to clear")
      return
    end
    store:clear(turn)
    Util.info("sidekick.review: cleared comments for the latest turn")
  end
  if UI.current and not UI.current.closed then
    UI.current:render({ keep_cursor = true })
  end
end

M.UI = UI

return M
