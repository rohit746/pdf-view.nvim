local harness = require("tests.harness")
local eq = harness.eq
local placeholder = require("pdf-view.placeholder")

describe("placeholder", function()
  it("has kitty's 297 row/column marks, all distinct combining characters", function()
    eq(297, placeholder.MAX)
    local seen = {}
    for index = 1, placeholder.MAX do
      local mark = placeholder.mark(index)
      eq(false, seen[mark] or false, "duplicate mark at " .. index)
      seen[mark] = true
      eq(1, vim.fn.strdisplaywidth("a" .. mark), "mark " .. index .. " adds no width to its base character")
    end
  end)

  it("starts the table with the values kitty documents", function()
    eq(0x0305, vim.fn.char2nr(placeholder.mark(1)))
    eq(0x030D, vim.fn.char2nr(placeholder.mark(2)))
    eq(0x1D244, vim.fn.char2nr(placeholder.mark(297)))
  end)

  it("draws every cell as U+10EEEE plus its row and column mark", function()
    local grid = placeholder.build(3, 2, 0, 0, 2)
    eq(2, #grid.lines)
    local expected_first = placeholder.PLACEHOLDER .. placeholder.mark(1) .. placeholder.mark(1)
    eq(expected_first, grid.lines[1]:sub(1, #expected_first))
    local expected_last = placeholder.PLACEHOLDER .. placeholder.mark(2) .. placeholder.mark(3)
    eq(expected_last, grid.lines[2]:sub(-#expected_last))
  end)

  it("makes each cell one screen column wide", function()
    local grid = placeholder.build(7, 2, 0, 0, 2)
    eq(7, vim.fn.strdisplaywidth(grid.lines[1]))
  end)

  it("centres with blank lines above and spaces to the left", function()
    local grid = placeholder.build(4, 3, 5, 2, 10)
    eq(10, #grid.lines)
    eq("", grid.lines[1])
    eq("", grid.lines[2])
    eq("     ", grid.lines[3]:sub(1, 5))
    eq("", grid.lines[6])
    eq("", grid.lines[10])
  end)

  it("reports the range to highlight", function()
    local grid = placeholder.build(4, 3, 5, 2, 10)
    eq(2, grid.row)
    eq(4, grid.end_row)
    eq(5, grid.col)
    eq(#grid.lines[5], grid.end_col)
  end)

  it("rejects images larger than the placeholder grid", function()
    local ok = pcall(placeholder.build, placeholder.MAX + 1, 1, 0, 0, 1)
    eq(false, ok)
  end)
end)
