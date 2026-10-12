--- What the keys do: turning pages, scrolling, zooming, fitting, searching and jumping to bookmarks. Each action
--- changes the session and asks `render` to show it.
local config = require("pdf-view.config")
local layout = require("pdf-view.layout")
local mupdf = require("pdf-view.mupdf")
local render = require("pdf-view.render")
local search = require("pdf-view.search")
local session = require("pdf-view.session")
local terminal = require("pdf-view.terminal")

local M = {}

local uv = vim.uv
local show = render.show
local stamp_of, purge_cache, window_for, text_area, uses_viewport =
  session.stamp_of, session.purge_cache, session.window_for, session.text_area, session.uses_viewport

--- Stop the search that is running, if any. It reports nothing.
---@param s PdfView.Session
local function cancel_search(s)
  if s.search_job then
    s.search_job:kill(15)
  end
  s.search_job, s.search_again = nil, nil
end

--- Search the document for `needle`, in place of a search that is still running. `done` is only called for a search
--- that is still the session's own when it finishes: one that was cancelled or replaced reports nothing.
---@param s PdfView.Session
---@param needle string
---@param done fun(err?: string, matches?: PdfView.Match[], truncated?: boolean)
local function start_search(s, needle, done)
  cancel_search(s)
  local job
  job = mupdf.search(s.path, needle, config.options.search_limit, function(...)
    if s.search_job ~= job then
      return
    end
    s.search_job, s.search_again = nil, nil
    done(...)
  end)
  s.search_job = job
  s.search_again = function()
    start_search(s, needle, done)
  end
end

--- Search the document again for the active search, after the file changed: pages, text and positions may differ.
---@param s PdfView.Session
local function rescan(s)
  if s.search_again then
    return s.search_again() -- a search is still running: it read the old file, so it starts over
  end
  local old = s.search
  if not old then
    return
  end
  start_search(s, old.needle, function(err, matches, truncated)
    if s.closed or s.search ~= old or err then
      return -- the next change of the file tries again
    end
    local fresh = search.new(old.needle, matches, truncated, old.dir)
    fresh.current = search.start(fresh, s.page, old.dir)
    s.search = fresh
    show(s)
  end)
end

--- Where on the new page a zoomed view starts, as a fraction of the page. Missing fields keep their value.
---@alias PdfView.Anchor { cx?: number, cy?: number }

local TOP = { cy = 0 }

---@param s PdfView.Session
---@param page integer
---@param anchor? PdfView.Anchor
local function go(s, page, anchor)
  if s.closed then
    return
  end
  page = math.max(1, math.min(page, s.count or page))
  if page == (s.target or s.page) and s.slot ~= 0 then
    return
  end
  s.target = page
  if anchor then
    s.cx, s.cy = anchor.cx or s.cx, anchor.cy or s.cy
  end
  show(s, page)
end

---@param s PdfView.Session
function M.reload(s)
  purge_cache(s)
  s.outline = nil
  s.requested_key, s.requested_stamp = nil, nil
  show(s)
  rescan(s)
end

--- Fit the whole page ("page"), its width ("width") or its height ("height") to the window, at zoom 1.
--- A page is read from the top, so a width fit starts at the top and a height fit at the left edge.
---@param s PdfView.Session
---@param mode PdfView.FitMode
local function set_mode(s, mode)
  if s.mode == mode and s.zoom == 1 then
    return
  end
  s.mode, s.zoom = mode, 1
  if mode == "width" then
    s.cx, s.cy = 0.5, 0
  elseif mode == "height" then
    s.cx, s.cy = 0, 0.5
  else
    s.cx, s.cy = 0.5, 0.5
  end
  show(s)
end

---@param s PdfView.Session
---@param zoom number multiplies the fitted size; below 1 steps back from a width/height fit to the whole page
local function set_zoom(s, zoom)
  if zoom < 1 and s.zoom == 1 and s.mode ~= "page" then
    return set_mode(s, "page")
  end
  zoom = math.min(math.max(zoom, 1), config.options.max_zoom)
  if math.abs(zoom - 1) < 0.01 then
    zoom = 1
  end
  if zoom == s.zoom then
    return
  end
  if s.mode == "page" and s.zoom == 1 then
    -- the fitted page is centred, wherever an earlier page turn left the stored centre
    s.cx, s.cy = 0.5, 0.5
  end
  s.zoom = zoom
  show(s)
end

--- Scroll a zoomed page by `steps` of `config.pan_step` windows. Returns whether the view moved.
---@param s PdfView.Session
---@param dx -1|0|1
---@param dy -1|0|1
---@param steps integer
---@return boolean
local function pan(s, dx, dy, steps)
  local win = uses_viewport(s) and s.geom and window_for(s)
  if not win then
    return false
  end
  local cols, rows = text_area(win)
  local cell = terminal.cell_size()
  local view = layout.viewport(s.geom.w, s.geom.h, cols, rows, cell.w, cell.h, s.zoom, s.cx, s.cy, s.mode)

  local moved = false
  if dx ~= 0 and view.scroll_x then
    local x = math.min(math.max(view.vx + dx * steps * config.options.pan_step * view.view_w, 0), view.max_x)
    if math.abs(x - view.vx) > 0.5 then
      s.cx, moved = (x + view.view_w / 2) / view.full_w, true
    end
  end
  if dy ~= 0 and view.scroll_y then
    local y = math.min(math.max(view.vy + dy * steps * config.options.pan_step * view.view_h, 0), view.max_y)
    if math.abs(y - view.vy) > 0.5 then
      s.cy, moved = (y + view.view_h / 2) / view.full_h, true
    end
  end
  return moved
end

--- A movement key scrolls the page when it can, and otherwise turns it, landing at the start of the next page
--- or the end of the previous one. Without zoom nothing can scroll, so these are plain page turns.
---@param s PdfView.Session
---@param dx -1|0|1
---@param dy -1|0|1
local function move(s, dx, dy)
  local count = vim.v.count1
  if pan(s, dx, dy, count) then
    return show(s)
  end
  local forward = dx + dy > 0
  local anchor ---@type PdfView.Anchor
  if forward then
    anchor = dx ~= 0 and { cx = 0, cy = 0 } or TOP
  else
    anchor = dx ~= 0 and { cx = 1, cy = 1 } or { cy = 1 }
  end
  go(s, (s.target or s.page) + (forward and count or -count), anchor)
end

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify("pdf-view: " .. message, level or vim.log.levels.INFO)
end

--- Whether a match already lies inside the part of the page that is on screen.
---@param s PdfView.Session
---@param match PdfView.Match
---@return boolean
local function match_visible(s, match)
  local win = s.page == match.page and s.geom and window_for(s)
  if not win then
    return false
  end
  local cols, rows = text_area(win)
  local cell = terminal.cell_size()
  if not uses_viewport(s) then
    return true -- the whole page is on screen
  end
  local view = layout.viewport(s.geom.w, s.geom.h, cols, rows, cell.w, cell.h, s.zoom, s.cx, s.cy, s.mode)
  for _, rect in ipairs(match.rects) do
    local inside = rect[1] * view.scale >= view.vx
      and rect[3] * view.scale <= view.vx + view.view_w
      and rect[2] * view.scale >= view.vy
      and rect[4] * view.scale <= view.vy + view.view_h
    if not inside then
      return false
    end
  end
  return true
end

--- Make match `index` the current one and bring it into view.
---@param s PdfView.Session
---@param index integer
local function goto_match(s, index)
  local match = s.search.matches[index]
  s.search.current = index
  if not match_visible(s, match) then
    s.cx, s.cy = match.cx, match.cy
  end
  s.target = match.page
  show(s, match.page)
end

--- Search the whole document for `needle` and jump to the first match from the current page.
---@param s PdfView.Session
---@param needle string
---@param dir 1|-1
local function run_search(s, needle, dir)
  start_search(s, needle, function(err, matches, truncated)
    if s.closed then
      return
    end
    if err then
      return notify("search failed: " .. err, vim.log.levels.WARN)
    end
    if #matches == 0 then
      notify(("no matches for `%s`"):format(needle), vim.log.levels.WARN)
      if s.search then
        s.search = nil
        show(s) -- an earlier search's highlights should not outlive a failed one
      end
      return
    end
    local found = search.new(needle, matches, truncated, dir)
    s.search = found
    found.current = search.start(found, s.target or s.page, dir)
    goto_match(s, found.current)
    if truncated then
      notify(("stopped at the first %d matches"):format(#matches), vim.log.levels.WARN)
    end
  end)
end

---@param s PdfView.Session
---@param dir 1|-1
local function prompt_search(s, dir)
  vim.ui.input({ prompt = dir > 0 and "/" or "?" }, function(input)
    if input and input ~= "" then
      run_search(s, input, dir)
    end
  end)
end

--- Step to the next match in the direction of the search (`reverse` false) or against it.
---@param s PdfView.Session
---@param reverse boolean
local function step_match(s, reverse)
  local found = s.search
  if not found then
    return notify("no search yet: press / to search")
  end
  local sign = reverse and -found.dir or found.dir
  local index = found.current
  if index and found.matches[index].page ~= (s.target or s.page) then
    index = nil -- the user has moved on: continue from where they are, not from the old match
  end
  local wrapped = false
  if index then
    for _ = 1, vim.v.count1 do
      index, wrapped = search.step(found, index, sign)
    end
  else
    index = search.start(found, s.target or s.page, sign)
  end
  if wrapped then
    vim.api.nvim_echo({
      { sign > 0 and "search hit BOTTOM, continuing at TOP" or "search hit TOP, continuing at BOTTOM", "WarningMsg" },
    }, false, {})
  end
  if index then
    goto_match(s, index)
  end
end

---@param s PdfView.Session
local function clear_search(s)
  cancel_search(s)
  if s.search then
    s.search = nil
    show(s)
  end
end

--- Pick one of the document's bookmarks and go to its page.
---@param s PdfView.Session
local function pick_outline(s)
  local function choose(entries)
    if #entries == 0 then
      return notify("this document has no outline")
    end
    vim.ui.select(entries, {
      prompt = "Outline",
      format_item = function(entry)
        return ("%s%s  (p. %d)"):format(("  "):rep(entry.depth), entry.title, entry.page)
      end,
    }, function(entry)
      if entry then
        go(s, entry.page, TOP)
      end
    end)
  end

  local stat = uv.fs_stat(s.path)
  local stamp = stat and stamp_of(stat) or ""
  if s.outline and s.outline.stamp == stamp then
    return choose(s.outline.entries)
  end
  mupdf.outline(s.path, function(err, entries)
    if s.closed then
      return
    end
    if err or not entries then
      return notify("cannot read the outline: " .. tostring(err), vim.log.levels.WARN)
    end
    s.outline = { stamp = stamp, entries = entries }
    choose(entries)
  end)
end

local ACTION_ORDER = {
  "down",
  "up",
  "right",
  "left",
  "next",
  "prev",
  "first",
  "last",
  "zoom_in",
  "zoom_out",
  "zoom_reset",
  "fit_width",
  "fit_height",
  "search",
  "search_back",
  "search_next",
  "search_prev",
  "search_clear",
  "outline",
  "reload",
  "close",
  "help",
}

---@type table<string, { desc: string, run: fun(s: PdfView.Session) }>
local ACTIONS = {}

ACTIONS.down = {
  desc = "scroll down, or next page ({count} times)",
  run = function(s)
    move(s, 0, 1)
  end,
}

ACTIONS.up = {
  desc = "scroll up, or previous page",
  run = function(s)
    move(s, 0, -1)
  end,
}

ACTIONS.right = {
  desc = "scroll right, or next page",
  run = function(s)
    move(s, 1, 0)
  end,
}

ACTIONS.left = {
  desc = "scroll left, or previous page",
  run = function(s)
    move(s, -1, 0)
  end,
}

ACTIONS.next = {
  desc = "next page ({count} pages ahead)",
  run = function(s)
    go(s, (s.target or s.page) + vim.v.count1, TOP)
  end,
}

ACTIONS.prev = {
  desc = "previous page ({count} pages back)",
  run = function(s)
    go(s, (s.target or s.page) - vim.v.count1, TOP)
  end,
}

ACTIONS.first = {
  desc = "first page, or page {count}",
  run = function(s)
    go(s, vim.v.count > 0 and vim.v.count or 1, TOP)
  end,
}

ACTIONS.last = {
  desc = "last page, or page {count}",
  run = function(s)
    go(s, vim.v.count > 0 and vim.v.count or math.huge, TOP)
  end,
}

ACTIONS.zoom_in = {
  desc = "zoom in ({count} steps)",
  run = function(s)
    set_zoom(s, s.zoom * config.options.zoom_step ^ vim.v.count1)
  end,
}

ACTIONS.zoom_out = {
  desc = "zoom out",
  run = function(s)
    set_zoom(s, s.zoom / config.options.zoom_step ^ vim.v.count1)
  end,
}

ACTIONS.zoom_reset = {
  desc = "fit the whole page to the window",
  run = function(s)
    set_mode(s, "page")
  end,
}

ACTIONS.fit_width = {
  desc = "fit the page's width to the window",
  run = function(s)
    set_mode(s, "width")
  end,
}

ACTIONS.fit_height = {
  desc = "fit the page's height to the window",
  run = function(s)
    set_mode(s, "height")
  end,
}

ACTIONS.search = {
  desc = "search forward",
  run = function(s)
    prompt_search(s, 1)
  end,
}

ACTIONS.search_back = {
  desc = "search backward",
  run = function(s)
    prompt_search(s, -1)
  end,
}

ACTIONS.search_next = {
  desc = "next match ({count} matches ahead)",
  run = function(s)
    step_match(s, false)
  end,
}

ACTIONS.search_prev = {
  desc = "previous match",
  run = function(s)
    step_match(s, true)
  end,
}

ACTIONS.search_clear = {
  desc = "remove the search highlights",
  run = clear_search,
}

ACTIONS.outline = {
  desc = "jump to a bookmark",
  run = pick_outline,
}

ACTIONS.reload = { desc = "re-render the page", run = M.reload }

ACTIONS.close = {
  desc = "close the viewer",
  run = function(s)
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end,
}

ACTIONS.help = {
  desc = "show this help",
  run = function()
    local lines = { "pdf-view keys" }
    for _, action in ipairs(ACTION_ORDER) do
      local keys = (config.options.keymaps or {})[action]
      if keys and #keys > 0 then
        lines[#lines + 1] = ("  %-24s %s"):format(table.concat(keys, " "), ACTIONS[action].desc)
      end
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "pdf-view" })
  end,
}

---@param s PdfView.Session
local function set_keymaps(s)
  local keymaps = config.options.keymaps
  if not keymaps then
    return
  end
  for action, keys in pairs(keymaps) do
    for _, lhs in ipairs(keys) do
      vim.keymap.set("n", lhs, function()
        ACTIONS[action].run(s)
      end, { buffer = s.buf, nowait = true, silent = true, desc = "PDF: " .. ACTIONS[action].desc })
    end
  end
end

M.rescan = rescan
M.set_keymaps = set_keymaps

return M
