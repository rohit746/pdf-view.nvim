local config = require("pdf-view.config")
local terminal = require("pdf-view.terminal")

local M = {}

-- smallest document `mutool` accepts: no xref table, so it is repaired (and warns) on load
local MINIMAL_PDF = [[
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 100 100]>>endobj
trailer<</Root 1 0 R>>
]]

--- Run an async mupdf call to completion; returns what its callback received, or `nil` on timeout.
---@param start fun(cb: fun(...))
---@return table? results
local function await(start)
  local results
  start(function(...)
    results = { n = select("#", ...), ... }
  end)
  vim.wait(10000, function()
    return results ~= nil
  end, 10)
  return results
end

local function check_mutool()
  local exe = config.options.mutool
  if vim.fn.executable(exe) ~= 1 then
    vim.health.error(("`%s` not found"):format(exe), {
      "Install MuPDF: `brew install mupdf` (macOS), `apt install mupdf-tools` (Debian/Ubuntu),",
      "`pacman -S mupdf-tools` (Arch). Or set `mutool` in setup() to its full path.",
    })
    return
  end
  local version = vim.system({ exe, "-v" }, { text = true }):wait(2000)
  vim.health.ok(vim.trim((version.stdout or "") .. (version.stderr or "")))

  local file = vim.fn.tempname() .. ".pdf"
  local handle = assert(io.open(file, "wb"))
  handle:write(MINIMAL_PDF)
  handle:close()
  local png = vim.fn.tempname() .. ".png"
  local mupdf = require("pdf-view.mupdf")

  local advice = {
    "pdf-view drives mutool's JavaScript engine for page geometry, zoom, search and bookmarks. Use a mutool built",
    "with it and recent enough to have the drawing API (the Homebrew and distro mupdf packages are; try upgrading).",
  }

  local advised = false

  ---@param what string
  ---@param results table? what the callback received: `{ err, ... }`, or nil on timeout
  ---@param ok_message string
  local function report(what, results, ok_message)
    if not results then
      vim.health.error(what .. " timed out")
    elseif results[1] then
      vim.health.error(what .. " failed: " .. tostring(results[1]), not advised and advice or nil)
      advised = true -- the advice is the same for every check, so give it once
    else
      vim.health.ok(ok_message)
    end
  end

  local info = await(function(cb)
    mupdf.info(file, 1, cb)
  end)
  local geometry = info
    and not info[1]
    and ("`mutool run` works (read a %dx%d pt page)"):format(info[2].width, info[2].height)
  report("page geometry (`mutool run`)", info, geometry or "")

  report(
    "rendering (`mutool draw`)",
    await(function(cb)
      mupdf.render(file, 1, 40, 40, png, cb)
    end),
    "`mutool draw` works"
  )
  os.remove(png)

  report(
    "zoomed rendering with highlights",
    await(function(cb)
      local clip =
        { scale_x = 2, scale_y = 2, x = 10, y = 10, width = 80, height = 80, highlights = "5,5,40,40,ffe14d" }
      mupdf.render_clip(file, 1, clip, png, cb)
    end),
    "zoomed rendering and search highlights work"
  )
  os.remove(png)

  report(
    "text search",
    await(function(cb)
      mupdf.search(file, "x", 10, cb)
    end),
    "text search works"
  )

  report(
    "outline",
    await(function(cb)
      mupdf.outline(file, cb)
    end),
    "bookmark reading works"
  )

  os.remove(file)
end

local function check_terminal()
  local detected = terminal.detect()
  if config.options.force then
    vim.health.warn("`force = true`: terminal detection is skipped")
  elseif detected.name then
    vim.health.ok("terminal: " .. detected.name)
  else
    vim.health.error(
      ("terminal not recognised (TERM_PROGRAM=%s, TERM=%s)"):format(vim.env.TERM_PROGRAM or "", vim.env.TERM or ""),
      {
        "Use a terminal with Kitty graphics and Unicode placeholder support: kitty or Ghostty.",
        "WezTerm and iTerm2 lack Unicode placeholders. Set `force = true` to try anyway.",
      }
    )
  end

  if terminal.in_tmux() then
    local state = terminal.tmux_passthrough()
    if state == "on" or state == "all" then
      vim.health.ok("tmux allow-passthrough: " .. state)
    elseif config.options.tmux_passthrough then
      vim.health.ok("tmux allow-passthrough is off here; pdf-view enables it for its pane on first use")
    else
      vim.health.error(
        "tmux allow-passthrough is off",
        { "Add `set -g allow-passthrough on` to tmux.conf (tmux >= 3.3a)." }
      )
    end
  end

  if vim.o.termguicolors then
    vim.health.ok("'termguicolors' is on")
  else
    vim.health.error(
      "'termguicolors' is off",
      { "Image ids travel in 24-bit foreground colours: `:set termguicolors`." }
    )
  end

  if vim.o.ambiwidth ~= "single" then
    vim.health.warn("'ambiwidth' is not \"single\"; the placeholder character may be drawn two cells wide")
  end

  local cell = terminal.cell_size()
  if cell.source == "fallback" then
    vim.health.warn(("the terminal did not report its pixel size; assuming %dx%d px cells"):format(cell.w, cell.h), {
      "Pages are rendered at this guessed resolution. Set `cell_size = { width, height }` in setup() for sharper output.",
    })
  else
    vim.health.ok(("cell size: %.1fx%.1f px (%s)"):format(cell.w, cell.h, cell.source))
  end

  vim.health.info("image transmission: " .. terminal.transmission())
end

local function check_conflicts()
  local ok, snacks = pcall(require, "snacks")
  local image = ok and snacks.image and snacks.image.config
  if image and image.enabled ~= false and vim.tbl_contains(image.formats or {}, "pdf") then
    vim.health.warn("snacks.nvim image also handles `*.pdf` buffers", {
      'Two handlers will draw over each other. Remove "pdf" from `image.formats` in the snacks.nvim options.',
    })
  end
end

function M.check()
  vim.health.start("pdf-view")
  if vim.fn.has("nvim-0.11") == 1 and vim.api.nvim_ui_send then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11 or newer is required")
  end
  check_mutool()
  check_terminal()
  check_conflicts()
end

return M
