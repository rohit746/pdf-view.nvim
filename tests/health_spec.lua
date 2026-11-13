local harness = require("tests.harness")
local truthy = harness.truthy
local config = require("pdf-view.config")
local terminal = require("pdf-view.terminal")

--- The text of `:checkhealth pdf-view`.
---@return string
local function checkhealth()
  vim.cmd("silent checkhealth pdf-view")
  local buf = vim.api.nvim_get_current_buf()
  local report = ""
  -- Neovim 0.13 runs the checks asynchronously and fills the buffer when they are done
  vim.wait(10000, function()
    report = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return (
      report:find("image transmission:", 1, true)
      or report:find("is not a terminal", 1, true)
      or report:find("Failed to run healthcheck", 1, true)
    ) ~= nil
  end, 10)
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose") -- the report has a tab of its own unless the editor was empty
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return report
end

describe("health", function()
  it("runs :checkhealth pdf-view to the end, without a Lua error", function()
    config.setup()
    local report = checkhealth()
    -- a check that throws is reported in the buffer, and :checkhealth itself succeeds
    truthy(not report:find("Failed to run healthcheck", 1, true), report)
    truthy(report:find("image transmission:", 1, true), "the last check did not report:\n" .. report)
  end)

  it("reports iTerm2 inline images, which carry the PNG every time", function()
    config.setup({ protocol = "iterm2" })
    local report = checkhealth()
    truthy(report:find("with iTerm2 inline images (OSC 1337)", 1, true), report)
    truthy(report:find("pages are printed at the position of their window", 1, true), report)
    truthy(report:find("image transmission: bytes", 1, true), report)
    truthy(not report:find("Kitty graphics query", 1, true), "nothing is asked:\n" .. report)
    config.setup()
  end)

  it("says how to turn on VS Code's images when it cannot ask whether they are on", function()
    config.setup()
    local saved = { program = vim.env.TERM_PROGRAM, tmux = vim.env.TMUX, zellij = vim.env.ZELLIJ }
    vim.env.TERM_PROGRAM, vim.env.TMUX, vim.env.ZELLIJ = "vscode", nil, nil
    terminal.forget()
    local ok, report = pcall(checkhealth)
    vim.env.TERM_PROGRAM, vim.env.TMUX, vim.env.ZELLIJ = saved.program, saved.tmux, saved.zellij
    terminal.forget()
    assert(ok, report)
    truthy(report:find("VS Code, with iTerm2 inline images (OSC 1337)", 1, true), report)
    truthy(report:find('"terminal.integrated.enableImages": true', 1, true), report)
  end)

  it("reports sixel, which is drawn pixel for pixel", function()
    config.setup({ protocol = "sixel" })
    local report = checkhealth()
    truthy(report:find("with sixel", 1, true), report)
    truthy(report:find("pages are printed at the position of their window", 1, true), report)
    truthy(report:find("image transmission: bytes (a sixel image", 1, true), report)
    truthy(not report:find("Kitty graphics query", 1, true), "no Kitty graphics question:\n" .. report)
    config.setup({ protocol = "sixel", cell_size = { 9, 18 } })
    report = checkhealth()
    truthy(report:find("cell size: 9.0x18.0 px (config)", 1, true), report)
    config.setup()
  end)

  it("says what to do when the terminal was not asked, or did not answer, whether it reads the files", function()
    config.setup()
    local saved = { probe = terminal.probe, conn = vim.env.SSH_CONNECTION, tty = vim.env.SSH_TTY }
    vim.env.SSH_CONNECTION, vim.env.SSH_TTY = nil, nil -- over SSH, pages are sent as bytes and nothing is asked
    for _, state in ipairs({ "unasked", "silent" }) do
      terminal.probe = { state = state }
      local report = checkhealth()
      truthy(report:find('If pages stay blank, set `transmission = "direct"`', 1, true), state .. ":\n" .. report)
    end
    terminal.probe, vim.env.SSH_CONNECTION, vim.env.SSH_TTY = saved.probe, saved.conn, saved.tty
  end)

  it("reports the name a terminal the environment does not name gave when asked (XTVERSION)", function()
    if vim.fn.has("nvim-0.12") == 0 then
      return -- Neovim 0.11 cannot read the answer, so it is not asked
    end
    local kitty = require("pdf-view.kitty")
    local vars = { "TERM", "TERM_PROGRAM", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "WEZTERM_EXECUTABLE" }
    vim.list_extend(vars, { "KONSOLE_VERSION", "LC_TERMINAL", "TERMINAL_NAME", "MLTERM", "WT_SESSION" })
    vim.list_extend(vars, { "XTERM_VERSION", "TMUX", "ZELLIJ" })
    local saved_env = {}
    for _, name in ipairs(vars) do
      saved_env[name] = vim.env[name]
      vim.env[name] = nil
    end
    vim.env.TERM = "xterm-256color" -- kitty over SSH, without its terminfo on the host
    local saved = { ui_attached = terminal.ui_attached, write = kitty.write }
    ---@param name string? what the terminal answers to XTVERSION; nil when it does not know the question
    local function report_for(name)
      terminal.forget()
      ---@diagnostic disable-next-line: duplicate-set-field
      terminal.ui_attached = function()
        return true
      end
      ---@diagnostic disable-next-line: duplicate-set-field
      kitty.write = function(data)
        if data:find("\27[>q", 1, true) then
          vim.schedule(function()
            if name then
              vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27P>|" .. name .. "\27\\" } })
            end
            for _ = 1, 2 do
              vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;22c" } })
            end
          end)
        end
      end
      local ok, report = pcall(checkhealth)
      terminal.ui_attached, kitty.write = saved.ui_attached, saved.write
      return ok, report
    end
    config.setup()
    local ok, named = report_for("kitty(0.36.4)")
    local ok_silent, silent = report_for(nil)
    for _, name in ipairs(vars) do
      vim.env[name] = saved_env[name]
    end
    terminal.forget()
    assert(ok, named)
    assert(ok_silent, silent)
    truthy(named:find("it named itself `kitty(0.36.4)` when asked (XTVERSION)", 1, true), named)
    truthy(named:find("OK terminal: kitty", 1, true), named)
    truthy(silent:find("it did not give its name when asked (XTVERSION)", 1, true), silent)
    truthy(silent:find("terminal not recognised", 1, true), silent)
  end)

  it("says that a GUI cannot show pages, whatever terminal it was started from", function()
    config.setup()
    local saved = { uis = vim.api.nvim_list_uis, term = vim.env.TERM, kitty = vim.env.KITTY_WINDOW_ID }
    vim.env.TERM, vim.env.KITTY_WINDOW_ID = "xterm-kitty", "1"
    terminal.forget()
    vim.api.nvim_list_uis = function()
      return { { stdout_tty = false, stdin_tty = false, term_name = "" } } -- what Neovide or nvim-qt reports
    end
    local ok, report = pcall(checkhealth)
    vim.api.nvim_list_uis, vim.env.TERM, vim.env.KITTY_WINDOW_ID = saved.uis, saved.term, saved.kitty
    terminal.forget()
    assert(ok, report)
    truthy(report:find("ERROR this Neovim UI is not a terminal, so it cannot show pages", 1, true), report)
    truthy(not report:find("terminal: kitty", 1, true), "the inherited environment is not reported:\n" .. report)
  end)
end)
