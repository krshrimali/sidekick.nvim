---@brief The reviewable model: turns as pull requests.
---
--- One **turn** = one user prompt plus everything the agent did in response.
--- That is the unit the review UI treats as a PR: it has a title (the prompt),
--- a description (the agent's prose), and a set of changed files.
---
--- Building a turn list is provider specific; see `sidekick.review.provider`.
--- Everything downstream works on the types declared here regardless of which
--- CLI produced them.
local Provider = require("sidekick.review.provider")
local Transcript = require("sidekick.review.transcript")

local M = {}

---@class sidekick.review.Block
---@field kind "text"|"thinking"|"tool"
---@field text? string
---@field tool? sidekick.review.Tool
---@field uuid string

---@class sidekick.review.Tool
---@field id string
---@field name string
---@field input table<string, any>
---@field result? string
---@field error? boolean
---@field uuid string

---@class sidekick.review.Change a single edit applied to a file
---@field kind "edit"|"write"
---@field old string content that was replaced ("" for a new file)
---@field new string replacement content
---@field replace_all? boolean
---@field tool_id string

---@class sidekick.review.FileChange
---@field path string absolute path
---@field rel string path relative to cwd
---@field changes sidekick.review.Change[]
---@field added integer
---@field removed integer
---@field created boolean file did not exist before this turn
---@field deleted boolean file was removed by this turn

---@class sidekick.review.Turn
---@field id string stable id of the user prompt
---@field idx integer 1-based turn number within the session
---@field prompt string the user's message
---@field title string one-line summary of the prompt
---@field ts number unix timestamp (seconds)
---@field blocks sidekick.review.Block[]
---@field tools sidekick.review.Tool[]
---@field files sidekick.review.FileChange[]
---@field session string
---@field cwd string
---@field provider string
---@field pending boolean true while the agent may still be appending

---@class sidekick.review.Transcript
---@field session string
---@field file string
---@field cwd string
---@field provider string
---@field turns sidekick.review.Turn[]
---@field mtime number

---@deprecated use `require("sidekick.review.provider").EDIT_TOOLS`
M.EDIT_TOOLS = Provider.EDIT_TOOLS

---@deprecated use `require("sidekick.review.provider").clean_prompt`
M.clean_prompt = Provider.clean_prompt

--- Transcripts already built, keyed by file, with the size and mtime they were
--- built from.
---@type table<string, {size:number, mtime:number, transcript:sidekick.review.Transcript}>
local cache = {}

--- Forget every built transcript. Used by tests.
function M.clear_cache()
  cache = {}
end

--- Build the turn list for a transcript source.
---
--- A project usually has several sessions and only one of them is being
--- written to; re-parsing the rest on every refresh is pure waste, and these
--- files reach megabytes. Transcripts are append-only, so size and mtime are
--- enough to know a file has not moved on.
---@param src sidekick.review.Source
---@return sidekick.review.Transcript
function M.build(src)
  local hit = cache[src.file]
  if hit and hit.size == src.size and hit.mtime == src.mtime then
    return hit.transcript
  end

  local provider = Provider.get(src.provider or "claude")
  local turns = provider and provider.build(src) or {}

  if turns[#turns] then
    turns[#turns].pending = true
  end

  local transcript = {
    session = src.session,
    file = src.file,
    cwd = src.cwd,
    provider = src.provider,
    turns = turns,
    mtime = src.mtime,
  } ---@type sidekick.review.Transcript

  cache[src.file] = { size = src.size, mtime = src.mtime, transcript = transcript }
  return transcript
end

--- Load a transcript for `cwd`.
---@param cwd? string
---@param session? string specific session, else the most recent
---@param opts? {provider?:string}
---@return sidekick.review.Transcript?
function M.load(cwd, session, opts)
  local src = session and Transcript.by_session(session, cwd) or Transcript.latest(cwd, opts)
  if not src then
    return nil
  end
  return M.build(src)
end

--- Every session available for `cwd`, newest first.
---@param cwd? string
---@param opts? {all?:boolean}
---@return sidekick.review.Source[]
function M.sessions(cwd, opts)
  return Transcript.sources(cwd, opts)
end

return M
