local M = {}

---@class PdfView.Keymaps
---@field next string[] next page (accepts a count: `3<PageDown>` jumps three pages)
---@field prev string[] previous page (accepts a count)
---@field down string[] scroll down when zoomed in, else (or at the bottom edge) next page
---@field up string[] scroll up when zoomed in, else (or at the top edge) previous page
---@field half_down string[] scroll down half a window when zoomed in, else (or at the bottom edge) next page
---@field half_up string[] scroll up half a window when zoomed in, else (or at the top edge) previous page
---@field right string[] scroll right when zoomed in, else (or at the right edge) next page
---@field left string[] scroll left when zoomed in, else (or at the left edge) previous page
---@field scroll_down string[] mouse wheel: `down` for the viewer under the mouse
---@field scroll_up string[] mouse wheel: `up` for the viewer under the mouse
---@field scroll_right string[] mouse wheel: `right` for the viewer under the mouse
---@field scroll_left string[] mouse wheel: `left` for the viewer under the mouse
---@field first string[] first page, or page {count}
---@field last string[] last page, or page {count}
---@field zoom_in string[] zoom in (accepts a count: `3+` zooms in three steps)
---@field zoom_out string[] zoom out, down to the fitted size
---@field zoom_reset string[] fit the whole page to the window
---@field fit_width string[] fit the page's width to the window
---@field fit_height string[] fit the page's height to the window
---@field fit_content string[] fit the part of the page with content on it to the window, cropping the margins
---@field search string[] prompt for text and search forward
---@field search_back string[] prompt for text and search backward
---@field search_next string[] next match, in the direction of the search
---@field search_prev string[] previous match
---@field search_clear string[] remove the highlights
---@field search_list string[] pick one of the matches of the search, listed with their pages and lines of text
---@field outline string[] pick a bookmark to jump to
---@field follow_link string[] pick a link on the page: go to its page, open another PDF in the viewer, or open its
--- address with `vim.ui.open()`
---@field yank_text string[] yank the text of the page into the register given (`"+y`), linewise
---@field show_text string[] show the text of the page in a scratch buffer in a split
---@field jump_back string[] back through the jump list (`gg`, `G`, bookmarks, searches and marks are jumps)
---@field jump_forward string[] forward through the jump list
---@field mark string[] followed by a to z: mark the page, fit, zoom and view
---@field goto_mark string[] followed by a to z: go to that mark; doubled (`''`): to where the latest jump started
---@field inverse_search string[] go to the line of the TeX source that the point under the mouse was typeset from
--- (SyncTeX)
---@field spread string[] show facing pages side by side, or one page at a time (`spread`, or "on" when that is "off")
---@field recolor string[] switch the recolouring of the pages on and off (`recolor`, or "invert" when that is "off")
---@field reload string[] re-render the current page
---@field close string[] close the viewer buffer
---@field help string[] show the key summary

---@alias PdfView.Recolor "off"|"invert"|"colorscheme"

---@alias PdfView.Spread "off"|"on"|"cover"

---@class PdfView.Config
---@field auto_open boolean open files with one of `extensions` (`:edit`, `nvim file.pdf`, ...) in the viewer
---@field extensions string[] file extensions that `auto_open` and `:PdfView` take, matched ignoring case
---@field live_reload boolean re-render when the PDF changes on disk
---@field reload_delay integer ms to wait after the last file event before reloading
---@field winbar boolean show "<file> <page> / <pages>" in the window's winbar
---@field hide_cursor boolean hide the cursor while a viewer is focused (it would sit on top of the page)
---@field remember_position boolean reopen a PDF at the page, fit and zoom it was left at, also after a restart
---@field mutool string mutool executable
---@field synctex string `synctex` executable, for going between a TeX source and its PDF (SyncTeX)
---@field transmission "auto"|"file"|"direct" how images reach the terminal ("auto" is "direct" over SSH)
---@field tmux_passthrough boolean let the plugin run `tmux set -p allow-passthrough on` for its pane
---@field placement "auto"|"placeholders"|"positioned" how the page is put on screen: as Unicode placeholder text,
--- or at the screen position of its window (for zellij, which has no placeholders). "auto" is "positioned" in zellij
---@field protocol "auto"|"kitty"|"iterm2"|"sixel" the image protocol: Kitty graphics, iTerm2 inline images (OSC 1337),
--- or sixel. "auto" is "iterm2" in iTerm2 and VS Code, "sixel" in foot, Windows Terminal, xterm, Contour, mlterm and
--- a terminal that says it draws sixel, else "kitty"
---@field force boolean skip terminal detection and assume the image protocol works
---@field max_pixels integer cap for either side of a rendered page image (zoomed views are window-sized)
---@field zoom_step number factor of one zoom step, greater than 1
---@field max_zoom number largest zoom, relative to the fit-to-window size
---@field pan_step number how far one scroll key moves, as a fraction of the window (0 to 1]
---@field search_limit integer stop collecting matches after this many
---@field link_schemes string[] the schemes of the addresses that `f` opens with `vim.ui.open()` without asking, matched
--- ignoring case. Any other address (a `file:` address, a PDF's Launch action) can start a program, so `f` asks first
---@field text_scale number size of the text of reflowable documents (EPUB, FB2, MOBI), which are laid out to fit the
--- window, relative to the terminal's text
---@field highlight { match: string, current: string } `#rrggbb` colours multiplied onto search matches
---@field recolor PdfView.Recolor how pages are recoloured: not at all, with their brightness inverted but their hues
--- kept (dark pages with light text), or in the colours of the `Normal` highlight (text and background)
---@field continuous boolean scrolling a page taller than the window (zoomed, or fitted to its width) goes on into
--- the next page, with the end of one page and the start of the next on screen together, instead of turning the page
---@field spread PdfView.Spread show facing pages side by side: pages 1 and 2, 3 and 4 ("on"), or page 1 alone and then
--- 2 and 3, 4 and 5, as a book opens ("cover"). E-books are always shown a page at a time
---@field cell_size? number[] `{ width, height }` of a terminal cell in pixels, when it cannot be detected
---@field keymaps PdfView.Keymaps|false buffer-local normal mode mappings, `false` for none

---@type PdfView.Config
local defaults = {
  auto_open = true,
  extensions = { "pdf", "cbz", "xps", "epub", "fb2", "mobi" },
  live_reload = true,
  reload_delay = 200,
  winbar = true,
  hide_cursor = true,
  remember_position = true,
  mutool = "mutool",
  synctex = "synctex",
  transmission = "auto",
  tmux_passthrough = true,
  placement = "auto",
  protocol = "auto",
  force = false,
  max_pixels = 4096,
  zoom_step = 1.25,
  max_zoom = 8,
  pan_step = 0.2,
  search_limit = 5000,
  link_schemes = { "http", "https", "mailto" },
  text_scale = 1,
  highlight = { match = "#ffe14d", current = "#ff8c1a" },
  recolor = "off",
  spread = "off",
  continuous = false,
  cell_size = nil,
  keymaps = {
    -- not <Space>: it is often the leader key
    next = { "<PageDown>", "<C-f>" },
    prev = { "<PageUp>", "<BS>", "<C-b>" },
    down = { "j", "<Down>" },
    up = { "k", "<Up>" },
    half_down = { "<C-d>" },
    half_up = { "<C-u>" },
    right = { "l", "<Right>" },
    left = { "h", "<Left>" },
    scroll_down = { "<ScrollWheelDown>" },
    scroll_up = { "<ScrollWheelUp>" },
    scroll_right = { "<ScrollWheelRight>" },
    scroll_left = { "<ScrollWheelLeft>" },
    first = { "gg", "<Home>" },
    last = { "G", "<End>" },
    zoom_in = { "+", "=" },
    zoom_out = { "-" },
    zoom_reset = { "0" },
    fit_width = { "w" },
    fit_height = { "W" },
    fit_content = { "c" },
    search = { "/" },
    search_back = { "?" },
    search_next = { "n" },
    search_prev = { "N" },
    search_clear = { "<Esc>" },
    search_list = { "g/" },
    outline = { "gO" },
    follow_link = { "f" },
    yank_text = { "y" },
    show_text = { "t" },
    jump_back = { "<C-o>" },
    jump_forward = { "<C-i>", "<Tab>" },
    mark = { "m" },
    goto_mark = { "'", "`" },
    inverse_search = { "<2-LeftMouse>" },
    spread = { "d" },
    recolor = { "i" },
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
  -- a key given to two actions would do whichever was mapped last
  local owner = {}
  for action, keys in pairs(value) do
    for _, lhs in ipairs(keys) do
      local other = owner[vim.keycode(lhs)]
      if other and other ~= action then
        local first, second = other < action and other or action, other < action and action or other
        error(("pdf-view: `%s` is mapped to both `keymaps.%s` and `keymaps.%s`"):format(lhs, first, second), 3)
      end
      owner[vim.keycode(lhs)] = action
    end
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
  local booleans = {
    "auto_open",
    "live_reload",
    "winbar",
    "hide_cursor",
    "remember_position",
    "tmux_passthrough",
    "force",
    "continuous",
  }
  for _, key in ipairs(booleans) do
    if opts[key] ~= nil and type(opts[key]) ~= "boolean" then
      fail(key, "a boolean", opts[key])
    end
  end
  for _, key in ipairs({ "mutool", "synctex" }) do
    if opts[key] ~= nil and (type(opts[key]) ~= "string" or opts[key] == "") then
      fail(key, "a non-empty string", opts[key])
    end
  end
  if opts.extensions ~= nil then
    check_string_list("extensions", opts.extensions)
    for _, extension in ipairs(opts.extensions) do
      if not extension:match("^%w+$") then
        fail("extensions", 'extensions without the dot, like { "pdf", "cbz" }', extension)
      end
    end
  end
  if opts.link_schemes ~= nil then
    check_string_list("link_schemes", opts.link_schemes)
    for _, scheme in ipairs(opts.link_schemes) do
      if not scheme:match("^%a[%w+.-]*$") then
        fail("link_schemes", 'schemes without the colon, like { "https", "mailto" }', scheme)
      end
    end
  end
  if opts.transmission ~= nil and not vim.tbl_contains({ "auto", "file", "direct" }, opts.transmission) then
    fail("transmission", '"auto", "file" or "direct"', opts.transmission)
  end
  if opts.placement ~= nil and not vim.tbl_contains({ "auto", "placeholders", "positioned" }, opts.placement) then
    fail("placement", '"auto", "placeholders" or "positioned"', opts.placement)
  end
  if opts.protocol ~= nil and not vim.tbl_contains({ "auto", "kitty", "iterm2", "sixel" }, opts.protocol) then
    fail("protocol", '"auto", "kitty", "iterm2" or "sixel"', opts.protocol)
  end
  if opts.recolor ~= nil and not vim.tbl_contains({ "off", "invert", "colorscheme" }, opts.recolor) then
    fail("recolor", '"off", "invert" or "colorscheme"', opts.recolor)
  end
  if opts.spread ~= nil and not vim.tbl_contains({ "off", "on", "cover" }, opts.spread) then
    fail("spread", '"off", "on" or "cover"', opts.spread)
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
  if opts.text_scale ~= nil and (type(opts.text_scale) ~= "number" or opts.text_scale <= 0) then
    fail("text_scale", "a positive number", opts.text_scale)
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

--- The names of the actions, sorted: the keys of `keymaps`, which has an entry for every action. Read here rather than
--- from the actions themselves, which would load most of the plugin at startup.
---@return string[]
function M.actions()
  local names = vim.tbl_keys(defaults.keymaps)
  table.sort(names)
  return names
end

--- Replace the configuration with the defaults merged with `opts`. Invalid input raises immediately.
---@param opts? table
---@return PdfView.Config
function M.setup(opts)
  opts = opts or {}
  validate(opts)
  local merged = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    if key == "keymaps" and type(value) == "table" then
      -- the user's keys win: a default action keeps only the keys no user action takes
      local taken = {}
      for _, keys in pairs(value) do
        for _, lhs in ipairs(keys) do
          taken[vim.keycode(lhs)] = true
        end
      end
      for action, keys in pairs(merged.keymaps) do
        if value[action] == nil then
          merged.keymaps[action] = vim.tbl_filter(function(lhs)
            return not taken[vim.keycode(lhs)]
          end, keys)
        end
      end
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
