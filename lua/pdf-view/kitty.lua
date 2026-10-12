--- Encoding and sending of Kitty graphics protocol commands.
---
--- Pages are uploaded as PNG, shown through a *virtual* placement (`U=1`) and drawn with Unicode
--- placeholders, so nothing here knows about cursor positions or scrolling.
local M = {}

local ESC = "\27"
local CHUNK_SIZE = 4096

--- One APC graphics command. Keys are emitted in sorted order so the output is deterministic.
---@param keys table<string, string|number>
---@param payload? string
---@return string
function M.sequence(keys, payload)
  local names = vim.tbl_keys(keys)
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = name .. "=" .. tostring(keys[name])
  end
  return ESC .. "_G" .. table.concat(parts, ",") .. (payload and (";" .. payload) or "") .. ESC .. "\\"
end

--- Wrap a sequence in tmux's DCS passthrough so it reaches the outer terminal.
---@param sequence string
---@param in_tmux? boolean defaults to whether `$TMUX` is set
---@return string
function M.wrap(sequence, in_tmux)
  if in_tmux == nil then
    in_tmux = (vim.env.TMUX or "") ~= ""
  end
  if not in_tmux then
    return sequence
  end
  return ESC .. "Ptmux;" .. sequence:gsub(ESC, ESC .. ESC) .. ESC .. "\\"
end

--- Commands that upload the PNG at `path` as image `id`.
---@param id integer
---@param path string
---@param mode "file"|"direct" "file" sends the path (local terminal), "direct" sends the bytes (e.g. over SSH)
---@return string[]
function M.transmit(id, path, mode)
  if mode == "file" then
    return { M.sequence({ a = "t", f = 100, t = "f", i = id, q = 2 }, vim.base64.encode(path)) }
  end

  local file = assert(io.open(path, "rb"))
  local data = vim.base64.encode(file:read("*a"))
  file:close()

  local commands = {}
  local position = 1
  while position <= #data do
    local piece = data:sub(position, position + CHUNK_SIZE - 1)
    position = position + CHUNK_SIZE
    local more = position <= #data and 1 or 0
    if #commands == 0 then
      commands[1] = M.sequence({ a = "t", f = 100, t = "d", i = id, q = 2, m = more }, piece)
    else
      commands[#commands + 1] = M.sequence({ m = more, q = 2 }, piece)
    end
  end
  return commands
end

--- Command that makes image `id` available to placeholder cells covering `cols` x `rows` cells.
---@param id integer
---@param cols integer
---@param rows integer
---@return string
function M.place(id, cols, rows)
  return M.sequence({ a = "p", U = 1, i = id, C = 1, c = cols, r = rows, q = 2 })
end

--- Command that removes image `id` and frees its data.
---@param id integer
---@return string
function M.delete(id)
  return M.sequence({ a = "d", d = "I", i = id, q = 2 })
end

--- Write raw bytes to the terminal. Replaceable, mainly so tests can capture the output.
---@param data string
function M.write(data)
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    -- Neovim 0.11 has no nvim_ui_send(); its stderr is still the terminal the TUI draws on
    vim.api.nvim_chan_send(vim.v.stderr, data)
  end
end

--- Send commands to the terminal, one passthrough-wrapped write per command.
---@param commands string|string[]
function M.send(commands)
  if type(commands) == "string" then
    commands = { commands }
  end
  for _, command in ipairs(commands) do
    M.write(M.wrap(command))
  end
end

return M
