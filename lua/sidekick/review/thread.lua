---@brief Thread Claude's answers back under the comments they answer.
---
--- When a review is submitted each comment carries a `[cN]` tag and Claude is
--- asked to lead every reply with it. On the next refresh we find the turn that
--- carried the submission and split its prose on those tags.
local Store = require("sidekick.review.store")

local M = {}

--- Tags a submitted review message contains, e.g. `{ c1 = true, c4 = true }`.
---@param prompt string
---@return table<string, boolean>
function M.submitted_tags(prompt)
  local ret = {} ---@type table<string, boolean>
  for id in prompt:gmatch("###%s*%[(c%d+)%]") do
    ret[id] = true
  end
  return ret
end

--- Split assistant prose into `tag -> reply body`.
---
--- A tag claims every line up to the next tag. Text before the first tag is
--- returned separately as the reply's preamble.
---@param text string
---@return table<string, string>, string
function M.split(text)
  local ret = {} ---@type table<string, string>
  local order = {} ---@type string[]
  local preamble = {} ---@type string[]
  local current ---@type string?
  local buf = {} ---@type string[]

  local function flush()
    if current then
      local body = table.concat(buf, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if ret[current] then
        ret[current] = ret[current] .. "\n" .. body
      else
        ret[current] = body
        order[#order + 1] = current
      end
    end
    buf = {}
  end

  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    -- a tag must open the line: `[c1]`, `**[c1]**`, `### [c1]`, `- [c1]`
    local id, rest = line:match("^%s*[#%-%*_%s]*%[(c%d+)%]%s*(.*)$")
    if id then
      -- drop the closing half of `**[c1]**` and any `:` / dash separator
      rest = rest:gsub("^[%*_]+", ""):gsub("^%s*[:%-–—]+%s*", ""):gsub("^%s+", "")
      flush()
      current = id
      buf = rest ~= "" and { rest } or {}
    elseif current then
      buf[#buf + 1] = line
    else
      preamble[#preamble + 1] = line
    end
  end
  flush()

  return ret, (table.concat(preamble, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param turn sidekick.review.Turn
---@return string
local function prose(turn)
  local parts = {} ---@type string[]
  for _, b in ipairs(turn.blocks) do
    if b.kind == "text" and b.text then
      parts[#parts + 1] = b.text
    end
  end
  return table.concat(parts, "\n\n")
end

---@param comment sidekick.review.Comment
---@param turn_id string
---@return boolean
local function has_reply_from(comment, turn_id)
  for _, r in ipairs(comment.replies) do
    if r.role == "claude" and r.turn == turn_id then
      return true
    end
  end
  return false
end

--- Attach Claude's tagged replies to their comments.
---@param cwd string
---@param transcript sidekick.review.Transcript
---@return integer number of replies attached
function M.sync(cwd, transcript)
  local store = Store.get(cwd)
  local attached = 0

  for _, turn in ipairs(transcript.turns) do
    local tags = M.submitted_tags(turn.prompt)
    if next(tags) then
      local answers, preamble = M.split(prose(turn))
      -- a tagless reply still answers the whole review; give it to every comment
      local fallback = next(answers) == nil and preamble or nil

      for id in pairs(tags) do
        local c = store:find(id)
        if c and not has_reply_from(c, turn.id) then
          local body = answers[id] or fallback
          if body and body ~= "" then
            store:reply(id, { role = "claude", body = body, ts = turn.ts, turn = turn.id })
            if c.status == "sent" then
              store:set_status(id, "resolved")
            end
            attached = attached + 1
          end
        end
      end
    end
  end

  return attached
end

return M
