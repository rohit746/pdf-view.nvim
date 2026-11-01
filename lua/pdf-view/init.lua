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
  vim.api.nvim_clear_autocmds({ group = group, event = "BufReadCmd" })
  if not config.options.auto_open or #config.options.extensions == 0 then
    return
  end
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = vim.tbl_map(pattern, config.options.extensions),
    desc = "Open PDF (and CBZ, XPS, ...) files in pdf-view",
    callback = function(args)
      require("pdf-view.viewer").read(args.buf)
    end,
  })
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

--- Called by plugin/pdf-view.lua: register the command and the default handler.
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
  sync_handler()
end

return M
