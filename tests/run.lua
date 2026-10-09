-- Usage: nvim --headless -u NONE -i NONE -l tests/run.lua [spec files...]
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. package.path

local harness = require("tests.harness")
_G.describe, _G.it = harness.describe, harness.it

local specs = #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
for _, spec in ipairs(specs) do
  io.stdout:write(vim.fn.fnamemodify(spec, ":t"), "\n")
  dofile(spec)
end

os.exit(harness.summary() and 0 or 1)
