--- A PDF viewer is an ordinary buffer (named after the file) whose text is Kitty Unicode placeholders. This is
--- its lifecycle: becoming a viewer (`attach`, `read`, `open`), following the file on disk, and cleaning up.
--- Rendering is in `render`, the keys are in `actions`, the state is in `session`.
local actions = require("pdf-view.actions")
local config = require("pdf-view.config")
local cursor = require("pdf-view.cursor")
local kitty = require("pdf-view.kitty")
local positions = require("pdf-view.positions")
local render = require("pdf-view.render")
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
---@type table<integer, PdfView.Position|{ jumps?: PdfView.Position[], jump_index?: integer, marks?: table<string, PdfView.Position> }>
local resume = {}

--- Holds each viewer's own `BufReadCmd`, which outlives the session (`destroy` clears only `augroup`) so `:edit`
--- re-attaches the buffer even when `auto_open` is off and no `*.pdf` handler exists.
local reread = vim.api.nvim_create_augroup("PdfViewReread", { clear = true })

--- Where the viewer `s` is, for `resume`.
---@param s PdfView.Session
local function position(s)
  return { page = s.target or s.page, mode = s.mode, zoom = s.zoom, cx = s.cx, cy = s.cy }
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
  if config.options.remember_position then
    pcall(positions.set, s.path, where)
  end
end

M.sessions = sessions
M.reload = actions.reload

---@param s PdfView.Session
local function on_file_changed(s)
  if s.closed then
    return
  end
  local stat = uv.fs_stat(s.path)
  if not stat or stamp_of(stat) == s.requested_stamp then
    return
  end
  show(s, nil, { retries = RELOAD_RETRIES, keep = true })
  rescan(s)
end

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
        if sessions[vim.api.nvim_win_get_buf(win)] then
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

  local path = vim.api.nvim_buf_get_name(buf)
  local last = resume[buf] or (config.options.remember_position and positions.get(path)) or {}
  resume[buf] = nil

  ---@type PdfView.Session
  local s = {
    buf = buf,
    path = path,
    page = last.page or 1,
    mode = last.mode or "page",
    zoom = math.max(1, math.min(last.zoom or 1, config.options.max_zoom)),
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
    closed = false,
  }
  sessions[buf] = s

  -- `nofile` stops Neovim from reading the PDF's bytes into the buffer and refuses `:w` over the original
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.swapfile = false
  bo.bufhidden = "hide"
  bo.undolevels = -1
  bo.modifiable = false
  bo.filetype = "pdf-view"

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    buffer = buf,
    desc = "Show the PDF page in the entered window",
    callback = function()
      apply_window_options(s, vim.api.nvim_get_current_win())
      relayout(s)
      if s.search_stale then
        rescan(s)
      end
    end,
  })
  -- The terminal drops the oldest images once it holds too many (kitty and Ghostty keep about 320 MB), and says
  -- nothing about it: a viewer in no window frees its images, and sends its page again when a window shows it.
  vim.api.nvim_create_autocmd("BufHidden", {
    group = augroup,
    buffer = buf,
    desc = "Free the images of a PDF viewer in no window",
    callback = function()
      vim.schedule(function() -- the buffer is still in its last window while this runs
        if s.closed or #vim.fn.win_findbuf(buf) > 0 or terminal.placement() == "positioned" then
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
  end
  vim.schedule(function()
    relayout(s)
  end)
  return s
end

--- Bring the viewers that are open in line with `config.options` after `setup()`: their keys, live reload, winbar
--- and colours.
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
  if vim.api.nvim_buf_get_name(s.buf) ~= s.path then -- :saveas has renamed the buffer: view the copy
    resume[s.buf] = kept(s)
    destroy(s)
    M.attach(s.buf)
  end
end

--- `BufReadCmd` handler: take over local PDF files and leave everything else (new files, URLs) alone.
---@param buf integer
function M.read(buf)
  local stat = uv.fs_stat(vim.api.nvim_buf_get_name(buf))
  if not stat or stat.type ~= "file" then
    return
  end
  local s = sessions[buf]
  if s then
    return M.reload(s)
  end
  M.attach(buf)
end

--- Open a PDF in the current window.
---@param path string
---@return integer buf
function M.open(path)
  -- not expand(): it would rewrite a name with `{`, `$` or a backtick in it (":PdfView" has expanded its argument)
  path = vim.fn.fnamemodify(path, ":p")
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    error(("pdf-view: cannot read `%s`"):format(path), 0)
  end
  local buf = vim.fn.bufadd(path)
  M.attach(buf)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

--- "page / pages" of the viewer in `buf`, plus "x1.56" while zoomed, for statuslines. Empty for other buffers.
---@param buf? integer
---@return string
function M.status(buf)
  local s = sessions[buf or vim.api.nvim_get_current_buf()]
  if not s then
    return ""
  end
  local mode = s.mode ~= "page" and (" " .. s.mode) or ""
  local zoom = s.zoom > 1 and (" x%.2f"):format(s.zoom) or ""
  return ("%d / %s%s%s"):format(s.page, s.count or "?", mode, zoom)
end

return M
