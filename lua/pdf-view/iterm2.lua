--- Encoding of iTerm2 inline images (OSC 1337 `File=`), which iTerm2, VS Code's terminal, WezTerm and Konsole draw.
---
--- An inline image is printed into the cells at the cursor, like text: it has no id, so it cannot be moved or
--- deleted later. It goes when the cells are written over or erased, and it is printed again to move it (see
--- `positioned`). Every print carries the whole PNG, as base64.
local M = {}

local ESC = "\27"

--- Command that prints the PNG `data` at the cursor, stretched to `cols` x `rows` cells. The cursor stays where it
--- is in the terminals that know `doNotMoveCursor` (WezTerm, iTerm2 3.5); the others move it past the image.
---@param data string the PNG's bytes
---@param cols integer
---@param rows integer
---@return string
function M.image(data, cols, rows)
  local args = ("inline=1;size=%d;width=%d;height=%d;preserveAspectRatio=0;doNotMoveCursor=1"):format(#data, cols, rows)
  -- "width=Nc" would be N cells too, but a bare number is cells in every terminal that reads the sequence
  return ESC .. "]1337;File=" .. args .. ":" .. vim.base64.encode(data) .. "\a"
end

--- Command that prints the PNG at `path`, as `image()` does. Raises when the file cannot be read.
---@param path string
---@param cols integer
---@param rows integer
---@return string
function M.image_file(path, cols, rows)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return M.image(data, cols, rows)
end

return M
