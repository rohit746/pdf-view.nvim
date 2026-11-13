--- Viewer state: one session per PDF buffer, and the helpers that read and write it (windows, the winbar, the
--- render cache, image ids). Nothing here renders a page.
local config = require("pdf-view.config")
local cursor = require("pdf-view.cursor")
local kitty = require("pdf-view.kitty")
local mupdf = require("pdf-view.mupdf")
local positioned = require("pdf-view.positioned")
local search = require("pdf-view.search")
local terminal = require("pdf-view.terminal")

local M = {}

--- Points of paper between two facing pages.
M.SPREAD_GAP = 8

local CACHE_LIMIT = 16
-- image ids per viewer: the terminal keeps this many of the latest pages, so turning back to one sends nothing
local IMAGE_IDS = 4

local uv = vim.uv
local ns = vim.api.nvim_create_namespace("pdf-view")
local augroup = vim.api.nvim_create_augroup("PdfViewSessions", { clear = true })

-- Window options that would draw over, or shift, the page image.
local WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldenable = false, -- 'foldmethod' "indent" would fold the page away: it is indented to centre it
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

-- Highlights that Neovim lays over buffer text. A colour of theirs would replace the image id in the foreground of
-- the cells it covers, so in a viewer's window they are mapped to a group without colours ('winhighlight' creates
-- the group, empty, by naming it).
local MUTED_HIGHLIGHTS = { "Search", "CurSearch", "IncSearch", "Visual", "VisualNOS" }
local NO_HIGHLIGHT = "PdfViewNone"

---@class PdfView.Session
---@field buf integer
---@field path string absolute path of the PDF
---@field page integer page on screen (or being shown)
---@field target? integer page requested by the latest navigation key, until it is on screen
---@field count? integer number of pages
---@field reflowable? boolean the document is laid out to the window (EPUB, FB2, MOBI)
---@field laid_out? { key: string, size: PdfView.Layout } the layout of the page on screen, for a reflowable document
---@field mode PdfView.FitMode what zoom 1 means: the whole page, the page as wide / as tall as the window, or the
--- part of the page with content on it
---@field zoom number multiplies the fitted size: 1 is as fitted, 2 is twice that
---@field search? PdfView.Search the active search, whose matches are highlighted
---@field search_job? PdfView.Job in-flight search
---@field searching? string the needle of the in-flight search, for the winbar
---@field last_needle? string the text last searched for, which an empty `/` prompt searches for again
---@field search_again? fun() starts the in-flight search over, for when the file changes under it
---@field search_stale? boolean the file changed while the viewer was in no window: search again when one shows it
---@field jumps PdfView.Position[] where jumps (`gg`, `G`, bookmarks, searches, marks) started, oldest first
---@field jump_index integer the entry of `jumps` that `<C-o>` and `<C-i>` are at: `#jumps + 1` after a new jump
---@field marks table<string, PdfView.Position> `m{a-z}` marks, and `'` for where the latest jump started
---@field outline? { stamp: string, entries: PdfView.OutlineEntry[] } bookmarks of the file as of `stamp`
---@field cx number centre of the viewport as a fraction of the page width (only matters while zoomed)
---@field cy number centre of the viewport as a fraction of the page height
---@field geom? { w: number, h: number, box?: number[] } size in points of the page on screen, and the part of it with
--- content (`PdfView.PageInfo.content`) once that was read
---@field fit? PdfView.Fit|PdfView.Viewport how the page on screen maps onto the window's cells
---@field synced? { id: integer, page: integer, rects: number[][] } where the latest forward search (SyncTeX) landed,
--- highlighted until `<Esc>` or the file changes
---@field gen integer incremented by every render request
---@field job? PdfView.Job in-flight mutool process
---@field ids integer[] Kitty image ids: a new page goes to one that is not on screen, so a page swap never shows a
--- blank frame
---@field slot integer which of `ids` is on screen (0 = none yet)
---@field images table<integer, string> the PNG the terminal holds under each id, to show it again without sending it
---@field image_used table<integer, integer> when each id was last put on screen, to reuse the oldest one
---@field rendering table<string, PdfView.Rendering> renders in progress, by cache key
---@field prefetch? { stopped: boolean, job?: PdfView.Job } the pages next to the one on screen being rendered ahead of
--- time, and the render it is waiting for
---@field win? integer window the layout was computed for
---@field cache table<string, string> render cache: key -> PNG path
---@field cache_order string[]
---@field info? { stamp: string, count: integer, pages: table<integer, PdfView.PageInfo> } page geometry read from the file as of `stamp`
---@field requested_key? string layout key of the latest render request
---@field requested_stamp? string file stamp of the latest render request
---@field grid_key? string
---@field grid? PdfView.Placeholders
---@field picture? PdfView.Picture the image on screen, when it is placed at the window's position (zellij)
---@field placed? { id: integer, count: integer, key: string, base: integer, rects?: PdfView.Rect[] } the placements
--- of `picture` the terminal has: ids `base + 1` to `base + count`. With iTerm2 images, `rects` are where it was
--- printed on screen
---@field lost? boolean the terminal no longer has `picture`: send it again before placing it
---@field dirty? boolean the screen may have moved or dropped the placements: place them again
---@field cut_key? string the last placements of `picture` that were cut around a float, since it was sent
---@field watcher? PdfView.Watcher
---@field mapped? string[] the keys mapped in the buffer by `actions.set_keymaps`
---@field waiting_for_ui? boolean the first render is waiting for a UI to attach
---@field waiting_for_terminal? { page?: integer, opts?: table } the page to show once the terminal has said what it draws
---@field page_text? string the terminal cannot show pages: the reason, shown above the text of the page instead
---@field unlocking? boolean the password prompt of a password-protected document is open
---@field locked? boolean the password prompt was cancelled: say so instead of asking again, until `actions.reload`
---@field recolor? PdfView.Recolor how the pages are recoloured, once toggled; until then `config.options.recolor`
---@field spread? PdfView.Spread whether facing pages are shown side by side, once toggled; until then
--- `config.options.spread`
---@field scrolled? boolean the view was scrolled there with `continuous` on, so it may reach past the page's
--- edges, into the pages next to it; a jump or a change of fit or zoom keeps it inside the page again
---@field last? integer the last page on screen: `page` + 1 when two facing pages are, else `page`
---@field parts? PdfView.SheetLayout[] where the pages on screen lie in `geom`, when there are two side by side
---@field worker_timer? uv.uv_timer_t stops the mutool worker once the viewer has been in no window for a while
---@field closed boolean

---@type table<integer, PdfView.Session>
local sessions = {}
M.sessions = sessions

local next_image_id

--- `IMAGE_IDS` ids per session, drawn from the middle of the 24-bit range to stay clear of other graphics users.
---@return integer[]
local function allocate_ids()
  next_image_id = next_image_id or (uv.hrtime() % 0xC00000 + 0x100000)
  if next_image_id > 0xFFFFF0 then
    next_image_id = 0x100000
  end
  local ids = {}
  for index = 1, IMAGE_IDS do
    ids[index] = next_image_id + index - 1
  end
  next_image_id = next_image_id + IMAGE_IDS
  return ids
end

--- The image id is carried by the foreground colour of the placeholder cells.
---@param id integer
local function define_highlight(id)
  vim.api.nvim_set_hl(0, "PdfViewImage" .. id, { fg = id, bg = "NONE", nocombine = true })
end

--- Search highlight colours as the `rrggbb` strings `worker.js` takes.
---@return { match: string, current: string }
local function match_colors()
  local highlight = config.options.highlight
  return { match = highlight.match:sub(2), current = highlight.current:sub(2) }
end

--- How the pages of `s` are recoloured: as toggled in the viewer, or else as configured.
---@param s PdfView.Session
---@return PdfView.Recolor
local function recolor_mode(s)
  return s.recolor or config.options.recolor
end

--- How `worker.js` recolours the pages of `s`: "" for not at all, "invert", or "tint,<fg>,<bg>" with the `Normal`
--- colours, black becoming the text colour and white the background. A colour the colorscheme leaves unset (a
--- transparent background) is white or black, whichever suits 'background'.
---@param s PdfView.Session
---@return string
local function recolor_spec(s)
  local mode = recolor_mode(s)
  if mode == "invert" then
    return "invert"
  elseif mode ~= "colorscheme" then
    return ""
  end
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local dark = vim.o.background == "dark"
  local fg = normal.fg or (dark and 0xffffff or 0x000000)
  local bg = normal.bg or (dark and 0x000000 or 0xffffff)
  return ("tint,%06x,%06x"):format(fg, bg)
end

--- Whether the pages of `s` are shown in spreads, and how: as configured, or as toggled in the viewer. E-books are
--- laid out to the window, one page at a time.
---@param s PdfView.Session
---@return PdfView.Spread
local function spread_mode(s)
  if s.reflowable then
    return "off"
  end
  return s.spread or config.options.spread
end

--- The first and the last page of the spread that holds `page`: pairs of pages from page 1 on ("on"), or from page 2
--- on after page 1 alone ("cover", as a book opens). Just `page` when spreads are off.
---@param s PdfView.Session
---@param page integer
---@param count? integer pages in the document, when known
---@return integer first, integer last
local function spread_range(s, page, count)
  local mode = spread_mode(s)
  if mode == "off" then
    return page, page
  end
  local first
  if mode == "cover" then
    first = page == 1 and 1 or page - page % 2
  else
    first = page - (page - 1) % 2
  end
  local last = (mode == "cover" and first == 1) and 1 or first + 1
  return first, count and math.min(last, count) or last
end

--- The first page of the spread `steps` spreads after (or, for a negative number, before) the one that holds `page`.
--- Not clamped to the document.
---@param s PdfView.Session
---@param page integer
---@param steps integer
---@return integer
local function spread_step(s, page, steps)
  if spread_mode(s) == "off" then
    return page + steps
  end
  local first = spread_range(s, page)
  for _ = 1, math.abs(steps) do
    if steps > 0 then
      local _, last = spread_range(s, first)
      first = last + 1
    else
      first = spread_range(s, math.max(1, first - 1))
    end
  end
  return first
end

--- Whether `page` is on screen in `s`: the page, or one of the pages of the spread.
---@param s PdfView.Session
---@param page integer
---@return boolean
local function on_screen(s, page)
  local first = s.target or s.page
  local last = s.target and select(2, spread_range(s, s.target, s.count)) or (s.last or s.page)
  return page >= first and page <= last
end

--- The point (`x`, `y`) of page `page`, as fractions of it, as fractions of the spread it is shown in: the same unless
--- two pages are side by side. Measured with the pages on screen, which have the size of the other pages of almost
--- every document.
---@param s PdfView.Session
---@param page integer
---@param x number
---@param y number
---@return number x, number y
local function sheet_point(s, page, x, y)
  local first, last = spread_range(s, page, s.count)
  if first == last or not s.geom then
    return x, y
  end
  local parts = s.parts
  if not (parts and #parts == last - first + 1) then
    -- one page on screen: the spread is two pages of its size
    local w, h = s.geom.w, s.geom.h
    parts = { { x = 0, y = 0, width = w, height = h }, { x = w + M.SPREAD_GAP, y = 0, width = w, height = h } }
  end
  local part = parts[page - first + 1]
  local width = parts[#parts].x + parts[#parts].width
  local height = math.max(parts[1].height, parts[#parts].height)
  return (part.x + x * part.width) / width, (part.y + y * part.height) / height
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

--- Mark `key` as just used, so that the render cache evicts it last.
---@param s PdfView.Session
---@param key string
local function touch(s, key)
  local order = s.cache_order
  for index = #order, 1, -1 do
    if order[index] == key then
      table.remove(order, index)
      break
    end
  end
  order[#order + 1] = key
end

---@param s PdfView.Session
---@param key string
---@param path string
local function remember(s, key, path)
  if s.cache[key] and s.cache[key] ~= path then
    os.remove(s.cache[key])
  end
  touch(s, key)
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
  s.info = nil
  s.images = {} -- sent again, in case the terminal dropped one
end

--- The geometry of `page`, if it was already read from the file as of `stamp`.
---@param s PdfView.Session
---@param stamp string
---@param page integer may lie outside the document, as for `mupdf.info()`
---@return PdfView.PageInfo?
local function known_info(s, stamp, page)
  local known = s.info
  if known and known.stamp == stamp then
    return known.pages[math.max(1, math.min(page, known.count))]
  end
end

---@param s PdfView.Session
---@param stamp string
---@param info PdfView.PageInfo
local function remember_info(s, stamp, info)
  if not (s.info and s.info.stamp == stamp) then
    s.info = { stamp = stamp, count = info.count, pages = {} }
  end
  s.info.pages[info.page] = info
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

--- Whether scrolling `s` goes on from one page into the next (`continuous`): it does for a zoomed or fitted page.
---@param s PdfView.Session
---@return boolean
local function continuous(s)
  return config.options.continuous and uses_viewport(s)
end

--- Set the window-local value of `name` in `win`, unless it has that value already. The local value is compared:
--- for global-local options ('scrolloff', 'winbar') the window would otherwise follow later changes to the global one.
---@param win integer
---@param name string
---@param value any
local function set_window_option(win, name, value)
  if vim.api.nvim_get_option_value(name, { scope = "local", win = win }) ~= value then
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
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
  local needle = s.searching or (s.search and s.search.needle)
  if needle then
    if vim.fn.strchars(needle) > 24 then
      needle = vim.fn.strcharpart(needle, 0, 23) .. "…"
    end
    found = ("/%s %s   "):format(needle, s.searching and "searching…" or search.progress(s.search))
  end

  local text = (" %s%%=%s%s / %s%s "):format(
    escape(vim.fn.fnamemodify(s.path, ":t")),
    escape(found),
    M.pages_label(s),
    s.count or "?",
    #label > 0 and escape("  " .. table.concat(label, " ")) or ""
  )
  set_window_option(win, "winbar", text)
end

--- 'winhighlight' for a viewer's window: `current` (what the window has, e.g. from another plugin) with the
--- highlights that would paint over the page muted.
---@param current string
---@return string
local function muted_winhighlight(current)
  local parts = {}
  for _, part in ipairs(vim.split(current, ",", { plain = true, trimempty = true })) do
    if not vim.tbl_contains(MUTED_HIGHLIGHTS, (part:match("^[^:]*"))) then
      parts[#parts + 1] = part
    end
  end
  for _, group in ipairs(MUTED_HIGHLIGHTS) do
    parts[#parts + 1] = group .. ":" .. NO_HIGHLIGHT
  end
  return table.concat(parts, ",")
end

--- Window-local (`:setlocal`) values: Neovim restores the previous ones when the window shows another buffer.
--- Each is set only when it differs: every render calls this, and each set fires OptionSet for other plugins.
---@param s PdfView.Session
---@param win integer
local function apply_window_options(s, win)
  for name, value in pairs(WINDOW_OPTIONS) do
    set_window_option(win, name, value)
  end
  local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = win })
  set_window_option(win, "winhighlight", muted_winhighlight(winhighlight))
  update_winbar(s, win)
end

--- Scroll `win` back to the top-left corner of its buffer. A viewer's buffer is exactly as tall as its window, so
--- anything that scrolls it (<C-e>, the mouse wheel) only pushes the page out of the window.
---@param win integer
local function reset_view(win)
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    if view.topline ~= 1 or view.leftcol ~= 0 then
      vim.fn.winrestview({ topline = 1, leftcol = 0, lnum = 1, col = 0 })
    end
  end)
end

--- Break `text` into lines of at most `cols` cells, at spaces where it can.
---@param text string
---@param cols integer
---@return string[]
local function wrap_text(text, cols)
  local width = vim.fn.strdisplaywidth
  local lines = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line ~= "" and width(line .. " " .. word) > cols then
        lines[#lines + 1] = line
        line = ""
      end
      line = line == "" and word or (line .. " " .. word)
      while width(line) > cols and vim.fn.strchars(line) > 1 do -- one word wider than the window, such as a path
        -- cut by cells, not characters: a double-width character takes two (at least one character per piece)
        local n = 1
        while width(vim.fn.strcharpart(line, 0, n + 1)) <= cols do
          n = n + 1
        end
        lines[#lines + 1] = vim.fn.strcharpart(line, 0, n)
        line = vim.fn.strcharpart(line, n)
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

---@param s PdfView.Session
---@param win integer
---@param text string
local function display_message(s, win, text)
  positioned.clear(s)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  s.grid_key, s.grid = nil, nil
  -- the window does not wrap its lines (that would tear a page apart), so the message is wrapped here
  local cols = vim.api.nvim_win_is_valid(win) and text_area(win) or 80
  write_buffer(s, wrap_text(text, cols))
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
  if s.worker_timer then
    s.worker_timer:stop()
    s.worker_timer:close()
    s.worker_timer = nil
  end
  mupdf.release(s.path)
  if s.watcher then
    s.watcher.stop()
  end
  if s.slot ~= 0 and not terminal.printed() then
    for _, id in ipairs(s.ids) do
      kitty.send(kitty.delete(id))
    end
  end
  positioned.forget(s)
  purge_cache(s)
  cursor.show(s.buf)
  sessions[s.buf] = nil
  -- a later :edit! attaches a fresh session to the same buffer; don't leave this one's autocmds behind
  pcall(vim.api.nvim_clear_autocmds, { group = augroup, buffer = s.buf })
end

--- "3" for the page on screen, "3-4" for two facing pages.
---@param s PdfView.Session
---@return string
function M.pages_label(s)
  if s.last and s.last ~= s.page then
    return ("%d-%d"):format(s.page, s.last)
  end
  return tostring(s.page)
end

M.ns = ns
M.continuous = continuous
M.spread_mode = spread_mode
M.spread_range = spread_range
M.spread_step = spread_step
M.on_screen = on_screen
M.sheet_point = sheet_point
M.augroup = augroup
M.define_highlight = define_highlight
M.match_colors = match_colors
M.recolor_mode = recolor_mode
M.recolor_spec = recolor_spec
M.stamp_of = stamp_of
M.layout_key = layout_key
M.write_buffer = write_buffer
M.remember = remember
M.touch = touch
M.purge_cache = purge_cache
M.known_info = known_info
M.remember_info = remember_info
M.window_for = window_for
M.text_area = text_area
M.uses_viewport = uses_viewport
M.update_winbar = update_winbar
M.apply_window_options = apply_window_options
M.reset_view = reset_view
M.wrap_text = wrap_text
M.display_message = display_message
M.allocate_ids = allocate_ids
M.destroy = destroy

return M
