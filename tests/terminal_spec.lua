local harness = require("tests.harness")
local eq, truthy = harness.eq, harness.truthy
local config = require("pdf-view.config")
local fixture = require("tests.fixture")
local kitty = require("pdf-view.kitty")
local terminal = require("pdf-view.terminal")

--- Run `body` with $TMUX set and `tmux display-message` answering `stdout`.
---@param stdout string?
---@param body fun()
local function in_tmux(stdout, body)
  local saved_tmux, saved_system = vim.env.TMUX, vim.system
  vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(cmd)
    assert(cmd[1] == "tmux" and cmd[2] == "display-message", vim.inspect(cmd))
    return {
      wait = function()
        return { code = stdout and 0 or 1, stdout = stdout or "" }
      end,
    }
  end
  local ok, err = pcall(body)
  vim.env.TMUX, vim.system = saved_tmux, saved_system
  assert(ok, err)
end

describe("terminal.tmux_rgb", function()
  it("is nil outside tmux", function()
    local saved = vim.env.TMUX
    vim.env.TMUX = nil
    eq(nil, terminal.tmux_rgb())
    vim.env.TMUX = saved
  end)

  it("sees the RGB feature of the attached client", function()
    in_tmux("xterm-kitty\tbpaste,ccolour,clipboard,cstyle,focus,RGB,title\n", function()
      eq({ true, "xterm-kitty" }, { terminal.tmux_rgb() })
    end)
  end)

  it("reports a client without RGB, which tmux reduces to 256 colours", function()
    in_tmux("xterm-256color\tbpaste,ccolour,clipboard,cstyle,focus,title\n", function()
      eq({ false, "xterm-256color" }, { terminal.tmux_rgb() })
    end)
  end)

  it("cannot tell without an attached client", function()
    in_tmux("\t\n", function()
      eq(nil, terminal.tmux_rgb())
    end)
    in_tmux(nil, function()
      eq(nil, terminal.tmux_rgb())
    end)
  end)
end)

local ESC = "\27"
local PROBE = ESC .. "_Gi=16777214"

--- Run `body` with the terminal stubbed: a UI attached, no SSH, graphics output captured, the probe not made yet.
---@param body fun(written: string[])
local function with_terminal(body)
  local saved = {
    ui_attached = terminal.ui_attached,
    write = kitty.write,
    on_fallback = terminal.on_fallback,
    probe = terminal.probe,
    options = config.options,
    ssh = { vim.env.SSH_CONNECTION, vim.env.SSH_TTY, vim.env.TMUX },
  }
  local written = {}
  terminal.ui_attached = function()
    return true
  end
  kitty.write = function(data)
    written[#written + 1] = data
  end
  terminal.probe = nil
  vim.env.SSH_CONNECTION, vim.env.SSH_TTY, vim.env.TMUX = nil, nil, nil
  config.setup({})
  local ok, err = pcall(body, written)
  terminal.ui_attached, kitty.write, terminal.on_fallback = saved.ui_attached, saved.write, saved.on_fallback
  terminal.probe, config.options = saved.probe, saved.options
  vim.env.SSH_CONNECTION, vim.env.SSH_TTY, vim.env.TMUX = saved.ssh[1], saved.ssh[2], saved.ssh[3]
  if not ok then
    error(err, 0)
  end
end

---@param written string[]
---@return string path the probe asked the terminal to read
local function probed_path(written)
  eq(1, #written, "one probe command")
  local keys, payload = written[1]:match("^" .. ESC .. "_G([^;]*);(.*)" .. ESC .. "\\$")
  eq("a=q,f=100,i=16777214,t=f", keys)
  return vim.base64.decode(payload)
end

---@param sequence string
local function reply(sequence)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = sequence } })
end

describe("terminal", function()
  it("reads the terminal's answer to the probe", function()
    eq(true, terminal.probe_reply(PROBE .. ";OK" .. ESC .. "\\"))
    eq(true, terminal.probe_reply(PROBE .. ";OK"))
    local ok, message = terminal.probe_reply(PROBE .. ";EBADF:Failed to open file" .. ESC .. "\\")
    eq(false, ok)
    eq("EBADF:Failed to open file", message)
    eq(nil, terminal.probe_reply(ESC .. "_Gi=1048577;ENOENT:No such image" .. ESC .. "\\"), "a reply about a page")
    eq(nil, terminal.probe_reply(ESC .. "[?62;4c"), "not a graphics reply")
  end)

  if vim.fn.has("nvim-0.12") == 0 then
    it("asks nothing on Neovim 0.11, which cannot read the answer", function()
      with_terminal(function(written)
        terminal.probe_file(fixture.tmpdir())
        eq({}, written)
        eq("file", terminal.transmission())
      end)
    end)
    return
  end

  it("sends pages as bytes once the terminal says it cannot read the PNG", function()
    with_terminal(function(written)
      local fallbacks = 0
      terminal.on_fallback = function()
        fallbacks = fallbacks + 1
      end
      local dir = fixture.tmpdir()
      terminal.probe_file(dir)
      local path = probed_path(written)
      eq(dir, vim.fs.dirname(path), "the probe is a file in the directory pages are rendered to")
      eq(true, vim.uv.fs_stat(path) ~= nil, "the probe file exists while the terminal is asked")
      eq("file", terminal.transmission(), "unchanged until the terminal answers")

      reply(PROBE .. ";EBADF:Failed to open file" .. ESC .. "\\")
      harness.wait_for(function()
        return terminal.probe.state ~= "pending"
      end, "the answer")
      eq({ state = "failed", error = "EBADF:Failed to open file" }, terminal.probe)
      eq("direct", terminal.transmission())
      eq(1, fallbacks, "pages already sent are sent again")
      eq(nil, vim.uv.fs_stat(path), "the probe file is removed")

      terminal.probe_file(dir)
      eq(1, #written, "the terminal is asked only once")
    end)
  end)

  it("keeps sending paths when the terminal can read them", function()
    with_terminal(function(written)
      terminal.probe_file(fixture.tmpdir())
      local path = probed_path(written)
      reply(ESC .. "_Gi=1048577;ENOENT:No such image" .. ESC .. "\\") -- about something else
      reply(PROBE .. ";OK" .. ESC .. "\\")
      harness.wait_for(function()
        return terminal.probe.state ~= "pending"
      end, "the answer")
      eq("ok", terminal.probe.state)
      eq("file", terminal.transmission())
      eq(nil, vim.uv.fs_stat(path), "the probe file is removed")
    end)
  end)

  --- Run `body` in a pretend tmux whose `extended-keys` server option is `mode`.
  ---@param mode string
  ---@param body fun()
  local function with_extended_keys(mode, body)
    local saved_system = vim.system
    vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd)
      local asked = table.concat(cmd, " ")
      assert(asked == "tmux show-options -sv extended-keys", asked)
      return {
        wait = function()
          return { code = 0, stdout = mode .. "\n" }
        end,
      }
    end
    local ok, err = pcall(body)
    vim.system = saved_system
    if not ok then
      error(err, 0)
    end
  end

  it("asks nothing behind tmux with extended keys, which would type the answer into the buffer", function()
    for _, mode in ipairs({ "on", "always" }) do
      with_terminal(function(written)
        with_extended_keys(mode, function()
          eq(true, terminal.replies_arrive_as_keys())
          terminal.probe_file(fixture.tmpdir())
        end)
        eq({}, written, mode)
        eq({ state = "unasked" }, terminal.probe, mode)
        eq("file", terminal.transmission(), mode)
      end)
    end
  end)

  it("asks behind tmux with extended keys off", function()
    with_terminal(function(written)
      with_extended_keys("off", function()
        eq(false, terminal.replies_arrive_as_keys())
        terminal.probe_file(fixture.tmpdir())
      end)
      eq(1, #written, "one probe command")
      eq(
        true,
        written[1]:find("^" .. ESC .. "Ptmux;" .. ESC .. ESC .. "_Ga=q,f=100,i=16777214,t=f;") ~= nil,
        written[1]
      )
      eq("pending", terminal.probe.state)
      reply(PROBE .. ";OK" .. ESC .. "\\")
      harness.wait_for(function()
        return terminal.probe.state ~= "pending"
      end, "the answer")
    end)
  end)

  it("asks nothing when the transmission is set, or over SSH", function()
    with_terminal(function(written)
      config.setup({ transmission = "file" })
      terminal.probe_file(fixture.tmpdir())
      config.setup({})
      vim.env.SSH_CONNECTION = "10.0.0.1 22 10.0.0.2 22"
      terminal.probe_file(fixture.tmpdir())
      eq("direct", terminal.transmission())
      eq({}, written)
      eq(nil, terminal.probe)
    end)
  end)
end)

local TERMINAL_VARS = {
  "TERM",
  "TERM_PROGRAM",
  "KITTY_WINDOW_ID",
  "GHOSTTY_RESOURCES_DIR",
  "WEZTERM_EXECUTABLE",
  "KONSOLE_VERSION",
  "LC_TERMINAL",
  "TERMINAL_NAME",
  "MLTERM",
  "WT_SESSION",
  "XTERM_VERSION",
  "TMUX",
  "ZELLIJ",
}

--- Run `body` with only the terminal variables in `vars` set, and nothing detected yet.
---@param vars table<string, string>
---@param body fun()
local function with_env(vars, body)
  local saved = {}
  for _, name in ipairs(TERMINAL_VARS) do
    saved[name] = vim.env[name]
    vim.env[name] = vars[name]
  end
  terminal.forget()
  local ok, err = pcall(body)
  for _, name in ipairs(TERMINAL_VARS) do
    vim.env[name] = saved[name]
  end
  terminal.forget()
  if not ok then
    error(err, 0)
  end
end

describe("terminal.detect", function()
  it("recognises WezTerm and Konsole, which have Kitty graphics but no Unicode placeholders", function()
    config.setup()
    with_env(
      { TERM = "xterm-256color", TERM_PROGRAM = "WezTerm", WEZTERM_EXECUTABLE = "/usr/bin/wezterm-gui" },
      function()
        eq({ name = "wezterm", term = "wezterm", placeholders = false }, terminal.detect())
        eq("positioned", terminal.placement())
      end
    )
    with_env({ TERM = "xterm-256color", WEZTERM_EXECUTABLE = "/usr/bin/wezterm-gui" }, function()
      eq("wezterm", terminal.detect().name, "by $WEZTERM_EXECUTABLE alone, as inside tmux")
    end)
    with_env({ TERM = "xterm-256color", KONSOLE_VERSION = "251203" }, function()
      eq({ name = "konsole", term = "xterm-256color", placeholders = false }, terminal.detect())
      eq("positioned", terminal.placement())
      eq(true, terminal.hides_images_under_text())
      eq(true, terminal.bytes_only())
    end)
  end)

  it("keeps placeholders for kitty and Ghostty, and recognises nothing in xterm", function()
    config.setup()
    with_env({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" }, function()
      eq({ name = "kitty", term = "xterm-kitty", placeholders = true }, terminal.detect())
      eq("placeholders", terminal.placement())
      eq(false, terminal.hides_images_under_text())
    end)
    with_env({ TERM = "xterm-ghostty", TERM_PROGRAM = "ghostty" }, function()
      eq("ghostty", terminal.detect().name)
      eq("placeholders", terminal.placement())
    end)
    with_env({ TERM = "xterm-256color" }, function()
      eq({ term = "xterm-256color" }, terminal.detect())
      eq("placeholders", terminal.placement())
    end)
  end)

  it("sends iTerm2 inline images to iTerm2 and VS Code, at the window's position", function()
    config.setup()
    with_env({ TERM = "xterm-256color", TERM_PROGRAM = "iTerm.app" }, function()
      eq({ name = "iterm2", term = "iterm.app", placeholders = false }, terminal.detect())
      eq("iterm2", terminal.protocol())
      eq("positioned", terminal.placement())
    end)
    with_env({ TERM = "xterm-256color", LC_TERMINAL = "iTerm2" }, function()
      eq("iterm2", terminal.detect().name, "by $LC_TERMINAL, which ssh passes on")
      eq("iterm2", terminal.protocol())
    end)
    with_env({ TERM = "xterm-256color", TERM_PROGRAM = "vscode" }, function()
      eq("vscode", terminal.detect().name)
      eq("iterm2", terminal.protocol())
      eq("positioned", terminal.placement())
    end)
    for _, vars in ipairs({
      { TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" },
      { TERM_PROGRAM = "WezTerm" },
      { KONSOLE_VERSION = "251203" },
      { TERM = "xterm-256color" },
    }) do
      with_env(vars, function()
        eq("kitty", terminal.protocol(), vim.inspect(vars))
      end)
    end
    with_env({ TERM_PROGRAM = "iTerm.app", ZELLIJ = "0" }, function()
      eq("kitty", terminal.protocol(), "zellij draws Kitty graphics itself")
    end)
  end)

  it("sends sixel images to the terminals that draw them, at the window's position", function()
    config.setup()
    for _, case in ipairs({
      { { TERM = "foot" }, "foot" },
      { { TERM = "foot-extra" }, "foot" },
      { { TERM = "xterm-256color", XTERM_VERSION = "XTerm(390)" }, "xterm" },
      { { TERM = "xterm-256color", WT_SESSION = "8e4f6c3a" }, "windows-terminal" },
      { { TERM = "contour", TERMINAL_NAME = "contour" }, "contour" },
      { { TERM = "xterm-256color", TERMINAL_NAME = "contour" }, "contour" },
      { { TERM = "mlterm" }, "mlterm" },
      { { TERM = "xterm-256color", MLTERM = "3.9.3" }, "mlterm" },
    }) do
      with_env(case[1], function()
        eq(case[2], terminal.detect().name, vim.inspect(case[1]))
        eq(false, terminal.detect().placeholders)
        eq("sixel", terminal.protocol(), vim.inspect(case[1]))
        eq("positioned", terminal.placement())
      end)
    end
    with_env({ TERM = "foot", ZELLIJ = "0" }, function()
      eq("kitty", terminal.protocol(), "zellij draws Kitty graphics itself")
    end)
    with_env({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1", XTERM_VERSION = "XTerm(390)" }, function()
      eq("kitty", terminal.detect().name, "kitty started from an xterm")
    end)
    with_env({ TERM = "tmux-256color", TERM_PROGRAM = "tmux" }, function()
      in_tmux("xterm-256color XTerm(390)\n", function()
        eq("xterm", terminal.detect().name, "by the name xterm gave tmux")
        eq("sixel", terminal.protocol())
      end)
    end)
    config.setup({ protocol = "sixel" })
    with_env({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" }, function()
      eq("sixel", terminal.protocol())
      eq("positioned", terminal.placement(), "sixel images have no placeholders")
    end)
    config.setup()
  end)

  it("reads the device attributes", function()
    eq({ 65, 4, 6, 18, 22, 52 }, terminal.da1_attributes(ESC .. "[?65;4;6;18;22;52c"))
    eq({ 62, 22 }, terminal.da1_attributes(ESC .. "[?62;22c"))
    eq(nil, terminal.da1_attributes(ESC .. "[?1;0;1024S"))
    eq(nil, terminal.da1_attributes(ESC .. "_Gi=1;OK" .. ESC .. "\\"))
  end)

  it("recognises iTerm2 behind tmux by the name the client gave", function()
    config.setup()
    with_env({ TERM = "tmux-256color", TERM_PROGRAM = "tmux" }, function()
      in_tmux("xterm-256color iTerm2 3.5.14\n", function()
        eq("iterm2", terminal.detect().name)
        eq("iterm2", terminal.protocol())
      end)
    end)
    with_env({ TERM = "tmux-256color", TERM_PROGRAM = "tmux" }, function()
      in_tmux("xterm-kitty kitty(0.45.0)\n", function()
        eq("kitty", terminal.detect().name)
      end)
    end)
  end)

  it("lets the protocol option win", function()
    config.setup({ protocol = "iterm2" })
    with_env({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" }, function()
      eq("iterm2", terminal.protocol())
      eq("positioned", terminal.placement(), "iTerm2 images have no placeholders")
    end)
    config.setup({ protocol = "kitty" })
    with_env({ TERM_PROGRAM = "iTerm.app" }, function()
      eq("kitty", terminal.protocol())
    end)
    config.setup()
  end)

  it("lets the placement option win", function()
    config.setup({ placement = "placeholders" })
    with_env({ TERM_PROGRAM = "WezTerm" }, function()
      eq("placeholders", terminal.placement())
    end)
    config.setup()
  end)
end)

describe("terminal.check", function()
  local QUERY = "a=q,f=100,i=16777213,t=d;"

  ---@param written string[]
  ---@return integer queries graphics queries written
  local function queries(written)
    local count = 0
    for _, data in ipairs(written) do
      count = count + (data:find(QUERY, 1, true) and 1 or 0)
    end
    return count
  end

  it("says that WezTerm has no placeholders when they are asked for", function()
    with_terminal(function()
      config.setup({ placement = "placeholders" })
      with_env({ TERM_PROGRAM = "WezTerm" }, function()
        local ok, reason = terminal.check()
        eq(false, ok)
        truthy(reason:find("wezterm has no Unicode placeholders", 1, true), reason)
      end)
    end)
  end)

  it("accepts iTerm2 without asking anything", function()
    with_terminal(function(written)
      with_env({ TERM = "xterm-256color", TERM_PROGRAM = "iTerm.app" }, function()
        eq(true, (terminal.check()))
        terminal.probe_file(fixture.tmpdir())
        eq(nil, terminal.probe, "no question about files: the image travels in the sequence")
      end)
      eq({}, written)
    end)
  end)

  it("asks VS Code whether it shows images, which its device attributes say", function()
    for _, case in ipairs({
      { ESC .. "[?62;4;9;22c", true }, -- the image addon is loaded
      { ESC .. "[?1;2c", false }, -- enableImages is off, or the WebGL renderer is not in use
    }) do
      with_terminal(function(written)
        with_env({ TERM = "xterm-256color", TERM_PROGRAM = "vscode" }, function()
          if vim.fn.has("nvim-0.12") == 0 then
            eq(true, (terminal.check()), "Neovim 0.11 cannot read the answer")
            eq({}, written)
            return
          end
          eq(nil, (terminal.check()), "it is asked first")
          local done = false
          terminal.ask(function()
            done = true
          end)
          eq({ ESC .. "[c" }, written)
          reply(case[1])
          harness.wait_for(function()
            return done
          end, "the answer")
          eq("iterm2", terminal.protocol(), "still iTerm2 images, whatever it says about sixel")
          local ok, reason = terminal.check()
          eq(case[2], ok, case[1])
          if not ok then
            truthy(reason:find('"terminal.integrated.enableImages": true', 1, true), reason)
            truthy(reason:find("gpuAcceleration", 1, true), reason)
          end
          terminal.probe_file(fixture.tmpdir())
          eq(nil, terminal.probe, "no question about files: the image travels in the sequence")
          eq(1, #written, "asked once")
        end)
      end)
    end
  end)

  it("takes VS Code that does not answer, or inside tmux, at its name", function()
    if vim.fn.has("nvim-0.12") == 0 then
      return
    end
    with_terminal(function(written)
      with_env({ TERM = "xterm-256color", TERM_PROGRAM = "vscode" }, function()
        local done = false
        terminal.ask(function()
          done = true
        end)
        harness.wait_for(function()
          return done
        end, "the question to time out")
        eq(true, (terminal.check()))
      end)
      eq(1, #written)
    end)
    with_terminal(function(written)
      with_env({ TERM = "tmux-256color", TERM_PROGRAM = "tmux" }, function()
        in_tmux("vscode xterm-256color", function()
          eq("vscode", terminal.detect().name)
          eq(true, (terminal.check()), "tmux answers DA1 itself")
        end)
      end)
      eq({}, written)
    end)
  end)

  it("says that iTerm2 images have no placeholders when they are asked for", function()
    with_terminal(function()
      config.setup({ placement = "placeholders" })
      with_env({ TERM_PROGRAM = "iTerm.app" }, function()
        local ok, reason = terminal.check()
        eq(false, ok)
        truthy(reason:find("iTerm2 inline images have no Unicode placeholders", 1, true), reason)
      end)
    end)
  end)

  it("refuses a terminal it does not recognise, which does not say it draws sixel", function()
    with_terminal(function(written)
      with_env({ TERM = "xterm-256color" }, function()
        if vim.fn.has("nvim-0.12") == 1 then
          eq(nil, (terminal.check()), "it is asked first")
          local done = false
          terminal.ask(function()
            done = true
          end)
          eq({ ESC .. "[c" }, written, "only whether it draws sixel: placeholders are not set to positioned")
          reply(ESC .. "[?62;22c")
          harness.wait_for(function()
            return done
          end, "the answer")
          eq(false, terminal.sixel())
        end
        local ok, reason = terminal.check()
        eq(false, ok)
        truthy(reason:find("`xterm-256color` does not look like", 1, true), reason)
        eq(vim.fn.has("nvim-0.12") == 1 and 1 or 0, #written, "not asked again")
      end)
    end)
  end)

  if vim.fn.has("nvim-0.12") == 0 then
    it("accepts WezTerm without asking on Neovim 0.11, which cannot read the answer", function()
      with_terminal(function(written)
        with_env({ TERM_PROGRAM = "WezTerm" }, function()
          eq(true, (terminal.check()))
          eq({}, written)
        end)
      end)
    end)
    return
  end

  it("asks a terminal without placeholders whether it has Kitty graphics, once", function()
    with_terminal(function(written)
      with_env({ KONSOLE_VERSION = "251203" }, function()
        eq(nil, (terminal.check()), "not known yet")
        local answered = 0
        terminal.ask_graphics(function()
          answered = answered + 1
        end)
        terminal.ask_graphics(function()
          answered = answered + 1
        end)
        eq(1, queries(written), "one query for both")
        reply(ESC .. "_Gi=16777213;OK" .. ESC .. "\\")
        harness.wait_for(function()
          return answered == 2
        end, "the answer")
        eq(true, terminal.graphics())
        eq(true, (terminal.check()))
        terminal.ask_graphics(function()
          answered = answered + 1
        end)
        eq(3, answered, "known: at once")
        eq(1, queries(written), "not asked again")
      end)
    end)
  end)

  it("tells how to turn on WezTerm's Kitty graphics when it does not answer", function()
    with_terminal(function(written)
      with_env({ TERM_PROGRAM = "WezTerm" }, function()
        local done = false
        terminal.ask_graphics(function()
          done = true
        end)
        eq(1, queries(written))
        harness.wait_for(function()
          return done
        end, "the query to time out")
        eq(false, terminal.graphics())
        local ok, reason = terminal.check()
        eq(false, ok)
        truthy(reason:find("enable_kitty_graphics = true", 1, true), reason)
      end)
    end)
  end)

  it("gives sixel to a terminal it does not recognise that says it draws sixel", function()
    with_terminal(function(written)
      with_env({ TERM = "xterm-256color" }, function()
        eq(nil, (terminal.check()))
        local done = false
        terminal.ask(function()
          done = true
        end)
        reply(ESC .. "[?65;4;6;18;22c")
        harness.wait_for(function()
          return done
        end, "the answer")
        eq(true, terminal.sixel())
        eq("sixel", terminal.protocol())
        eq("positioned", terminal.placement())
        eq(true, (terminal.check()))
        eq({ ESC .. "[c" }, written)
      end)
    end)
  end)

  it("asks xterm whether it draws sixel, and says how to make it", function()
    with_terminal(function(written)
      with_env({ TERM = "xterm-256color", XTERM_VERSION = "XTerm(390)" }, function()
        eq(nil, (terminal.check()))
        local done = false
        terminal.ask(function()
          done = true
        end)
        eq({ ESC .. "[c" }, written, "no Kitty graphics query: the answer would not change anything")
        reply(ESC .. "[?64;1;2;6;9;15;16;17;18;21;22;28c") -- a VT420, xterm's default
        harness.wait_for(function()
          return done
        end, "the answer")
        local ok, reason = terminal.check()
        eq(false, ok)
        truthy(reason:find("xterm -ti vt340", 1, true), reason)
      end)
    end)
  end)

  it("takes a sixel terminal that does not answer at its name", function()
    with_terminal(function(written)
      with_env({ TERM = "foot" }, function()
        eq(nil, (terminal.check()))
        local done = false
        terminal.ask(function()
          done = true
        end)
        harness.wait_for(function()
          return done
        end, "the question to time out")
        eq(nil, terminal.sixel())
        eq(true, (terminal.check()))
        eq(1, #written, "asked once")
      end)
    end)
  end)

  it("asks what the protocol set by hand needs, and then knows", function()
    with_terminal(function(written)
      for _, case in ipairs({
        { { TERM_PROGRAM = "WezTerm" }, "sixel", ESC .. "[?65;4;6c", "[c" },
        { { TERM = "foot" }, "kitty", ESC .. "_Gi=16777213;OK" .. ESC .. "\\", "i=16777213" },
      }) do
        config.setup({ protocol = case[2] })
        with_env(case[1], function()
          eq(nil, (terminal.check()), case[2])
          local done = false
          terminal.ask(function()
            done = true
          end)
          eq(1, #written, "asked one question")
          truthy(written[1]:find(case[4], 1, true), written[1])
          reply(case[3])
          harness.wait_for(function()
            return done
          end, "the answer")
          eq(true, (terminal.check()), case[2])
        end)
        for index = #written, 1, -1 do
          written[index] = nil
        end
      end
    end)
  end)

  it("asks any terminal when the placement is set to positioned, without `force`", function()
    with_terminal(function(written)
      config.setup({ placement = "positioned" })
      with_env({ TERM = "st-256color" }, function()
        eq(nil, (terminal.check()))
        local done = false
        terminal.ask(function()
          done = true
        end)
        reply(ESC .. "_Gi=16777213;OK" .. ESC .. "\\")
        reply(ESC .. "[?62;22c")
        harness.wait_for(function()
          return done
        end, "both answers")
        eq(true, terminal.graphics())
        eq("kitty", terminal.protocol())
        eq(true, (terminal.check()))
        eq(1, queries(written))
      end)
    end)
  end)
end)

describe("terminal.pane_offset", function()
  it("is 0, 0 outside tmux", function()
    local saved = vim.env.TMUX
    vim.env.TMUX = nil
    eq({ 0, 0 }, { terminal.pane_offset(true) })
    vim.env.TMUX = saved
  end)

  it("adds a status line at the top to the pane's position", function()
    in_tmux("16 51 on top\n", function()
      eq({ 17, 51 }, { terminal.pane_offset(true) })
    end)
    in_tmux("3 0 2 top\n", function()
      eq({ 5, 0 }, { terminal.pane_offset(true) })
    end)
    in_tmux("16 51 on bottom\n", function()
      eq({ 16, 51 }, { terminal.pane_offset(true) })
      eq({ 16, 51 }, { terminal.pane_offset() }, "remembered")
    end)
    in_tmux(nil, function()
      eq({ 0, 0 }, { terminal.pane_offset(true) }, "tmux did not answer")
    end)
    terminal.forget()
  end)
end)
