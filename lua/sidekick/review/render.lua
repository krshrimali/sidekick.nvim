---@brief Pure rendering for the review UI.
---
--- Everything here maps model data to `sidekick.review.Line[]`: text plus
--- highlight ranges plus the item the line represents. No window or buffer API
--- is touched, so the whole UI can be asserted on in tests.
local Markdown = require("sidekick.review.markdown")
local Provider = require("sidekick.review.provider")
local Store = require("sidekick.review.store")
local Treesitter = require("sidekick.treesitter")

local M = {}

---@alias sidekick.review.HL { [1]:integer, [2]:integer, [3]:string } col_start, col_end (exclusive, -1 = eol), group

---@class sidekick.review.Item
---@field kind "session"|"turn"|"file"|"response"|"threads"|"diff"|"comment"|"reply"|"text"|"code"|"tool"|"hunk"|"prompt"|"blank"|"header"
---@field turn? string
---@field file? string file path (diff view)
---@field lnum? integer line number in the file
---@field old_lnum? integer
---@field side? "new"|"old"
---@field anchor_key? string stable id used to re-attach comments across renders
---@field anchor? string the source text of this line
---@field comment? sidekick.review.Comment
---@field session? string sidebar session group
---@field key? string sidebar item key (`@response` or a path)
---@field diff? sidekick.review.FileDiff

---@class sidekick.review.Line
---@field text string
---@field hl? sidekick.review.HL[]
---@field item? sidekick.review.Item

---@class sidekick.review.Ctx
---@field transcript sidekick.review.Transcript
---@field store sidekick.review.Store
---@field expanded table<string, boolean> turn id -> expanded
---@field show_thinking boolean
---@field sel_turn? string
---@field sel_key? string
---@field diffs table<string, sidekick.review.FileDiff[]> turn id -> diffs
---@field transcripts? sidekick.review.Transcript[] every session in view, newest first
---@field rollups? table<string, sidekick.review.Turn> session id -> its cumulative change
---@field session? string set when narrowed to a single session
---@field sessions? sidekick.review.Source[] every session available for this cwd
---@field collapsed table<string, boolean> comment id -> explicitly collapsed
---@field expanded_threads table<string, boolean> comment id -> explicitly expanded
---@field width integer

-- stylua: ignore
M.icons = {
  expanded   = "▾ ",
  collapsed  = "▸ ",
  response   = "󰭹 ",
  file       = " ",
  new        = " ",
  removed    = " ",
  viewed     = " ",
  unviewed   = " ",
  comment    = " ",
  reply      = "↳ ",
  you        = "▌",
  agent      = "▌",
  threads    = "󰭻 ",
  rollup     = "󰦒 ",
  pending    = "● ",
  sent       = "◍ ",
  resolved   = "✓ ",
  tool       = " ",
  failed     = "✗ ",
  thinking   = " ",
  aside      = "╎ ",
  pending_turn = "󱎫 ",
  approved   = "✓",
  changes    = "✗",
}

---@param ts number
---@return string
function M.ago(ts)
  if ts <= 0 then
    return ""
  end
  local d = os.time() - ts
  if d < 60 then
    return "now"
  elseif d < 3600 then
    return ("%dm"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%dh"):format(math.floor(d / 3600))
  elseif d < 86400 * 30 then
    return ("%dd"):format(math.floor(d / 86400))
  end
  return os.date("%b %d", ts) --[[@as string]]
end

---@param str string
---@param width integer
---@return string
local function trunc(str, width)
  if width <= 1 then
    return ""
  end
  if vim.fn.strdisplaywidth(str) <= width then
    return str
  end
  local ret = str
  while vim.fn.strdisplaywidth(ret) > width - 1 and #ret > 0 do
    ret = vim.fn.strcharpart(ret, 0, vim.fn.strchars(ret) - 1)
  end
  return ret .. "…"
end

--- Truncate a path from the left so the file name always survives.
---@param path string
---@param width integer
---@return string
function M.path(path, width)
  -- files outside the project keep an absolute path; shorten $HOME to `~`
  if path:sub(1, 1) == "/" then
    path = vim.fn.fnamemodify(path, ":~") --[[@as string]]
  end
  if width <= 1 or vim.fn.strdisplaywidth(path) <= width then
    return path
  end
  local parts = vim.split(path, "/", { plain = true })
  local ret = parts[#parts]
  for i = #parts - 1, 1, -1 do
    local next_ret = parts[i] .. "/" .. ret
    if vim.fn.strdisplaywidth(next_ret) + 1 > width then
      break
    end
    ret = next_ret
  end
  if ret ~= path then
    ret = "…/" .. ret
  end
  -- a single very long component still has to be cut somewhere
  if vim.fn.strdisplaywidth(ret) > width then
    ret = "…" .. vim.fn.strcharpart(ret, vim.fn.strchars(ret) - (width - 1))
  end
  return ret
end

---@param str string
---@param width integer
---@return string
local function pad(str, width)
  local w = vim.fn.strdisplaywidth(str)
  return w >= width and str or (str .. string.rep(" ", width - w))
end

--- Inline markdown highlights (`code`, **bold**, links) for a line whose body
--- starts at `offset`.
---@param text string
---@param offset integer
---@param base string
---@return sidekick.review.HL[]
function M.inline_md(text, offset, base)
  local body = text:sub(offset + 1)
  local ret = {} ---@type sidekick.review.HL[]
  for _, hl in ipairs(Markdown.inline(body, base)) do
    ret[#ret + 1] = { hl[1] == 0 and offset or offset + hl[1], hl[2] == -1 and -1 or offset + hl[2], hl[3] }
  end
  return ret
end

---@param status string
---@return string
local function status_icon(status)
  return M.icons[status] or M.icons.pending
end

--------------------------------------------------------------------------------
-- Sidebar
--------------------------------------------------------------------------------

--- Status of a turn item, aggregated over its comments.
---@param ctx sidekick.review.Ctx
---@param turn sidekick.review.Turn
---@param key string
---@return integer n_comments, integer n_pending, boolean viewed
local function item_stats(ctx, turn, key)
  local comments ---@type sidekick.review.Comment[]
  if key == Store.THREADS then
    comments = {} -- the node shows its own counts in the stat column
  elseif key == Store.RESPONSE then
    comments = ctx.store:for_turn(turn.id, { target = "response" })
  else
    comments = ctx.store:for_turn(turn.id, { target = "file", file = key })
  end
  local pending = 0
  for _, c in ipairs(comments) do
    if c.status == "pending" then
      pending = pending + 1
    end
  end
  return #comments, pending, ctx.store:is_viewed(turn.id, key)
end

---@param ctx sidekick.review.Ctx
---@return sidekick.review.Line[]
function M.sidebar(ctx)
  local lines = {} ---@type sidekick.review.Line[]
  local W = ctx.width

  ---@param text string
  ---@param hl? sidekick.review.HL[]
  ---@param item? sidekick.review.Item
  local function add(text, hl, item)
    lines[#lines + 1] = { text = text, hl = hl, item = item }
  end

  add(" Review", { { 0, -1, "SidekickReviewTitle" } }, { kind = "header" })

  local transcripts = ctx.transcripts or {}
  local n_turns = 0
  for _, tr in ipairs(transcripts) do
    n_turns = n_turns + #tr.turns
  end
  local scope = ctx.session and "1 session (s: all)"
    or ("%d session%s"):format(#transcripts, #transcripts == 1 and "" or "s")
  add((" %s · %d turn%s"):format(scope, n_turns, n_turns == 1 and "" or "s"), {
    { 0, -1, "SidekickReviewDim" },
  }, { kind = "header" })
  add(string.rep("─", W), { { 0, -1, "SidekickReviewSep" } }, { kind = "blank" })

  if #transcripts == 0 then
    add(" no sessions found", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end

  -- two runs of the same CLI look identical otherwise
  local seen = {} ---@type table<string, integer>
  for _, tr in ipairs(transcripts) do
    seen[tr.provider] = (seen[tr.provider] or 0) + 1
  end

  ---@param tr sidekick.review.Transcript
  local function session_header(tr)
    local provider = Provider.get(tr.provider)
    local open = ctx.expanded[tr.session] == true
    local label = provider and provider.label or tr.provider
    if (seen[tr.provider] or 0) > 1 then
      label = label .. " · " .. tr.session:sub(1, 8)
    end
    local newest = tr.turns[#tr.turns]
    local when = newest and M.ago(newest.ts) or ""
    local count = ("%d"):format(#tr.turns)
    local prefix = open and M.icons.expanded or M.icons.collapsed
    local right = count .. "  " .. when
    local avail = W - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(right) - 1
    local text = prefix .. pad(trunc(label, math.max(avail, 4)), math.max(avail, 4)) .. " " .. right
    add(text, {
      { 0, #prefix, "SidekickReviewSession" },
      { #prefix, #text - #right, "SidekickReviewSession" },
      { #text - #right, -1, "SidekickReviewDim" },
    }, { kind = "session", session = tr.session })
  end

  -- more than one session in view: group them, so a repository reads as a
  -- history rather than as one flat list of unrelated turns
  local grouped = #transcripts > 1
  local indent = grouped and "  " or ""

  --- One turn row plus, when expanded, its response / threads / files.
  --- A rollup renders through here too: it is a turn as far as the sidebar,
  --- comments and viewed marks are concerned.
  ---@param turn sidekick.review.Turn
  local function turn_row(turn)
    local open = ctx.expanded[turn.id] == true
    local sel = ctx.sel_turn == turn.id
    local rolled = turn.idx == 0

    local n_total, n_pending = 0, 0
    for _, c in ipairs(ctx.store:for_turn(turn.id)) do
      n_total = n_total + 1
      if c.status == "pending" then
        n_pending = n_pending + 1
      end
    end

    local when = rolled and "" or M.ago(turn.ts)
    local prefix = indent
      .. (open and M.icons.expanded or M.icons.collapsed)
      .. (rolled and M.icons.rollup or ("#%d "):format(turn.idx))
    local badge = n_pending > 0 and (" %s%d"):format(M.icons.comment, n_pending)
      or (n_total > 0 and (" %s%d"):format(M.icons.comment, n_total) or "")
    -- a turn you have already ruled on should read as settled at a glance
    local verdict = ctx.store.verdict and ctx.store:verdict(turn.id) or nil
    if verdict == "approved" then
      badge = " " .. M.icons.approved .. badge
    elseif verdict == "changes" then
      badge = " " .. M.icons.changes .. badge
    end
    if turn.pending and not rolled then
      badge = " " .. M.icons.pending_turn .. badge
    end
    if rolled then
      local n = #(ctx.diffs[turn.id] or {})
      badge = badge .. (" %d file%s"):format(n, n == 1 and "" or "s")
    end
    -- widths are in display cells; byte lengths would under-count the room
    -- available whenever the prefix carries a multi-byte icon
    local avail = W - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(badge) - #when - 2
    local title = trunc(turn.title, math.max(avail, 4))
    local text = prefix .. pad(title, math.max(avail, 4)) .. badge .. " " .. when

    local hl = {
      { 0, #prefix, sel and "SidekickReviewTurnSel" or "SidekickReviewTurn" },
      { #prefix, #prefix + #title, sel and "SidekickReviewTurnSel" or "SidekickReviewText" },
    } ---@type sidekick.review.HL[]
    if badge ~= "" then
      local badge_hl = n_pending > 0 and "SidekickReviewPending" or "SidekickReviewDim"
      hl[#hl + 1] = { #text - #when - #badge - 1, #text - #when - 1, badge_hl }
    end
    hl[#hl + 1] = { #text - #when, -1, "SidekickReviewDim" }
    add(text, hl, { kind = "turn", turn = turn.id })

    if open then
      ---@param key string
      ---@param icon string
      ---@param label string
      ---@param stat string
      ---@param stat_hl string
      local function child(key, icon, label, stat, stat_hl)
        local n, pend, viewed = item_stats(ctx, turn, key)
        local mark = viewed and M.icons.viewed or "  "
        local cbadge = n > 0 and ("%s%d"):format(M.icons.comment, n) or ""
        local right = (cbadge ~= "" and (cbadge .. " ") or "") .. stat
        local left = indent .. "  " .. mark .. icon
        local avail2 = W - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right) - 1
        -- keep the file name readable: cut from the left, not the right
        local name = key == Store.RESPONSE and trunc(label, math.max(avail2, 4))
          or M.path(label, math.max(avail2, 4))
        local t = left .. pad(name, math.max(avail2, 4)) .. " " .. right
        local is_sel = ctx.sel_turn == turn.id and ctx.sel_key == key
        local name_hl = is_sel and "SidekickReviewSelected"
          or (viewed and "SidekickReviewViewed" or "SidekickReviewText")
        local h = {
          { 0, #left, viewed and "SidekickReviewViewed" or "SidekickReviewDim" },
          { #left, #left + #name, name_hl },
        } ---@type sidekick.review.HL[]
        if cbadge ~= "" then
          local s = #t - #right
          h[#h + 1] = { s, s + #cbadge, pend > 0 and "SidekickReviewPending" or "SidekickReviewDim" }
        end
        if stat ~= "" then
          h[#h + 1] = { #t - #stat, -1, stat_hl }
        end
        local kind = "file"
        if key == Store.RESPONSE then
          kind = "response"
        elseif key == Store.THREADS then
          kind = "threads"
        end
        add(t, h, {
          kind = kind,
          turn = turn.id,
          key = key,
          file = kind == "file" and key or nil,
        })
      end

      if not rolled then
        child(Store.RESPONSE, M.icons.response, "Response", "", "SidekickReviewDim")
      end

      -- conversations are easier to follow in one place than scattered through
      -- the diffs they are anchored to
      if n_total > 0 then
        local open_n = 0
        for _, c in ipairs(ctx.store:for_turn(turn.id)) do
          if c.status ~= "resolved" then
            open_n = open_n + 1
          end
        end
        child(
          Store.THREADS,
          M.icons.threads,
          ("Threads (%d)"):format(n_total),
          open_n > 0 and ("%d open"):format(open_n) or "all resolved",
          open_n > 0 and "SidekickReviewPending" or "SidekickReviewResolved"
        )
      end

      for _, d in ipairs(ctx.diffs[turn.id] or {}) do
        local icon = M.icons.file
        local stat = ("+%d -%d"):format(d.added, d.removed)
        local stat_hl = "SidekickReviewStat"
        if d.deleted then
          icon, stat, stat_hl = M.icons.removed, "deleted", "SidekickReviewDiffDelete"
        elseif d.created then
          icon = M.icons.new
        end
        child(d.path, icon, d.rel, stat, stat_hl)
      end
      if #(ctx.diffs[turn.id] or {}) == 0 then
        add(indent .. "    no files changed", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank", turn = turn.id })
      end
    end
  end

  for _, tr in ipairs(transcripts) do
    if grouped then
      session_header(tr)
      if ctx.expanded[tr.session] ~= true then
        goto continue
      end
    end

    -- what the session did as a whole, before the turn-by-turn account of it
    local rollup = (ctx.rollups or {})[tr.session]
    if rollup then
      turn_row(rollup)
    end

    -- newest first: the turn you want to review is almost always the last one
    for i = #tr.turns, 1, -1 do
      turn_row(tr.turns[i])
    end

    ::continue::
  end

  return lines
end

--------------------------------------------------------------------------------
-- Comment threads
--------------------------------------------------------------------------------

--- Should this thread render collapsed?
---
--- Resolved conversations fold away by default so a busy diff stays readable;
--- anything still waiting on someone stays open. An explicit toggle wins.
---@param ctx sidekick.review.Ctx
---@param c sidekick.review.Comment
---@return boolean
function M.is_collapsed(ctx, c)
  if ctx.expanded_threads and ctx.expanded_threads[c.id] then
    return false
  end
  if ctx.collapsed and ctx.collapsed[c.id] then
    return true
  end
  return c.status == "resolved"
end

--- One line describing where a comment is anchored.
---@param c sidekick.review.Comment
---@return string
function M.location(c)
  if c.target ~= "file" then
    return "response"
  end
  local loc = c.rel or c.file or "?"
  if c.lnum then
    loc = c.end_lnum and c.end_lnum > c.lnum and ("%s:%d-%d"):format(loc, c.lnum, c.end_lnum)
      or ("%s:%d"):format(loc, c.lnum)
  end
  return loc
end

--- Short status word shown in a thread header.
---@param c sidekick.review.Comment
---@return string, string highlight group
local function status_label(c)
  if c.status == "sent" then
    return "awaiting reply", "SidekickReviewSent"
  elseif c.status == "resolved" then
    return "resolved", "SidekickReviewResolved"
  end
  return #c.replies > 0 and "needs another look" or "draft", "SidekickReviewPending"
end

--- Render a comment and its replies as a thread block.
---
--- A thread that has been round-tripped a few times gets long, and several of
--- them inside one diff quickly drown the code. So a thread is a first class,
--- collapsible unit: collapsed it is a single summary line, expanded it reads
--- as a conversation with one labelled turn per message.
---@param c sidekick.review.Comment
---@param width integer
---@param opts? {collapsed?:boolean, location?:boolean, selected?:boolean}
---@return sidekick.review.Line[]
function M.thread(c, width, opts)
  opts = opts or {}
  local lines = {} ---@type sidekick.review.Line[]
  local bar = "│ "
  local label, label_hl = status_label(c)
  local n = #c.replies

  ---@param text string
  ---@param hl sidekick.review.HL[]
  ---@param kind "comment"|"reply"
  local function add(text, hl, kind)
    lines[#lines + 1] = { text = text, hl = hl, item = { kind = kind, comment = c } }
  end

  if opts.collapsed then
    -- one line: who started it, the gist, and how far along it is
    local gist = (c.body:gsub("%s+", " "))
    local head = ("%s%s[%s] "):format(M.icons.collapsed, status_icon(c.status), c.id)
    local tail = n > 0 and ("  %d repl%s · %s"):format(n, n == 1 and "y" or "ies", label) or ("  %s"):format(label)
    if opts.location then
      tail = ("  %s"):format(M.location(c)) .. tail
    end
    local room = math.max(width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail), 8)
    local gist_s = trunc(gist, room)
    local text = head .. pad(gist_s, room) .. tail
    add(text, {
      { 0, #head, label_hl },
      { #head, #head + #gist_s, "SidekickReviewThreadCollapsed" },
      { #text - #tail, -1, "SidekickReviewDim" },
    }, "comment")
    return lines
  end

  -- header: ╭ ● [c1] lua/greet.lua:4 ──────────── 2 replies · resolved ─
  local head = ("╭ %s[%s]"):format(status_icon(c.status), c.id)
  if opts.location then
    head = head .. " " .. M.location(c)
  end
  local tail = n > 0 and ("%d repl%s · %s"):format(n, n == 1 and "y" or "ies", label) or label
  local fill = math.max(width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail) - 3, 1)
  local text = head .. " " .. string.rep("─", fill) .. " " .. tail
  add(text, {
    { 0, 1, "SidekickReviewCommentBorder" },
    { 1, #head, label_hl },
    { #head, #text - #tail, "SidekickReviewCommentBorder" },
    { #text - #tail, -1, "SidekickReviewDim" },
  }, "comment")

  --- One message in the conversation.
  ---@param role "you"|"claude"
  ---@param body string
  ---@param ts? number
  ---@param kind "comment"|"reply"
  local function message(role, body, ts, kind)
    local mine = role == "you"
    local when = ts and ts > 0 and M.ago(ts) or ""
    local who = ("%s%s"):format(mine and "" or M.icons.reply, role)
    local stamp = when ~= "" and ("  " .. when) or ""
    add(bar .. who .. stamp, {
      { 0, #bar, "SidekickReviewCommentBorder" },
      { #bar, #bar + #who, mine and "SidekickReviewAuthorYou" or "SidekickReviewAuthorAgent" },
      { #bar + #who, -1, "SidekickReviewDim" },
    }, kind)
    for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
      local body_line = bar .. "  " .. l
      local hl = M.inline_md(body_line, #bar + 2, mine and "SidekickReviewComment" or "SidekickReviewReply")
      table.insert(hl, 1, { 0, #bar, "SidekickReviewCommentBorder" })
      add(body_line, hl, kind)
    end
  end

  message("you", c.body, c.created, "comment")
  for _, r in ipairs(c.replies) do
    add(bar, { { 0, -1, "SidekickReviewCommentBorder" } }, "reply")
    message(r.role == "claude" and "claude" or "you", r.body, r.ts, "reply")
  end

  add("╰" .. string.rep("─", math.max(width - 1, 4)), { { 0, -1, "SidekickReviewCommentBorder" } }, "comment")
  return lines
end

--------------------------------------------------------------------------------
-- Response view
--------------------------------------------------------------------------------

---@param tool sidekick.review.Tool
---@param cwd? string paths are shown relative to it
---@return string
function M.tool_summary(tool, cwd)
  local input = tool.input or {}
  local path = input.file_path or input.notebook_path or input.path
  local detail = input.description
    or path
    or input.pattern
    or input.command
    or input.url
    or input.prompt
    or input.skill
    or ""
  if type(detail) ~= "string" then
    detail = vim.inspect(detail)
  end
  if cwd and detail == path then
    detail = vim.fs.relpath(cwd, vim.fs.normalize(detail)) or vim.fn.fnamemodify(detail, ":~")
  end
  detail = detail:gsub("%s+", " "):gsub("^%s+", "")
  return detail
end

--- Group comments by their anchor key so they can be inserted after a line.
---@param comments sidekick.review.Comment[]
---@return table<string, sidekick.review.Comment[]>
local function by_anchor(comments)
  local ret = {} ---@type table<string, sidekick.review.Comment[]>
  for _, c in ipairs(comments) do
    local key = c.anchor_key or "?"
    ret[key] = ret[key] or {}
    table.insert(ret[key], c)
  end
  return ret
end

---@param ctx sidekick.review.Ctx
---@param turn sidekick.review.Turn
---@return sidekick.review.Line[]
function M.response(ctx, turn)
  local lines = {} ---@type sidekick.review.Line[]
  local W = ctx.width
  local anchored = by_anchor(ctx.store:for_turn(turn.id, { target = "response" }))
  local orphans = {} ---@type sidekick.review.Comment[]
  local used = {} ---@type table<string, boolean>

  ---@param text string
  ---@param hl? sidekick.review.HL[]
  ---@param item? sidekick.review.Item
  local function add(text, hl, item)
    lines[#lines + 1] = { text = text, hl = hl, item = item }
  end

  ---@param key string
  local function flush(key)
    used[key] = true
    for _, c in ipairs(anchored[key] or {}) do
      vim.list_extend(lines, M.thread(c, W, { collapsed = M.is_collapsed(ctx, c) }))
    end
  end

  add(("#%d  %s"):format(turn.idx, turn.title), { { 0, -1, "SidekickReviewTitle" } }, {
    kind = "header",
    turn = turn.id,
  })
  local meta = ("%s · %d file%s changed · %d tool call%s"):format(
    M.ago(turn.ts),
    #turn.files,
    #turn.files == 1 and "" or "s",
    #turn.tools,
    #turn.tools == 1 and "" or "s"
  )
  add(" " .. meta, { { 0, -1, "SidekickReviewDim" } }, { kind = "header", turn = turn.id })
  add(string.rep("─", W), { { 0, -1, "SidekickReviewSep" } }, { kind = "blank" })

  -- the response view reads as a conversation, so say who is speaking: the
  -- prompt is yours, everything after it is the agent's. Without labels the
  -- prompt was indistinguishable from a review comment, which shares a gutter.
  local you = M.icons.you .. " you"
  add(you, { { 0, 1, "SidekickReviewAuthorYou" }, { 1, -1, "SidekickReviewAuthorYou" } }, {
    kind = "prompt",
    turn = turn.id,
  })
  for i, l in ipairs(vim.split(turn.prompt, "\n", { plain = true })) do
    if i > 40 then
      add(M.icons.you .. " …", { { 0, -1, "SidekickReviewDim" } }, { kind = "prompt", turn = turn.id })
      break
    end
    add(M.icons.you .. " " .. l, {
      { 0, #M.icons.you, "SidekickReviewAuthorYou" },
      { #M.icons.you, -1, "SidekickReviewPrompt" },
    }, { kind = "prompt", turn = turn.id })
  end
  add("", nil, { kind = "blank" })

  local provider = Provider.get(turn.provider)
  local agent = M.icons.agent .. " " .. (provider and provider.label or "agent")
  add(agent, { { 0, 1, "SidekickReviewAuthorAgent" }, { 1, -1, "SidekickReviewAuthorAgent" } }, {
    kind = "header",
    turn = turn.id,
  })
  add("", nil, { kind = "blank" })

  for bi, block in ipairs(turn.blocks) do
    if block.kind == "text" and block.text then
      -- prose is markdown: headings, lists, quotes and fenced code all get
      -- their own treatment, but one rendered line per source line so comment
      -- anchors (`b3:7`) keep pointing at the same thing
      for _, ml in ipairs(Markdown.render(block.text, { width = W })) do
        local key = ml.src and ("b%d:%d"):format(bi, ml.src) or nil
        add(ml.text, ml.hl, {
          kind = ml.code and "code" or "text",
          turn = turn.id,
          anchor_key = key,
          anchor = ml.text,
        })
        if key then
          flush(key)
        end
      end
      add("", nil, { kind = "blank" })
    elseif block.kind == "thinking" and block.text then
      local key = ("b%d:1"):format(bi)
      if ctx.show_thinking then
        -- an aside, not something the agent said: mark every line, so it
        -- reads as thinking even where colour does not come through
        add(M.icons.aside .. M.icons.thinking .. "thinking", { { 0, -1, "SidekickReviewThinking" } }, {
          kind = "text",
          turn = turn.id,
          anchor_key = key,
          anchor = "thinking",
        })
        for li, l in ipairs(vim.split(block.text, "\n", { plain = true })) do
          add(M.icons.aside .. l, { { 0, -1, "SidekickReviewThinking" } }, {
            kind = "text",
            turn = turn.id,
            anchor_key = ("b%d:%d"):format(bi, li),
            anchor = l,
          })
        end
        add("", nil, { kind = "blank" })
      else
        local n = select(2, block.text:gsub("\n", "")) + 1
        local label = ("%s%sthinking (%d lines, `T` to expand)"):format(M.icons.aside, M.icons.thinking, n)
        add(label, { { 0, -1, "SidekickReviewDim" } }, {
          kind = "text",
          turn = turn.id,
          anchor_key = key,
          anchor = "thinking",
        })
      end
      flush(key)
    elseif block.kind == "tool" and block.tool then
      local tool = block.tool
      local key = ("b%d:1"):format(bi)
      local detail = trunc(M.tool_summary(tool, turn.cwd), math.max(W - #tool.name - 8, 8))
      -- a failed tool call is worth spotting without relying on colour alone
      local left = ("  %s%s "):format(tool.error and M.icons.failed or M.icons.tool, tool.name)
      local text = left .. detail
      local hl = {
        { 0, #left, tool.error and "SidekickReviewToolError" or "SidekickReviewTool" },
        { #left, -1, "SidekickReviewDim" },
      } ---@type sidekick.review.HL[]
      add(text, hl, { kind = "tool", turn = turn.id, anchor_key = key, anchor = tool.name .. " " .. detail })
      flush(key)
    end
  end

  -- comments whose anchor line vanished still deserve to be seen
  for key, cs in pairs(anchored) do
    if not used[key] then
      vim.list_extend(orphans, cs)
    end
  end
  if #orphans > 0 then
    add("", nil, { kind = "blank" })
    add(" unanchored comments", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    for _, c in ipairs(orphans) do
      vim.list_extend(lines, M.thread(c, W, { collapsed = M.is_collapsed(ctx, c) }))
    end
  end

  return lines
end

--------------------------------------------------------------------------------
-- Diff view
--------------------------------------------------------------------------------

---@param diff sidekick.review.FileDiff
---@return table<integer, table<integer, string>> row -> col -> hl group
local function syntax_index(diff)
  if not diff.filetype then
    return {}
  end
  -- highlight the "after" side of each hunk as one fragment; treesitter on a
  -- partial file is imperfect but still far more readable than plain text
  local src = {} ---@type string[]
  local rows = {} ---@type integer[]
  for _, h in ipairs(diff.hunks) do
    for _, l in ipairs(h.lines) do
      if l.kind ~= "del" then
        src[#src + 1] = l.text
        rows[#rows + 1] = #src
      end
    end
  end
  if #src == 0 then
    return {}
  end
  local ok, extmarks = pcall(Treesitter.get_extmarks, table.concat(src, "\n"), { ft = diff.filetype })
  if not ok or not extmarks then
    return {}
  end
  local index = {} ---@type table<integer, table<integer, string>>
  for _, e in ipairs(extmarks) do
    if e.hl_group and e.end_col then
      index[e.row] = index[e.row] or {}
      for i = e.col + 1, e.end_col do
        index[e.row][i] = e.hl_group
      end
    end
  end
  return index
end

M.GUTTER = 11 -- "%4s %4s %s " => old, new, sign

---@param ctx sidekick.review.Ctx
---@param turn sidekick.review.Turn
---@param diff sidekick.review.FileDiff
---@return sidekick.review.Line[]
function M.diff(ctx, turn, diff)
  local lines = {} ---@type sidekick.review.Line[]
  local W = ctx.width
  local comments = ctx.store:for_turn(turn.id, { target = "file", file = diff.path })
  local anchored = by_anchor(comments)
  local used = {} ---@type table<string, boolean>

  ---@param text string
  ---@param hl? sidekick.review.HL[]
  ---@param item? sidekick.review.Item
  local function add(text, hl, item)
    lines[#lines + 1] = { text = text, hl = hl, item = item }
  end

  local stat = diff.deleted and "deleted" or ("+%d -%d"):format(diff.added, diff.removed)
  local suffix = diff.created and "  (new file)" or (diff.deleted and "  (deleted)" or "")
  local title = M.path(diff.rel, math.max(W - #stat - #suffix - 2, 8)) .. suffix
  add(
    pad(title, math.max(W - #stat - 1, 1)) .. stat,
    { { 0, #title, "SidekickReviewTitle" }, { #title, -1, "SidekickReviewStat" } },
    { kind = "header", turn = turn.id, file = diff.path }
  )
  local viewed = ctx.store:is_viewed(turn.id, diff.path)
  local note = "x toggle viewed · c comment"
  if diff.deleted then
    note = "removed by this turn"
  elseif diff.approx then
    note = "approximate line numbers (file changed since)"
  elseif diff.missing then
    note = "file no longer on disk"
  end
  local sub = ("%s · %s"):format(viewed and "viewed" or "not reviewed", note)
  add(" " .. sub, { { 0, -1, diff.approx and "SidekickReviewWarn" or "SidekickReviewDim" } }, {
    kind = "header",
    turn = turn.id,
    file = diff.path,
  })
  add(string.rep("─", W), { { 0, -1, "SidekickReviewSep" } }, { kind = "blank" })

  if diff.binary then
    add(" binary file — no textual diff", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end
  if #diff.hunks == 0 then
    local why = diff.deleted and " this file was deleted — its contents are not in the transcript"
      or " no textual changes"
    add(why, { { 0, -1, diff.deleted and "SidekickReviewDiffDelete" or "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end

  local syntax = syntax_index(diff)
  local srow = 0

  for hi, h in ipairs(diff.hunks) do
    -- an approximate diff has no line numbers to put in the header
    local hdr = diff.approx and ("@@ recorded edit %d of %d @@"):format(hi, #diff.hunks)
      or ("@@ -%d,%d +%d,%d @@"):format(h.old_start, h.old_count, h.new_start, h.new_count)
    add(hdr, { { 0, -1, "SidekickReviewHunk" } }, { kind = "hunk", turn = turn.id, file = diff.path })

    for _, l in ipairs(h.lines) do
      local sign = l.kind == "add" and "+" or (l.kind == "del" and "-" or " ")
      local gut = ("%4s %4s %s "):format(l.old_lnum or "", l.new_lnum or "", sign)
      local text = gut .. l.text
      local body_hl = l.kind == "add" and "SidekickReviewDiffAdd"
        or (l.kind == "del" and "SidekickReviewDiffDelete" or "SidekickReviewDiffContext")
      local hl = {
        { 0, #gut, "SidekickReviewLineNr" },
        { #gut, -1, body_hl },
      } ---@type sidekick.review.HL[]

      if l.kind ~= "del" then
        srow = srow + 1
        local row = syntax[srow]
        if row then
          -- overlay treesitter colours on top of the diff background
          local from, group = 0, nil ---@type integer, string?
          local function push(to)
            if group and to >= from then
              hl[#hl + 1] = { #gut + from, #gut + to, group }
            end
            from, group = to, nil
          end
          for col = 1, #l.text do
            local g = row[col]
            if g ~= group then
              push(col - 1)
              group = g
              from = col - 1
            end
          end
          push(#l.text)
        end
      end

      local side = l.kind == "del" and "old" or "new"
      local lnum = l.kind == "del" and l.old_lnum or l.new_lnum
      local key = ("%s:%s"):format(side, tostring(lnum))
      add(text, hl, {
        kind = "diff",
        turn = turn.id,
        file = diff.path,
        lnum = l.new_lnum,
        old_lnum = l.old_lnum,
        side = side,
        anchor_key = key,
        anchor = l.text,
      })
      used[key] = true
      for _, c in ipairs(anchored[key] or {}) do
        vim.list_extend(lines, M.thread(c, W, { collapsed = M.is_collapsed(ctx, c) }))
      end
    end
    add("", nil, { kind = "blank" })
  end

  local orphans = {} ---@type sidekick.review.Comment[]
  for key, cs in pairs(anchored) do
    if not used[key] then
      vim.list_extend(orphans, cs)
    end
  end
  if #orphans > 0 then
    add(" comments on lines outside the current diff", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    for _, c in ipairs(orphans) do
      vim.list_extend(lines, M.thread(c, W, { collapsed = M.is_collapsed(ctx, c) }))
    end
  end

  return lines
end

--------------------------------------------------------------------------------
-- Threads view
--------------------------------------------------------------------------------

--- Every conversation on a turn, in one place.
---
--- Inline threads are right next to the code they are about, which is what you
--- want while reviewing. Once a review has been round-tripped a couple of times
--- it is the conversation you want to follow, not the diff, so this view lists
--- them in order with their location as a heading.
---@param ctx sidekick.review.Ctx
---@param turn sidekick.review.Turn
---@return sidekick.review.Line[]
function M.threads(ctx, turn)
  local lines = {} ---@type sidekick.review.Line[]
  local W = ctx.width
  local comments = ctx.store:for_turn(turn.id)

  ---@param text string
  ---@param hl? sidekick.review.HL[]
  ---@param item? sidekick.review.Item
  local function add(text, hl, item)
    lines[#lines + 1] = { text = text, hl = hl, item = item }
  end

  local open_n, replies = 0, 0
  for _, c in ipairs(comments) do
    if c.status ~= "resolved" then
      open_n = open_n + 1
    end
    replies = replies + #c.replies
  end

  add(("Threads · #%d %s"):format(turn.idx, turn.title), { { 0, -1, "SidekickReviewTitle" } }, {
    kind = "header",
    turn = turn.id,
  })
  add(
    (" %d conversation%s · %d open · %d repl%s"):format(
      #comments,
      #comments == 1 and "" or "s",
      open_n,
      replies,
      replies == 1 and "y" or "ies"
    ),
    { { 0, -1, "SidekickReviewDim" } },
    { kind = "header", turn = turn.id }
  )
  add(string.rep("─", W), { { 0, -1, "SidekickReviewSep" } }, { kind = "blank" })

  if #comments == 0 then
    local hint = " no comments on this turn yet — press `c` on a diff line"
    add(hint, { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end

  for i, c in ipairs(comments) do
    if i > 1 then
      add("", nil, { kind = "blank" })
    end
    vim.list_extend(lines, M.thread(c, W, { collapsed = M.is_collapsed(ctx, c), location = true }))
  end

  add("", nil, { kind = "blank" })
  add(" <CR> fold/unfold · r reply · o jump to the code", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
  return lines
end

--- Overview shown when a rollup is selected but no file within it is.
---@param ctx sidekick.review.Ctx
---@param turn sidekick.review.Turn
---@return sidekick.review.Line[]
function M.rollup_summary(ctx, turn)
  local lines = {} ---@type sidekick.review.Line[]
  local W = ctx.width
  local diffs = ctx.diffs[turn.id] or {}

  ---@param text string
  ---@param hl? sidekick.review.HL[]
  ---@param item? sidekick.review.Item
  local function add(text, hl, item)
    lines[#lines + 1] = { text = text, hl = hl, item = item }
  end

  local added, removed = 0, 0
  for _, d in ipairs(diffs) do
    added, removed = added + d.added, removed + d.removed
  end

  add("All changes in this session", { { 0, -1, "SidekickReviewTitle" } }, { kind = "header", turn = turn.id })
  add((" %d file%s · +%d -%d"):format(#diffs, #diffs == 1 and "" or "s", added, removed), {
    { 0, -1, "SidekickReviewDim" },
  }, { kind = "header", turn = turn.id })
  add(string.rep("─", W), { { 0, -1, "SidekickReviewSep" } }, { kind = "blank" })

  if #diffs == 0 then
    add(" nothing changed", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end

  for _, d in ipairs(diffs) do
    local stat = d.deleted and "deleted" or ("+%d -%d"):format(d.added, d.removed)
    local name = M.path(d.rel, math.max(W - #stat - 4, 8))
    local text = " " .. pad(name, math.max(W - #stat - 2, 8)) .. stat
    add(text, {
      { 0, #text - #stat, "SidekickReviewText" },
      { #text - #stat, -1, d.deleted and "SidekickReviewDiffDelete" or "SidekickReviewStat" },
    }, { kind = "file", turn = turn.id, key = d.path, file = d.path })
  end

  add("", nil, { kind = "blank" })
  add(" <CR> open a file · this is the diff you would review before committing", {
    { 0, -1, "SidekickReviewDim" },
  }, { kind = "blank" })
  return lines
end

---@param ctx sidekick.review.Ctx
---@return sidekick.review.Line[]
function M.main(ctx)
  local turn ---@type sidekick.review.Turn?
  for _, rollup in pairs(ctx.rollups or {}) do
    if rollup.id == ctx.sel_turn then
      turn = rollup
    end
  end
  for _, tr in ipairs(ctx.transcripts or {}) do
    for _, t in ipairs(tr.turns) do
      if t.id == ctx.sel_turn then
        turn = t
        break
      end
    end
  end
  if not turn then
    return {
      { text = "", item = { kind = "blank" } },
      {
        text = "  No turn selected. Pick one on the left, or press `R` to refresh.",
        hl = { { 0, -1, "SidekickReviewDim" } },
        item = { kind = "blank" },
      },
    }
  end
  if ctx.sel_key == Store.THREADS then
    return M.threads(ctx, turn)
  end
  if turn.idx == 0 and (not ctx.sel_key or ctx.sel_key == Store.RESPONSE) then
    -- a rollup is a set of changes, not a conversation: point at its files
    return M.rollup_summary(ctx, turn)
  end
  if not ctx.sel_key or ctx.sel_key == Store.RESPONSE then
    return M.response(ctx, turn)
  end
  for _, d in ipairs(ctx.diffs[turn.id] or {}) do
    if d.path == ctx.sel_key then
      return M.diff(ctx, turn, d)
    end
  end
  return M.response(ctx, turn)
end

--- Footer / status bar.
---@param ctx sidekick.review.Ctx
---@return sidekick.review.Line
function M.footer(ctx)
  local pending = ctx.store:pending_count()
  local left = pending > 0 and ("%s%d pending"):format(M.icons.comment, pending) or "no pending comments"
  local right = "s sessions/filter · c comment · S submit · g? help · q quit"
  local gap = math.max(ctx.width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right) - 2, 1)
  local text = " " .. left .. string.rep(" ", gap) .. right
  return {
    text = text,
    hl = {
      { 0, #left + 1, pending > 0 and "SidekickReviewPending" or "SidekickReviewDim" },
      { #left + 1, -1, "SidekickReviewDim" },
    },
    item = { kind = "blank" },
  }
end

return M
