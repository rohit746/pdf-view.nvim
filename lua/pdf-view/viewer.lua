--- A PDF viewer is an ordinary buffer (named after the file) whose text is Kitty Unicode placeholders. This is
--- its lifecycle: becoming a viewer (`attach`, `read`, `open`), following the file on disk, and cleaning up.
--- Rendering is in `render`, the keys are in `actions`, the state is in `session`.
local actions = require("pdf-view.actions")
local config = require("pdf-view.config")
local cursor = require("pdf-view.cursor")
local render = require("pdf-view.render")
local session = require("pdf-view.session")
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
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    desc = "Restore PDF image highlights",
    callback = function()
      cursor.define()
      for _, s in pairs(sessions) do
        for _, id in ipairs(s.ids) do
          define_highlight(id)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    desc = "Free PDF images held by the terminal",
    callback = function()
      for _, s in pairs(sessions) do
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

  ---@type PdfView.Session
  local s = {
    buf = buf,
    path = vim.api.nvim_buf_get_name(buf),
    page = 1,
    mode = "page",
    zoom = 1,
    cx = 0.5,
    cy = 0.5,
    gen = 0,
    ids = allocate_ids(),
    slot = 0,
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
    callback = function()
      destroy(s)
    end,
  })

  set_keymaps(s)
  set_global_autocmds()
  if config.options.live_reload then
    s.watcher = watch.start(s.path, config.options.reload_delay, function()
      on_file_changed(s)
    end)
  end

  if vim.api.nvim_get_current_buf() == buf then
    cursor.hide(buf) -- BufEnter may already have fired for this buffer
  end
  vim.schedule(function()
    relayout(s)
  end)
  return s
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
