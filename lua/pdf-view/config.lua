local M = {}

---@class PdfView.Keymaps
---@field next string[] next page (accepts a count: `3<PageDown>` jumps three pages)
---@field prev string[] previous page (accepts a count)
---@field down string[] scroll down when zoomed in, else (or at the bottom edge) next page
---@field up string[] scroll up when zoomed in, else (or at the top edge) previous page
---@field right string[] scroll right when zoomed in, else (or at the right edge) next page
---@field left string[] scroll left when zoomed in, else (or at the left edge) previous page
---@field first string[] first page, or page {count}
---@field last string[] last page, or page {count}
---@field zoom_in string[] zoom in (accepts a count: `3+` zooms in three steps)
---@field zoom_out string[] zoom out, down to the fitted size
---@field zoom_reset string[] fit the whole page to the window
---@field fit_width string[] fit the page's width to the window
---@field fit_height string[] fit the page's height to the window
---@field search string[] prompt for text and search forward
---@field search_back string[] prompt for text and search backward
---@field search_next string[] next match, in the direction of the search
---@field search_prev string[] previous match
---@field search_clear string[] remove the highlights
---@field outline string[] pick a bookmark to jump to
---@field reload string[] re-render the current page
---@field close string[] close the viewer buffer
---@field help string[] show the key summary

---@class PdfView.Config
---@field auto_open boolean open `*.pdf` buffers (`:edit`, `nvim file.pdf`, ...) in the viewer
---@field live_reload boolean re-render when the PDF changes on disk
---@field reload_delay integer ms to wait after the last file event before reloading
---@field winbar boolean show "<file> <page> / <pages>" in the window's winbar
---@field mutool string mutool executable
---@field transmission "auto"|"file"|"direct" how images reach the terminal ("auto" is "direct" over SSH)
---@field tmux_passthrough boolean let the plugin run `tmux set -p allow-passthrough on` for its pane
---@field force boolean skip terminal detection and assume Kitty graphics + Unicode placeholders work
---@field max_pixels integer cap for either side of a rendered page image (zoomed views are window-sized)
---@field zoom_step number factor of one zoom step, greater than 1
---@field max_zoom number largest zoom, relative to the fit-to-window size
---@field pan_step number how far one scroll key moves, as a fraction of the window (0 to 1]
---@field search_limit integer stop collecting matches after this many
---@field highlight { match: string, current: string } `#rrggbb` colours multiplied onto search matches
---@field cell_size? number[] `{ width, height }` of a terminal cell in pixels, when it cannot be detected
---@field keymaps PdfView.Keymaps|false buffer-local normal mode mappings, `false` for none

---@type PdfView.Config
local defaults = {
  auto_open = true,
  live_reload = true,
  reload_delay = 200,
  winbar = true,
  mutool = "mutool",
  transmission = "auto",
  tmux_passthrough = true,
  force = false,
  max_pixels = 4096,
  zoom_step = 1.25,
  max_zoom = 8,
  pan_step = 0.2,
  search_limit = 5000,
  highlight = { match = "#ffe14d", current = "#ff8c1a" },
  cell_size = nil,
  keymaps = {
    -- not <Space>: it is often the leader key
    next = { "<PageDown>", "<C-f>" },
    prev = { "<PageUp>", "<BS>", "<C-b>" },
    down = { "j", "<Down>" },
    up = { "k", "<Up>" },
    right = { "l", "<Right>" },
    left = { "h", "<Left>" },
    first = { "gg", "<Home>" },
    last = { "G", "<End>" },
    zoom_in = { "+", "=" },
    zoom_out = { "-" },
    zoom_reset = { "0" },
    fit_width = { "w" },
    fit_height = { "W" },
    search = { "/" },
    search_back = { "?" },
    search_next = { "n" },
    search_prev = { "N" },
    search_clear = { "<Esc>" },
    outline = { "gO" },
    reload = { "r" },
    close = { "q" },
    help = { "g?" },
  },
}

local function describe(value)
  if type(value) == "table" then
    return "table"
  end
  return ("%s (%s)"):format(vim.inspect(value), type(value))
end

local function fail(key, expected, value)
  error(("pdf-view: invalid option `%s`: expected %s, got %s"):format(key, expected, describe(value)), 3)
end

local function check_string_list(key, value)
  if type(value) ~= "table" then
    fail(key, "a list of strings", value)
  end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then
      fail(key, "a list of strings", value)
    end
  end
end

local function check_keymaps(value)
  if value == false then
    return
  end
  if type(value) ~= "table" then
    fail("keymaps", "a table or false", value)
  end
  for action, keys in pairs(value) do
    if defaults.keymaps[action] == nil then
      error(("pdf-view: unknown keymap action `%s`"):format(action), 3)
    end
    check_string_list("keymaps." .. action, keys)
  end
end

local function check_positive_integer(key, value)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    fail(key, "a positive integer", value)
  end
end

---@param opts table
local function validate(opts)
  for key in pairs(opts) do
    if key ~= "cell_size" and defaults[key] == nil then
      error(("pdf-view: unknown option `%s`"):format(key), 3)
    end
  end
  for _, key in ipairs({ "auto_open", "live_reload", "winbar", "tmux_passthrough", "force" }) do
    if opts[key] ~= nil and type(opts[key]) ~= "boolean" then
      fail(key, "a boolean", opts[key])
    end
  end
  if opts.mutool ~= nil and (type(opts.mutool) ~= "string" or opts.mutool == "") then
    fail("mutool", "a non-empty string", opts.mutool)
  end
  if opts.transmission ~= nil and not vim.tbl_contains({ "auto", "file", "direct" }, opts.transmission) then
    fail("transmission", '"auto", "file" or "direct"', opts.transmission)
  end
  if opts.reload_delay ~= nil and (type(opts.reload_delay) ~= "number" or opts.reload_delay < 0) then
    fail("reload_delay", "a non-negative number", opts.reload_delay)
  end
  if opts.max_pixels ~= nil then
    check_positive_integer("max_pixels", opts.max_pixels)
  end
  if opts.zoom_step ~= nil and (type(opts.zoom_step) ~= "number" or opts.zoom_step <= 1) then
    fail("zoom_step", "a number greater than 1", opts.zoom_step)
  end
  if opts.max_zoom ~= nil and (type(opts.max_zoom) ~= "number" or opts.max_zoom < 1) then
    fail("max_zoom", "a number of at least 1", opts.max_zoom)
  end
  if opts.pan_step ~= nil and (type(opts.pan_step) ~= "number" or opts.pan_step <= 0 or opts.pan_step > 1) then
    fail("pan_step", "a number in (0, 1]", opts.pan_step)
  end
  if opts.search_limit ~= nil then
    check_positive_integer("search_limit", opts.search_limit)
  end
  if opts.highlight ~= nil then
    if type(opts.highlight) ~= "table" then
      fail("highlight", "a table { match = '#rrggbb', current = '#rrggbb' }", opts.highlight)
    end
    for name, color in pairs(opts.highlight) do
      if name ~= "match" and name ~= "current" then
        error(("pdf-view: unknown highlight colour `%s` (use `match` and `current`)"):format(name), 3)
      end
      if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then
        fail("highlight." .. name, "a colour like '#ffe14d'", color)
      end
    end
  end
  if opts.cell_size ~= nil then
    local size = opts.cell_size
    if
      type(size) ~= "table"
      or type(size[1]) ~= "number"
      or type(size[2]) ~= "number"
      or size[1] <= 0
      or size[2] <= 0
    then
      fail("cell_size", "{ width, height } in pixels", size)
    end
  end
  if opts.keymaps ~= nil then
    check_keymaps(opts.keymaps)
  end
end

---@type PdfView.Config
M.options = vim.deepcopy(defaults)

--- Replace the configuration with the defaults merged with `opts`. Invalid input raises immediately.
---@param opts? table
---@return PdfView.Config
function M.setup(opts)
  opts = opts or {}
  validate(opts)
  local merged = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    if key == "keymaps" and type(value) == "table" then
      for action, keys in pairs(value) do
        merged.keymaps[action] = keys
      end
    elseif key == "highlight" then
      merged.highlight = vim.tbl_extend("force", merged.highlight, value)
    else
      merged[key] = value
    end
  end
  M.options = merged
  return merged
end

return M
