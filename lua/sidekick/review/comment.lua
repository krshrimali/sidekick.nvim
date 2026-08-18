---@brief A small markdown composer used for comments, replies and submissions.
---
--- The quoted anchor lives in its own pinned window above the input rather than
--- inside the buffer, so it can never be edited into the comment body.
--- (Virtual lines are not an option: `virt_lines_above` on the first line has
--- nothing to draw into.)
local M = {}

---@class sidekick.review.comment.Opts
---@field title string
---@field body? string prefilled text
---@field context? string[] read-only lines shown above the input
---@field height? number fraction of the screen height for the input
---@field submit_label? string
---@field on_submit fun(body:string)
---@field on_cancel? fun()

M.MAX_CONTEXT = 8

---@param opts sidekick.review.comment.Opts
---@return integer buf, integer win
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "sidekick://review/compose")

  local body = opts.body and vim.split(opts.body, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modified = false

  local total_h = math.max(vim.o.lines - vim.o.cmdheight, 8)
  local width = math.min(math.max(math.floor(vim.o.columns * 0.6), 50), vim.o.columns - 4)

  -- the quote takes what it needs, the input takes the rest
  local quote = {} ---@type string[]
  for i, l in ipairs(opts.context or {}) do
    if i > M.MAX_CONTEXT then
      local rest = #opts.context - M.MAX_CONTEXT
      quote[#quote + 1] = ("… %d more line%s"):format(rest, rest == 1 and "" or "s")
      break
    end
    quote[#quote + 1] = (l:gsub("\t", "  "))
  end

  local input_h = math.floor(total_h * (opts.height or 0.35))
  input_h = math.max(math.min(input_h, total_h - #quote - 6), 3)
  local quote_h = #quote
  -- borders: 2 for the input, 2 for the quote when present
  local block_h = input_h + 2 + (quote_h > 0 and quote_h + 2 or 0)
  local top = math.max(math.floor((total_h - block_h) / 2), 0)
  local col = math.max(math.floor((vim.o.columns - width) / 2), 0)

  local wins = {} ---@type integer[]

  if quote_h > 0 then
    local qbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(qbuf, 0, -1, false, quote)
    vim.bo[qbuf].modifiable = false
    vim.bo[qbuf].bufhidden = "wipe"
    local qwin = vim.api.nvim_open_win(qbuf, false, {
      relative = "editor",
      row = top,
      col = col,
      width = width,
      height = quote_h,
      style = "minimal",
      border = "rounded",
      title = " context ",
      title_pos = "center",
      zindex = 249,
    })
    vim.wo[qwin].wrap = false
    vim.wo[qwin].winhighlight =
      "Normal:SidekickReviewQuote,FloatBorder:SidekickReviewCommentBorder,FloatTitle:SidekickReviewDim"
    wins[#wins + 1] = qwin
  end

  local label = opts.submit_label or "save"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = top + (quote_h > 0 and quote_h + 2 or 0),
    col = col,
    width = width,
    height = input_h,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    footer = (" <C-s> or :w %s  ·  <Esc><Esc> or q cancel "):format(label),
    footer_pos = "center",
    zindex = 250,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight =
    "Normal:SidekickReviewNormal,FloatBorder:SidekickReviewBorder,FloatTitle:SidekickReviewTitle,FloatFooter:SidekickReviewDim"

  local done = false
  ---@param submit boolean
  local function finish(submit)
    if done then
      return
    end
    done = true
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    vim.bo[buf].modified = false
    for _, w in ipairs(wins) do
      pcall(vim.api.nvim_win_close, w, true)
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if submit then
      opts.on_submit(text)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function map(mode, lhs, submit)
    vim.keymap.set(mode, lhs, function()
      finish(submit)
    end, { buffer = buf, nowait = true, silent = true })
  end

  map({ "n", "i" }, "<C-s>", true)
  map("n", "q", false)
  map("n", "<Esc><Esc>", false)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      finish(true)
    end,
  })
  -- closing the input by any other means must still tear down the quote window
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if done then
        return
      end
      done = true
      for _, w in ipairs(wins) do
        pcall(vim.api.nvim_win_close, w, true)
      end
      if opts.on_cancel then
        opts.on_cancel()
      end
    end,
  })

  if #body > 1 or (body[1] or "") ~= "" then
    pcall(vim.api.nvim_win_set_cursor, win, { #body, 0 })
  else
    vim.cmd.startinsert()
  end

  return buf, win
end

return M
