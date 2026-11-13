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
    results = vim.F.pack_len(...)
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
    "pdf-view drives mutool's JavaScript engine for page geometry, rendering, search and bookmarks. Use a mutool built",
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
    "rendering",
    await(function(cb)
      mupdf.render(file, 1, 40, 40, png, cb)
    end),
    "rendering works"
  )
  os.remove(png)

  local clipped = await(function(cb)
    local clip = { scale_x = 2, scale_y = 2, x = 10, y = 10, width = 80, height = 80, highlights = "5,5,40,40,ffe14d" }
    mupdf.render_clip(file, 1, clip, png, cb)
  end)
  report("zoomed rendering with highlights", clipped, "zoomed rendering and search highlights work")
  if clipped and not clipped[1] and (clipped[2] or ""):find("translucent", 1, true) then
    vim.health.warn("this MuPDF cannot multiply highlights onto the page (that needs MuPDF 1.27 or newer)", {
      "Search matches are drawn as a translucent fill instead, so text under a match is a little duller.",
      "Everything else is unaffected.",
    })
  end
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

  mupdf.release(file)
  os.remove(file)
end

local function check_transmission()
  if terminal.protocol() == "iterm2" then
    vim.health.info("image transmission: bytes (an iTerm2 inline image carries its PNG every time it is printed)")
    return
  elseif terminal.protocol() == "sixel" then
    vim.health.info("image transmission: bytes (a sixel image carries its pixels every time it is printed)")
    return
  end
  local mode, probe = terminal.transmission(), terminal.probe
  local blank = 'If pages stay blank, set `transmission = "direct"` in setup().'
  if config.options.transmission ~= "auto" then
    vim.health.info(("image transmission: %s (set in setup())"):format(mode))
  elseif probe and probe.state == "failed" then
    vim.health.warn(
      ("the terminal cannot read the PNG files of pages (it said `%s`), so pages are sent as bytes"):format(probe.error),
      {
        "Neovim and the terminal do not see the same files: Neovim runs in a container or as another user, or the",
        'terminal is a flatpak. Pages still show, a little slower. Set `transmission = "direct"` to skip the check.',
      }
    )
  elseif mode == "direct" and terminal.bytes_only() then
    vim.health.info("image transmission: direct (the terminal does not read image files)")
  elseif mode == "direct" then
    vim.health.info("image transmission: direct (over SSH)")
  elseif probe and probe.state == "ok" then
    vim.health.ok("image transmission: file (the terminal reads the PNG files of pages)")
  elseif probe and probe.state == "unasked" then
    vim.health.info(
      "image transmission: file (tmux has `extended-keys` on, which would turn the terminal's answer into typed keys, "
        .. "so it is not asked whether it can read the files). "
        .. blank
    )
  elseif probe and probe.state == "silent" then
    vim.health.info("image transmission: file (the terminal did not answer whether it can read the files). " .. blank)
  elseif probe then
    vim.health.info("image transmission: file (still asking the terminal whether it can read the files)")
  elseif vim.fn.has("nvim-0.12") == 0 then
    vim.health.info(
      "image transmission: file (Neovim 0.11 cannot ask the terminal whether it can read the files). " .. blank
    )
  else
    vim.health.info("image transmission: file (the terminal is asked whether it can read the files on the first page)")
  end
end

--- What is known of a terminal for Kitty graphics: whether it has Unicode placeholders, or answers a graphics query.
---@param detected PdfView.Terminal
---@param positioned boolean
local function check_kitty_terminal(detected, positioned)
  if detected.placeholders then
    vim.health.ok("terminal: " .. detected.name)
  elseif detected.name or (positioned and config.options.placement == "positioned") then
    local name = detected.name or ("`" .. (detected.term or "") .. "`")
    local asked = false
    terminal.ask_graphics(function()
      asked = true
    end)
    vim.wait(2000, function()
      return asked
    end, 10)
    local answer = terminal.graphics()
    if answer then
      vim.health.ok(("terminal: %s (it answered a Kitty graphics query)"):format(name))
    elseif answer == nil then
      vim.health.info(("terminal: %s (it cannot be asked whether it has Kitty graphics here)"):format(name))
    elseif detected.name == "wezterm" then
      vim.health.error("terminal: WezTerm, but it did not answer a Kitty graphics query", {
        "WezTerm has Kitty graphics turned off by default. Add `config.enable_kitty_graphics = true` to wezterm.lua",
        "and restart WezTerm.",
      })
    else
      vim.health.error(("terminal: %s, but it did not answer a Kitty graphics query"):format(name))
    end
  else
    vim.health.error(
      ("terminal not recognised (TERM_PROGRAM=%s, TERM=%s)"):format(vim.env.TERM_PROGRAM or "", vim.env.TERM or ""),
      {
        "Use kitty or Ghostty (directly or inside tmux or zellij), or WezTerm or Konsole: they have Kitty graphics.",
        'Or iTerm2 or VS Code, with iTerm2 inline images. Another terminal with them: `protocol = "iterm2"`.',
        "Or foot, Windows Terminal, xterm (as a VT340), Contour or mlterm, with sixel; another terminal that lists",
        'sixel in its device attributes gets it too. Another terminal with sixel: `protocol = "sixel"`.',
        'Another terminal with Kitty graphics can be tried with `placement = "positioned"`, or `force = true`.',
      }
    )
  end
end

-- how the terminals that get iTerm2 inline images or sixel are named in the report
local IMAGE_TERMINALS = {
  iterm2 = "iTerm2",
  vscode = "VS Code",
  wezterm = "WezTerm",
  konsole = "Konsole",
  foot = "foot",
  xterm = "xterm",
  ["windows-terminal"] = "Windows Terminal",
  contour = "Contour",
  mlterm = "mlterm",
}

--- What is known of a terminal for sixel: whether it lists sixel graphics in its device attributes.
---@param name string
local function check_sixel_terminal(name)
  local asked = false
  terminal.ask_sixel(function()
    asked = true
  end)
  vim.wait(2000, function()
    return asked
  end, 10)
  local answer = terminal.sixel()
  if answer then
    vim.health.ok(("terminal: %s, with sixel (it lists sixel graphics in its device attributes)"):format(name))
  elseif answer == nil then
    vim.health.info(("terminal: %s, with sixel (it cannot be asked whether it draws sixel here)"):format(name))
  elseif terminal.detect().name == "xterm" and not terminal.in_tmux() then
    vim.health.error("terminal: xterm, but not as a VT340, so it draws no sixel images", {
      "Start it with `xterm -ti vt340`, or set `XTerm*decTerminalID: vt340` in ~/.Xresources.",
    })
  else
    vim.health.error(("terminal: %s, but it does not list sixel graphics in its device attributes"):format(name))
  end
end

--- Whether VS Code's terminal shows images: its device attributes list sixel graphics when it does.
---@param name string
local function check_vscode_images(name)
  local settings = {
    'Add `"terminal.integrated.enableImages": true` to VS Code\'s settings, and keep',
    "`terminal.integrated.gpuAcceleration` on: VS Code draws images only with the WebGL renderer.",
  }
  if not terminal.vscode_images_askable() then
    vim.health.ok(("terminal: %s, with iTerm2 inline images (OSC 1337)"):format(name))
    vim.health.info(
      "VS Code cannot be asked whether it shows images here. If pages stay blank: " .. table.concat(settings, " ")
    )
    return
  end
  local asked = false
  terminal.ask_sixel(function()
    asked = true
  end)
  vim.wait(2000, function()
    return asked
  end, 10)
  if terminal.vscode_images_off() then
    vim.health.error(("terminal: %s, but it shows no images"):format(name), settings)
  else
    vim.health.ok(("terminal: %s, with iTerm2 inline images (OSC 1337)"):format(name))
  end
end

local function check_terminal()
  local detected = terminal.detect()
  local positioned = terminal.placement() == "positioned"
  local printed = terminal.printed()
  if config.options.force then
    vim.health.warn("`force = true`: terminal detection is skipped")
  elseif terminal.gui_only() then
    -- what the environment says is about the terminal the GUI was started from, so there is nothing more to check
    vim.health.error("this Neovim UI is not a terminal, so it cannot show pages: the page's text is shown instead", {
      "Open the PDF in Neovim running in a terminal that shows images (kitty, Ghostty, WezTerm, ...).",
    })
    return
  end
  if terminal.protocol() == "sixel" then
    local name = IMAGE_TERMINALS[detected.name] or detected.name or ("`" .. (detected.term or "") .. "`")
    if config.options.force then
      vim.health.ok(("terminal: %s, with sixel"):format(name))
    else
      check_sixel_terminal(name)
    end
    if detected.name == "konsole" then
      vim.health.warn("Konsole draws sixel images over the row below them", {
        'Remove `protocol = "sixel"`: Konsole shows pages better with Kitty graphics.',
      })
    end
  elseif printed then
    local name = IMAGE_TERMINALS[detected.name] or detected.name or ("`" .. (detected.term or "") .. "`")
    if detected.name == "vscode" and not config.options.force then
      check_vscode_images(name)
    else
      vim.health.ok(("terminal: %s, with iTerm2 inline images (OSC 1337)"):format(name))
    end
  elseif not config.options.force then
    check_kitty_terminal(detected, positioned)
  end
  if terminal.in_zellij() then
    local version = terminal.zellij_version()
    if version and vim.version.lt(version, { 0, 45, 0 }) then
      vim.health.error(("zellij %s has no Kitty graphics support"):format(tostring(version)), {
        "Upgrade to zellij 0.45 or newer.",
      })
    else
      vim.health.ok(
        ("zellij%s implements the Kitty graphics protocol"):format(version and (" " .. tostring(version)) or "")
      )
    end
    vim.health.info("zellij must not have `support_kitty_graphics_protocol false` in its configuration")
  end
  if printed then
    vim.health.ok("pages are printed at the position of their window, and again after Neovim draws over them")
  elseif positioned then
    vim.health.ok("pages are placed at the position of their window (Unicode placeholders are not used)")
  else
    vim.health.ok("pages are drawn with Unicode placeholders")
  end

  if terminal.in_tmux() and positioned and not terminal.in_zellij() then
    -- tmux knows nothing of a positioned page, and only focus events tell Neovim that its window was left, or shown
    -- again (and drawn again by tmux, without an iTerm2 image)
    local focus = vim.system({ "tmux", "show-options", "-gv", "focus-events" }, { text = true }):wait(1000)
    if vim.trim(focus.stdout or "") == "on" then
      vim.health.ok(
        printed and "tmux focus-events: on (a page is printed again when its tmux window is shown again)"
          or "tmux focus-events: on (a page is taken off the screen while its tmux window is not shown)"
      )
    else
      local effect = printed and "a page stays blank after switching back to its tmux window"
        or "a page stays on the screen over another tmux window"
      vim.health.warn("tmux focus-events is off: " .. effect, { "Add `set -g focus-events on` to tmux.conf." })
    end
  end

  if terminal.in_tmux() and printed then
    -- an inline or sixel image passes through tmux in one piece, which tmux drops when it is over its input buffer
    local size = tonumber(
      vim.trim(
        vim.system({ "tmux", "show-options", "-sv", "input-buffer-size" }, { text = true }):wait(1000).stdout or ""
      )
    ) or 1048576
    if size < 4194304 then
      local limit = terminal.protocol() == "sixel" and ("whose sixel is over %d KiB"):format(math.floor(size / 1024))
        or ("whose PNG is over %d KiB"):format(math.floor(size * 3 / 4 / 1024))
      vim.health.info(
        ("tmux drops an image over its input buffer (%d KiB), so a page %s stays blank. "):format(
          math.floor(size / 1024),
          limit
        ) .. "If one does, add `set -s input-buffer-size 4194304` to tmux.conf (tmux 3.6 has it)."
      )
    end
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

  -- placements need neither colours nor the placeholder character
  if not positioned then
    if vim.o.termguicolors then
      vim.health.ok("'termguicolors' is on")
    else
      vim.health.error(
        "'termguicolors' is off",
        { "Image ids travel in 24-bit foreground colours: `:set termguicolors`." }
      )
    end
    local rgb, termname = terminal.tmux_rgb()
    if rgb then
      vim.health.ok("tmux sends 24-bit colours to this client (RGB)")
    elseif rgb == false then
      vim.health.error(("tmux reduces colours to 256 for this client (TERM=%s has no RGB feature)"):format(termname), {
        "Image ids travel in 24-bit foreground colours, so pages would not show. Add this to tmux.conf and restart tmux:",
        ("`set -as terminal-features ',%s:RGB'`"):format(termname),
      })
    end
    if vim.o.ambiwidth ~= "single" then
      vim.health.warn("'ambiwidth' is not \"single\"; the placeholder character may be drawn two cells wide")
    end
  end

  local cell = terminal.cell_size()
  if cell.source == "fallback" and terminal.protocol() == "sixel" then
    vim.health.error(("the terminal did not report its pixel size; assuming %dx%d px cells"):format(cell.w, cell.h), {
      "A sixel image is drawn pixel for pixel, so pages come out the wrong size.",
      "Set `cell_size = { width, height }` in setup() to the size of a cell in pixels.",
    })
  elseif cell.source == "fallback" then
    vim.health.warn(("the terminal did not report its pixel size; assuming %dx%d px cells"):format(cell.w, cell.h), {
      "Pages are rendered at this guessed resolution. Set `cell_size = { width, height }` in setup() for sharper output.",
    })
  else
    vim.health.ok(("cell size: %.1fx%.1f px (%s)"):format(cell.w, cell.h, cell.source))
  end

  check_transmission()
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
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11 or newer is required")
  end
  check_mutool()
  check_terminal()
  check_conflicts()
end

return M
