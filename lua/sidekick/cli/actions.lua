local Config = require("sidekick.config")

---@alias sidekick.cli.Action fun(terminal: sidekick.cli.Terminal):string?
---@type table<string, sidekick.cli.Action>
local M = {}

function M.prompt(t)
  vim.cmd.stopinsert() -- needed, since otherwise Neovim will do this

  vim.schedule(function()
    local Cli = require("sidekick.cli")
    Cli.prompt(function(prompt)
      vim.schedule(function()
        vim.cmd.startinsert()
      end)
      if prompt then
        t:send(prompt .. "\n")
      end
    end)
  end)
end

---@param source string
---@param t sidekick.cli.Terminal
local function picker(source, t)
  vim.cmd.stopinsert()
  vim.schedule(function()
    require("sidekick.cli.picker").open(source, { filter = { session = t.id } }, {
      on_show = function()
        t.normal_mode = false
      end,
    })
  end)
end

function M.files(t)
  picker("files", t)
end

function M.buffers(t)
  picker("buffers", t)
end

---@param dir "h"|"j"|"k"|"l"
local function nav(dir)
  ---@type sidekick.cli.Action
  return function(terminal)
    local at_edge = vim.fn.winnr() == vim.fn.winnr(dir)
    if at_edge or terminal:is_float() then
      return ("<c-%s>"):format(dir)
    end
    vim.schedule(function()
      (Config.cli.win.nav or vim.cmd.wincmd)(dir)
    end)
  end
end

M.nav_left = nav("h")
M.nav_down = nav("j")
M.nav_up = nav("k")
M.nav_right = nav("l")

--- Extract all file path candidates from a line of text.
--- Handles formats like: path/to/file.rs:42:5, path/to/file.rs:42, path/to/file.rs
--- Also strips ANSI escape codes and handles backtick-wrapped paths.
---@param line string
---@param cursor_col integer 0-indexed cursor column
---@param cwd string working directory to resolve relative paths
---@return string? file, integer? lnum, integer? col, integer? end_lnum
local function parse_file_path(line, cursor_col, cwd)
  -- Strip ANSI escape codes and other non-printable sequences from terminal output
  local clean = line:gsub("\027%[[%d;]*[A-Za-z]", "")
  -- Replace common non-ASCII whitespace (e.g. non-breaking spaces) with regular spaces
  clean = clean:gsub("\xc2\xa0", " ")

  local best_file, best_lnum, best_col, best_end_lnum, best_dist

  -- Patterns to try, ordered by specificity
  -- File path: word chars, dots, slashes, hyphens — at minimum "x.y"
  local patterns = {
    -- path:line:col
    "([%w_./-]+%.[%w_]+):(%d+):(%d+)",
    -- path:line
    "([%w_./-]+%.[%w_]+):(%d+)",
    -- bare path (with / or .ext)
    "([%w_./-]+%.[%w_]+)",
  }

  for _, pat in ipairs(patterns) do
    local pos = 1
    while pos <= #clean do
      local results = { clean:find(pat, pos) }
      if not results[1] then
        break
      end
      local s, e = results[1], results[2]
      local path = results[3]
      local lnum = results[4] and tonumber(results[4])
      local num2 = results[5] and tonumber(results[5])
      -- Heuristic: if the third number > second number, treat as line range (start:end)
      -- Otherwise treat as line:col (e.g. compiler output like file.rs:68:5)
      local col_num, end_lnum
      if num2 and lnum and num2 > lnum then
        end_lnum = num2
      else
        col_num = num2
      end

      -- Resolve relative paths
      local abs_path
      if vim.startswith(path, "/") then
        abs_path = path
      else
        abs_path = cwd .. "/" .. path
      end
      abs_path = vim.fs.normalize(abs_path)

      -- Check if file exists
      local stat = vim.uv.fs_stat(abs_path)
      if stat and stat.type == "file" then
        -- Distance from cursor to the match (prefer matches the cursor is inside)
        local dist
        if cursor_col >= s - 1 and cursor_col <= e then
          dist = 0
        else
          dist = math.min(math.abs(cursor_col - s), math.abs(cursor_col - e))
        end
        if not best_dist or dist < best_dist then
          best_file = abs_path
          best_lnum = lnum
          best_col = col_num
          best_end_lnum = end_lnum
          best_dist = dist
        end
      end

      pos = e + 1
    end

    -- If we found a match with the more specific pattern, use it
    if best_file then
      break
    end
  end

  return best_file, best_lnum, best_col, best_end_lnum
end

--- Find a suitable target window for opening files (non-terminal window)
---@return integer? win_id of the target window, or nil if none found
local function find_target_window()
  local current_win = vim.api.nvim_get_current_win()

  -- Try the previous window first (window before terminal was focused)
  local prev_win = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev_win ~= 0 and prev_win ~= current_win and vim.api.nvim_win_is_valid(prev_win) then
    local bufnr = vim.api.nvim_win_get_buf(prev_win)
    local buftype = vim.bo[bufnr].buftype
    -- Accept normal file buffers or empty buftype
    if buftype == '' or buftype == 'acwrite' then
      return prev_win
    end
  end

  -- Find any non-terminal, non-special window
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= current_win and vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      local buftype = vim.bo[bufnr].buftype
      if buftype == '' or buftype == 'acwrite' then
        return win
      end
    end
  end

  return nil
end

---@param open_cmd string vim command to open the file ("edit", "split", "vsplit")
---@param t sidekick.cli.Terminal
local function goto_file_with(open_cmd, t)
  -- Capture terminal buffer context BEFORE stopinsert/schedule to avoid race conditions
  local term_win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(term_win)
  local row = cursor[1]
  local col = cursor[2] -- 0-indexed
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  local cwd = t.cwd or vim.fn.getcwd()

  vim.cmd.stopinsert()
  vim.schedule(function()
    local file, lnum, file_col, end_lnum = parse_file_path(line, col, cwd)
    if not file then
      vim.notify("No file path found on this line", vim.log.levels.WARN)
      return
    end

    -- Find and switch to a suitable target window (main editor view)
    local target_win = find_target_window()
    if target_win then
      vim.api.nvim_set_current_win(target_win)
    else
      -- Fallback to previous window if no suitable window found
      vim.cmd.wincmd("p")
    end

    vim.cmd(open_cmd .. " " .. vim.fn.fnameescape(file))
    if lnum then
      vim.api.nvim_win_set_cursor(0, { lnum, (file_col or 1) - 1 })
      if end_lnum then
        -- Visually select the line range
        vim.cmd("normal! V")
        vim.api.nvim_win_set_cursor(0, { end_lnum, 0 })
      end
    end
  end)
end

function M.goto_file(t)
  goto_file_with("edit", t)
end

function M.goto_file_hsplit(t)
  goto_file_with("split", t)
end

function M.goto_file_vsplit(t)
  goto_file_with("vsplit", t)
end

return M
