local config = require("pdf-view.config")

local M = {}

local group = vim.api.nvim_create_augroup("PdfView", { clear = true })

--- `*.[pP][dD][fF]` for "pdf": the autocommand pattern of one extension, matching any case.
---@param extension string
---@return string
local function pattern(extension)
  return "*." .. extension:gsub("%a", function(letter)
    return "[" .. letter:lower() .. letter:upper() .. "]"
  end)
end

--- Whether `path` has one of the `extensions` the viewer takes.
---@param path string
---@return boolean
local function supported(path)
  local extension = vim.fn.fnamemodify(path, ":e"):lower()
  for _, candidate in ipairs(config.options.extensions) do
    if candidate:lower() == extension then
      return true
    end
  end
  return false
end

--- Own reads of the files with one of the `extensions` when `auto_open` is on. Re-run after the configuration changes.
local function sync_handler()
  vim.api.nvim_clear_autocmds({ group = group, event = { "BufReadCmd", "FileReadCmd" } })
  if not config.options.auto_open or #config.options.extensions == 0 then
    return
  end
  local patterns = vim.tbl_map(pattern, config.options.extensions)
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = patterns,
    desc = "Open PDF (and CBZ, XPS, ...) files in pdf-view",
    callback = function(args)
      require("pdf-view.viewer").read(args.buf)
    end,
  })
  -- `:read file.pdf` would otherwise insert the raw bytes into the current buffer (#58).
  vim.api.nvim_create_autocmd("FileReadCmd", {
    group = group,
    pattern = patterns,
    desc = "Refuse :read of PDF (and CBZ, XPS, ...) files; use :PdfView",
    callback = function(args)
      if args.file:match("^%a[%w+.-]*://") then -- a URL: netrw (or another plugin) reads it
        return
      end
      local stat = vim.uv.fs_stat(args.file)
      if not stat or stat.type ~= "file" then -- a typo in the path is not a PDF being refused
        return vim.notify(("pdf-view: cannot read `%s`"):format(args.file), vim.log.levels.ERROR)
      end
      vim.notify("pdf-view: cannot :read this file; use :PdfView", vim.log.levels.ERROR)
    end,
  })
end

--- After `:source Session.vim`: a viewer's window comes back as an empty buffer named after the PDF (see
--- `viewer.restore`). Make every such buffer shown in a window a viewer again.
local function restore_session()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local path = vim.api.nvim_buf_get_name(buf)
    if
      path ~= ""
      and vim.bo[buf].buftype == "" -- a viewer is `nofile`
      and not vim.bo[buf].modified
      and supported(path)
      and vim.api.nvim_buf_line_count(buf) == 1
      and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    then
      require("pdf-view.viewer").restore(buf)
    end
  end
end

--- Configure the plugin. Optional: the defaults are used when this is never called.
---@param opts? table see `PdfView.Config` in lua/pdf-view/config.lua
function M.setup(opts)
  config.setup(opts)
  sync_handler()
  local viewer = package.loaded["pdf-view.viewer"]
  if viewer then -- viewers opened before this call
    viewer.apply_config()
  end
  return M
end

--- Open a PDF in the current window.
---@param path string
function M.open(path)
  return require("pdf-view.viewer").open(path)
end

--- Re-render the page shown in `buf` (default: the current buffer).
---@param buf? integer
function M.reload(buf)
  local s = require("pdf-view.viewer").sessions[buf or vim.api.nvim_get_current_buf()]
  if s then
    require("pdf-view.viewer").reload(s)
  end
end

--- "page / pages" for the viewer in `buf`, e.g. for a statusline component. Empty for other buffers.
---@param buf? integer
---@return string
function M.status(buf)
  local viewer = package.loaded["pdf-view.viewer"]
  return viewer and viewer.status(buf) or ""
end

--- Forward search (SyncTeX): show where the cursor's line of the TeX file in the current buffer is typeset, in its
--- PDF's viewer, which opens in a split if it is not on screen. `opts.pdf` names the PDF; by default vimtex's, then
--- those in open viewers, then the PDF named after the file are tried. `opts.file`, `opts.line` and `opts.col` stand
--- in for the buffer and the cursor.
---@param opts? { pdf?: string, file?: string, line?: integer, col?: integer }
function M.forward_search(opts)
  require("pdf-view.actions").forward_search(opts)
end

--- The viewer in `buf` (nil or 0: the current buffer). Warns and returns nil when there is none.
---@param buf? integer
---@return PdfView.Session?
local function viewer_in(buf)
  if buf ~= nil and type(buf) ~= "number" then
    error(("pdf-view: expected a buffer number, got %s"):format(vim.inspect(buf)), 3)
  end
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local viewer = package.loaded["pdf-view.viewer"]
  local s = viewer and viewer.sessions[buf]
  if not s then
    vim.notify(("pdf-view: buffer %d is not a PDF viewer"):format(buf), vim.log.levels.WARN)
  end
  return s
end

---@param name string
---@param value any
---@param expected string
local function invalid(name, value, expected)
  error(("pdf-view: invalid `%s`: expected %s, got %s"):format(name, expected, vim.inspect(value)), 3)
end

--- Run the action `name` (the name of its `keymaps` entry: "next", "zoom_in", "search", ...) in the viewer in `opts.buf`
--- (default: the current buffer), as its key does there. `opts.count` stands in for the count typed before the key;
--- by default it is `v:count`, so a mapping that calls this passes its count on. Returns whether there was a viewer.
---@param name string
---@param opts? { buf?: integer, count?: integer }
---@return boolean
function M.action(name, opts)
  opts = opts or {}
  local actions = require("pdf-view.actions")
  if type(name) ~= "string" or not actions.exists(name) then
    error(("pdf-view: unknown action %s"):format(vim.inspect(name)), 2)
  end
  local n = opts.count
  if n ~= nil and (type(n) ~= "number" or n < 0 or n % 1 ~= 0) then
    invalid("count", n, "a whole number, 0 or more")
  end
  local s = viewer_in(opts.buf)
  if not s then
    return false
  end
  actions.run(s, name, n)
  return true
end

--- Go to page `page` (clamped to the document) of the viewer in `opts.buf`, at its top. A jump, as `{count}G`.
---@param page integer
---@param opts? { buf?: integer }
---@return boolean # whether there was a viewer
function M.goto_page(page, opts)
  if type(page) ~= "number" or page % 1 ~= 0 then
    invalid("page", page, "a whole number")
  end
  local s = viewer_in((opts or {}).buf)
  if s then
    require("pdf-view.actions").goto_page(s, page)
  end
  return s ~= nil
end

--- Zoom the viewer in `opts.buf` to `zoom` times the fitted size, between 1 and `max_zoom`, keeping its fit.
---@param zoom number
---@param opts? { buf?: integer }
---@return boolean # whether there was a viewer
function M.set_zoom(zoom, opts)
  if type(zoom) ~= "number" or zoom ~= zoom then
    invalid("zoom", zoom, "a number")
  end
  local s = viewer_in((opts or {}).buf)
  if s then
    require("pdf-view.actions").set_zoom(s, zoom)
  end
  return s ~= nil
end

local FITS = { page = true, width = true, height = true, content = true }

--- Fit the page of the viewer in `opts.buf` to its window, at zoom 1: the whole page ("page"), its "width", its
--- "height", or the part of it with "content" on it.
---@param fit PdfView.FitMode
---@param opts? { buf?: integer }
---@return boolean # whether there was a viewer
function M.set_fit(fit, opts)
  if not FITS[fit] then
    invalid("fit", fit, '"page", "width", "height" or "content"')
  end
  local s = viewer_in((opts or {}).buf)
  if s then
    require("pdf-view.actions").set_fit(s, fit)
  end
  return s ~= nil
end

--- Search the document in the viewer in `opts.buf` for `text` and go to the first match after the page on screen
--- (before it with `opts.backward`), as `/` and `?` do: `n` and `N` step through the matches.
---@param text string
---@param opts? { buf?: integer, backward?: boolean }
---@return boolean # whether there was a viewer
function M.search(text, opts)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then
    invalid("text", text, "a non-empty string")
  end
  local s = viewer_in(opts.buf)
  if s then
    require("pdf-view.actions").search(s, text, opts.backward and -1 or 1)
  end
  return s ~= nil
end

--- Where the viewer in `buf` (default: the current buffer) is, nil for other buffers. `page` is the page it is on, or
--- going to, and `last` the last page on screen with it (the right one of facing pages, else `page`); `count` is nil
--- until the document was read. `fit` and `zoom` are as `set_fit()` and `set_zoom()` take them.
---@param buf? integer
---@return { buf: integer, path: string, page: integer, last: integer, count?: integer, fit: PdfView.FitMode, zoom: number }?
function M.get(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local viewer = package.loaded["pdf-view.viewer"]
  local s = viewer and viewer.sessions[buf]
  if not s then
    return nil
  end
  local session = require("pdf-view.session")
  local page = s.target or s.page
  local last = s.target and select(2, session.spread_range(s, s.target, s.count)) or (s.last or s.page)
  return { buf = s.buf, path = s.path, page = page, last = last, count = s.count, fit = s.mode, zoom = s.zoom }
end

--- Called by plugin/pdf-view.lua: register the commands and the default handler.
function M._init()
  vim.api.nvim_create_user_command("PdfView", function(args)
    local path = args.fargs[1]
    if not path then
      path = vim.api.nvim_buf_get_name(0)
      if not supported(path) then
        return vim.notify("pdf-view: usage: :PdfView {file.pdf}", vim.log.levels.ERROR)
      end
    end
    local ok, err = pcall(M.open, path)
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end, { nargs = "?", complete = "file", desc = "Open a PDF in the current window" })
  vim.api.nvim_create_user_command("PdfViewForward", function(args)
    M.forward_search({ pdf = args.fargs[1] })
  end, { nargs = "?", complete = "file", desc = "Show the cursor's line of the TeX source in its PDF (SyncTeX)" })
  -- `<Plug>(pdf-view-next)` and so on, for mappings made from Vim script or with `keymaps = false`
  for _, name in ipairs(config.actions()) do
    vim.keymap.set("n", ("<Plug>(pdf-view-%s)"):format(name), function()
      M.action(name)
    end, { silent = true, desc = "pdf-view: " .. name:gsub("_", " ") })
  end
  vim.api.nvim_clear_autocmds({ group = group, event = "SessionLoadPost" })
  vim.api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    desc = "Bring back the PDF viewers of a session",
    callback = restore_session,
  })
  sync_handler()
end

return M
