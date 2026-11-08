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
    return (report:find("image transmission:", 1, true) or report:find("Failed to run healthcheck", 1, true)) ~= nil
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
end)
