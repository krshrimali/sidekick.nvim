---@brief Parse Codex `apply_patch` payloads into review changes.
---
--- Codex records file edits as a patch document rather than as structured
--- old/new pairs:
---
--- ```
--- *** Begin Patch
--- *** Add File: /abs/path
--- +new line
--- *** Update File: /abs/path
--- @@ optional context header
---  context
--- -removed
--- +added
--- *** Delete File: /abs/path
--- *** End Patch
--- ```
---
--- Each `@@` section becomes one `old -> new` change, which is exactly the
--- shape Claude's `Edit` tool produces, so the diff reconstruction in
--- `sidekick.review.diff` works for both providers without knowing which is
--- which.

local M = {}

---@class sidekick.review.PatchFile
---@field path string
---@field action "add"|"update"|"delete"
---@field changes { old:string, new:string }[]

M.BEGIN = "*** Begin Patch"
M.END = "*** End Patch"

--- Decode a JavaScript/JSON double-quoted string body.
---@param s string
---@return string
local function unescape(s)
  local ok, decoded = pcall(vim.json.decode, '"' .. s .. '"')
  if ok and type(decoded) == "string" then
    return decoded
  end
  -- best effort when the slice is not valid JSON (e.g. a stray escape)
  return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

--- Pull every patch document out of arbitrary tool input.
---
--- Newer Codex builds run JavaScript, so the patch arrives embedded in a
--- string literal (`const patch = "*** Begin Patch\n…"`). Older builds pass
--- the patch as the tool input directly.
---@param input string
---@return string[]
function M.extract(input)
  if type(input) ~= "string" or input == "" then
    return {}
  end

  -- direct form: the input *is* the patch
  if input:find(M.BEGIN, 1, true) and input:find("\n", 1, true) and input:match("^%s*%*%*%* Begin Patch") then
    return { input }
  end

  local ret = {} ---@type string[]
  local from = 1
  while true do
    local at = input:find(M.BEGIN, from, true)
    if not at then
      break
    end
    from = at + #M.BEGIN

    -- walk back to the opening quote of the enclosing string literal
    local open ---@type integer?
    for i = at - 1, 1, -1 do
      if input:sub(i, i) == '"' then
        local slashes = 0
        for j = i - 1, 1, -1 do
          if input:sub(j, j) == "\\" then
            slashes = slashes + 1
          else
            break
          end
        end
        if slashes % 2 == 0 then
          open = i
          break
        end
      elseif input:sub(i, i) == "\n" then
        break -- a literal newline means we are not inside a JS string
      end
    end

    if open then
      -- and forward to its unescaped closing quote
      local close ---@type integer?
      local i = at
      while i <= #input do
        local c = input:sub(i, i)
        if c == "\\" then
          i = i + 2
        elseif c == '"' then
          close = i
          break
        else
          i = i + 1
        end
      end
      if close then
        local body = unescape(input:sub(open + 1, close - 1))
        if body:find(M.BEGIN, 1, true) then
          ret[#ret + 1] = body
        end
        from = close + 1
      end
    else
      -- not quoted: take the rest up to the end marker
      local stop = input:find(M.END, at, true)
      ret[#ret + 1] = input:sub(at, stop and stop + #M.END - 1 or #input)
      from = stop and stop + #M.END or #input + 1
    end
  end
  return ret
end

--- Parse one patch document.
---@param patch string
---@return sidekick.review.PatchFile[]
function M.parse(patch)
  local files = {} ---@type sidekick.review.PatchFile[]
  if type(patch) ~= "string" then
    return files
  end

  local current ---@type sidekick.review.PatchFile?
  local old, new = {}, {} ---@type string[], string[]
  local started = false

  local function flush_hunk()
    if current and (#old > 0 or #new > 0) then
      local a, b = table.concat(old, "\n"), table.concat(new, "\n")
      -- a section with only context lines changed nothing; drop it so it does
      -- not show up as an empty hunk in the review
      if a ~= b then
        current.changes[#current.changes + 1] = { old = a, new = b }
      end
    end
    old, new = {}, {}
  end

  local function flush_file()
    flush_hunk()
    current = nil
  end

  for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
    local add = line:match("^%*%*%* Add File: (.+)$")
    local update = line:match("^%*%*%* Update File: (.+)$")
    local del = line:match("^%*%*%* Delete File: (.+)$")
    local move = line:match("^%*%*%* Move to: (.+)$")

    if line:match("^%*%*%* Begin Patch") then
      started = true
    elseif line:match("^%*%*%* End Patch") then
      flush_file()
      break
    elseif add or update or del then
      flush_file()
      current = {
        path = vim.trim(add or update or del),
        action = add and "add" or (del and "delete" or "update"),
        changes = {},
      }
      files[#files + 1] = current
    elseif move and current then
      -- a rename keeps the same content; follow the destination path
      current.path = vim.trim(move)
    elseif current then
      local marker, rest = line:sub(1, 1), line:sub(2)
      if line:match("^@@") then
        flush_hunk()
      elseif marker == "+" then
        new[#new + 1] = rest
      elseif marker == "-" then
        old[#old + 1] = rest
      elseif marker == " " then
        old[#old + 1] = rest
        new[#new + 1] = rest
      elseif line == "" then
        -- a bare empty line inside a hunk is context
        old[#old + 1] = ""
        new[#new + 1] = ""
      end
    end
  end
  flush_file()

  if not started then
    return {}
  end

  -- an `Add File` section has no old side at all
  for _, f in ipairs(files) do
    if f.action == "add" then
      local lines = {} ---@type string[]
      for _, c in ipairs(f.changes) do
        if c.new ~= "" then
          lines[#lines + 1] = c.new
        end
      end
      f.changes = { { old = "", new = table.concat(lines, "\n") } }
    end
  end

  return files
end

--- Extract and parse in one step.
---@param input string
---@return sidekick.review.PatchFile[]
function M.files(input)
  local ret = {} ---@type sidekick.review.PatchFile[]
  for _, patch in ipairs(M.extract(input)) do
    vim.list_extend(ret, M.parse(patch))
  end
  return ret
end

return M
