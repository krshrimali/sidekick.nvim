---@brief Pure rendering for the review UI.
---
--- Everything here maps model data to `sidekick.review.Line[]`: text plus
--- highlight ranges plus the item the line represents. No window or buffer API
--- is touched, so the whole UI can be asserted on in tests.
local Store = require("sidekick.review.store")
local Treesitter = require("sidekick.treesitter")

local M = {}

---@alias sidekick.review.HL { [1]:integer, [2]:integer, [3]:string } col_start, col_end (exclusive, -1 = eol), group

---@class sidekick.review.Item
---@field kind "turn"|"file"|"response"|"diff"|"comment"|"reply"|"text"|"tool"|"hunk"|"prompt"|"blank"|"header"
---@field turn? string
---@field file? string file path (diff view)
---@field lnum? integer line number in the file
---@field old_lnum? integer
---@field side? "new"|"old"
---@field anchor_key? string stable id used to re-attach comments across renders
---@field anchor? string the source text of this line
---@field comment? sidekick.review.Comment
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
---@field width integer

-- stylua: ignore
M.icons = {
  expanded   = "▾ ",
  collapsed  = "▸ ",
  response   = "󰭹 ",
  file       = " ",
  new        = " ",
  viewed     = " ",
  unviewed   = " ",
  comment    = " ",
  reply      = "↳ ",
  pending    = "● ",
  sent       = "◍ ",
  resolved   = "✓ ",
  tool       = " ",
  failed     = "✗ ",
  thinking   = " ",
  pending_turn = "󱎫 ",
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

---@param icon string
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
  local comments = key == Store.RESPONSE and ctx.store:for_turn(turn.id, { target = "response" })
    or ctx.store:for_turn(turn.id, { target = "file", file = key })
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

  add(" Claude Review", { { 0, -1, "SidekickReviewTitle" } }, { kind = "header" })
  local sess = ctx.transcript and ctx.transcript.session:sub(1, 8) or "?"
  add(" session " .. sess, { { 0, -1, "SidekickReviewDim" } }, { kind = "header" })
  add(string.rep("─", W), { { 0, -1, "SidekickReviewSep" } }, { kind = "blank" })

  local turns = ctx.transcript and ctx.transcript.turns or {}
  if #turns == 0 then
    add(" no turns found", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end

  -- newest first: the turn you want to review is almost always the last one
  for i = #turns, 1, -1 do
    local turn = turns[i]
    local open = ctx.expanded[turn.id] == true
    local sel = ctx.sel_turn == turn.id

    local n_total, n_pending = 0, 0
    for _, c in ipairs(ctx.store:for_turn(turn.id)) do
      n_total = n_total + 1
      if c.status == "pending" then
        n_pending = n_pending + 1
      end
    end

    local when = M.ago(turn.ts)
    local prefix = (open and M.icons.expanded or M.icons.collapsed) .. ("#%d "):format(turn.idx)
    local badge = n_pending > 0 and (" %s%d"):format(M.icons.comment, n_pending)
      or (n_total > 0 and (" %s%d"):format(M.icons.comment, n_total) or "")
    if turn.pending then
      badge = " " .. M.icons.pending_turn .. badge
    end
    local avail = W - #prefix - vim.fn.strdisplaywidth(badge) - #when - 2
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
        local left = "  " .. mark .. icon
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
        add(t, h, {
          kind = key == Store.RESPONSE and "response" or "file",
          turn = turn.id,
          key = key,
          file = key ~= Store.RESPONSE and key or nil,
        })
      end

      child(Store.RESPONSE, M.icons.response, "Response", "", "SidekickReviewDim")

      for _, d in ipairs(ctx.diffs[turn.id] or {}) do
        local stat = ("+%d -%d"):format(d.added, d.removed)
        child(d.path, d.created and M.icons.new or M.icons.file, d.rel, stat, "SidekickReviewStat")
      end
      if #(ctx.diffs[turn.id] or {}) == 0 then
        add("    no files changed", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank", turn = turn.id })
      end
    end
  end

  return lines
end

--------------------------------------------------------------------------------
-- Comment threads
--------------------------------------------------------------------------------

--- Render a comment and its replies as an inline thread block.
---@param c sidekick.review.Comment
---@param width integer
---@return sidekick.review.Line[]
function M.thread(c, width)
  local lines = {} ---@type sidekick.review.Line[]
  local bar = "│ "

  local status = c.status
  local head = ("╭ %s[%s] you"):format(status_icon(status), c.id)
  if status == "sent" then
    head = head .. " · awaiting reply"
  elseif status == "resolved" then
    head = head .. " · resolved"
  end
  local head_hl = status == "pending" and "SidekickReviewPending"
    or (status == "resolved" and "SidekickReviewResolved" or "SidekickReviewSent")
  lines[#lines + 1] = {
    text = head,
    hl = { { 0, 2, "SidekickReviewCommentBorder" }, { 2, -1, head_hl } },
    item = { kind = "comment", comment = c },
  }

  for _, l in ipairs(vim.split(c.body, "\n", { plain = true })) do
    lines[#lines + 1] = {
      text = bar .. l,
      hl = { { 0, #bar, "SidekickReviewCommentBorder" }, { #bar, -1, "SidekickReviewComment" } },
      item = { kind = "comment", comment = c },
    }
  end

  for _, r in ipairs(c.replies) do
    local who = r.role == "claude" and "claude" or "you"
    lines[#lines + 1] = {
      text = ("%s%s%s"):format(bar, M.icons.reply, who),
      hl = { { 0, #bar, "SidekickReviewCommentBorder" }, { #bar, -1, "SidekickReviewReplyHead" } },
      item = { kind = "reply", comment = c },
    }
    for _, l in ipairs(vim.split(r.body, "\n", { plain = true })) do
      lines[#lines + 1] = {
        text = bar .. "  " .. l,
        hl = { { 0, #bar, "SidekickReviewCommentBorder" }, { #bar, -1, "SidekickReviewReply" } },
        item = { kind = "reply", comment = c },
      }
    end
  end

  lines[#lines + 1] = {
    text = "╰" .. string.rep("─", math.min(math.max(width - 2, 4), 40)),
    hl = { { 0, -1, "SidekickReviewCommentBorder" } },
    item = { kind = "comment", comment = c },
  }
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
      vim.list_extend(lines, M.thread(c, W))
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

  -- the prompt reads like a PR description
  for i, l in ipairs(vim.split(turn.prompt, "\n", { plain = true })) do
    if i > 40 then
      add("│ …", { { 0, -1, "SidekickReviewDim" } }, { kind = "prompt", turn = turn.id })
      break
    end
    add("│ " .. l, { { 0, 2, "SidekickReviewCommentBorder" }, { 2, -1, "SidekickReviewPrompt" } }, {
      kind = "prompt",
      turn = turn.id,
    })
  end
  add("", nil, { kind = "blank" })

  for bi, block in ipairs(turn.blocks) do
    if block.kind == "text" and block.text then
      for li, l in ipairs(vim.split(block.text, "\n", { plain = true })) do
        local key = ("b%d:%d"):format(bi, li)
        add(l, { { 0, -1, "SidekickReviewText" } }, {
          kind = "text",
          turn = turn.id,
          anchor_key = key,
          anchor = l,
        })
        flush(key)
      end
      add("", nil, { kind = "blank" })
    elseif block.kind == "thinking" and block.text then
      local key = ("b%d:1"):format(bi)
      if ctx.show_thinking then
        add(M.icons.thinking .. "thinking", { { 0, -1, "SidekickReviewThinking" } }, {
          kind = "text",
          turn = turn.id,
          anchor_key = key,
          anchor = "thinking",
        })
        for li, l in ipairs(vim.split(block.text, "\n", { plain = true })) do
          add("  " .. l, { { 0, -1, "SidekickReviewThinking" } }, {
            kind = "text",
            turn = turn.id,
            anchor_key = ("b%d:%d"):format(bi, li),
            anchor = l,
          })
        end
        add("", nil, { kind = "blank" })
      else
        local n = select(2, block.text:gsub("\n", "")) + 1
        local label = ("%sthinking (%d lines, `t` to expand)"):format(M.icons.thinking, n)
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
      vim.list_extend(lines, M.thread(c, W))
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

  local stat = ("+%d -%d"):format(diff.added, diff.removed)
  local suffix = diff.created and "  (new file)" or ""
  local title = M.path(diff.rel, math.max(W - #stat - #suffix - 2, 8)) .. suffix
  add(
    pad(title, math.max(W - #stat - 1, 1)) .. stat,
    { { 0, #title, "SidekickReviewTitle" }, { #title, -1, "SidekickReviewStat" } },
    { kind = "header", turn = turn.id, file = diff.path }
  )
  local viewed = ctx.store:is_viewed(turn.id, diff.path)
  local note = "x toggle viewed · c comment"
  if diff.approx then
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
    add(" no textual changes", { { 0, -1, "SidekickReviewDim" } }, { kind = "blank" })
    return lines
  end

  local syntax = syntax_index(diff)
  local srow = 0

  for _, h in ipairs(diff.hunks) do
    local hdr = ("@@ -%d,%d +%d,%d @@"):format(h.old_start, h.old_count, h.new_start, h.new_count)
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
        vim.list_extend(lines, M.thread(c, W))
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
      vim.list_extend(lines, M.thread(c, W))
    end
  end

  return lines
end

---@param ctx sidekick.review.Ctx
---@return sidekick.review.Line[]
function M.main(ctx)
  local turns = ctx.transcript and ctx.transcript.turns or {}
  local turn ---@type sidekick.review.Turn?
  for _, t in ipairs(turns) do
    if t.id == ctx.sel_turn then
      turn = t
      break
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
  local right = "c comment · r reply · S submit · x viewed · g? help · q quit"
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
