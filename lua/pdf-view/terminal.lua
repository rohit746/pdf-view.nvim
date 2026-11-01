local config = require("pdf-view.config")

local M = {}

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

--- How pages are put on screen: as Unicode placeholder cells, or as placements at the screen position of the window.
---@return "placeholders"|"positioned"
function M.placement()
  local mode = config.options.placement
  if mode ~= "auto" then
    return mode
  end
  return M.in_zellij() and "positioned" or "placeholders"
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
  local size = ffi.new("pdfview_winsize")
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

--- Identify a terminal that implements the Kitty graphics protocol *with* Unicode placeholders.
---@return { name?: string, term?: string }
function M.detect()
  if detected then
    return detected
  end
  local env = vim.env
  local term = env.TERM or ""
  local program = (env.TERM_PROGRAM or ""):lower()

  local function classify(value)
    value = (value or ""):lower()
    if value:find("kitty", 1, true) then
      return "kitty"
    elseif value:find("ghostty", 1, true) then
      return "ghostty"
    end
  end

  -- zellij passes the outer terminal's $TERM, $TERM_PROGRAM, $KITTY_WINDOW_ID and $GHOSTTY_RESOURCES_DIR on to its
  -- panes, so the checks below see through it
  local name
  if M.in_tmux() then
    -- inside tmux $TERM says nothing about the outer terminal, but the attached client knows
    name = classify(capture({ "tmux", "display-message", "-p", "#{client_termname}" }))
  end
  name = name
    or classify(term)
    or classify(program)
    or ((env.KITTY_WINDOW_ID or "") ~= "" and "kitty")
    or ((env.GHOSTTY_RESOURCES_DIR or "") ~= "" and "ghostty")
    or nil

  detected = { name = name or nil, term = program ~= "" and program or term }
  return detected
end

--- Whether pages can be displayed here. The second return value explains a failure.
---@return boolean, string?
function M.check()
  if config.options.force then
    return true
  end
  if M.detect().name then
    return true
  end
  local term = M.detect().term
  local needs = M.placement() == "positioned" and "Kitty graphics" or "Kitty graphics and Unicode placeholder"
  return false,
    (
      "pdf-view: %s does not look like a terminal with %s support (kitty, Ghostty). "
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
      detected, prepared = nil, nil -- `prepare()` notes the new client
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

--- How images are handed to the terminal. A local terminal can read the PNG itself; over SSH the bytes are sent, and
--- so they are when the terminal said it cannot read the file (see `probe_file()`).
---@return "file"|"direct"
function M.transmission()
  local mode = config.options.transmission
  if mode ~= "auto" then
    return mode
  end
  if over_ssh() or (M.probe and M.probe.state == "failed") then
    return "direct"
  end
  return "file"
end

-- image id of the probe, above the ids of pages (see `allocate_ids()` in session.lua)
local PROBE_ID = 0xFFFFFE
-- a 1x1 transparent PNG
local PROBE_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
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
  if M.probe or config.options.transmission ~= "auto" or over_ssh() then
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
  timer = vim.uv.new_timer()
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
