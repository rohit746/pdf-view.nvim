--- Viewer state: one session per PDF buffer, and the helpers that read and write it (windows, the winbar, the
--- render cache, image ids). Nothing here renders a page.
local config = require("pdf-view.config")
local cursor = require("pdf-view.cursor")
local kitty = require("pdf-view.kitty")
local search = require("pdf-view.search")

local M = {}

local CACHE_LIMIT = 16

local uv = vim.uv
local ns = vim.api.nvim_create_namespace("pdf-view")
local augroup = vim.api.nvim_create_augroup("PdfViewSessions", { clear = true })

-- Window options that would draw over, or shift, the page image.
local WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  list = false,
  wrap = false,
  cursorline = false,
  cursorcolumn = false,
  colorcolumn = "",
  spell = false,
  scrolloff = 0,
  sidescrolloff = 0,
}

---@class PdfView.Session
---@field buf integer
---@field path string absolute path of the PDF
---@field page integer page on screen (or being shown)
---@field target? integer page requested by the latest navigation key, until it is on screen
---@field count? integer number of pages
---@field mode PdfView.FitMode what zoom 1 means: the whole page, or the page as wide / as tall as the window
---@field zoom number multiplies the fitted size: 1 is as fitted, 2 is twice that
---@field search? PdfView.Search the active search, whose matches are highlighted
---@field search_job? PdfView.Job in-flight search
---@field outline? { stamp: string, entries: PdfView.OutlineEntry[] } bookmarks of the file as of `stamp`
---@field cx number centre of the viewport as a fraction of the page width (only matters while zoomed)
---@field cy number centre of the viewport as a fraction of the page height
---@field geom? { w: number, h: number } size in points of the page on screen
---@field gen integer incremented by every render request
---@field job? PdfView.Job in-flight mutool process
---@field ids integer[] two Kitty image ids, used alternately so a page swap never shows a blank frame
---@field slot integer which of `ids` is on screen (0 = none yet)
---@field win? integer window the layout was computed for
---@field cache table<string, string> render cache: key -> PNG path
---@field cache_order string[]
---@field requested_key? string layout key of the latest render request
---@field requested_stamp? string file stamp of the latest render request
---@field grid_key? string
---@field grid? PdfView.Placeholders
---@field watcher? PdfView.Watcher
---@field closed boolean

---@type table<integer, PdfView.Session>
local sessions = {}
M.sessions = sessions

local next_image_id

--- Two ids per session, drawn from the middle of the 24-bit range to stay clear of other graphics users.
---@return integer[]
local function allocate_ids()
  next_image_id = next_image_id or (uv.hrtime() % 0xC00000 + 0x100000)
  if next_image_id > 0xFFFFF0 then
    next_image_id = 0x100000
  end
  local first = next_image_id
  next_image_id = next_image_id + 2
  return { first, first + 1 }
end

--- The image id is carried by the foreground colour of the placeholder cells.
---@param id integer
local function define_highlight(id)
  vim.api.nvim_set_hl(0, "PdfViewImage" .. id, { fg = id, bg = "NONE", nocombine = true })
end

--- Search highlight colours as the `rrggbb` strings `render-clip.js` takes.
---@return { match: string, current: string }
local function match_colors()
  local highlight = config.options.highlight
  return { match = highlight.match:sub(2), current = highlight.current:sub(2) }
end

---@param stat uv.fs_stat.result
---@return string
local function stamp_of(stat)
  return ("%d.%09d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

---@param cols integer
---@param rows integer
---@param cell { w: number, h: number }
---@return string
local function layout_key(cols, rows, cell)
  return ("%dx%d@%.2fx%.2f"):format(cols, rows, cell.w, cell.h)
end

---@param s PdfView.Session
---@param lines string[]
local function write_buffer(s, lines)
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
  vim.bo[s.buf].modified = false
end

---@param s PdfView.Session
---@param key string
---@param path string
local function remember(s, key, path)
  if s.cache[key] and s.cache[key] ~= path then
    os.remove(s.cache[key])
  end
  if not s.cache[key] then
    s.cache_order[#s.cache_order + 1] = key
  end
  s.cache[key] = path
  while #s.cache_order > CACHE_LIMIT do
    local oldest = table.remove(s.cache_order, 1)
    os.remove(s.cache[oldest])
    s.cache[oldest] = nil
  end
end

---@param s PdfView.Session
local function purge_cache(s)
  for _, path in pairs(s.cache) do
    os.remove(path)
  end
  s.cache, s.cache_order = {}, {}
end

---@param s PdfView.Session
---@return integer?
local function window_for(s)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == s.buf then
    return current
  end
  if s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf then
    return s.win
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local windows = vim.fn.win_findbuf(s.buf)
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
  return windows[1]
end

--- Columns and rows available for text. `nvim_win_get_height()` counts the winbar line, `getwininfo()` does not.
---@param win integer
---@return integer cols, integer rows
local function text_area(win)
  local info = vim.fn.getwininfo(win)[1]
  return math.max(1, info.width - info.textoff), math.max(1, info.height)
end

--- Whether the page is drawn as a window-sized viewport onto an enlarged page, rather than as a whole fitted page.
---@param s PdfView.Session
---@return boolean
local function uses_viewport(s)
  return s.mode ~= "page" or s.zoom > 1
end

---@param s PdfView.Session
---@param win integer
local function update_winbar(s, win)
  if not config.options.winbar then
    return
  end
  local function escape(text)
    return (text:gsub("%%", "%%%%"))
  end

  local label = {}
  if s.mode ~= "page" then
    label[#label + 1] = s.mode
  end
  if s.zoom > 1 then
    label[#label + 1] = ("%d%%"):format(math.floor(s.zoom * 100 + 0.5))
  end

  local found = ""
  if s.search then
    local needle = s.search.needle
    if vim.fn.strchars(needle) > 24 then
      needle = vim.fn.strcharpart(needle, 0, 23) .. "…"
    end
    found = ("/%s %s   "):format(needle, search.progress(s.search))
  end

  local text = (" %s%%=%s%d / %s%s "):format(
    escape(vim.fn.fnamemodify(s.path, ":t")),
    escape(found),
    s.page,
    s.count or "?",
    #label > 0 and escape("  " .. table.concat(label, " ")) or ""
  )
  vim.api.nvim_set_option_value("winbar", text, { scope = "local", win = win })
end

--- Window-local (`:setlocal`) values: Neovim restores the previous ones when the window shows another buffer.
---@param s PdfView.Session
---@param win integer
local function apply_window_options(s, win)
  for name, value in pairs(WINDOW_OPTIONS) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  update_winbar(s, win)
end

---@param s PdfView.Session
---@param win integer
---@param text string
local function display_message(s, win, text)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  s.grid_key, s.grid = nil, nil
  write_buffer(s, vim.split(text, "\n", { plain = true }))
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

---@param s PdfView.Session
local function destroy(s)
  if s.closed then
    return
  end
  s.closed = true
  s.gen = s.gen + 1
  if s.job then
    s.job:kill(15)
  end
  if s.search_job then
    s.search_job:kill(15)
  end
  if s.watcher then
    s.watcher.stop()
  end
  if s.slot ~= 0 then
    for _, id in ipairs(s.ids) do
      kitty.send(kitty.delete(id))
    end
  end
  purge_cache(s)
  cursor.show(s.buf)
  sessions[s.buf] = nil
  -- a later :edit! attaches a fresh session to the same buffer; don't leave this one's autocmds behind
  pcall(vim.api.nvim_clear_autocmds, { group = augroup, buffer = s.buf })
end

M.ns = ns
M.augroup = augroup
M.define_highlight = define_highlight
M.match_colors = match_colors
M.stamp_of = stamp_of
M.layout_key = layout_key
M.write_buffer = write_buffer
M.remember = remember
M.purge_cache = purge_cache
M.window_for = window_for
M.text_area = text_area
M.uses_viewport = uses_viewport
M.update_winbar = update_winbar
M.apply_window_options = apply_window_options
M.display_message = display_message
M.allocate_ids = allocate_ids
M.destroy = destroy

return M
