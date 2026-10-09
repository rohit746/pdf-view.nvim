--- Showing a page: ask mutool for its size, render the page (or the part of it that is on screen), hand the PNG
--- to the terminal and redraw the placeholder cells. Always latest-wins: every request bumps `session.gen`, and
--- results from older generations are dropped.
local config = require("pdf-view.config")
local kitty = require("pdf-view.kitty")
local layout = require("pdf-view.layout")
local mupdf = require("pdf-view.mupdf")
local placeholder = require("pdf-view.placeholder")
local search = require("pdf-view.search")
local session = require("pdf-view.session")
local terminal = require("pdf-view.terminal")

local M = {}

local uv = vim.uv
local ns, augroup, sessions = session.ns, session.augroup, session.sessions
local define_highlight = session.define_highlight
local match_colors = session.match_colors
local stamp_of = session.stamp_of
local layout_key = session.layout_key
local write_buffer = session.write_buffer
local remember = session.remember
local window_for = session.window_for
local text_area = session.text_area
local uses_viewport = session.uses_viewport
local update_winbar = session.update_winbar
local apply_window_options = session.apply_window_options
local display_message = session.display_message

local RELOAD_RETRY_DELAY = 300
local RESIZE_DELAY = 60
local png_counter = 0
local tmpdir

---@return string
local function temp_dir()
  tmpdir = tmpdir or vim.fs.dirname(vim.fn.tempname()) -- Neovim removes its temp dir on exit
  return tmpdir
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

  local slot = s.slot == 1 and 2 or 1
  local id = s.ids[slot]
  local sent, commands = pcall(kitty.transmit, id, png, terminal.transmission())
  if not sent then
    return display_message(s, win, "pdf-view: " .. tostring(commands))
  end
  kitty.send(kitty.delete(id)) -- drop whatever this id held two pages ago
  kitty.send(commands)
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

  s.slot, s.page, s.count, s.target = slot, info.page, info.count, nil
  s.geom = { w = info.width, h = info.height }
  if fit.cx then
    s.cx, s.cy = fit.cx, fit.cy -- what was reachable, after clamping to the page
  end
  update_winbar(s, win)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

---@param s PdfView.Session
---@param page? integer defaults to the current page
---@param opts? { retries?: integer, keep?: boolean } `retries`: attempts left after a failure; `keep`: on failure leave the old page on screen
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
  if not supported then
    return display_message(s, win, reason --[[@as string]])
  end
  terminal.prepare()

  s.gen = s.gen + 1
  local gen = s.gen
  if s.job then
    s.job:kill(15)
    s.job = nil
  end

  local cols, rows = text_area(win)
  local cell = terminal.cell_size()
  local key = layout_key(cols, rows, cell)

  local function fail(message)
    if gen ~= s.gen then
      return
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
  local stamp = stamp_of(stat)
  s.requested_key, s.requested_stamp = key, stamp

  s.job = mupdf.info(s.path, page or s.target or s.page, function(err, info)
    if gen ~= s.gen then
      return
    end
    s.job = nil
    if err or not info then
      return fail(err or "mutool returned no page information")
    end

    local highlights, highlights_key = nil, ""
    if s.search then
      highlights, highlights_key = search.highlights(s.search, info.page, match_colors())
    end

    -- A whole fitted page is drawn by `mutool draw`, which is the fastest route. A zoomed or width/height-fitted
    -- page renders just the part that is on screen, and highlights are drawn by the same script.
    local fit, cache_key, render
    if uses_viewport(s) then
      local view = layout.viewport(info.width, info.height, cols, rows, cell.w, cell.h, s.zoom, s.cx, s.cy, s.mode)
      fit = view
      cache_key = table.concat({
        stamp,
        info.page,
        ("%.5f"):format(view.scale),
        view.x,
        view.y,
        view.width,
        view.height,
        highlights_key,
      }, ":")
      render = function(out, cb)
        local clip = {
          scale_x = view.scale,
          scale_y = view.scale,
          x = view.x,
          y = view.y,
          width = view.width,
          height = view.height,
          highlights = highlights,
        }
        return mupdf.render_clip(s.path, info.page, clip, out, cb)
      end
    else
      fit = layout.fit(info.width, info.height, cols, rows, cell.w, cell.h, config.options.max_pixels)
      cache_key = table.concat({ stamp, info.page, fit.width, fit.height, highlights_key }, ":")
      render = function(out, cb)
        if highlights then
          local clip = {
            scale_x = fit.width / info.width,
            scale_y = fit.height / info.height,
            x = 0,
            y = 0,
            width = fit.width,
            height = fit.height,
            highlights = highlights,
          }
          return mupdf.render_clip(s.path, info.page, clip, out, cb)
        end
        return mupdf.render(s.path, info.page, fit.width, fit.height, out, cb)
      end
    end

    local cached = s.cache[cache_key]
    if cached and uv.fs_stat(cached) then
      return present(s, win, cached, info, fit, rows)
    end

    png_counter = png_counter + 1
    local out = ("%s/pdf-view-%d-%d.png"):format(temp_dir(), s.buf, png_counter)
    s.job = render(out, function(render_err)
      if gen ~= s.gen then
        os.remove(out)
        return
      end
      s.job = nil
      if render_err then
        return fail(render_err)
      end
      remember(s, cache_key, out)
      present(s, win, out, info, fit, rows)
    end)
  end)
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

M.show = show
M.relayout = relayout
M.schedule_relayout = schedule_relayout

return M
