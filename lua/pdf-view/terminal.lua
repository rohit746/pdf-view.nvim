local config = require("pdf-view.config")

local M = {}

-- Only the aspect ratio matters when fitting; this is the fallback when the terminal does not report pixels.
local FALLBACK_CELL = { w = 16, h = 32 }

---@return boolean
function M.in_tmux()
  return (vim.env.TMUX or "") ~= ""
end

---@return boolean
function M.ui_attached()
  return #vim.api.nvim_list_uis() > 0
end

---@param cmd string[]
---@return string?
local function capture(cmd)
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true }):wait(1000)
  end)
  if not ok or result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout or "")
end

local ioctl_ready

--- Pixel size of the terminal as reported by the kernel, via TIOCGWINSZ on stdout/stderr/stdin.
---@return { cols: integer, rows: integer, width: integer, height: integer }?
local function window_pixels()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil
  end
  if ioctl_ready == nil then
    -- declared exactly like snacks.nvim does: LuaJIT rejects a redeclaration with a different signature
    ioctl_ready = pcall(
      ffi.cdef,
      [[
        typedef struct { unsigned short row, col, xpixel, ypixel; } pdfview_winsize;
        int ioctl(int, int, ...);
      ]]
    )
  end
  local request = vim.fn.has("linux") == 1 and 0x5413 or 0x40087468 -- TIOCGWINSZ
  local size = ffi.new("pdfview_winsize")
  for _, fd in ipairs({ 1, 2, 0 }) do
    local called, rc = pcall(function()
      return ffi.C.ioctl(fd, request, size)
    end)
    if called and rc == 0 and size.col > 0 and size.row > 0 and size.xpixel > 0 and size.ypixel > 0 then
      return { cols = size.col, rows = size.row, width = size.xpixel, height = size.ypixel }
    end
  end
  return nil
end

--- Size of one terminal cell in pixels.
---@return { w: number, h: number, source: string }
function M.cell_size()
  local override = config.options.cell_size
  if override then
    return { w = override[1], h = override[2], source = "config" }
  end
  local pixels = window_pixels()
  if pixels then
    return { w = pixels.width / pixels.cols, h = pixels.height / pixels.rows, source = "ioctl" }
  end
  return { w = FALLBACK_CELL.w, h = FALLBACK_CELL.h, source = "fallback" }
end

local detected

--- Identify a terminal that implements the Kitty graphics protocol *with* Unicode placeholders.
---@return { name?: string, term?: string }
function M.detect()
  if detected then
    return detected
  end
  local env = vim.env
  local term = env.TERM or ""
  local program = (env.TERM_PROGRAM or ""):lower()

  local function classify(value)
    value = (value or ""):lower()
    if value:find("kitty", 1, true) then
      return "kitty"
    elseif value:find("ghostty", 1, true) then
      return "ghostty"
    end
  end

  local name
  if M.in_tmux() then
    -- inside tmux $TERM says nothing about the outer terminal, but the attached client knows
    name = classify(capture({ "tmux", "display-message", "-p", "#{client_termname}" }))
  end
  name = name
    or classify(term)
    or classify(program)
    or ((env.KITTY_WINDOW_ID or "") ~= "" and "kitty")
    or ((env.GHOSTTY_RESOURCES_DIR or "") ~= "" and "ghostty")
    or nil

  detected = { name = name or nil, term = program ~= "" and program or term }
  return detected
end

--- Whether pages can be displayed here. The second return value explains a failure.
---@return boolean, string?
function M.check()
  if config.options.force then
    return true
  end
  if M.detect().name then
    return true
  end
  local term = M.detect().term
  return false,
    (
      "pdf-view: %s does not look like a terminal with Kitty graphics and Unicode placeholder support "
      .. "(kitty, Ghostty). Set `force = true` in setup() to try anyway."
    ):format(term ~= "" and ("`" .. term .. "`") or "this terminal")
end

local prepared

--- One-time terminal preparation: tmux only forwards graphics escape codes when passthrough is on.
function M.prepare()
  if prepared then
    return
  end
  prepared = true
  if M.in_tmux() and config.options.tmux_passthrough then
    capture({ "tmux", "set-option", "-p", "allow-passthrough", "on" })
  end
end

--- How images are handed to the terminal. A local terminal can read the PNG itself; over SSH the bytes are sent.
---@return "file"|"direct"
function M.transmission()
  local mode = config.options.transmission
  if mode ~= "auto" then
    return mode
  end
  if (vim.env.SSH_CONNECTION or "") ~= "" or (vim.env.SSH_TTY or "") ~= "" then
    return "direct"
  end
  return "file"
end

--- tmux's effective `allow-passthrough` for this pane ("on", "all", "off"), or nil outside tmux.
---@return string?
function M.tmux_passthrough()
  if not M.in_tmux() then
    return nil
  end
  return capture({ "tmux", "show-options", "-pv", "allow-passthrough" })
    or capture({ "tmux", "show-options", "-gv", "allow-passthrough" })
    or "off"
end

return M
