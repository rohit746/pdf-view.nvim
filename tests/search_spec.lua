local harness = require("tests.harness")
local eq, truthy = harness.eq, harness.truthy
local search = require("pdf-view.search")

local OUTPUT = table.concat({
  "1 0 612 792 10.00,20.00,50.00,30.00",
  "1 1 612 792 100.00,200.00,140.00,212.00;10.00,220.00,60.00,232.00",
  "3 0 612 792 300.00,400.00,360.00,412.00",
  "7 0 800 500 80.00,50.00,160.00,70.00",
}, "\n")

local function found(needle)
  local matches, truncated = search.parse(OUTPUT)
  return search.new(needle or "x", matches, truncated)
end

describe("search.parse", function()
  it("reads one match per line with its rectangles", function()
    local matches, truncated = search.parse(OUTPUT)
    eq(false, truncated)
    eq(
      { 1, 1, 3, 7 },
      vim.tbl_map(function(m)
        return m.page
      end, matches)
    )
    eq({ { 10, 20, 50, 30 } }, matches[1].rects)
    eq({ { 100, 200, 140, 212 }, { 10, 220, 60, 232 } }, matches[2].rects, "a wrapped match has a rectangle per line")
    eq({ 800, 500 }, { matches[4].width, matches[4].height })
  end)

  it("centres a match on its first rectangle, as a fraction of the page", function()
    local matches = search.parse(OUTPUT)
    harness.near(30 / 612, matches[1].cx, 1e-9)
    harness.near(25 / 792, matches[1].cy, 1e-9)
    harness.near(120 / 612, matches[2].cx, 1e-9, "the first line of a wrapped match")
  end)

  it("notices when the script hit its limit", function()
    local _, truncated = search.parse(OUTPUT .. "\ntruncated\n")
    eq(true, truncated)
  end)

  it("skips lines it cannot understand", function()
    local matches = search.parse("garbage\n1 0 612 792 not,rects\n2 0 612 792 1.00,2.00,3.00,4.00\n")
    eq(1, #matches)
    eq(2, matches[1].page)
  end)

  it("handles empty output", function()
    eq({}, (search.parse("")))
    eq({}, (search.parse(nil)))
  end)
end)

describe("search.new", function()
  it("indexes matches by page and gives every search its own id", function()
    local a, b = found(), found()
    eq({ 1, 2 }, a.by_page[1])
    eq({ 3 }, a.by_page[3])
    eq(nil, a.by_page[2])
    truthy(a.id ~= b.id)
    eq(1, a.dir)
  end)
end)

describe("search.start", function()
  it("starts at the first match on or after the page when searching forward", function()
    local s = found()
    eq(1, search.start(s, 1, 1))
    eq(3, search.start(s, 2, 1))
    eq(3, search.start(s, 3, 1))
    eq(4, search.start(s, 4, 1))
  end)

  it("wraps to the first match when none follows", function()
    eq(1, search.start(found(), 8, 1))
  end)

  it("starts at the last match on or before the page when searching backward", function()
    local s = found()
    eq(2, search.start(s, 2, -1))
    eq(3, search.start(s, 6, -1))
    eq(4, search.start(s, 9, -1))
  end)

  it("wraps to the last match when none precedes", function()
    local matches = search.parse("5 0 612 792 1.00,2.00,3.00,4.00")
    eq(1, search.start(search.new("x", matches, false), 1, -1))
    eq(4, search.start(found(), 0, -1))
  end)

  it("returns nil without matches", function()
    eq(nil, search.start(search.new("x", {}, false), 1, 1))
  end)
end)

describe("search.step", function()
  it("moves one match at a time", function()
    local s = found()
    eq({ 2, false }, { search.step(s, 1, 1) })
    eq({ 1, false }, { search.step(s, 2, -1) })
  end)

  it("wraps at both ends and says so", function()
    local s = found()
    eq({ 1, true }, { search.step(s, 4, 1) })
    eq({ 4, true }, { search.step(s, 1, -1) })
  end)

  it("returns nil without matches", function()
    eq({ nil, false }, { search.step(search.new("x", {}, false), 1, 1) })
  end)
end)

describe("search.highlights", function()
  local colors = { match = "ffe14d", current = "ff8c1a" }

  it("lists every rectangle on the page with the right colour", function()
    local s = found()
    s.current = 2
    local text = search.highlights(s, 1, colors)
    eq(
      table.concat({
        "10.00,20.00,50.00,30.00,ffe14d",
        "100.00,200.00,140.00,212.00,ff8c1a",
        "10.00,220.00,60.00,232.00,ff8c1a",
      }, ";"),
      text
    )
  end)

  it("has nothing for a page without matches", function()
    local text, key = search.highlights(found(), 2, colors)
    eq({ nil, "" }, { text, key })
  end)

  it("changes the cache key when the current match moves onto or off the page", function()
    local s = found()
    s.current = 1
    local _, on_page_one = search.highlights(s, 1, colors)
    s.current = 2
    local _, moved = search.highlights(s, 1, colors)
    s.current = 3
    local _, away = search.highlights(s, 1, colors)
    truthy(on_page_one ~= moved and moved ~= away and on_page_one ~= away)
    local _, other_page = search.highlights(s, 3, colors)
    truthy(other_page ~= away)
  end)

  it("changes the cache key for a new search or new colours", function()
    local _, first = search.highlights(found(), 1, colors)
    local _, second = search.highlights(found(), 1, colors)
    local _, recoloured = search.highlights(found(), 1, { match = "000000", current = "ff8c1a" })
    truthy(first ~= second and second ~= recoloured)
  end)
end)

describe("search.progress", function()
  it("shows the position in the list", function()
    local s = found()
    s.current = 3
    eq("3/4", search.progress(s))
  end)

  it("marks a list cut short by the limit", function()
    local s = found()
    s.current = 1
    s.truncated = true
    eq("1/4+", search.progress(s))
  end)

  it("says when there is nothing", function()
    eq("no matches", search.progress(search.new("x", {}, false)))
  end)
end)
