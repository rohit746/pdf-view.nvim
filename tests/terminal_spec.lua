local harness = require("tests.harness")
local eq = harness.eq
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
