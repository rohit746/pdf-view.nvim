local eq = require("tests.harness").eq
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
