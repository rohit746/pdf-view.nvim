--- What the keys do: turning pages, scrolling, zooming, fitting, searching and jumping to bookmarks. Each action
--- changes the session and asks `render` to show it.
local config = require("pdf-view.config")
local cursor = require("pdf-view.cursor")
local layout = require("pdf-view.layout")
local mupdf = require("pdf-view.mupdf")
local render = require("pdf-view.render")
local search = require("pdf-view.search")
local session = require("pdf-view.session")
local synctex = require("pdf-view.synctex")
local terminal = require("pdf-view.terminal")

local M = {}

local uv = vim.uv
local show = render.show
local stamp_of, purge_cache, window_for, text_area, uses_viewport =
  session.stamp_of, session.purge_cache, session.window_for, session.text_area, session.uses_viewport

---@param s PdfView.Session
local function refresh_winbar(s)
  local win = not s.closed and window_for(s)
  if win then
    session.update_winbar(s, win)
  end
end

--- Stop the search that is running, if any. It reports nothing.
---@param s PdfView.Session
local function cancel_search(s)
  if s.search_job then
    s.search_job:kill(15)
  end
  s.search_job, s.search_again = nil, nil
  if s.searching then
    s.searching = nil
    refresh_winbar(s)
  end
end

--- Search the document for `needle`, in place of a search that is still running. `done` is only called for a search
--- that is still the session's own when it finishes: one that was cancelled or replaced reports nothing.
---@param s PdfView.Session
---@param needle string
---@param done fun(err?: string, matches?: PdfView.Match[], truncated?: boolean)
---@param waited? boolean the user is waiting for it, so the winbar says "searching…" until it finishes
local function start_search(s, needle, done, waited)
  cancel_search(s)
  local job
  job = mupdf.search(s.path, needle, config.options.search_limit, function(...)
    if s.search_job ~= job then
      return
    end
    s.search_job, s.search_again = nil, nil
    if s.searching then
      s.searching = nil
      refresh_winbar(s)
    end
    done(...)
  end)
  s.search_job = job
  s.search_again = function()
    start_search(s, needle, done, waited)
  end
  if waited then
    s.searching = needle
    refresh_winbar(s)
  end
end

--- Search the document again for the active search, after the file changed: pages, text and positions may differ.
--- A viewer in no window only notes that its search is stale, and searches again when a window shows it
--- (`BufWinEnter`): a document rebuilt on every save would otherwise be searched whole each time for nothing.
---@param s PdfView.Session
local function rescan(s)
  if not window_for(s) then
    s.search_stale = s.search_again ~= nil or s.search ~= nil
    return
  end
  s.search_stale = nil
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

--- Where a viewer is: its page, fit, zoom and the centre of the view. The jump list and the marks hold these.
---@alias PdfView.Position { page: integer, mode: PdfView.FitMode, zoom: number, cx: number, cy: number }

local JUMP_LIMIT = 100 -- as in Vim

---@param s PdfView.Session
---@return PdfView.Position
local function here(s)
  return { page = s.target or s.page, mode = s.mode, zoom = s.zoom, cx = s.cx, cy = s.cy }
end

--- Go back to `where`, with the fit and zoom it had.
---@param s PdfView.Session
---@param where PdfView.Position
local function restore(s, where)
  if s.closed then
    return
  end
  s.mode, s.zoom, s.cx, s.cy = where.mode, where.zoom, where.cx, where.cy
  s.scrolled = nil
  s.target = math.max(1, math.min(where.page, s.count or where.page))
  show(s, s.target)
end

--- Put the position `where` at the end of the jump list, in place of an older entry for the same page.
---@param s PdfView.Session
---@param where PdfView.Position
local function push_jump(s, where)
  local jumps = s.jumps
  for index = #jumps, 1, -1 do
    if jumps[index].page == where.page then
      table.remove(jumps, index)
    end
  end
  jumps[#jumps + 1] = where
  if #jumps > JUMP_LIMIT then
    table.remove(jumps, 1)
  end
  s.jump_index = #jumps + 1
end

--- Record a jump that is about to leave the current position: `<C-o>` comes back to it, and so does `''`.
---@param s PdfView.Session
local function record_jump(s)
  local where = here(s)
  push_jump(s, where)
  s.marks["'"] = where
end

--- Move `count` entries through the jump list: back for a negative count, forward for a positive one. Past either
--- end of the list the rest of the count goes to Vim's own jump list, as `<C-o>` would: back to the file the viewer
--- was opened from, or forward to the one `<C-o>` came from.
---@param s PdfView.Session
---@param count integer
local function walk_jumps(s, count)
  local jumps = s.jumps
  local index = s.jump_index
  if count < 0 and index > #jumps then
    -- leaving the end of the list: keep the current position so `<C-i>` can come back to it
    push_jump(s, here(s))
    index = #jumps
  end
  -- the entries there are in that direction: after a new jump (`#jumps + 1`) there is none forward
  local room = count < 0 and index - 1 or math.max(0, #jumps - index)
  local steps = math.min(math.abs(count), room)
  local rest = math.abs(count) - steps
  if steps > 0 then
    local to = index + (count < 0 and -steps or steps)
    s.marks["'"] = here(s)
    s.jump_index = to
    restore(s, jumps[to])
  end
  if rest > 0 then
    vim.api.nvim_feedkeys(rest .. vim.keycode(count < 0 and "<C-o>" or "<C-i>"), "n", false)
  end
end

--- Where on the new page a zoomed view starts, as a fraction of the page. Missing fields keep their value.
---@alias PdfView.Anchor { cx?: number, cy?: number }

local TOP = { cy = 0 }

---@param s PdfView.Session
---@param page integer
---@param anchor? PdfView.Anchor
---@param jump? boolean a jump to a page (`gg`, `G`, a bookmark) moves to `anchor` even on the page that is on screen;
--- a page turn that cannot go further (the last page, the top of the first one) leaves the view where it is
local function go(s, page, anchor, jump)
  if s.closed or (page == math.huge and not s.count) then -- `G` before the last page is known
    return
  end
  if jump then
    record_jump(s)
  end
  page = session.spread_range(s, math.max(1, math.min(page, s.count or page)), s.count)
  if page == (s.target or s.page) and s.slot ~= 0 then
    if not (jump and anchor and uses_viewport(s)) then
      return
    end
    local cx, cy = anchor.cx or s.cx, anchor.cy or s.cy
    if cx == s.cx and cy == s.cy then
      return
    end
  end
  s.target = page
  if anchor then
    s.cx, s.cy = anchor.cx or s.cx, anchor.cy or s.cy
  end
  s.scrolled = nil
  show(s, page)
end

--- The anchor that brings the point (`x`, `y`) of page `page`, as fractions of it, to the top left of the window,
--- where a link or a bookmark leads: the top of the page when it says nothing more, or when the whole page is on
--- screen. The window is measured with the page on screen, which is the size of the other pages of almost every
--- document.
---@param s PdfView.Session
---@param page integer
---@param x? number
---@param y? number
---@return PdfView.Anchor
local function anchor_at(s, page, x, y)
  local win = y and uses_viewport(s) and s.geom and window_for(s)
  if not win then
    return TOP
  end
  local sheet_x, sheet_y = session.sheet_point(s, page, x or 0, y --[[@as number]]) -- facing pages are one sheet
  x, y = x and sheet_x, sheet_y
  local cols, rows = text_area(win)
  local cell = terminal.cell_size()
  local view = layout.viewport(s.geom.w, s.geom.h, cols, rows, cell.w, cell.h, s.zoom, s.cx, s.cy, s.mode, s.geom.box)
  local anchor = { cy = view.scroll_y and y + view.view_h / 2 / view.full_h or 0 }
  if x and view.scroll_x then
    anchor.cx = x + view.view_w / 2 / view.full_w
  end
  return anchor
end

---@param s PdfView.Session
function M.reload(s)
  purge_cache(s)
  s.outline = nil
  s.requested_key, s.requested_stamp = nil, nil
  s.locked = nil -- the password prompt was cancelled: ask again
  show(s)
  rescan(s)
end

--- Fit the whole page ("page"), its width ("width"), its height ("height") or the part of it with content on it
--- ("content") to the window, at zoom 1. A page is read from the top, so a width fit starts at the top and a height fit
--- at the left edge.
---@param s PdfView.Session
---@param mode PdfView.FitMode
local function set_mode(s, mode)
  if s.mode == mode and s.zoom == 1 then
    return
  end
  s.mode, s.zoom, s.scrolled = mode, 1, nil
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
  if (s.mode == "page" or s.mode == "content") and s.zoom == 1 then
    -- the fitted page is centred, wherever an earlier page turn left the stored centre; zooming in on a page with the
    -- current search match goes towards the match instead
    local found = s.search
    local match = found and found.current and found.matches[found.current]
    if match and session.on_screen(s, match.page) then
      s.cx, s.cy = session.sheet_point(s, match.page, match.cx, match.cy)
    else
      s.cx, s.cy = 0.5, 0.5
    end
  end
  s.zoom, s.scrolled = zoom, nil
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
  local continuous = session.continuous(s)
  local view = layout.viewport(
    s.geom.w,
    s.geom.h,
    cols,
    rows,
    cell.w,
    cell.h,
    s.zoom,
    s.cx,
    s.cy,
    s.mode,
    s.geom.box,
    continuous and s.scrolled
  )

  local moved = false
  if dx ~= 0 and view.scroll_x then
    local x = math.min(math.max(view.vx + dx * steps * config.options.pan_step * view.view_w, view.min_x), view.max_x)
    if math.abs(x - view.vx) > 0.5 then
      s.cx, moved = (x + view.view_w / 2) / view.full_w, true
    end
  end
  if dy ~= 0 and view.scroll_y then
    -- continuous scrolling goes on past the page's edges into the pages next to it, up to the ends of the document
    local top, bottom = view.min_y, view.max_y
    if continuous then
      top = s.page > 1 and -math.huge or top
      bottom = (s.last or s.page) < (s.count or 0) and math.huge or bottom
    end
    local y = math.min(math.max(view.vy + dy * steps * config.options.pan_step * view.view_h, top), bottom)
    if math.abs(y - view.vy) > 0.5 then
      s.cy, moved = (y + view.view_h / 2) / view.full_h, true
      s.scrolled = continuous or nil
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
  go(s, session.spread_step(s, s.target or s.page, forward and count or -count), anchor)
end

--- The mouse wheel moves the viewer it is over, as `move` does. These keys are mapped in each viewer, and while a
--- viewer is open also globally (`set_global_wheel`), so the wheel moves a viewer the cursor is not in. Over any other
--- window the wheel does what it would do there without the mappings.
---@param s? PdfView.Session the focused viewer; nil for the global mappings
---@param dx -1|0|1
---@param dy -1|0|1
---@param lhs string the key that was pressed
local function wheel(s, dx, dy, lhs)
  local win = vim.fn.getmousepos().winid
  if win == 0 and s then -- no mouse position: the key came from a script or another mapping
    return move(s, dx, dy)
  end
  local over = win ~= 0 and session.sessions[vim.api.nvim_win_get_buf(win)]
  if over and not over.closed then
    return move(over, dx, dy)
  end
  vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
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
  local win = s.target == nil and session.on_screen(s, match.page) and s.geom and window_for(s)
  if not win then
    return false
  end
  local cols, rows = text_area(win)
  local cell = terminal.cell_size()
  if not uses_viewport(s) then
    return true -- the whole page is on screen
  end
  local free = session.continuous(s) and s.scrolled
  local view =
    layout.viewport(s.geom.w, s.geom.h, cols, rows, cell.w, cell.h, s.zoom, s.cx, s.cy, s.mode, s.geom.box, free)
  local ox, oy = 0, 0 -- where the page lies on a sheet of facing pages
  for _, part in ipairs(s.parts or {}) do
    if part.page == match.page then
      ox, oy = part.x, part.y
    end
  end
  for _, rect in ipairs(match.rects) do
    local inside = (ox + rect[1]) * view.scale >= view.vx
      and (ox + rect[3]) * view.scale <= view.vx + view.view_w
      and (oy + rect[2]) * view.scale >= view.vy
      and (oy + rect[4]) * view.scale <= view.vy + view.view_h
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
  record_jump(s)
  s.search.current = index
  if not match_visible(s, match) then
    s.cx, s.cy = session.sheet_point(s, match.page, match.cx, match.cy)
    s.scrolled = nil
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
  end, true)
end

--- Prompt for text and search for it. The text goes into the search history (`:history /`); an empty answer searches
--- again for the last text searched in this viewer, as `/<CR>` does in Vim.
---@param s PdfView.Session
---@param dir 1|-1
local function prompt_search(s, dir)
  vim.ui.input({ prompt = dir > 0 and "/" or "?" }, function(input)
    if s.closed then
      return -- an input plugin that asks asynchronously leaves time to close the viewer before the answer
    end
    if input == "" then
      input = s.last_needle
    end
    if input and input ~= "" then
      s.last_needle = input
      vim.fn.histadd("search", input)
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
  if index and not session.on_screen(s, found.matches[index].page) then
    index = nil -- the user has moved on: continue from where they are, not from the old match
  end
  local wrapped, steps = false, vim.v.count1
  if not index then
    index, wrapped = search.start(found, s.target or s.page, sign)
    steps = steps - 1 -- landing on the first match from here is the first step
  end
  for _ = 1, index and steps or 0 do
    local w
    index, w = search.step(found, index --[[@as integer]], sign)
    wrapped = wrapped or w
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

--- Pick one of the matches of the search from a list of them, each with its page and line of text, and go to it as
--- `n` would.
---@param s PdfView.Session
local function pick_match(s)
  local found = s.search
  if s.searching then
    return notify(("still searching for `%s`"):format(s.searching))
  end
  if not found then
    return notify("no search yet: press / to search")
  end
  local indices = {}
  for index = 1, #found.matches do
    indices[index] = index
  end
  local count = #found.matches .. (found.truncated and "+" or "")
  vim.ui.select(indices, {
    prompt = ("Matches for `%s` (%s)"):format(found.needle, count),
    kind = "pdf-view.matches",
    format_item = function(index)
      return search.describe(found, index)
    end,
  }, function(index)
    -- a picker that answers later leaves time to close the viewer, or to search again (or the file to change)
    if not index or s.closed then
      return
    end
    if s.search ~= found then
      return notify("the search has changed since the list was shown: list its matches again")
    end
    goto_match(s, index)
  end)
end

---@param s PdfView.Session
local function clear_search(s)
  cancel_search(s)
  if s.search or s.synced then
    s.search, s.synced = nil, nil
    show(s)
  end
end

local next_sync = 0

--- Show where a forward search landed in the viewer `s`: the page of the first box, with the boxes on it highlighted
--- and, when the page is zoomed or fitted to its width, in the middle of the window. A jump, so `<C-o>` comes back.
---@param s PdfView.Session
---@param boxes PdfView.SyncBox[]
local function show_synced(s, boxes)
  local page = boxes[1].page
  local rects = {}
  for _, box in ipairs(boxes) do
    if box.page == page then
      rects[#rects + 1] = box.rect
    end
  end
  mupdf.info(s.path, page, function(err, info)
    if s.closed then
      return
    end
    if err or not info then
      return notify("cannot read page " .. page .. ": " .. tostring(err), vim.log.levels.WARN)
    end
    record_jump(s)
    next_sync = next_sync + 1
    s.synced = { id = next_sync, page = info.page, rects = rects }
    local first = rects[1]
    if uses_viewport(s) then
      local cx, cy = session.sheet_point(
        s,
        info.page,
        (first[1] + first[3]) / 2 / info.width,
        (first[2] + first[4]) / 2 / info.height
      )
      s.cy = cy
      local win = window_for(s)
      if win then
        local cols, rows = text_area(win)
        local cell = terminal.cell_size()
        -- facing pages are measured with the sheet on screen
        local spread = session.spread_mode(s) ~= "off" and s.geom
        local w, h = spread and s.geom.w or info.width, spread and s.geom.h or info.height
        local view = layout.viewport(w, h, cols, rows, cell.w, cell.h, s.zoom, s.cx, s.cy, s.mode, nil)
        if view.scroll_x then
          s.cx = cx
        end
      end
    end
    s.target = session.spread_range(s, info.page, info.count)
    s.scrolled = nil
    show(s, s.target)
  end)
end

--- The PDFs a forward search from `file` tries, most likely first: the one vimtex builds, those open in viewers (on
--- screen first), and the PDF of the same name next to the file.
---@param file string
---@return string[]
local function sync_candidates(file)
  local candidates, seen = {}, {}
  local function add(path)
    if type(path) ~= "string" or path == "" then
      return
    end
    path = vim.fn.fnamemodify(path, ":p")
    if not seen[path] and vim.fn.filereadable(path) == 1 then
      seen[path] = true
      candidates[#candidates + 1] = path
    end
  end
  if vim.fn.exists("b:vimtex") == 1 then -- not `vim.b.vimtex`: its functions do not convert to Lua
    local ok, out = pcall(vim.api.nvim_eval, "b:vimtex.out()")
    if ok then
      add(out)
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local shown, hidden = {}, {}
  for _, s in pairs(session.sessions) do
    local on_screen = false
    for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
      on_screen = on_screen or vim.api.nvim_win_get_tabpage(win) == tab
    end
    table.insert(on_screen and shown or hidden, s.path)
  end
  table.sort(shown)
  table.sort(hidden)
  vim.list_extend(shown, hidden)
  for _, path in ipairs(shown) do
    add(path)
  end
  add(vim.fn.fnamemodify(file, ":r") .. ".pdf")
  return candidates
end

--- Forward search (SyncTeX): show where line `line`, column `col` of the TeX file `file` (the current buffer and
--- cursor by default) is typeset, in the viewer of `pdf`. Without `pdf`, the PDFs of `sync_candidates()` are tried in
--- turn. A PDF that is in no window of the current tab opens in a vertical split; the cursor stays in the source.
---@param opts? { pdf?: string, file?: string, line?: integer, col?: integer }
function M.forward_search(opts)
  opts = opts or {}
  local file = opts.file or vim.api.nvim_buf_get_name(0)
  if file == "" then
    return notify("forward search: the buffer has no file", vim.log.levels.WARN)
  end
  file = vim.fn.fnamemodify(file, ":p")
  local pos = vim.api.nvim_win_get_cursor(0)
  local line, col = opts.line or pos[1], opts.col or (pos[2] + 1)
  local candidates = opts.pdf and { vim.fn.fnamemodify(opts.pdf, ":p") } or sync_candidates(file)
  if #candidates == 0 then
    return notify(("forward search: no PDF found for %s"):format(vim.fn.fnamemodify(file, ":~:.")), vim.log.levels.WARN)
  end
  local source_win = vim.api.nvim_get_current_win()
  local last_err
  local function try(index)
    local pdf = candidates[index]
    if not pdf then
      local where = ("%s:%d"):format(vim.fn.fnamemodify(file, ":t"), line)
      return notify(
        last_err and ("forward search: %s"):format(last_err)
          or ("forward search: %s is not in the SyncTeX data of %s (build with `-synctex=1`)"):format(
            where,
            table.concat(
              vim.tbl_map(function(path)
                return vim.fn.fnamemodify(path, ":t")
              end, candidates),
              ", "
            )
          ),
        vim.log.levels.WARN
      )
    end
    synctex.view(pdf, file, line, col, function(err, boxes)
      if err or not boxes or #boxes == 0 then
        last_err = err and err:match("^cannot run") and err or last_err
        return try(index + 1)
      end
      -- by the file, not the name: a symlink and the PDF it points to share the viewer
      local real = vim.uv.fs_realpath(pdf) or pdf
      local s
      for _, candidate in pairs(session.sessions) do
        if (vim.uv.fs_realpath(candidate.path) or candidate.path) == real and not candidate.closed then
          s = candidate
        end
      end
      local tab = vim.api.nvim_get_current_tabpage()
      local shown = false
      for _, win in ipairs(s and vim.fn.win_findbuf(s.buf) or {}) do
        shown = shown or vim.api.nvim_win_get_tabpage(win) == tab
      end
      if not shown then
        -- next to the source, and back to it: the cursor stays where the search started
        local from = vim.api.nvim_win_is_valid(source_win) and source_win or 0
        vim.api.nvim_win_call(from, function()
          vim.cmd("vertical rightbelow split")
          s = session.sessions[require("pdf-view.viewer").open(pdf)]
        end)
        -- the viewer's BufEnter hid the cursor, and nvim_win_call comes back without the BufLeave that shows it
        local current = vim.api.nvim_get_current_buf()
        if session.sessions[current] then
          cursor.hide(current)
        else
          cursor.show()
        end
      end
      if s then
        show_synced(s, boxes)
      end
    end)
  end
  try(1)
end

--- The page under the cell at `row`, `col` (0-based, in the window's text area) of the viewer `s`, and the point of
--- it there, in points from the page's top-left corner. Nil off the page.
---@param s PdfView.Session
---@param row integer
---@param col integer
---@return integer? page, number? x, number? y
local function point_at(s, row, col)
  local fit, geom = s.fit, s.geom
  if not (fit and geom) then
    return nil
  end
  local cx, cy = col - fit.pad_left + 0.5, row - fit.pad_top + 0.5
  if cx < 0 or cy < 0 or cx > fit.cols or cy > fit.rows then
    return nil
  end
  if fit.parts then -- a continuous view: the pages one below the other
    local px, py = cx * fit.width / fit.cols, cy * fit.height / fit.rows
    for _, part in ipairs(fit.parts) do
      local clip = part.clip
      if px >= clip[1] and px <= clip[3] and py >= clip[2] and py <= clip[4] then
        return part.page, (px - part.dx) / part.scale_x, (py - part.dy) / part.scale_y
      end
    end
    return nil -- between the pages
  end
  local x, y
  if fit.scale then -- a viewport: the cells show its pixels from (x, y) on
    x, y = (fit.x + cx * fit.width / fit.cols) / fit.scale, (fit.y + cy * fit.height / fit.rows) / fit.scale
  else
    x, y = cx / fit.cols * geom.w, cy / fit.rows * geom.h
  end
  for _, part in ipairs(s.parts or {}) do -- facing pages: the one under the cell
    if x >= part.x and x <= part.x + part.width and y >= part.y and y <= part.y + part.height then
      return part.page, x - part.x, y - part.y
    end
  end
  if s.parts then
    return nil -- between the pages
  end
  return s.page, x, y
end

--- Open `source` at its line: in a window of the current tab that shows it, else in the previous window when that is
--- a normal window with a file in it, else in a vertical split.
---@param source PdfView.SyncSource
local function open_source(source)
  local target, buf
  -- not bufnr(): it takes a pattern, and matches another buffer with this path inside its name
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == source.file then
      buf = b
      break
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if buf and vim.api.nvim_win_get_buf(win) == buf then
      target = win
      break
    end
  end
  if not target then
    local previous = vim.fn.win_getid(vim.fn.winnr("#"))
    local current = vim.api.nvim_get_current_win()
    -- not a sidebar, quickfix, help or terminal window, nor one that :edit cannot change or a floating one
    if
      previous ~= 0
      and previous ~= current
      and vim.api.nvim_win_get_config(previous).relative == ""
      and not vim.wo[previous].winfixbuf
      and vim.bo[vim.api.nvim_win_get_buf(previous)].buftype == ""
      and not session.sessions[vim.api.nvim_win_get_buf(previous)]
    then
      target = previous
    end
  end
  if target then
    vim.api.nvim_set_current_win(target)
    if vim.api.nvim_win_get_buf(target) ~= buf then
      vim.cmd.edit(vim.fn.fnameescape(source.file))
    end
  else
    vim.cmd("vertical leftabove split " .. vim.fn.fnameescape(source.file))
  end
  local last = vim.api.nvim_buf_line_count(0)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(source.line, last), math.max(0, source.column - 1) })
  vim.cmd("normal! zv")
end

--- Inverse search (SyncTeX): open the TeX source at the line that the point under the mouse was typeset from.
---@param s PdfView.Session
---@param lhs string the key that was pressed
local function inverse_search(s, lhs)
  local mouse = vim.fn.getmousepos()
  local over = mouse.winid ~= 0 and session.sessions[vim.api.nvim_win_get_buf(mouse.winid)]
  if not over then
    return vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
  end
  s = over
  local info = vim.fn.getwininfo(mouse.winid)[1] -- `winrow` counts the winbar, `wincol` the sign and number columns
  local page, x, y = point_at(s, mouse.winrow - 1 - info.winbar, mouse.wincol - 1 - info.textoff)
  if not page then
    return
  end
  synctex.edit(s.path, page, x --[[@as number]], y --[[@as number]], function(err, source)
    if s.closed then
      return
    end
    if err then
      return notify("inverse search: " .. err, vim.log.levels.WARN)
    end
    if not source then
      return notify(("inverse search: SyncTeX knows no source for this point of page %d"):format(page))
    end
    open_source(source)
  end)
end

--- Pick one of the document's bookmarks and go to where it leads.
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
        go(s, entry.page, anchor_at(s, entry.page, entry.x, entry.y), true)
      end
    end)
  end

  local stat = uv.fs_stat(s.path)
  -- the pages of a reflowable document follow its layout
  local stamp = (stat and stamp_of(stat) or "") .. (s.laid_out and "@" .. s.laid_out.key or "")
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

--- What `results` holds for each page on screen (two facing pages, or one), as `fetch` reads it, in page order.
--- Stops at the first error.
---@generic T
---@param s PdfView.Session
---@param fetch fun(path: string, page: integer, cb: fun(err?: string, result?: T))
---@param done fun(err?: string, results?: T[])
local function for_pages_on_screen(s, fetch, done)
  local first, last = s.page, s.last or s.page
  local results = {}
  local function step(page)
    if page > last then
      return done(nil, results)
    end
    fetch(s.path, page, function(err, result)
      if s.closed then
        return
      end
      if err or result == nil then
        return done(err or "no answer")
      end
      results[#results + 1] = result
      step(page + 1)
    end)
  end
  step(first)
end

--- "page 3", or "pages 3-4" for facing pages.
---@param s PdfView.Session
---@return string
local function pages_on_screen(s)
  return (s.last and s.last ~= s.page and "pages " or "page ") .. session.pages_label(s)
end

--- The scheme of an address, in lower case ("https" for "HTTPS://example.com"), or nil when it has none.
---@param uri string
---@return string?
local function scheme_of(uri)
  local scheme = uri:match("^(%a[%w+.-]*):")
  return scheme and scheme:lower()
end

--- Open the address of a link with `vim.ui.open()`. An address whose scheme is not in `link_schemes` (a `file:`
--- address, which a PDF's Launch action becomes too, or a custom scheme) can start a program on this machine, so the
--- user is asked first, with the whole address.
---@param uri string
local function open_address(uri)
  local scheme = scheme_of(uri)
  local trusted = scheme ~= nil
    and vim.tbl_contains(config.options.link_schemes, function(allowed)
      return allowed:lower() == scheme
    end, { predicate = true })
  if not trusted then
    local answer = vim.fn.confirm(
      ("pdf-view: this link can start a program. Open it?\n%s"):format(uri),
      "&Open\n&Cancel",
      2,
      "Warning"
    )
    if answer ~= 1 then
      return
    end
  end
  local _, open_err = vim.ui.open(uri)
  if open_err then
    notify(("cannot open %s: %s"):format(uri, open_err), vim.log.levels.WARN)
  end
end

---@class PdfView.DocumentLink
---@field name string the file as the link names it, decoded ("other.pdf")
---@field path string the file, absolute: a relative name is resolved against the directory of the linking document
---@field fragment? string where in the file it leads, with its `#` ("#page=3&view=Fit", "#nameddest=intro")
---@field page? integer the page of `#page=N`
---@field dest? string the name of `#nameddest=...`, decoded

--- `%20` and the like decoded.
---@param text string
---@return string
local function percent_decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- The document that the address `uri` of a link in the viewer `s` leads to, when the viewer can open it: a `file:`
--- address, or one without a scheme, of a local file with one of the `extensions`. A link to another PDF (`/GoToR`)
--- reaches here as `file:other.pdf#page=3&view=Fit`. Nil for any other address.
---@param s PdfView.Session
---@param uri string
---@return PdfView.DocumentLink?
local function document_link(s, uri)
  local scheme = scheme_of(uri)
  local rest = uri
  if scheme == "file" then
    rest = uri:sub(#"file:" + 1)
    local host = rest:match("^//([^/]*)")
    if host then
      if host ~= "" and host:lower() ~= "localhost" then
        return nil -- a file on another machine
      end
      rest = rest:sub(#host + 3)
    end
  elseif scheme then
    return nil
  end
  local file, fragment = rest:match("^([^#]*)(#?.*)$")
  local name = percent_decode(file)
  if
    name == ""
    or not vim.tbl_contains(config.options.extensions, function(extension)
      return extension:lower() == vim.fn.fnamemodify(name, ":e"):lower()
    end, { predicate = true })
  then
    return nil
  end
  local base = vim.fn.fnamemodify(s.path, ":p:h")
  local path = name:sub(1, 1) == "/" and name or vim.fs.joinpath(base, name)
  ---@type PdfView.DocumentLink
  local link = { name = name, path = vim.fs.normalize(path), fragment = #fragment > 1 and fragment or nil }
  for param in fragment:sub(2):gmatch("[^&]+") do
    local key, value = param:match("^([^=]*)=(.*)$")
    if key == "page" then
      link.page = tonumber(value:match("^%d+$"))
    elseif key == "nameddest" then
      link.dest = percent_decode(value)
    end
  end
  return link
end

--- How the picker shows where a link to another document leads: "other.pdf, p. 3".
---@param link PdfView.DocumentLink
---@return string
local function document_label(link)
  if link.page then
    return ("%s, p. %d"):format(link.name, link.page)
  end
  return link.dest and ("%s, %s"):format(link.name, link.dest) or link.name
end

--- Follow a link from the viewer `s` to another document: open it in a viewer in the same window, at the page it leads
--- to. `<C-o>` past the start of the new viewer's jump list comes back to `s`, through Vim's jump list.
---@param s PdfView.Session
---@param link PdfView.DocumentLink
local function open_document(s, link)
  local real = vim.uv.fs_realpath(link.path)
  local stat = real and vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return notify(("cannot read %s"):format(vim.fn.fnamemodify(link.path, ":~:.")), vim.log.levels.WARN)
  end
  local target = s
  if real ~= (vim.uv.fs_realpath(s.path) or s.path) then
    local win = window_for(s)
    if win and win ~= vim.api.nvim_get_current_win() then
      vim.api.nvim_set_current_win(win)
    end
    vim.cmd("normal! m'") -- `<C-o>` comes back here
    local ok, buf = pcall(require("pdf-view.viewer").open, link.path)
    if not ok then
      return notify(tostring(buf), vim.log.levels.WARN)
    end
    target = session.sessions[buf]
  end
  if not link.fragment or not target then
    return
  end
  mupdf.destination(target.path, link.fragment, function(err, dest)
    if target.closed then
      return
    end
    if err then
      if not mupdf.password_error(err) then -- the viewer asks for the password itself
        notify(("cannot follow the link to %s: %s"):format(link.name, err), vim.log.levels.WARN)
      end
      return
    end
    if not dest then
      return notify(("%s has no %s"):format(link.name, link.fragment), vim.log.levels.WARN)
    end
    -- in the same document a jump, so `<C-o>` comes back; a new viewer's first page is not one
    go(target, dest.page, anchor_at(target, dest.page, dest.x, dest.y), target == s)
  end)
end

--- Pick one of the links on the page on screen and follow it: a link into the document jumps to where it leads, a link
--- to another document that the viewer opens (a PDF) opens it in this window at the page it leads to, any other opens
--- with `vim.ui.open()`, a web address or an e-mail right away, another address once the user agrees. Facing pages
--- offer the links of both.
---@param s PdfView.Session
local function follow_link(s)
  local label = pages_on_screen(s)
  for_pages_on_screen(s, mupdf.links, function(err, per_page)
    if err or not per_page then
      return notify("cannot read the links of the page: " .. tostring(err), vim.log.levels.WARN)
    end
    local links = {}
    for _, list in ipairs(per_page) do
      vim.list_extend(links, list)
    end
    if #links == 0 then
      return notify(("%s has no links"):format(label))
    end
    vim.ui.select(links, {
      prompt = "Links",
      format_item = function(link)
        local document = link.uri and document_link(s, link.uri)
        local target = link.page and ("p. %d"):format(link.page) or document and document_label(document) or link.uri
        return link.text ~= "" and ("%s  (%s)"):format(link.text, target) or target
      end,
    }, function(link)
      if not link then
        return
      end
      if link.page then
        return go(s, link.page, anchor_at(s, link.page, link.x, link.y), true)
      end
      -- before `link_schemes`: a document the viewer opens itself starts no program, so it needs no question
      local document = document_link(s, link.uri)
      if document then
        return open_document(s, document)
      end
      open_address(link.uri)
    end)
  end)
end

--- Read the text of the page on screen and hand its lines to `use`, without the empty lines at its end, with what it
--- is called ("page 3", "pages 3-4" for facing pages, whose texts follow each other). A page without text, such as a
--- scanned one, only gets a notification.
---@param s PdfView.Session
---@param use fun(lines: string[], label: string)
local function with_page_text(s, use)
  local label = pages_on_screen(s)
  for_pages_on_screen(s, mupdf.text, function(err, texts)
    if err or not texts then
      return notify("cannot read the text of the page: " .. tostring(err), vim.log.levels.WARN)
    end
    local lines = {}
    for _, text in ipairs(texts) do
      local own = vim.split(text, "\n", { plain = true })
      while #own > 0 and not own[#own]:match("%S") do
        own[#own] = nil
      end
      if #own > 0 and #lines > 0 then
        lines[#lines + 1] = ""
      end
      vim.list_extend(lines, own)
    end
    if #lines == 0 then
      return notify(("%s has no text"):format(label))
    end
    use(lines, label)
  end)
end

--- Put the text of the page into the register the key was given (`"+y` for the clipboard), linewise.
---@param s PdfView.Session
local function yank_text(s)
  local register = vim.v.register
  with_page_text(s, function(lines, label)
    vim.fn.setreg(register, lines, "l")
    notify(('%s: %d lines yanked into "%s'):format(label, #lines, register))
  end)
end

--- Show the text of the page in a scratch buffer, in a split next to the viewer. Each document has one such buffer,
--- named after the page it holds: `t` on another page fills it again, renames it and focuses its window.
---@param s PdfView.Session
local function show_text(s)
  with_page_text(s, function(lines, label)
    local buf
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[candidate].pdf_view_text_of == s.path then
        buf = candidate
      end
    end
    if not buf then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.b[buf].pdf_view_text_of = s.path
    end
    local old_name = vim.api.nvim_buf_get_name(buf)
    local name = ("pdf-view://%s (%s)"):format(vim.fn.fnamemodify(s.path, ":t"), label)
    if old_name ~= name and not pcall(vim.api.nvim_buf_set_name, buf, name) then
      -- another document of the same file name holds that name: the full path tells them apart
      pcall(vim.api.nvim_buf_set_name, buf, ("pdf-view://%s (%s)"):format(s.path, label))
    end
    if old_name ~= "" and old_name ~= vim.api.nvim_buf_get_name(buf) then
      -- renaming leaves an empty alternate buffer under the old name, as `:file` does
      for _, other in ipairs(vim.api.nvim_list_bufs()) do
        if other ~= buf and not vim.api.nvim_buf_is_loaded(other) and vim.api.nvim_buf_get_name(other) == old_name then
          vim.api.nvim_buf_delete(other, { force = true })
        end
      end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      vim.api.nvim_open_win(buf, true, { vertical = true, win = window_for(s) or 0 })
    end
  end)
end

--- Read the name of a mark after `m`, `'` or `` ` ``. Nil when the key is not one: <Esc> cancels quietly.
---@param allowed string Lua pattern of the names
---@return string?
local function read_mark(allowed)
  local ok, key = pcall(vim.fn.getcharstr)
  if not ok or key == "\27" then
    return nil
  end
  if not key:match("^" .. allowed .. "$") then
    notify(("`%s` is not a mark: use a to z"):format(vim.fn.keytrans(key)), vim.log.levels.WARN)
    return nil
  end
  return key
end

---@param s PdfView.Session
local function set_mark(s)
  local name = read_mark("%l")
  if name then
    s.marks[name] = here(s)
  end
end

--- Jump to mark a to z, or with `''` (or ``` `` ```) back to where the latest jump started.
---@param s PdfView.Session
local function goto_mark(s)
  local name = read_mark("[%l'`]")
  if not name then
    return
  end
  local where = s.marks[name == "`" and "'" or name]
  if not where then
    return notify(("mark `%s` is not set"):format(name), vim.log.levels.WARN)
  end
  record_jump(s)
  restore(s, where)
end

local ACTION_ORDER = {
  "down",
  "up",
  "right",
  "left",
  "scroll_down",
  "scroll_up",
  "scroll_right",
  "scroll_left",
  "next",
  "prev",
  "first",
  "last",
  "zoom_in",
  "zoom_out",
  "zoom_reset",
  "fit_width",
  "fit_height",
  "fit_content",
  "search",
  "search_back",
  "search_next",
  "search_prev",
  "search_clear",
  "search_list",
  "outline",
  "follow_link",
  "yank_text",
  "show_text",
  "jump_back",
  "jump_forward",
  "mark",
  "goto_mark",
  "inverse_search",
  "spread",
  "recolor",
  "reload",
  "close",
  "help",
}

---@type table<string, { desc: string, run: fun(s: PdfView.Session, lhs: string) }>
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

ACTIONS.scroll_down = {
  desc = "scroll down, or next page",
  run = function(s, lhs)
    wheel(s, 0, 1, lhs)
  end,
}

ACTIONS.scroll_up = {
  desc = "scroll up, or previous page",
  run = function(s, lhs)
    wheel(s, 0, -1, lhs)
  end,
}

ACTIONS.scroll_right = {
  desc = "scroll right, or next page",
  run = function(s, lhs)
    wheel(s, 1, 0, lhs)
  end,
}

ACTIONS.scroll_left = {
  desc = "scroll left, or previous page",
  run = function(s, lhs)
    wheel(s, -1, 0, lhs)
  end,
}

ACTIONS.next = {
  desc = "next page ({count} pages ahead)",
  run = function(s)
    go(s, session.spread_step(s, s.target or s.page, vim.v.count1), TOP)
  end,
}

ACTIONS.prev = {
  desc = "previous page ({count} pages back)",
  run = function(s)
    go(s, session.spread_step(s, s.target or s.page, -vim.v.count1), TOP)
  end,
}

ACTIONS.first = {
  desc = "first page, or page {count}",
  run = function(s)
    go(s, vim.v.count > 0 and vim.v.count or 1, TOP, true)
  end,
}

ACTIONS.last = {
  desc = "last page, or page {count}",
  run = function(s)
    go(s, vim.v.count > 0 and vim.v.count or math.huge, TOP, true)
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

ACTIONS.fit_content = {
  desc = "fit the page's content to the window, without its margins",
  run = function(s)
    set_mode(s, "content")
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

ACTIONS.search_list = {
  desc = "list the matches of the search, with their text, and go to one",
  run = pick_match,
}

ACTIONS.outline = {
  desc = "jump to a bookmark",
  run = pick_outline,
}

ACTIONS.follow_link = {
  desc = "pick a link on the page and follow it",
  run = follow_link,
}

ACTIONS.yank_text = {
  desc = "yank the page's text (\"+y: to the clipboard)",
  run = yank_text,
}

ACTIONS.show_text = {
  desc = "show the page's text in a split",
  run = show_text,
}

ACTIONS.jump_back = {
  desc = "back to where the previous jump started ({count} jumps)",
  run = function(s)
    walk_jumps(s, -vim.v.count1)
  end,
}

ACTIONS.jump_forward = {
  desc = "forward in the jump list",
  run = function(s)
    walk_jumps(s, vim.v.count1)
  end,
}

ACTIONS.mark = {
  desc = "m{a-z}: mark the page, fit and zoom",
  run = set_mark,
}

ACTIONS.goto_mark = {
  desc = "'{a-z}: go to a mark; '' to where the latest jump started",
  run = goto_mark,
}

ACTIONS.inverse_search = {
  desc = "go to the TeX source of the point under the mouse (SyncTeX)",
  run = inverse_search,
}

ACTIONS.spread = {
  desc = "show facing pages side by side, or one page at a time",
  run = function(s)
    if session.spread_mode(s) ~= "off" then
      s.spread = "off"
    else
      local configured = config.options.spread
      s.spread = configured ~= "off" and configured or "on"
    end
    -- the spread that holds the page on screen; one page at a time, the page that was on the left
    s.target = session.spread_range(s, s.target or s.page, s.count)
    show(s, s.target)
  end,
}

ACTIONS.recolor = {
  desc = "recolour the pages, or stop (dark mode)",
  run = function(s)
    if session.recolor_mode(s) ~= "off" then
      s.recolor = "off"
    else
      local configured = config.options.recolor
      s.recolor = configured ~= "off" and configured or "invert"
    end
    show(s)
  end,
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

--- The direction of each wheel action, as `wheel` takes it.
local WHEEL = { scroll_down = { 0, 1 }, scroll_up = { 0, -1 }, scroll_right = { 1, 0 }, scroll_left = { -1, 0 } }

--- The global wheel mappings that `set_global_wheel` made, to remove them again.
---@type { mode: string, lhs: string, callback: function }[]
local global_wheel = {}

--- The global (not buffer-local) mapping of `lhs` in `mode`, if there is one.
---@param mode string
---@param lhs string
---@return table?
local function global_mapping(mode, lhs)
  local raw = vim.keycode(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if map.lhsraw == raw or map.lhsrawalt == raw then
      return map
    end
  end
end

--- While a viewer is open, map the wheel keys of the `scroll_*` actions globally, in normal and insert mode, so the
--- wheel over a viewer moves it while the cursor is in another window (the TeX or Typst source beside its PDF). Over
--- other windows the key is passed on unmapped. A key the user has mapped globally is left alone, and only keys of
--- the wheel itself are mapped. The mappings are removed when the last viewer closes.
local function set_global_wheel()
  for _, done in ipairs(global_wheel) do
    local map = global_mapping(done.mode, done.lhs)
    if map and map.callback == done.callback then -- not replaced by the user's own mapping since
      pcall(vim.keymap.del, done.mode, done.lhs)
    end
  end
  global_wheel = {}
  local keymaps = config.options.keymaps
  if not keymaps or next(session.sessions) == nil then
    return
  end
  for action, dir in pairs(WHEEL) do
    for _, lhs in ipairs(keymaps[action] or {}) do
      if lhs:lower():find("scrollwheel", 1, true) then
        for _, mode in ipairs({ "n", "i" }) do
          if not global_mapping(mode, lhs) then
            local function callback()
              wheel(nil, dir[1], dir[2], lhs)
            end
            local desc = "PDF: " .. ACTIONS[action].desc .. " in the viewer under the mouse"
            vim.keymap.set(mode, lhs, callback, { silent = true, desc = desc })
            global_wheel[#global_wheel + 1] = { mode = mode, lhs = lhs, callback = callback }
          end
        end
      end
    end
  end
end

--- Map the keys of `config.options.keymaps` in the viewer's buffer, replacing the ones mapped before (`setup()` may
--- have changed them since), and the global wheel keys.
---@param s PdfView.Session
local function set_keymaps(s)
  for _, lhs in ipairs(s.mapped or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = s.buf })
  end
  s.mapped = {}
  local keymaps = config.options.keymaps
  if not keymaps then
    return set_global_wheel()
  end
  for action, keys in pairs(keymaps) do
    for _, lhs in ipairs(keys) do
      vim.keymap.set("n", lhs, function()
        ACTIONS[action].run(s, lhs)
      end, { buffer = s.buf, nowait = true, silent = true, desc = "PDF: " .. ACTIONS[action].desc })
      s.mapped[#s.mapped + 1] = lhs
    end
  end
  set_global_wheel()
end

M.rescan = rescan
-- a reflowable document laid out again has its matches on other pages
render.on_reflow = rescan
M.set_keymaps = set_keymaps
M.set_global_wheel = set_global_wheel

return M
