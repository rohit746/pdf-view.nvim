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

  it("refuses a terminal it does not recognise", function()
    with_terminal(function(written)
      with_env({ TERM = "xterm-256color" }, function()
        local ok, reason = terminal.check()
        eq(false, ok)
        truthy(reason:find("`xterm-256color` does not look like", 1, true), reason)
        eq({}, written, "nothing is asked")
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

  it("asks any terminal when the placement is set to positioned, without `force`", function()
    with_terminal(function(written)
      config.setup({ placement = "positioned" })
      with_env({ TERM = "foot" }, function()
        eq(nil, (terminal.check()))
        terminal.ask_graphics(function() end)
        reply(ESC .. "_Gi=16777213;OK" .. ESC .. "\\")
        harness.wait_for(function()
          return terminal.graphics() ~= nil
        end, "the answer")
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
