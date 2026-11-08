--- Showing a page: ask mutool for its size, render the page (or the part of it that is on screen), hand the PNG
--- to the terminal and redraw the placeholder cells, then render the pages next to it ahead of time. Always
--- latest-wins: every request bumps `session.gen`, and results from older generations are dropped.
local config = require("pdf-view.config")
local kitty = require("pdf-view.kitty")
local layout = require("pdf-view.layout")
local mupdf = require("pdf-view.mupdf")
local placeholder = require("pdf-view.placeholder")
local positioned = require("pdf-view.positioned")
local search = require("pdf-view.search")
local session = require("pdf-view.session")
local terminal = require("pdf-view.terminal")

local M = {}

local uv = vim.uv
local ns, augroup, sessions = session.ns, session.augroup, session.sessions
local define_highlight = session.define_highlight
local match_colors = session.match_colors
local recolor_spec = session.recolor_spec
local stamp_of = session.stamp_of
local layout_key = session.layout_key
local write_buffer = session.write_buffer
local remember = session.remember
local known_info, remember_info = session.known_info, session.remember_info
local window_for = session.window_for
local text_area = session.text_area
local uses_viewport = session.uses_viewport
local update_winbar = session.update_winbar
local apply_window_options = session.apply_window_options
local display_message = session.display_message

local RELOAD_RETRY_DELAY = 300
local RESIZE_DELAY = 60
local png_counter = 0
local image_counter = 0

--- Which of the session's image ids to show `png` with, and whether the terminal already holds it there. The id on
--- screen is never chosen, so the page on screen stays until the next one is placed. In zellij the pages alternate
--- between two ids and are always sent; elsewhere the terminal keeps the latest pages, and the least recently shown
--- one makes room.
---@param s PdfView.Session
---@param png string
---@return integer slot, boolean held
local function choose_image(s, png)
  if terminal.placement() == "positioned" then
    return s.slot == 1 and 2 or 1, false
  end
  local on_screen = s.ids[s.slot]
  local oldest
  for slot, id in ipairs(s.ids) do
    if id ~= on_screen then
      if s.images[id] == png then
        return slot, true
      end
      if not oldest or (s.image_used[id] or 0) < (s.image_used[s.ids[oldest]] or 0) then
        oldest = slot
      end
    end
  end
  return oldest, false
end

--- Neovim's own temp dir, which it removes on exit. Asked for every time: when a cleaner has deleted the directory
--- under a long-running Neovim, `tempname()` makes a new one.
---@return string
local function temp_dir()
  return vim.fs.dirname(vim.fn.tempname())
end

---@param s PdfView.Session
---@param win integer
---@param png string
---@param info PdfView.PageInfo
---@param fit PdfView.Fit|PdfView.Viewport how the image maps onto cells; a viewport also records where it is looking
---@param rows integer window height the fit was computed for
local function present(s, win, png, info, fit, rows)
  if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == s.buf) then
    return
  end

  local slot, held = choose_image(s, png)
  local id = s.ids[slot]
  if held then
    kitty.send(kitty.unplace(id)) -- the terminal still has the page: only its placement is made again
  elseif not terminal.printed() then -- an iTerm2 or sixel image is sent as it is printed (see `positioned`)
    local sent, commands = pcall(kitty.transmit, id, png, terminal.transmission())
    if not sent then
      return display_message(s, win, "pdf-view: " .. tostring(commands))
    end
    kitty.send(kitty.delete(id)) -- drop the page this id held before
    kitty.send(commands)
    -- zellij forgets an image once nothing shows it, so only a terminal with placeholders keeps pages for later
    s.images[id] = terminal.placement() ~= "positioned" and png or nil
  end
  image_counter = image_counter + 1
  s.image_used[id] = image_counter
  s.win = win

  if terminal.placement() == "positioned" then
    -- the buffer is blank, as tall as the window; the image is placed over it
    local grid_key = "positioned:" .. rows
    if s.grid_key ~= grid_key then
      s.grid, s.grid_key = nil, grid_key
      local lines = {}
      for index = 1, rows do
        lines[index] = ""
      end
      write_buffer(s, lines)
    end
    vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
    -- zellij gives a pane the pixel size of its cells, so a page drawn for that size needs no scaling
    local cell = terminal.cell_size()
    local exact = cell.source == "ioctl"
      and math.abs(fit.width - fit.cols * cell.w) < 0.5
      and math.abs(fit.height - fit.rows * cell.h) < 0.5
    positioned.show(s, {
      id = id,
      path = png,
      cols = fit.cols,
      rows = fit.rows,
      width = fit.width,
      height = fit.height,
      row = fit.pad_top,
      col = fit.pad_left,
      exact = exact,
    })
  else
    kitty.send(kitty.place(id, fit.cols, fit.rows))
    define_highlight(id)

    local grid_key = table.concat({ fit.cols, fit.rows, fit.pad_left, fit.pad_top, rows }, "x")
    if s.grid_key ~= grid_key then
      s.grid = placeholder.build(fit.cols, fit.rows, fit.pad_left, fit.pad_top, rows)
      s.grid_key = grid_key
      write_buffer(s, s.grid.lines)
    end
    local grid = s.grid --[[@as PdfView.Placeholders]]
    vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(s.buf, ns, grid.row, grid.col, {
      end_row = grid.end_row,
      end_col = grid.end_col,
      hl_group = "PdfViewImage" .. id,
    })
  end

  s.slot, s.page, s.count, s.target = slot, info.page, info.count, nil
  s.last, s.parts = info.last or info.page, info.parts
  s.laid_out = info.layout and { key = table.concat(info.layout, "x"), size = info.layout } or nil
  s.geom = { w = info.width, h = info.height, box = info.content }
  s.fit = fit
  if fit.cx then
    s.cx, s.cy = fit.cx, fit.cy -- what was reachable, after clamping to the page
  end
  update_winbar(s, win)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

--- The highlights drawn onto page `page` of `s`: its search matches, and where a forward search landed.
---@param s PdfView.Session
---@param page integer
---@return string? highlights as `worker.js` takes them, nil for none
---@return string key changes whenever the highlights would, for render caches
local function page_highlights(s, page)
  local highlights, highlights_key = nil, ""
  local colors = match_colors()
  if s.search then
    highlights, highlights_key = search.highlights(s.search, page, colors)
  end
  local synced = s.synced
  if synced and synced.page == page then
    -- where a forward search landed, in the colour of the current match
    local parts = { highlights }
    for _, rect in ipairs(synced.rects) do
      parts[#parts + 1] = ("%.2f,%.2f,%.2f,%.2f,%s"):format(rect[1], rect[2], rect[3], rect[4], colors.current)
    end
    highlights = table.concat(parts, ";")
    highlights_key = ("%s:sync%d:%s"):format(highlights_key, synced.id, colors.current)
  end
  return highlights, highlights_key
end

--- How the pages of a spread are drawn into an image of `width` x `height` pixels that shows the sheet scaled by
--- (`scale_x`, `scale_y`) from its pixel (`x`, `y`) on: the parts of the render, and their cache key.
---@param s PdfView.Session
---@param info PdfView.PageInfo a sheet, with `parts`
---@return PdfView.SheetPart[] parts, string key
local function sheet_parts(s, info, scale_x, scale_y, x, y, width, height)
  local parts, keys = {}, {}
  for _, part in ipairs(info.parts) do
    local dx, dy = part.x * scale_x - x, part.y * scale_y - y
    local clip = {
      math.max(0, dx),
      math.max(0, dy),
      math.min(width, dx + part.width * scale_x),
      math.min(height, dy + part.height * scale_y),
    }
    if clip[3] > clip[1] and clip[4] > clip[2] then -- not scrolled out of view
      local highlights, highlights_key = page_highlights(s, part.page)
      parts[#parts + 1] = {
        page = part.page,
        scale_x = scale_x,
        scale_y = scale_y,
        dx = dx,
        dy = dy,
        clip = clip,
        highlights = highlights,
      }
      keys[#keys + 1] = part.page .. "=" .. highlights_key
    end
  end
  return parts, table.concat(keys, ",")
end

--- How page `info` is drawn into a window of `cols` x `rows` cells, with the centre of a zoomed view at (`cx`, `cy`):
--- how the image maps onto cells, the render cache key, and the render. `info` may be a sheet of facing pages
--- (`layout.sheet()`), which is drawn as one page.
---@param s PdfView.Session
---@param info PdfView.PageInfo
---@param stamp string
---@param cols integer
---@param rows integer
---@param cell { w: number, h: number }
---@param cx number
---@param cy number
---@return PdfView.Fit|PdfView.Viewport fit
---@return string cache_key
---@return fun(out: string, cb: fun(err?: string)): PdfView.Job render
local function plan(s, info, stamp, cols, rows, cell, cx, cy)
  local recolor = recolor_spec(s)

  -- A whole fitted page is stretched to its cells. A zoomed or width/height-fitted page renders just the part that is
  -- on screen. Highlights are drawn by the same render.
  if uses_viewport(s) then
    local view =
      layout.viewport(info.width, info.height, cols, rows, cell.w, cell.h, s.zoom, cx, cy, s.mode, info.content)
    if info.parts then
      local parts, parts_key = sheet_parts(s, info, view.scale, view.scale, view.x, view.y, view.width, view.height)
      local cache_key = table.concat(
        { stamp, "sheet", ("%.5f"):format(view.scale), view.x, view.y, view.width, view.height, parts_key, recolor },
        ":"
      )
      return view,
        cache_key,
        function(out, cb)
          return mupdf.render_sheet(s.path, view.width, view.height, parts, out, cb, recolor)
        end
    end
    local highlights, highlights_key = page_highlights(s, info.page)
    local cache_key = table.concat({
      stamp,
      info.page,
      ("%.5f"):format(view.scale),
      view.x,
      view.y,
      view.width,
      view.height,
      highlights_key,
      recolor,
    }, ":")
    return view,
      cache_key,
      function(out, cb)
        local clip = {
          scale_x = view.scale,
          scale_y = view.scale,
          x = view.x,
          y = view.y,
          width = view.width,
          height = view.height,
          highlights = highlights,
          recolor = recolor,
        }
        return mupdf.render_clip(s.path, info.page, clip, out, cb)
      end
  end

  local fit = layout.fit(info.width, info.height, cols, rows, cell.w, cell.h, config.options.max_pixels)
  if info.parts then
    local parts, parts_key =
      sheet_parts(s, info, fit.width / info.width, fit.height / info.height, 0, 0, fit.width, fit.height)
    local cache_key = table.concat({ stamp, "sheet", fit.width, fit.height, parts_key, recolor }, ":")
    return fit,
      cache_key,
      function(out, cb)
        return mupdf.render_sheet(s.path, fit.width, fit.height, parts, out, cb, recolor)
      end
  end
  local highlights, highlights_key = page_highlights(s, info.page)
  local cache_key = table.concat({ stamp, info.page, fit.width, fit.height, highlights_key, recolor }, ":")
  return fit,
    cache_key,
    function(out, cb)
      if highlights then
        local clip = {
          scale_x = fit.width / info.width,
          scale_y = fit.height / info.height,
          x = 0,
          y = 0,
          width = fit.width,
          height = fit.height,
          highlights = highlights,
          recolor = recolor,
        }
        return mupdf.render_clip(s.path, info.page, clip, out, cb)
      end
      return mupdf.render(s.path, info.page, fit.width, fit.height, out, cb, recolor)
    end
end

--- The pages `first` to `last` as one sheet (`layout.sheet()`), with their geometry read from the file where it is
--- not known yet. `track` is handed each request to mutool, to stop it with.
---@param s PdfView.Session
---@param stamp string
---@param first integer
---@param last integer
---@param content boolean whether the part of the pages with content on it is needed
---@param track fun(job: PdfView.Job)
---@param cb fun(err?: string, sheet?: PdfView.PageInfo)
local function sheet_of(s, stamp, first, last, content, track, cb)
  local infos = {}
  local function step(page)
    if page > last then
      return cb(nil, layout.sheet(infos, session.SPREAD_GAP))
    end
    local known = known_info(s, stamp, page)
    if known and known.page == page and (known.content or not content) then
      infos[#infos + 1] = known
      return step(page + 1)
    end
    track(mupdf.info(s.path, page, function(err, info)
      if err or not info then
        return cb(err or "mutool returned no page information")
      end
      if not s.closed then
        remember_info(s, stamp, info)
      end
      infos[#infos + 1] = info
      step(page + 1)
    end, content))
  end
  step(first)
end

--- Render into the render cache under `key`, calling `done` and whoever waits on `s.rendering[key]` when it is done.
---@param s PdfView.Session
---@param key string
---@param render fun(out: string, cb: fun(err?: string)): PdfView.Job
---@param done fun(err?: string, png?: string)
---@return PdfView.Job
local function start_render(s, key, render, done)
  png_counter = png_counter + 1
  local out = ("%s/pdf-view-%d-%d.png"):format(temp_dir(), s.buf, png_counter)
  local entry = { waiters = { done } }
  s.rendering[key] = entry
  local job = render(out, function(err)
    if s.rendering[key] == entry then
      s.rendering[key] = nil
    end
    if err or s.closed then
      os.remove(out) -- a failed render can leave an empty file behind
    else
      remember(s, key, out)
    end
    for _, waiter in ipairs(entry.waiters) do
      waiter(err or (s.closed and "closed" or nil), out)
    end
  end)
  return {
    --- A render the worker is busy with may be left to finish (see `mupdf`): it is still kept in the render cache,
    --- and `done` is still called. One that is stopped is no longer waited on.
    kill = function()
      if job:kill(15) and s.rendering[key] == entry then
        s.rendering[key] = nil -- nobody else may wait on it now
      end
    end,
  }
end

-- the pages drawn ahead of time after a page is shown: the next one first, starting at its top as a page turn
-- does, then the previous one, at its bottom
local NEIGHBOURS = { { 1, 0 }, { -1, 1 } }

--- Render the pages next to the one on screen into the render cache, one after the other, so that turning to them
--- shows them at once. A newer `show()` stops this before it asks for anything (`s.prefetch.stopped`); what is being
--- rendered then is still finished and kept, and `show()` waits for it when it wants that page.
---@param s PdfView.Session
---@param stamp string
---@param cols integer
---@param rows integer
---@param cell { w: number, h: number }
local function prefetch(s, stamp, cols, rows, cell)
  local run = { stopped = false }
  s.prefetch = run
  local todo = {}
  for _, neighbour in ipairs(NEIGHBOURS) do
    local page = session.spread_step(s, s.page, neighbour[1])
    if page >= 1 and page <= (s.count or 0) and page ~= s.page then
      todo[#todo + 1] = { page = page, cy = neighbour[2] }
    end
  end
  local content = s.mode == "content"

  local function step()
    local next_page = table.remove(todo, 1)
    if run.stopped or s.closed or not next_page then
      if s.prefetch == run then
        s.prefetch = nil
      end
      return
    end
    -- the geometry is kept even when stopped meanwhile: it is read once
    local first, last = session.spread_range(s, next_page.page, s.count)
    sheet_of(s, stamp, first, last, content, function() end, function(err, info)
      if run.stopped or s.closed or err or not info then
        return step()
      end
      local _, key, render = plan(s, info, stamp, cols, rows, cell, s.cx, next_page.cy)
      local cached = s.cache[key]
      if s.rendering[key] or (cached and uv.fs_stat(cached)) then
        return step()
      end
      start_render(s, key, render, function()
        step()
      end)
    end)
  end
  step()
end

--- Ask for the password of a password-protected document, which mutool would not open without one (`why` is
--- "missing") or with the one it was given ("wrong"), and call `retry` with it set. Cancelling the prompt, or an
--- empty answer, leaves a message in the window instead, which stays there without asking again until `reload`.
---@param s PdfView.Session
---@param win integer
---@param why "missing"|"wrong"
---@param retry fun()
local function unlock(s, win, why, retry)
  if s.unlocking then
    return -- the prompt is open already, and shows the page again once it is answered
  end
  local name = vim.fn.fnamemodify(s.path, ":t")
  local message = ("pdf-view: %s is password-protected. :edit to enter the password"):format(name)
  if s.locked then
    return display_message(s, win, message)
  end
  local prompt = why == "wrong" and ("Wrong password for %s, try again: "):format(name)
    or ("Password for %s: "):format(name)
  s.unlocking = true
  local ok, password = pcall(vim.fn.inputsecret, prompt)
  s.unlocking = false
  -- clear the prompt from the command line: it would stay there until something else is shown
  vim.api.nvim_echo({ { "" } }, false, {})
  if s.closed then
    return
  end
  if not ok or password == "" then
    mupdf.set_password(s.path, nil) -- a wrong one is not tried again on :edit
    s.locked = true
    return display_message(s, win, message)
  end
  mupdf.set_password(s.path, password)
  retry()
end

--- In a terminal that cannot show pages: `reason` in the window, and under it the text of the page, which the page
--- keys turn like pages. A document is still readable over a plain SSH session.
---@param s PdfView.Session
---@param win integer
---@param page? integer
---@param reason string
local function show_text_instead(s, win, page, reason)
  s.gen = s.gen + 1
  local gen = s.gen
  if s.job then
    s.job:kill(15)
    s.job = nil
  end
  if s.page_text ~= reason then
    display_message(s, win, reason) -- until the text is read, and for good when it cannot be
  end
  local function shown_here()
    return gen == s.gen and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == s.buf
  end
  s.job = mupdf.info(s.path, page or s.target or s.page, function(err, info)
    if gen ~= s.gen then
      return
    end
    s.job = nil
    if err or not info then
      return display_message(s, win, reason)
    end
    s.job = mupdf.text(s.path, info.page, function(text_err, text)
      if gen ~= s.gen then
        return
      end
      s.job = nil
      if text_err or not shown_here() then
        return display_message(s, win, reason)
      end
      text = vim.trim(text or "")
      display_message(s, win, reason .. "\n\n" .. (text ~= "" and text or "(no text on this page)"))
      s.page_text = reason
      s.page, s.count, s.target = info.page, info.count, nil
      update_winbar(s, win)
    end)
  end)
end

---@param s PdfView.Session
---@param page? integer defaults to the current page
---@param opts? { retries?: integer, keep?: boolean, asked?: boolean } `retries`: attempts left after a failure; `keep`: on
--- failure leave the old page on screen; `asked`: the terminal was just asked what it can draw
local function show(s, page, opts)
  opts = opts or {}
  if s.closed then
    return
  end

  if not terminal.ui_attached() then
    -- loading a file given on the command line happens before the TUI attaches
    if not s.waiting_for_ui then
      s.waiting_for_ui = true
      vim.api.nvim_create_autocmd("UIEnter", {
        group = augroup,
        once = true,
        callback = function()
          s.waiting_for_ui = false
          show(s, page, opts)
        end,
      })
    end
    return
  end

  local win = window_for(s)
  if not win then
    return
  end
  s.win = win
  apply_window_options(s, win)

  local supported, reason = terminal.check()
  if supported == nil and opts.asked then
    -- asked already, and the answer did not settle it: do not ask again and again
    supported, reason =
      false,
      "pdf-view: the terminal's answers do not tell whether it can show pages. "
        .. "Set `protocol` or `force = true` in setup()."
  end
  if supported == nil then
    -- the terminal is asked what it draws (see `terminal.ask()`); the latest page asked for meanwhile is shown then
    local first = not s.waiting_for_terminal
    s.waiting_for_terminal = { page = page, opts = opts }
    if first then
      terminal.ask(function()
        local latest = s.waiting_for_terminal
        s.waiting_for_terminal = nil
        if latest then
          show(s, latest.page, vim.tbl_extend("force", latest.opts, { asked = true }))
        end
      end)
    end
    return
  end
  if not supported then
    return show_text_instead(s, win, page, reason --[[@as string]])
  end
  s.page_text = nil
  terminal.prepare()

  s.gen = s.gen + 1
  local gen = s.gen
  if s.job then
    s.job:kill(15)
    s.job = nil
  end
  if s.prefetch then
    s.prefetch.stopped = true -- what it is rendering now is kept; it asks for nothing more
    s.prefetch = nil
  end

  local cols, rows = text_area(win)
  local cell = terminal.cell_size()
  local key = layout_key(cols, rows, cell)
  -- a reflowable document is laid out to fill the window; other documents ignore this
  local reflow = layout.reflow(cols, rows, cell.w, cell.h, config.options.text_scale)
  local reflow_key = table.concat(reflow, "x")
  mupdf.set_layout(s.path, reflow)

  local function fail(message)
    if gen ~= s.gen then
      return
    end
    local locked = mupdf.password_error(message)
    if locked then
      return unlock(s, win, locked, function()
        show(s, page, opts)
      end)
    end
    if (opts.retries or 0) > 0 then
      -- most likely a PDF that is still being written
      vim.defer_fn(function()
        if gen == s.gen then
          show(s, page, { retries = opts.retries - 1, keep = opts.keep })
        end
      end, RELOAD_RETRY_DELAY)
    elseif opts.keep then
      vim.notify("pdf-view: " .. message, vim.log.levels.WARN)
    else
      display_message(s, win, "pdf-view: " .. message)
    end
  end

  local stat = uv.fs_stat(s.path)
  if not stat then
    return fail("file not found: " .. s.path)
  end
  -- what the page geometry and the renders are kept under: the file, and the layout of a reflowable one
  local stamp = stamp_of(stat)
  s.requested_key, s.requested_stamp = key, stamp
  if s.reflowable then
    stamp = stamp .. "@" .. reflow_key
  end

  local draw

  ---@param err? string
  ---@param info? PdfView.PageInfo
  local function on_info(err, info)
    if gen ~= s.gen then
      return
    end
    s.job = nil
    if err or not info then
      return fail(err or "mutool returned no page information")
    end
    if info.reflowable then
      if not s.reflowable then
        s.reflowable = true
        stamp = stamp .. "@" .. reflow_key
      end
      info.layout = reflow
    end
    remember_info(s, stamp, info)
    local first, last = session.spread_range(s, info.page, info.count)
    if first ~= info.page or last ~= info.page then
      -- facing pages: the spread that holds the page, drawn as one
      return sheet_of(s, stamp, first, last, s.mode == "content", function(job)
        s.job = job
      end, function(sheet_err, sheet)
        if gen ~= s.gen then
          return
        end
        s.job = nil
        if sheet_err or not sheet then
          return fail(sheet_err or "mutool returned no page information")
        end
        draw(sheet)
      end)
    end
    draw(info)
  end

  ---@param info PdfView.PageInfo
  draw = function(info)
    local fit, cache_key, render = plan(s, info, stamp, cols, rows, cell, s.cx, s.cy)

    local function shown(png)
      present(s, win, png, info, fit, rows)
      if s.page == info.page and not s.closed then
        prefetch(s, stamp, cols, rows, cell)
      end
    end

    ---@param render_err? string
    ---@param png? string
    local function rendered(render_err, png)
      if gen ~= s.gen then
        return
      end
      s.job = nil
      if render_err then
        return fail(render_err)
      end
      shown(png)
    end

    local cached = s.cache[cache_key]
    if cached and uv.fs_stat(cached) then
      return shown(cached)
    end

    local pending = s.rendering[cache_key]
    if pending then
      -- the page is being drawn ahead of time: wait for that
      local waiters = pending.waiters
      waiters[#waiters + 1] = rendered
      s.job = {
        kill = function()
          for index, waiter in ipairs(waiters) do
            if waiter == rendered then
              table.remove(waiters, index)
              break
            end
          end
        end,
      }
      return
    end

    s.job = start_render(s, cache_key, render, rendered)
  end

  -- a page's geometry only changes with the file, so mutool is asked for it once, and for where its content is
  -- the first time that is needed
  local wanted = page or s.target or s.page
  local content = s.mode == "content"
  -- a reflowable document laid out again has other pages: stay at the same point of the text
  local laid_out = s.laid_out
  if s.reflowable and not page and laid_out and laid_out.key ~= reflow_key then
    M.on_reflow(s)
    s.job = mupdf.info(s.path, wanted, on_info, content, laid_out.size)
    return
  end
  local known = known_info(s, stamp, wanted)
  if known and (known.content or not content) then
    return on_info(nil, known)
  end
  s.job = mupdf.info(s.path, wanted, on_info, content)
end

--- Show the page again if the window changed size or the file changed on disk since it was last rendered.
---@param s PdfView.Session
local function relayout(s)
  if s.closed then
    return
  end
  local win = window_for(s)
  if not win then
    return
  end
  local cols, rows = text_area(win)
  local key = layout_key(cols, rows, terminal.cell_size())
  local stat = uv.fs_stat(s.path)
  if key ~= s.requested_key or (stat and stamp_of(stat) ~= s.requested_stamp) then
    show(s)
  end
end

local resize_pending = false

local function schedule_relayout()
  if resize_pending or next(sessions) == nil then
    return
  end
  resize_pending = true
  vim.defer_fn(function()
    resize_pending = false
    for _, s in pairs(sessions) do
      relayout(s)
    end
  end, RESIZE_DELAY)
end

---@diagnostic disable-next-line: duplicate-set-field (a hook the module leaves empty)
positioned.rerender = function(s)
  show(s)
end

-- pages already sent by path never showed: send them again, now as bytes
---@diagnostic disable-next-line: duplicate-set-field (a hook the module leaves empty)
terminal.on_fallback = function()
  for _, s in pairs(sessions) do
    s.images = {}
    show(s)
  end
end

-- tmux was attached from another terminal, which has none of the pages: send them again, from the render cache
---@diagnostic disable-next-line: duplicate-set-field (a hook the module leaves empty)
terminal.on_reattach = function()
  for _, s in pairs(sessions) do
    s.images = {}
    s.requested_key = nil -- a viewer in no window is sent again when a window shows it (BufWinEnter)
    relayout(s)
  end
end

--- Called when a reflowable document is laid out again, which moves its text to other pages. `actions` searches
--- again here.
---@type fun(s: PdfView.Session)
M.on_reflow = function() end

M.show = show
M.relayout = relayout
M.schedule_relayout = schedule_relayout

return M
