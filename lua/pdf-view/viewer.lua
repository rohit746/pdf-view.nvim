--- A PDF viewer is an ordinary buffer (named after the file) whose text is Kitty Unicode placeholders. This is
--- its lifecycle: becoming a viewer (`attach`, `read`, `open`), following the file on disk, and cleaning up.
--- Rendering is in `render`, the keys are in `actions`, the state is in `session`.
local actions = require("pdf-view.actions")
local config = require("pdf-view.config")
local cursor = require("pdf-view.cursor")
local kitty = require("pdf-view.kitty")
local mupdf = require("pdf-view.mupdf")
local positions = require("pdf-view.positions")
local render = require("pdf-view.render")
local rotation = require("pdf-view.rotation")
local session = require("pdf-view.session")
local terminal = require("pdf-view.terminal")
local watch = require("pdf-view.watch")

local M = {}

local uv = vim.uv
local show, relayout, schedule_relayout = render.show, render.relayout, render.schedule_relayout
local set_keymaps, rescan = actions.set_keymaps, actions.rescan
local augroup, sessions = session.augroup, session.sessions
local define_highlight, stamp_of, apply_window_options, allocate_ids, destroy =
  session.define_highlight, session.stamp_of, session.apply_window_options, session.allocate_ids, session.destroy
local reset_view = session.reset_view

local RELOAD_RETRIES = 8

--- Where the viewer of a buffer was when the buffer was unloaded, with its jump list and marks. `:edit` unloads a
--- buffer and reads it again, and this is what brings it back to the same page instead of the first one.
---@type table<integer, PdfView.Remembered|{ jumps?: PdfView.Position[], jump_index?: integer, marks?: table<string, PdfView.Position> }>
local resume = {}

--- Holds each viewer's own `BufReadCmd`, which outlives the session (`destroy` clears only `augroup`) so `:edit`
--- re-attaches the buffer even when `auto_open` is off and no `*.pdf` handler exists.
local reread = vim.api.nvim_create_augroup("PdfViewReread", { clear = true })

--- Buffers that are a window's own view of a PDF that another window shows (`separate`) are named
--- `pdf-view://{n}/{path}`. The file a viewer buffer shows: its name, or the path in such a name.
---@param buf integer
---@return string path, boolean own_view
local function file_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name:match("^pdf%-view://%d+/(.+)$")
  return path or name, path ~= nil
end

local own_views = 0 -- views made by `separate`, numbering their names
local entered = 0 -- buffer entries, for `PdfView.Session.entered`

--- The windows (not floating) that show the viewer `s`, and the one of them that keeps it when `separate` gives the
--- others views of their own: the window it was drawn in, else the current one, else the first.
---@param s PdfView.Session
---@return integer[] wins, integer? keep
local function shared_windows(s)
  local wins = {}
  for _, win in ipairs(s.closed and {} or vim.fn.win_findbuf(s.buf)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      wins[#wins + 1] = win
    end
  end
  local keep = s.win
  if not vim.tbl_contains(wins, keep) then
    local current = vim.api.nvim_get_current_win()
    keep = vim.tbl_contains(wins, current) and current or wins[1]
  end
  return wins, keep
end

--- Where the viewer `s` is, for `resume`: with the layout of an e-book, whose page numbers follow it.
---@param s PdfView.Session
---@return PdfView.Remembered
local function position(s)
  local size = s.reflowable and s.laid_out and s.laid_out.size or nil
  return {
    page = s.target or s.page,
    mode = s.mode,
    zoom = s.zoom,
    cx = s.cx,
    cy = s.cy,
    rotation = s.rotation,
    layout = size,
  }
end

--- What `resume` keeps of the viewer `s`: where it is, its jump list and its marks.
---@param s PdfView.Session
local function kept(s)
  return vim.tbl_extend("force", position(s), { jumps = s.jumps, jump_index = s.jump_index, marks = s.marks })
end

--- Remember where the viewer `s` is for `:edit`, and in the state file for the next Neovim.
---@param s PdfView.Session
local function leave(s)
  local where = position(s)
  resume[s.buf] = kept(s)
  -- a window's own view comes and goes with the window: the PDF's reading position is its viewer's
  if config.options.remember_position and not s.own_view then
    pcall(positions.set, s.path, where)
  end
end

M.sessions = sessions
M.reload = actions.reload

--- Milliseconds a viewer may be in no window before its mutool worker is stopped, which frees the parsed document.
--- Long enough that flipping between buffers does not start it again and again. The next request starts another.
M.stop_worker_after = 30000

--- Forget the pending stop of the worker of `s`.
---@param s PdfView.Session
local function keep_worker(s)
  if s.worker_timer then
    s.worker_timer:stop()
    s.worker_timer:close()
    s.worker_timer = nil
  end
end

--- Stop the worker of `s` once it has been in no window for `M.stop_worker_after` milliseconds. A worker still busy
--- then (a page drawn ahead of time) is given as long again.
---@param s PdfView.Session
local function stop_worker_later(s)
  keep_worker(s)
  local timer = uv.new_timer()
  if not timer then
    return
  end
  s.worker_timer = timer
  timer:start(
    M.stop_worker_after,
    0,
    vim.schedule_wrap(function()
      if s.worker_timer ~= timer then
        return -- shown again, or closed, meanwhile
      end
      keep_worker(s)
      if s.closed or #vim.fn.win_findbuf(s.buf) > 0 or session.shares_file(s, true) then
        return -- a window's own view of the file keeps the worker it shares busy
      end
      if mupdf.stop_idle(s.path) then
        stop_worker_later(s)
      end
    end)
  )
end

--- Show the new version of the file of `s`, which live reload or a re-fit of the page (whichever comes first) found
--- changed on disk.
---@param s PdfView.Session
local function on_file_changed(s)
  if s.closed then
    return
  end
  local stat = uv.fs_stat(s.path)
  if not stat or stamp_of(stat) == s.requested_stamp then
    return
  end
  s.synced = nil -- a forward search into the old build may highlight other text in this one
  show(s, nil, { retries = RELOAD_RETRIES, keep = true })
  rescan(s)
end
render.on_file_changed = on_file_changed

local global_autocmds = false
local warned_unwatched = false -- the notice that live reload could not be set up is shown once

--- Watch the file of `s` as `config.options` says, replacing the watcher it had.
---@param s PdfView.Session
local function start_watcher(s)
  if s.watcher then
    s.watcher.stop()
    s.watcher = nil
  end
  if not config.options.live_reload then
    return
  end
  s.watcher = watch.start(s.path, config.options.reload_delay, function()
    on_file_changed(s)
  end)
  if not s.watcher and not warned_unwatched then
    warned_unwatched = true
    vim.notify(
      ("pdf-view: live reload is off: cannot watch `%s` for changes: reload it with :edit"):format(s.path),
      vim.log.levels.WARN
    )
  end
end

local function set_global_autocmds()
  if global_autocmds then
    return
  end
  global_autocmds = true
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter", "WinEnter" }, {
    group = augroup,
    desc = "Re-fit PDF pages to their window",
    callback = schedule_relayout,
  })
  vim.api.nvim_create_autocmd("WinNew", {
    group = augroup,
    desc = "Give a new window on a PDF viewer a view of its own",
    callback = function()
      M.schedule_separate()
    end,
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "UIEnter" }, {
    group = augroup,
    desc = "Send PDF pages again when tmux is attached from another terminal",
    callback = function()
      terminal.check_client()
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    desc = "Keep PDF pages from being scrolled out of their window",
    callback = function()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local s = sessions[vim.api.nvim_win_get_buf(win)]
        if s and not s.page_text then -- the text shown instead of a page is scrolled like any text
          reset_view(win)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    desc = "Forget where a wiped PDF viewer was",
    callback = function(args)
      resume[args.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    desc = "Restore PDF image highlights, and recolour pages in the colorscheme's colours",
    callback = function()
      cursor.define()
      for _, s in pairs(sessions) do
        for _, id in ipairs(s.ids) do
          define_highlight(id)
        end
        if not s.closed and session.recolor_mode(s) == "colorscheme" then
          show(s) -- the new colours are part of the render cache key, so the page is drawn again
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    desc = "Free PDF images held by the terminal",
    callback = function()
      for _, s in pairs(sessions) do
        if not s.closed then
          leave(s)
        end
        destroy(s)
      end
    end,
  })
end

--- Turn buffer `buf` (named after a PDF) into a viewer. Safe to call twice.
---@param buf integer
---@return PdfView.Session
function M.attach(buf)
  if sessions[buf] then
    return sessions[buf]
  end

  local path, own_view = file_of(buf)
  local last = resume[buf] or (config.options.remember_position and positions.get(path)) or {}
  resume[buf] = nil

  ---@type PdfView.Session
  local s = {
    buf = buf,
    path = path,
    page = last.page or 1,
    mode = last.mode or "page",
    zoom = math.max(1, math.min(last.zoom or 1, config.options.max_zoom)),
    rotation = rotation.valid(last.rotation) and last.rotation or 0,
    cx = math.max(0, math.min(last.cx or 0.5, 1)),
    cy = math.max(0, math.min(last.cy or 0.5, 1)),
    jumps = last.jumps or {},
    jump_index = last.jump_index or 1,
    marks = last.marks or {},
    gen = 0,
    ids = allocate_ids(),
    slot = 0,
    images = {},
    image_used = {},
    rendering = {},
    cache = {},
    cache_order = {},
    own_view = own_view or nil,
    entered = 0,
    closed = false,
  }
  sessions[buf] = s
  if type(last.layout) == "table" then
    -- the page is one of an e-book laid out this way: the first `show` finds where its text is in the window's
    -- layout, as it does when the window is resized
    s.reflowable = true
    s.laid_out = { key = table.concat(last.layout, "x"), size = last.layout }
  end

  -- `nofile` stops Neovim from reading the PDF's bytes into the buffer and refuses `:w` over the original
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.swapfile = false
  -- a window's own view is not a buffer to switch to: it goes when its window closes or shows another buffer
  bo.bufhidden = own_view and "wipe" or "hide"
  if own_view then
    bo.buflisted = false
  end
  bo.undolevels = -1
  bo.modifiable = false
  bo.filetype = "pdf-view"

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    buffer = buf,
    desc = "Show the PDF page in the entered window",
    callback = function()
      keep_worker(s)
      local win = vim.api.nvim_get_current_win()
      local wins, keep = shared_windows(s)
      if #wins > 1 then
        M.schedule_separate()
        if win ~= keep and vim.tbl_contains(wins, win) then
          return -- on screen in another window already: this one gets a view of its own, and that one stays
        end
      end
      apply_window_options(s, win)
      relayout(s)
      if s.search_stale then
        rescan(s)
      end
    end,
  })
  -- The terminal drops the oldest images once it holds too many (kitty and Ghostty keep about 320 MB), and says
  -- nothing about it: a viewer in no window frees its images, and sends its page again when a window shows it.
  -- Its mutool worker is stopped a while later; the render cache keeps the pages it drew.
  vim.api.nvim_create_autocmd("BufHidden", {
    group = augroup,
    buffer = buf,
    desc = "Free the images and the mutool worker of a PDF viewer in no window",
    callback = function()
      vim.schedule(function() -- the buffer is still in its last window while this runs
        if s.closed or #vim.fn.win_findbuf(buf) > 0 then
          return
        end
        stop_worker_later(s)
        if terminal.placement() == "positioned" then
          return -- `positioned` takes a page away from a window that no longer shows it
        end
        for _, id in ipairs(s.ids) do
          if s.images[id] then
            kitty.send(kitty.delete(id))
          end
        end
        s.images, s.image_used = {}, {}
        s.requested_key = nil -- shown again on BufWinEnter
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = buf,
    desc = "Hide the cursor over the PDF page",
    callback = function()
      entered = entered + 1
      s.entered = entered
      cursor.hide(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = buf,
    desc = "Bring the cursor back outside the PDF viewer",
    callback = function()
      cursor.show(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = augroup,
    buffer = buf,
    desc = "Release a PDF viewer",
    callback = function(args)
      if args.event == "BufUnload" and not s.closed then
        leave(s)
      end
      destroy(s)
      actions.set_global_wheel() -- removed with the last viewer
    end,
  })

  -- the buffer's text is image placeholders: writing it to another file would make a `.pdf` of them
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = buf,
    desc = "Save a copy of the PDF",
    callback = function(args)
      M.save_copy(s, args.match)
    end,
  })
  vim.api.nvim_create_autocmd({ "FileWriteCmd", "FileAppendCmd" }, {
    group = augroup,
    buffer = buf,
    desc = "Refuse to write part of a PDF",
    callback = function()
      vim.notify("pdf-view: only the whole PDF can be written: use :w {file}", vim.log.levels.ERROR)
    end,
  })

  vim.api.nvim_clear_autocmds({ group = reread, buffer = buf })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = reread,
    buffer = buf,
    desc = "Re-attach the PDF viewer after :edit",
    callback = function()
      if not sessions[buf] then -- the `auto_open` handler may have re-attached it already
        M.read(buf)
      end
    end,
  })

  set_keymaps(s)
  set_global_autocmds()
  start_watcher(s)

  if vim.api.nvim_get_current_buf() == buf then
    cursor.hide(buf) -- BufEnter may already have fired for this buffer
    entered = entered + 1
    s.entered = entered
  end
  vim.schedule(function()
    relayout(s)
  end)
  return s
end

--- Bring the viewers that are open in line with `config.options` after `setup()`: their keys, live reload, winbar,
--- colours and cursor.
function M.apply_config()
  for _, s in pairs(sessions) do
    if not s.closed then
      set_keymaps(s)
      start_watcher(s)
      if not config.options.winbar then -- the winbar set while it was on would stay, and stop following the page
        for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
          vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = win })
        end
      end
      show(s) -- a new `recolor` (or `highlight` colours) is part of the render cache key, so the page is drawn again
    end
  end
  local buf = vim.api.nvim_get_current_buf()
  local focused = sessions[buf]
  if focused and not focused.closed then -- a changed `hide_cursor`: no BufEnter follows to apply it
    cursor.show()
    cursor.hide(buf)
  end
end

--- `BufWriteCmd` handler (`:w {file}`, `:saveas {file}`): copy the PDF to `target`. Neovim has already refused a
--- write over the PDF itself (E382) and over an existing file without `!` (E13).
---@param s PdfView.Session
---@param target string
function M.save_copy(s, target)
  local real = uv.fs_realpath(target)
  if not (real and real == uv.fs_realpath(s.path)) then -- a link to the PDF is already a copy of it
    local ok, err = uv.fs_copyfile(s.path, target)
    if not ok then
      return vim.notify(("pdf-view: cannot write `%s`: %s"):format(target, err), vim.log.levels.ERROR)
    end
  end
  vim.api.nvim_echo({ { ('"%s" written'):format(vim.fn.fnamemodify(target, ":~:.")) } }, false, {})
  if file_of(s.buf) ~= s.path then -- :saveas has renamed the buffer: view the copy
    resume[s.buf] = kept(s)
    destroy(s)
    M.attach(s.buf)
  end
end

--- `BufReadCmd` handler: take over local PDF files and leave everything else (new files, URLs) alone.
---@param buf integer
function M.read(buf)
  local stat = uv.fs_stat((file_of(buf)))
  if not stat or stat.type ~= "file" then
    return
  end
  local s = sessions[buf]
  if s then
    return M.reload(s)
  end
  M.attach(buf)
end

--- `SessionLoadPost` handler for a buffer that a session brought back in place of a viewer. `:mksession` does not
--- save a `nofile` buffer as a file: with `blank` in 'sessionoptions' it saves `enew | file {pdf}`, which brings back
--- an empty buffer named after the PDF, without `BufReadCmd`. Make it a viewer again.
---@param buf integer
function M.restore(buf)
  M.read(buf)
  local s = sessions[buf]
  if s then -- no BufWinEnter follows: the buffer is in its windows already
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      apply_window_options(s, win)
    end
  end
end

--- Show the PDF of the viewer `s` in window `win` with a view of its own: a buffer of its own, unlisted, that starts
--- where `s` is (page, fit, zoom, search, jump list and marks) and turns its pages on its own.
---@param s PdfView.Session
---@param win integer
local function give_own_view(s, win)
  own_views = own_views + 1
  local buf = vim.api.nvim_create_buf(false, true)
  if not pcall(vim.api.nvim_buf_set_name, buf, ("pdf-view://%d/%s"):format(own_views, s.path)) then
    return vim.api.nvim_buf_delete(buf, { force = true }) -- a buffer of that name exists: leave the window as it is
  end
  resume[buf] = vim.deepcopy(kept(s))
  local view = M.attach(buf)
  view.recolor, view.spread, view.scrolled, view.synced = s.recolor, s.spread, s.scrolled, s.synced
  view.count, view.reflowable, view.laid_out = s.count, s.reflowable, s.laid_out
  view.last_needle, view.locked = s.last_needle, s.locked
  if s.search then -- the same matches; the current one is the view's own
    view.search = vim.tbl_extend("force", {}, s.search)
  end
  if not pcall(vim.api.nvim_win_set_buf, win, buf) then -- 'winfixbuf': the window shows the same page
    vim.api.nvim_buf_delete(buf, { force = true })
    apply_window_options(s, win)
  end
end

--- Give each window that shows a viewer which another window shows too a view of its own (`give_own_view`), so that
--- the windows turn their pages each on its own. The window the viewer was drawn in keeps it. Floating windows (a
--- picker's preview) are left alone, and show the same page.
function M.separate()
  local separated = false
  local list = vim.tbl_values(sessions)
  for _, s in ipairs(list) do
    local wins, keep = shared_windows(s)
    if #wins > 1 then
      for _, win in ipairs(wins) do
        if win ~= keep then
          give_own_view(s, win)
          separated = true
        end
      end
    end
  end
  if not separated then
    return
  end
  -- a buffer switched in another window than the current one moved the cursor's hiding to it
  local current = vim.api.nvim_get_current_buf()
  if sessions[current] then
    cursor.hide(current)
  else
    cursor.show()
  end
end

local separate_pending = false

--- `separate()` once the command that made a window or changed its buffer is done: `:split file.pdf` makes a window
--- on the current buffer first.
function M.schedule_separate()
  if separate_pending then
    return
  end
  separate_pending = true
  vim.schedule(function()
    separate_pending = false
    M.separate()
  end)
end

--- Open a PDF in the current window.
---@param path string
---@return integer buf the viewer's buffer, or the window's own view of it (`separate`)
function M.open(path)
  -- not expand(): it would rewrite a name with `{`, `$` or a backtick in it (":PdfView" has expanded its argument)
  path = vim.fn.fnamemodify(path, ":p")
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    error(("pdf-view: cannot read `%s`"):format(path), 0)
  end
  local buf = vim.fn.bufadd(path)
  vim.bo[buf].buflisted = true -- as :edit lists it, for :ls, :bnext and bufferlines
  M.attach(buf)
  vim.api.nvim_win_set_buf(0, buf)
  -- on screen in another window already: this window gets a view of its own, now, for the caller to move
  M.separate()
  return vim.api.nvim_get_current_buf()
end

--- "page / pages" of the viewer in `buf`, plus the fit, "x1.56" while zoomed and "90°" while the pages are turned, for
--- statuslines. Empty for other buffers.
---@param buf? integer
---@return string
function M.status(buf)
  local s = sessions[buf or vim.api.nvim_get_current_buf()]
  if not s then
    return ""
  end
  local mode = s.mode ~= "page" and (" " .. s.mode) or ""
  local zoom = s.zoom > 1 and (" x%.2f"):format(s.zoom) or ""
  local turned = s.rotation ~= 0 and (" %d°"):format(s.rotation) or ""
  return ("%s / %s%s%s%s"):format(session.pages_label(s), s.count or "?", mode, zoom, turned)
end

return M
