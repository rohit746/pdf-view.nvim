local config = require("pdf-view.config")

local M = {}

local ESC = "\27"

-- Only the aspect ratio matters when fitting; this is the fallback when the terminal does not report pixels.
local FALLBACK_CELL = { w = 16, h = 32 }

---@return boolean
function M.in_tmux()
  return (vim.env.TMUX or "") ~= ""
end

--- zellij sets `$ZELLIJ` in its panes. It implements the Kitty graphics protocol itself (0.45 and newer) rather than
--- passing it through, and it does not support Unicode placeholders.
---@return boolean
function M.in_zellij()
  return (vim.env.ZELLIJ or "") ~= ""
end

-- the terminals that draw sixel images and no Kitty graphics
local SIXEL = { foot = true, xterm = true, ["windows-terminal"] = true, contour = true, mlterm = true }

---@type boolean? whether the terminal's DA1 reply lists sixel graphics, once it has been asked (see `ask_sixel()`)
local da1_sixel
-- whether it has been asked, answered or not
local da1_asked = false

--- The image protocol pages are sent with: Kitty graphics, iTerm2 inline images (OSC 1337) for the terminals that
--- have no Kitty graphics but draw those (iTerm2, VS Code), or sixel for the ones that draw that (foot, Windows
--- Terminal, xterm, Contour, mlterm, and a terminal that is not recognised but says it has sixel graphics).
---@return "kitty"|"iterm2"|"sixel"
function M.protocol()
  local protocol = config.options.protocol
  if protocol ~= "auto" then
    return protocol --[[@as "kitty"|"iterm2"|"sixel"]]
  end
  if M.in_zellij() then
    return "kitty" -- zellij draws Kitty graphics itself, whatever the terminal around it draws
  end
  local name = M.detect().name
  if name == "iterm2" or name == "vscode" then
    return "iterm2"
  elseif SIXEL[name] or (name == nil and da1_sixel) then
    return "sixel"
  end
  return "kitty"
end

--- Whether pages are printed into the cells (iTerm2 inline images, sixel) rather than placed by id (Kitty graphics).
---@return boolean
function M.printed()
  return M.protocol() ~= "kitty"
end

--- How pages are put on screen: as Unicode placeholder cells, or as placements at the screen position of the window.
--- zellij and the terminals that have Kitty graphics but no Unicode placeholders (WezTerm, Konsole) get placements,
--- and so do iTerm2 inline images and sixel images, which are printed at the window's position.
---@return "placeholders"|"positioned"
function M.placement()
  if M.printed() then
    return "positioned"
  end
  local mode = config.options.placement
  if mode ~= "auto" then
    return mode --[[@as "placeholders"|"positioned"]]
  end
  if M.in_zellij() or M.detect().placeholders == false then
    return "positioned"
  end
  return "placeholders"
end

--- Whether an image placed under the text would be hidden. Konsole draws it behind every cell background but the
--- terminal's own, and Neovim paints the colour of its Normal group into every cell, so there the page is placed
--- over the text (the floats and the popup menu over the page are cut out of it all the same).
---@return boolean
function M.hides_images_under_text()
  return M.detect().name == "konsole"
end

---@return boolean
function M.ui_attached()
  return #vim.api.nvim_list_uis() > 0
end

---@param cmd string[]
---@return string?
local function capture(cmd)
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true }):wait(1000)
  end)
  if not ok or result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout or "")
end

local ioctl_ready

--- Pixel size of the terminal as reported by the kernel, via TIOCGWINSZ on stdout/stderr/stdin.
---@return { cols: integer, rows: integer, width: integer, height: integer }?
local function window_pixels()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil
  end
  if ioctl_ready == nil then
    -- declared exactly like snacks.nvim does: LuaJIT rejects a redeclaration with a different signature
    ioctl_ready = pcall(
      ffi.cdef,
      [[
        typedef struct { unsigned short row, col, xpixel, ypixel; } pdfview_winsize;
        int ioctl(int, int, ...);
      ]]
    )
  end
  local request = vim.fn.has("linux") == 1 and 0x5413 or 0x40087468 -- TIOCGWINSZ
  local size = ffi.new("pdfview_winsize") --[[@as { row: integer, col: integer, xpixel: integer, ypixel: integer }]]
  for _, fd in ipairs({ 1, 2, 0 }) do
    local called, rc = pcall(function()
      return ffi.C.ioctl(fd, request, size)
    end)
    if called and rc == 0 and size.col > 0 and size.row > 0 and size.xpixel > 0 and size.ypixel > 0 then
      return { cols = size.col, rows = size.row, width = size.xpixel, height = size.ypixel }
    end
  end
  return nil
end

--- Size of one terminal cell in pixels.
---@return { w: number, h: number, source: string }
function M.cell_size()
  local override = config.options.cell_size
  if override then
    return { w = override[1], h = override[2], source = "config" }
  end
  local pixels = window_pixels()
  if pixels then
    return { w = pixels.width / pixels.cols, h = pixels.height / pixels.rows, source = "ioctl" }
  end
  return { w = FALLBACK_CELL.w, h = FALLBACK_CELL.h, source = "fallback" }
end

local detected
-- rows and columns of the outer terminal above and left of this tmux pane, once asked (see `pane_offset()`)
---@type integer[]?
local pane_offset

-- the terminals pdf-view recognises, as { what their names contain, name }: the first four with the Kitty graphics
-- protocol, iTerm2 and VS Code with iTerm2 inline images (iTerm2 sets $TERM_PROGRAM to "iTerm.app"), the rest with
-- sixel ("XTerm(390)" is the name xterm gives tmux; xterm's $TERM is everyone's)
local KNOWN = {
  { "kitty", "kitty" },
  { "ghostty", "ghostty" },
  { "wezterm", "wezterm" },
  { "konsole", "konsole" },
  { "iterm", "iterm2" },
  { "vscode", "vscode" },
  { "foot", "foot" },
  { "contour", "contour" },
  { "mlterm", "mlterm" },
  { "xterm(", "xterm" },
}
-- whether they draw Unicode placeholders
local PLACEHOLDERS = {
  kitty = true,
  ghostty = true,
  wezterm = false,
  konsole = false,
  iterm2 = false,
  vscode = false,
  foot = false,
  xterm = false,
  ["windows-terminal"] = false,
  contour = false,
  mlterm = false,
}

---@alias PdfView.TerminalName "kitty"|"ghostty"|"wezterm"|"konsole"|"iterm2"|"vscode"|"foot"|"xterm"|"windows-terminal"|"contour"|"mlterm"

---@class PdfView.Terminal
---@field name? PdfView.TerminalName nil when the terminal is not recognised
---@field term? string $TERM_PROGRAM or $TERM, to name it in messages
---@field placeholders? boolean whether it draws Unicode placeholders; nil when it is not recognised

--- Identify a terminal that can show images (with the Kitty graphics protocol, or iTerm2 inline images), and whether
--- it has Unicode placeholders.
---@return PdfView.Terminal
function M.detect()
  if detected then
    return detected
  end
  local env = vim.env
  local term = env.TERM or ""
  local program = (env.TERM_PROGRAM or ""):lower()

  local function classify(value)
    value = (value or ""):lower()
    for _, known in ipairs(KNOWN) do
      if value:find(known[1], 1, true) then
        return known[2]
      end
    end
  end

  local function set(var)
    return (env[var] or "") ~= ""
  end

  -- zellij passes the outer terminal's $TERM, $TERM_PROGRAM and the variables below on to its panes, so the checks
  -- see through it. WezTerm, Konsole, iTerm2, VS Code, Windows Terminal and xterm leave $TERM at xterm-256color;
  -- they are told by the variables they set. iTerm2 also sets $LC_TERMINAL, which ssh passes on to the remote host.
  local name
  if M.in_tmux() then
    -- inside tmux $TERM says nothing about the outer terminal, but the attached client knows: its $TERM, and the
    -- name it gave when tmux asked (e.g. "iTerm2 3.5.0", tmux 3.3 and newer)
    name = classify(capture({ "tmux", "display-message", "-p", "#{client_termname} #{client_termtype}" }))
  end
  name = name
    or classify(term)
    or classify(program)
    or (set("KITTY_WINDOW_ID") and "kitty")
    or (set("GHOSTTY_RESOURCES_DIR") and "ghostty")
    or (set("WEZTERM_EXECUTABLE") and "wezterm")
    or (set("KONSOLE_VERSION") and "konsole")
    or classify(env.LC_TERMINAL)
    or classify(env.TERMINAL_NAME) -- Contour
    or (set("MLTERM") and "mlterm")
    or (set("WT_SESSION") and "windows-terminal")
    or (set("XTERM_VERSION") and "xterm")
    or nil

  detected = { name = name, term = program ~= "" and program or term, placeholders = PLACEHOLDERS[name] }
  return detected
end

-- a 1x1 transparent PNG
local PROBE_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
-- image id of the graphics query, next to the probe's (see `probe_file()`)
local QUERY_ID = 0xFFFFFD
-- a terminal that has not answered by then has no Kitty graphics, or they are turned off
local QUERY_TIMEOUT = 1000

---@type boolean? the answer to the graphics query, once it has been asked
local graphics
---@type fun()[]? callbacks waiting for that answer while the query is out
local waiting
---@type boolean? whether the terminal can be asked at all
local askable

--- Whether the terminal's replies (to a question, or to a graphics command) can be read: they come back as a
--- TermResponse, which Neovim 0.11 cannot read, and behind tmux with extended keys they would arrive as typed keys (see
--- `replies_arrive_as_keys()`). Known until `forget()`.
---@return boolean
function M.replies_readable()
  if not M.ui_attached() then
    return false
  end
  if askable == nil then
    askable = vim.fn.has("nvim-0.12") == 1 and not M.replies_arrive_as_keys()
  end
  return askable
end

--- Whether the terminal answered a Kitty graphics query: nil until it has been asked (see `ask_graphics()`), and when
--- it cannot be asked.
---@return boolean?
function M.graphics()
  return graphics
end

--- Ask the terminal, once, whether it has Kitty graphics: a query (`a=q`, which loads a 1x1 image without keeping
--- it) that a terminal without them, or with them turned off, does not answer. `callback` runs once the answer is in,
--- at once when it is known already or the terminal cannot be asked.
---@param callback fun()
function M.ask_graphics(callback)
  if graphics ~= nil or not M.replies_readable() then
    return callback()
  end
  if waiting then
    waiting[#waiting + 1] = callback
    return
  end
  waiting = { callback }
  local autocmd, timer
  local function finish(answer)
    if not waiting then
      return
    end
    pcall(vim.api.nvim_del_autocmd, autocmd)
    timer:stop()
    timer:close()
    graphics = answer
    local callbacks = waiting
    waiting = nil
    for _, waiter in ipairs(callbacks) do
      waiter()
    end
  end
  autocmd = vim.api.nvim_create_autocmd("TermResponse", {
    desc = "pdf-view: whether the terminal has Kitty graphics",
    callback = function(args)
      local sequence = (args.data and args.data.sequence) or vim.v.termresponse or ""
      local keys = sequence:match("^\27_G([^;]*);")
      if keys and tonumber(keys:match("i=(%d+)")) == QUERY_ID then
        vim.schedule(function()
          finish(true)
        end)
      end
    end,
  })
  timer = assert(vim.uv.new_timer())
  timer:start(QUERY_TIMEOUT, 0, function()
    vim.schedule(function()
      finish(false)
    end)
  end)
  local kitty = require("pdf-view.kitty")
  kitty.send(kitty.sequence({ a = "q", f = 100, t = "d", i = QUERY_ID }, PROBE_PNG))
end

---@type fun()[]? callbacks waiting for the DA1 reply while the question is out
local waiting_da1
-- a terminal that has not answered DA1 by then is not going to: every terminal answers it at once
local DA1_TIMEOUT = 1000

--- Whether the terminal said it draws sixel images: nil until it has been asked (see `ask_sixel()`), and when it
--- cannot be asked or did not answer.
---@return boolean?
function M.sixel()
  return da1_sixel
end

--- Whether `ask_sixel()` can find out whether the terminal draws sixel images: by asking it, or from tmux.
---@return boolean
function M.sixel_askable()
  return M.in_tmux() or M.replies_readable()
end

--- The attributes of a DA1 reply (`CSI ? 65 ; 4 ; 6 c`), or nil when `sequence` is not one.
---@param sequence string
---@return integer[]?
function M.da1_attributes(sequence)
  local list = sequence:match("^\27%[%?([%d;]*)c$")
  if not list then
    return nil
  end
  local attributes = {}
  for number in list:gmatch("%d+") do
    attributes[#attributes + 1] = tonumber(number)
  end
  return attributes
end

--- Ask the terminal, once, whether it draws sixel images: the primary device attributes (DA1) that every terminal
--- answers list 4 when it does. Inside tmux, which answers DA1 for itself, the features tmux found in the attached
--- terminal are read instead. `callback` runs once the answer is in, at once when it is known already or the terminal
--- cannot be asked.
---@param callback fun()
function M.ask_sixel(callback)
  if da1_asked or not M.sixel_askable() then
    return callback()
  end
  if M.in_tmux() then
    da1_asked = true
    local features = capture({ "tmux", "display-message", "-p", "#{client_termfeatures}" })
    if features then
      da1_sixel = vim.tbl_contains(vim.split(features, ",", { trimempty = true }), "sixel")
    end
    return callback()
  end
  if waiting_da1 then
    waiting_da1[#waiting_da1 + 1] = callback
    return
  end
  waiting_da1 = { callback }
  local autocmd, timer
  local function finish(answer)
    if not waiting_da1 then
      return
    end
    pcall(vim.api.nvim_del_autocmd, autocmd)
    timer:stop()
    timer:close()
    da1_sixel, da1_asked = answer, true
    local callbacks = waiting_da1
    waiting_da1 = nil
    for _, waiter in ipairs(callbacks) do
      waiter()
    end
  end
  autocmd = vim.api.nvim_create_autocmd("TermResponse", {
    desc = "pdf-view: whether the terminal draws sixel images",
    callback = function(args)
      -- the reply to anyone's DA1 says the same
      local attributes = M.da1_attributes((args.data and args.data.sequence) or vim.v.termresponse or "")
      if attributes then
        vim.schedule(function()
          finish(vim.list_contains(attributes, 4))
        end)
      end
    end,
  })
  timer = assert(vim.uv.new_timer())
  timer:start(DA1_TIMEOUT, 0, function()
    vim.schedule(function()
      finish(nil) -- not answered: the protocol is chosen by name alone
    end)
  end)
  require("pdf-view.kitty").write(ESC .. "[c") -- tmux is not asked (see above), so this needs no passthrough
end

--- Ask the terminal what `check()` needs to know, at the same time: whether it has Kitty graphics, and whether it
--- draws sixel images. `callback` runs once both answers are in.
---@param callback fun()
function M.ask(callback)
  local found = M.detect()
  local questions = {}
  if M.needs_da1() then
    questions[#questions + 1] = M.ask_sixel
  end
  -- Kitty graphics on a terminal without Unicode placeholders, as `check()` asks about them
  local positioned = not found.placeholders and (found.name ~= nil or config.options.placement == "positioned")
  if graphics == nil and positioned and M.protocol() == "kitty" then
    questions[#questions + 1] = M.ask_graphics
  end
  local left = #questions
  if left == 0 then
    return callback()
  end
  for _, question in ipairs(questions) do
    question(function()
      left = left - 1
      if left == 0 then
        callback()
      end
    end)
  end
end

--- Whether `check()` waits for the answer of `ask_sixel()`: for an unrecognised terminal, where it decides the
--- protocol, and for sixel, to tell whether the terminal draws it.
---@return boolean
function M.needs_da1()
  if da1_asked or config.options.force or not M.sixel_askable() then
    return false
  end
  local unknown = config.options.protocol == "auto" and M.detect().name == nil and not M.in_zellij()
  return unknown or M.protocol() == "sixel" or M.vscode_images_askable()
end

--- Whether VS Code can be asked whether it shows images: its terminal draws them only with
--- `terminal.integrated.enableImages` on and the WebGL renderer in use, which is when it loads xterm.js's image addon,
--- and that addon answers DA1 with sixel graphics listed. Inside tmux, which answers DA1 itself, it is not asked.
---@return boolean
function M.vscode_images_askable()
  return M.detect().name == "vscode" and M.protocol() == "iterm2" and not M.in_tmux() and M.replies_readable()
end

--- Whether VS Code said it shows no images (see `vscode_images_askable()`).
---@return boolean
function M.vscode_images_off()
  return da1_asked and da1_sixel == false and M.detect().name == "vscode" and not M.in_tmux()
end

M.VSCODE_IMAGES_OFF = "pdf-view: VS Code's terminal shows no images. Add "
  .. '`"terminal.integrated.enableImages": true` to its settings, and keep `terminal.integrated.gpuAcceleration` '
  .. "on (VS Code draws images only with the WebGL renderer), then restart Neovim."

--- Forget what was found out about the terminal, for another one attached through tmux.
function M.forget()
  detected, graphics, askable, pane_offset, da1_sixel, da1_asked = nil, nil, nil, nil, nil, false
end

--- Whether pages can be displayed here. The second return value explains a failure. Nil when the terminal has to be
--- asked first: call `ask()` and check again once it is answered.
---
--- A terminal without Unicode placeholders gets positioned placements, which need nothing but Kitty graphics: it is
--- asked whether it has them, as is an unrecognised terminal when `placement = "positioned"` is set. A terminal that
--- draws sixel images is asked whether it does (xterm does only as a VT340), and so is an unrecognised one, which then
--- gets sixel.
---@return boolean?, string?
function M.check()
  if config.options.force then
    return true
  end
  local found = M.detect()
  if M.needs_da1() then
    return nil -- whether it draws sixel images decides the protocol, or whether sixel works
  end
  local protocol = M.protocol()
  if protocol == "iterm2" then
    if config.options.placement == "placeholders" then
      return false, 'pdf-view: iTerm2 inline images have no Unicode placeholders. Remove `placement = "placeholders"`.'
    end
    if M.vscode_images_off() then
      return false, M.VSCODE_IMAGES_OFF
    end
    return true -- there is no question that tells whether a terminal draws them, but VS Code's DA1 says it
  end
  if protocol == "sixel" then
    if config.options.placement == "placeholders" then
      return false, 'pdf-view: sixel images have no Unicode placeholders. Remove `placement = "placeholders"`.'
    end
    if da1_sixel ~= false then
      return true
    end
    if found.name == "xterm" and not M.in_tmux() then
      return false,
        "pdf-view: xterm draws sixel images only as a VT340. Start it with `xterm -ti vt340`, or set "
          .. "`XTerm*decTerminalID: vt340` in ~/.Xresources."
    end
    return false,
      ("pdf-view: %s does not list sixel graphics in its device attributes, so it cannot show pages. "):format(
        found.name or (found.term ~= "" and ("`" .. found.term .. "`")) or "this terminal"
      ) .. "Set `force = true` in setup() to try anyway."
  end
  if found.placeholders then
    return true
  end
  local positioned = M.placement() == "positioned"
  if positioned and (found.name or config.options.placement == "positioned") then
    if graphics == nil and M.replies_readable() then
      return nil
    end
    if graphics ~= false then
      return true
    end
    if found.name == "wezterm" then
      return false,
        "pdf-view: WezTerm did not answer a Kitty graphics query. Add `config.enable_kitty_graphics = true` "
          .. "to wezterm.lua and restart WezTerm."
    end
    return false,
      ("pdf-view: %s did not answer a Kitty graphics query, so it cannot show pages. "):format(
        found.name or (found.term ~= "" and ("`" .. found.term .. "`")) or "this terminal"
      ) .. "Set `force = true` in setup() to try anyway."
  end
  if found.name and not positioned then
    return false,
      ('pdf-view: %s has no Unicode placeholders. Remove `placement = "placeholders"` from setup().'):format(found.name)
  end
  local term = found.term
  local needs = positioned and "Kitty graphics" or "Kitty graphics and Unicode placeholder"
  return false,
    (
      "pdf-view: %s does not look like a terminal with %s support (kitty, Ghostty, WezTerm, Konsole), "
      .. "with iTerm2 inline images (iTerm2, VS Code), or with sixel graphics (foot, Windows Terminal, xterm). "
      .. "Set `force = true` in setup() to try anyway."
    ):format(term ~= "" and ("`" .. term .. "`") or "this terminal", needs)
end

local prepared
-- the tmux client pages were first sent through (see `check_client()`)
local client

-- asks tmux which client is attached: one per `tmux attach`, so another terminal (or window) is another client
local CLIENT_QUERY = { "tmux", "display-message", "-p", "#{client_pid}" }

--- One-time terminal preparation: tmux only forwards graphics escape codes when passthrough is on, and the terminal
--- is asked whether it can read the PNGs of pages.
function M.prepare()
  if prepared then
    return
  end
  prepared = true
  if M.in_tmux() then
    client = capture(CLIENT_QUERY)
    if config.options.tmux_passthrough then
      capture({ "tmux", "set-option", "-p", "allow-passthrough", "on" })
    end
  end
  M.probe_file(vim.fs.dirname(vim.fn.tempname()))
end

--- Called when tmux was attached again through another client, whose terminal holds none of the images sent so far.
--- Set by `render`.
M.on_reattach = function() end

--- Whether tmux is now attached through another client than the one pages were sent through. When it is, the new
--- terminal holds none of the images and may be another kind of terminal: what was detected about the old one is
--- forgotten and `on_reattach()` sends the pages again. Asked on FocusGained and UIEnter; the answer comes later.
function M.check_client()
  if not (prepared and M.in_tmux()) then
    return
  end
  pcall(vim.system, CLIENT_QUERY, { text = true }, function(result)
    local now = result.code == 0 and vim.trim(result.stdout or "") or ""
    vim.schedule(function()
      if now == "" or now == client or not prepared then
        return
      end
      M.forget()
      prepared = nil -- `prepare()` notes the new client
      if not (M.probe and M.probe.state == "pending") then
        M.probe = nil -- the new terminal is asked again whether it can read the PNGs
      end
      M.on_reattach()
    end)
  end)
end

---@return boolean
local function over_ssh()
  return (vim.env.SSH_CONNECTION or "") ~= "" or (vim.env.SSH_TTY or "") ~= ""
end

--- Whether the terminal takes images only as bytes: Konsole answers ENOTSUPPORTED to a file.
---@return boolean
function M.bytes_only()
  return M.detect().name == "konsole"
end

--- How images are handed to the terminal. A local terminal can read the PNG itself; over SSH the bytes are sent, and
--- so they are to a terminal that reads no files, or when the terminal said it cannot read the file (see
--- `probe_file()`).
---@return "file"|"direct"
function M.transmission()
  local mode = config.options.transmission
  if mode ~= "auto" then
    return mode --[[@as "file"|"direct"]]
  end
  if over_ssh() or M.bytes_only() or (M.probe and M.probe.state == "failed") then
    return "direct"
  end
  return "file"
end

-- image id of the probe, above the ids of pages (see `allocate_ids()` in session.lua)
local PROBE_ID = 0xFFFFFE
-- a terminal that has not answered by then is not going to (a multiplexer may not pass the reply on)
local PROBE_TIMEOUT = 3000

---@class PdfView.Probe
---@field state "pending"|"ok"|"failed"|"silent"|"unasked" "silent": no reply came, so the file medium is kept;
--- "unasked": the reply would have arrived as typed keys (see `replies_arrive_as_keys()`), so the terminal was not asked
---@field error? string the terminal's reply when it failed

--- Result of the check that the terminal can read the PNGs pdf-view writes, once it has been made.
---@type PdfView.Probe?
M.probe = nil

--- Called once the check has found that the terminal cannot read the PNGs, to send pages that are already up again.
--- Set by `render`.
M.on_fallback = function() end

--- What a graphics protocol reply says about the probe: nil when the reply is not about it, otherwise whether the
--- terminal could read the file and, when it could not, its error message.
---@param sequence string
---@return boolean? ok
---@return string? error
function M.probe_reply(sequence)
  local keys, message = sequence:match("^\27_G([^;]*);(.-)\27?\\?$")
  if not keys or tonumber(keys:match("i=(%d+)")) ~= PROBE_ID then
    return nil
  end
  if message == "OK" then
    return true
  end
  return false, message
end

--- Whether the terminal's replies to graphics commands would reach Neovim as typed keys instead of a TermResponse.
--- tmux with `extended-keys` on (or always) re-encodes the reply's leading ESC _ as the key Alt-_ (`CSI 27;3;95~`
--- or `CSI 95;3u`) once Neovim asks for extended keys, so the rest of the reply is typed into the buffer: with
--- `Gi=16777214;OK`, `G` jumps to the last page, `i` recolours it and `=` zooms in.
---@return boolean
function M.replies_arrive_as_keys()
  if not M.in_tmux() then
    return false
  end
  local mode = capture({ "tmux", "show-options", "-sv", "extended-keys" })
  return mode ~= nil and mode ~= "" and mode ~= "off"
end

--- Ask the terminal, once, whether it can read a PNG in the directory pages are rendered to. It cannot when Neovim
--- runs in a container or as another user, or when the terminal is a flatpak, and then the page would just stay
--- blank. The question is asked with `a=q`, which loads the image without keeping it; the answer comes back as a
--- TermResponse. Neovim 0.11 cannot read replies (they would arrive as typed keys), so it is not asked there, and
--- neither is a terminal behind tmux with extended keys on, whose reply would be typed keys as well.
---@param dir string the directory pages are rendered to
function M.probe_file(dir)
  if M.probe or config.options.transmission ~= "auto" or over_ssh() or M.bytes_only() or M.printed() then
    return
  end
  if vim.fn.has("nvim-0.12") == 0 or not M.ui_attached() then
    return
  end
  if M.replies_arrive_as_keys() then
    M.probe = { state = "unasked" }
    return
  end
  local path = dir .. "/pdf-view-probe.png"
  local file = io.open(path, "wb")
  if not file then
    return
  end
  file:write(vim.base64.decode(PROBE_PNG))
  file:close()

  local probe = { state = "pending" } ---@type PdfView.Probe
  M.probe = probe
  local autocmd, timer
  local function finish(state, message)
    if probe.state ~= "pending" then
      return
    end
    probe.state, probe.error = state, message
    pcall(vim.api.nvim_del_autocmd, autocmd)
    if timer then
      timer:stop()
      timer:close()
    end
    os.remove(path)
    if state == "failed" then
      M.on_fallback()
    end
  end
  autocmd = vim.api.nvim_create_autocmd("TermResponse", {
    desc = "pdf-view: whether the terminal can read the PNG files of pages",
    callback = function(args)
      local ok, message = M.probe_reply((args.data and args.data.sequence) or vim.v.termresponse or "")
      if ok ~= nil then
        vim.schedule(function()
          finish(ok and "ok" or "failed", message)
        end)
      end
    end,
  })
  timer = assert(vim.uv.new_timer())
  timer:start(PROBE_TIMEOUT, 0, function()
    vim.schedule(function()
      finish("silent")
    end)
  end)

  local kitty = require("pdf-view.kitty")
  kitty.send(kitty.sequence({ a = "q", f = 100, t = "f", i = PROBE_ID }, vim.base64.encode(path)))
end

--- Version of the zellij on $PATH, or nil when it cannot be told.
---@return vim.Version?
function M.zellij_version()
  local out = capture({ "zellij", "--version" })
  return out and vim.version.parse(out:match("%d+%.%d+%.%d+") or "") or nil
end

--- Where this tmux pane is on the outer terminal's screen, as the rows and columns above and left of it: positioned
--- placements pass through tmux and land at a position on that screen. 0, 0 outside tmux.
---@param fresh? boolean ask tmux again, e.g. after the pane was resized
---@return integer rows, integer cols
function M.pane_offset(fresh)
  if not M.in_tmux() then
    return 0, 0
  end
  if fresh or not pane_offset then
    local cmd = { "tmux", "display-message", "-p" }
    if (vim.env.TMUX_PANE or "") ~= "" then
      vim.list_extend(cmd, { "-t", vim.env.TMUX_PANE })
    end
    cmd[#cmd + 1] = "#{pane_top} #{pane_left} #{status} #{status-position}"
    local top, left, status, position = (capture(cmd) or ""):match("^(%d+) (%d+) (%S+) (%S+)")
    if not top then
      return 0, 0 -- not remembered: asked again next time
    end
    -- pane_top counts the pane borders but not the status line, which is 1 row when "on", or as many as its number
    local lines = status == "off" and 0 or (tonumber(status) or 1)
    pane_offset = { tonumber(top) + (position == "top" and lines or 0), tonumber(left) }
  end
  return pane_offset[1], pane_offset[2]
end

--- Ask tmux whether this pane's window is on screen: it is not after switching to another window or session.
---@param callback fun(shown: boolean)
function M.tmux_window_shown(callback)
  local cmd = { "tmux", "display-message", "-p" }
  if (vim.env.TMUX_PANE or "") ~= "" then
    vim.list_extend(cmd, { "-t", vim.env.TMUX_PANE })
  end
  cmd[#cmd + 1] = "#{window_active} #{session_attached}"
  pcall(vim.system, cmd, { text = true }, function(result)
    local active, attached = (result.stdout or ""):match("^(%d+) (%d+)")
    local shown = result.code ~= 0 or not active or (active == "1" and attached ~= "0")
    vim.schedule(function()
      callback(shown)
    end)
  end)
end

--- tmux's effective `allow-passthrough` for this pane ("on", "all", "off"), or nil outside tmux.
---@return string?
function M.tmux_passthrough()
  if not M.in_tmux() then
    return nil
  end
  return capture({ "tmux", "show-options", "-pv", "allow-passthrough" })
    or capture({ "tmux", "show-options", "-gv", "allow-passthrough" })
    or "off"
end

--- Whether tmux sends 24-bit colours to the attached client as they are. Without its `RGB` feature tmux reduces them
--- to the 256-colour palette, which destroys the image ids carried in placeholder colours.
---@return boolean? rgb nil outside tmux or when there is no attached client to ask about
---@return string? termname the attached client's $TERM
function M.tmux_rgb()
  if not M.in_tmux() then
    return nil
  end
  local out = capture({ "tmux", "display-message", "-p", "#{client_termname}\t#{client_termfeatures}" })
  local termname, features = (out or ""):match("^([^\t]*)\t?(.*)$")
  if not termname or termname == "" then
    return nil
  end
  return vim.tbl_contains(vim.split(features, ",", { trimempty = true }), "RGB"), termname
end

return M
