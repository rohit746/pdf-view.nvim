local harness = require("tests.harness")
local eq = harness.eq
local config = require("pdf-view.config")
local positioned = require("pdf-view.positioned")
local terminal = require("pdf-view.terminal")

local function rect(row, col, rows, cols)
  return { row = row, col = col, rows = rows, cols = cols }
end

--- Every cell of `rects`, counting cells that are in several of them more than once.
local function cells(rects)
  local seen, total = {}, 0
  for _, r in ipairs(rects) do
    for row = r.row, r.row + r.rows - 1 do
      for col = r.col, r.col + r.cols - 1 do
        local key = row .. ":" .. col
        seen[key] = (seen[key] or 0) + 1
        total = total + 1
      end
    end
  end
  return seen, total
end

describe("positioned", function()
  it("keeps the whole area when nothing covers it", function()
    eq({ rect(2, 3, 10, 20) }, positioned.subtract(rect(2, 3, 10, 20), {}))
    eq({ rect(2, 3, 10, 20) }, positioned.subtract(rect(2, 3, 10, 20), { rect(0, 0, 2, 80), rect(2, 23, 5, 5) }))
  end)

  it("leaves nothing of an area that is covered completely", function()
    eq({}, positioned.subtract(rect(2, 3, 10, 20), { rect(0, 0, 40, 80) }))
  end)

  it("cuts a hole in the middle into four pieces around it", function()
    local pieces = positioned.subtract(rect(0, 0, 10, 10), { rect(3, 4, 2, 3) })
    eq({ rect(0, 0, 3, 10), rect(3, 0, 2, 4), rect(3, 7, 2, 3), rect(5, 0, 5, 10) }, pieces)
  end)

  it("covers every uncovered cell exactly once, for overlapping holes", function()
    local area = rect(1, 2, 12, 15)
    local holes = { rect(0, 0, 4, 6), rect(3, 5, 4, 4), rect(8, 10, 10, 10), rect(5, 6, 1, 1) }
    local pieces = positioned.subtract(area, holes)
    local seen, total = cells(pieces)
    local expected = 0
    for row = area.row, area.row + area.rows - 1 do
      for col = area.col, area.col + area.cols - 1 do
        local covered = false
        for _, h in ipairs(holes) do
          covered = covered or (row >= h.row and row < h.row + h.rows and col >= h.col and col < h.col + h.cols)
        end
        local key = row .. ":" .. col
        if covered then
          eq(nil, seen[key], "covered cell " .. key .. " is in a piece")
        else
          eq(1, seen[key], "uncovered cell " .. key)
          expected = expected + 1
        end
      end
    end
    eq(expected, total, "no cell twice")
  end)

  it("merges rows that have the same uncovered columns", function()
    -- a float over the left edge, from the top to the middle: the right part is one piece, not one per band
    local pieces = positioned.subtract(rect(0, 0, 10, 10), { rect(0, 0, 5, 3), rect(2, 0, 1, 3) })
    eq({ rect(0, 3, 5, 7), rect(5, 0, 5, 10) }, pieces)
  end)

  it("splits pieces until no two have the same size", function()
    -- a float in the middle leaves pieces of equal size above and below it, and left and right of it
    local pieces = positioned.distinct(positioned.subtract(rect(0, 0, 9, 10), { rect(3, 4, 3, 2) }))
    local sizes, area = {}, 0
    for _, piece in ipairs(pieces) do
      local size = piece.rows .. "x" .. piece.cols
      eq(nil, sizes[size], "two pieces of size " .. size)
      sizes[size] = true
      area = area + piece.rows * piece.cols
    end
    eq(9 * 10 - 3 * 2, area, "nothing lost")
    local seen = cells(pieces)
    eq(nil, seen["4:4"], "the hole stays empty")
  end)

  it("reads the image id from a reply saying that the terminal does not know the image", function()
    eq(1234, positioned.lost_image("\27_Gi=1234,p=1;ENOENT:unknown image id\27\\"))
    eq(77, positioned.lost_image("\27_Gi=77;ENOENT:no such image\27\\"))
    eq(nil, positioned.lost_image("\27_Gi=1234,p=1;EINVAL:bad\27\\"))
    eq(nil, positioned.lost_image("\27_Gi=1234;OK\27\\"))
    eq(nil, positioned.lost_image("\27]11;rgb:0000/0000/0000\27\\"))
  end)

  it("uses placements at the window's position inside zellij, placeholders elsewhere", function()
    local zellij = vim.env.ZELLIJ
    vim.env.ZELLIJ = "0"
    config.setup()
    eq("positioned", terminal.placement())
    config.setup({ placement = "placeholders" })
    eq("placeholders", terminal.placement(), "the option wins")
    vim.env.ZELLIJ = nil
    config.setup()
    eq("placeholders", terminal.placement())
    config.setup({ placement = "positioned" })
    eq("positioned", terminal.placement())
    vim.env.ZELLIJ = zellij
    config.setup()
  end)
end)
