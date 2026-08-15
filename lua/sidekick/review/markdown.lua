---@brief Render an agent's markdown prose into highlighted review lines.
---
--- This is deliberately a line-oriented renderer rather than a real markdown
--- parser: **every source line produces exactly one rendered line**. Comment
--- anchors are keyed by source line index (`b3:7`), so a renderer that added or
--- removed lines would silently detach existing threads. Decorations that carry
--- no source line (a code fence's top and bottom rule) are emitted separately
--- and marked unanchorable.
local Treesitter = require("sidekick.treesitter")

local M = {}

---@class sidekick.review.md.Line
---@field text string
---@field hl sidekick.review.HL[]
---@field src? integer 1-based index of the source line this came from
---@field code? boolean part of a fenced code block

-- stylua: ignore
M.icons = {
  bullet   = "•",
  quote    = "▏",
  rule     = "─",
  fence    = "▏",
  checked  = "",
  unchecked= "",
}

---@param lang? string
---@return string?
local function to_filetype(lang)
  if not lang or lang == "" then
    return nil
  end
  lang = lang:lower():match("^[%w_+#.-]+") or lang
  local ok, ft = pcall(vim.filetype.get_option, lang, "filetype")
  if ok and type(ft) == "string" and ft ~= "" then
    return lang
  end
  -- `vim.treesitter.language.get_lang` resolves aliases like `sh` -> `bash`
  local ok2, resolved = pcall(vim.treesitter.language.get_lang, lang)
  return ok2 and resolved or lang
end

--- Highlight ranges for inline spans: `code`, **bold**, *italic*, [link](url).
---@param text string
---@param base string
---@return sidekick.review.HL[]
function M.inline(text, base)
  local hl = { { 0, -1, base } } ---@type sidekick.review.HL[]

  ---@param pattern string
  ---@param group string
  local function mark(pattern, group)
    local from = 1
    while true do
      local s, e = text:find(pattern, from)
      if not s then
        break
      end
      hl[#hl + 1] = { s - 1, e, group }
      from = e + 1
    end
  end

  mark("`[^`]+`", "SidekickReviewMdCode")
  mark("%*%*[^%*]+%*%*", "SidekickReviewMdBold")
  mark("%[[^%]]+%]%([^%)]+%)", "SidekickReviewMdLink")
  return hl
end

--- Split prose into rendered lines.
---@param text string
---@param opts? {width?:integer}
---@return sidekick.review.md.Line[]
function M.render(text, opts)
  opts = opts or {}
  local width = opts.width or 80
  local out = {} ---@type sidekick.review.md.Line[]
  local src_lines = vim.split(text, "\n", { plain = true })

  -- first pass: find fenced blocks so their bodies can be highlighted together
  local fences = {} ---@type {from:integer, to:integer, lang?:string}[]
  local open ---@type {from:integer, lang?:string}?
  local marker ---@type string?
  for i, line in ipairs(src_lines) do
    local fence, lang = line:match("^%s*(```+)%s*([%w_+#.-]*)")
    if not fence then
      fence, lang = line:match("^%s*(~~~+)%s*([%w_+#.-]*)")
    end
    if fence then
      if open and fence:sub(1, 1) == (marker or ""):sub(1, 1) and #fence >= #(marker or "") then
        fences[#fences + 1] = { from = open.from, to = i, lang = open.lang }
        open, marker = nil, nil
      elseif not open then
        open, marker = { from = i, lang = lang ~= "" and lang or nil }, fence
      end
    end
  end
  if open then
    -- an unterminated fence still renders as code to the end of the block
    fences[#fences + 1] = { from = open.from, to = #src_lines + 1, lang = open.lang }
  end

  local in_fence = {} ---@type table<integer, {fence:table, index:integer}>
  for _, f in ipairs(fences) do
    for i = f.from + 1, math.min(f.to - 1, #src_lines) do
      in_fence[i] = { fence = f, index = i - f.from }
    end
  end

  -- syntax highlight each fenced body in one go
  local syntax = {} ---@type table<integer, table<integer, table<integer, string>>>
  for fi, f in ipairs(fences) do
    local ft = to_filetype(f.lang)
    if ft then
      local body = {} ---@type string[]
      for i = f.from + 1, math.min(f.to - 1, #src_lines) do
        body[#body + 1] = src_lines[i]
      end
      if #body > 0 then
        local ok, extmarks = pcall(Treesitter.get_extmarks, table.concat(body, "\n"), { ft = ft })
        if ok and extmarks then
          local index = {} ---@type table<integer, table<integer, string>>
          for _, e in ipairs(extmarks) do
            if e.hl_group and e.end_col then
              index[e.row] = index[e.row] or {}
              for c = e.col + 1, e.end_col do
                index[e.row][c] = e.hl_group
              end
            end
          end
          syntax[fi] = index
        end
      end
    end
  end

  ---@param text_ string
  ---@param hl sidekick.review.HL[]
  ---@param src? integer
  ---@param code? boolean
  local function add(text_, hl, src, code)
    out[#out + 1] = { text = text_, hl = hl, src = src, code = code }
  end

  for i, line in ipairs(src_lines) do
    local fence = nil ---@type table?
    local fi = nil ---@type integer?
    for k, f in ipairs(fences) do
      if i == f.from or i == f.to then
        fence, fi = f, k
      end
    end

    if fence and i == fence.from then
      -- opening fence: replace the ``` marker with a labelled rule
      local label = fence.lang and (" " .. fence.lang .. " ") or ""
      local rule = M.icons.fence .. "╴" .. label .. string.rep("╴", math.max(width - #label - 4, 2))
      add(rule, { { 0, -1, "SidekickReviewMdFence" } }, i)
    elseif fence and i == fence.to then
      add(M.icons.fence .. string.rep("╴", math.max(width - 2, 2)), { { 0, -1, "SidekickReviewMdFence" } }, i)
    elseif in_fence[i] then
      local info = in_fence[i]
      local gutter = M.icons.fence .. " "
      local body = gutter .. line
      local hl = {
        { 0, #gutter, "SidekickReviewMdFence" },
        { #gutter, -1, "SidekickReviewMdCodeBlock" },
      } ---@type sidekick.review.HL[]
      local fidx ---@type integer?
      for k, f in ipairs(fences) do
        if f == info.fence then
          fidx = k
        end
      end
      local rows = fidx and syntax[fidx]
      local row = rows and rows[info.index]
      if row then
        local from, group = 0, nil ---@type integer, string?
        local function push(to)
          if group and to >= from then
            hl[#hl + 1] = { #gutter + from, #gutter + to, group }
          end
          from, group = to, nil
        end
        for col = 1, #line do
          local g = row[col]
          if g ~= group then
            push(col - 1)
            group, from = g, col - 1
          end
        end
        push(#line)
      end
      add(body, hl, i, true)
    else
      local heading, htext = line:match("^(#+)%s+(.*)$")
      local quote = line:match("^%s*>%s?(.*)$")
      local bullet, btext = line:match("^(%s*)[%-%*%+]%s+(.*)$")
      local num, ntext = line:match("^%s*(%d+[%.%)])%s+(.*)$")
      local rule = line:match("^%s*([%-%*_])%s*%1%s*%1[%s%-%*_]*$")

      if heading then
        local level = #heading
        local text_ = ("%s %s"):format(string.rep("#", level), htext)
        add(text_, { { 0, -1, level <= 2 and "SidekickReviewMdH1" or "SidekickReviewMdH2" } }, i)
      elseif rule then
        add(string.rep(M.icons.rule, math.max(width, 4)), { { 0, -1, "SidekickReviewSep" } }, i)
      elseif quote then
        local text_ = M.icons.quote .. " " .. quote
        local hl = M.inline(text_, "SidekickReviewMdQuote")
        table.insert(hl, 1, { 0, 1, "SidekickReviewCommentBorder" })
        add(text_, hl, i)
      elseif bullet then
        local mark_, rest = btext:match("^%[([ xX])%]%s+(.*)$")
        local glyph = M.icons.bullet
        if mark_ then
          glyph = (mark_ == " ") and M.icons.unchecked or M.icons.checked
          btext = rest
        end
        local text_ = bullet .. glyph .. " " .. btext
        local hl = M.inline(text_, "SidekickReviewText")
        table.insert(hl, 1, { #bullet, #bullet + #glyph, "SidekickReviewMdBullet" })
        add(text_, hl, i)
      elseif num then
        local text_ = ("%s %s"):format(num, ntext)
        local hl = M.inline(text_, "SidekickReviewText")
        table.insert(hl, 1, { 0, #num, "SidekickReviewMdBullet" })
        add(text_, hl, i)
      else
        add(line, M.inline(line, "SidekickReviewText"), i)
      end
    end
  end

  return out
end

return M
