local harness = require("tests.harness")
local eq = harness.eq
local session = require("pdf-view.session")

describe("session", function()
  it("wraps a message at spaces", function()
    eq({ "one two", "three" }, session.wrap_text("one two three", 8))
    eq({ "one two three" }, session.wrap_text("one two three", 13))
  end)

  it("cuts a word that is wider than the window", function()
    eq({ "abcde", "fghij", "k l" }, session.wrap_text("abcdefghijk l", 5))
  end)

  it("keeps the line breaks a message already has", function()
    eq({ "a", "", "b c" }, session.wrap_text("a\n\nb c", 10))
  end)
end)

describe("session spreads", function()
  local config = require("pdf-view.config")

  local function viewer_with(spread)
    return { spread = spread, page = 1 }
  end

  it("pairs pages from the first one on", function()
    local s = viewer_with("on")
    eq({ 1, 2 }, { session.spread_range(s, 1) })
    eq({ 1, 2 }, { session.spread_range(s, 2) })
    eq({ 3, 4 }, { session.spread_range(s, 4) })
    eq({ 5, 5 }, { session.spread_range(s, 5, 5) }, "the last page of an odd count is alone")
    eq(3, session.spread_step(s, 1, 1))
    eq(5, session.spread_step(s, 2, 2))
    eq(1, session.spread_step(s, 4, -1))
  end)

  it("shows the first page alone, as a book opens, with cover", function()
    local s = viewer_with("cover")
    eq({ 1, 1 }, { session.spread_range(s, 1) })
    eq({ 2, 3 }, { session.spread_range(s, 2) })
    eq({ 2, 3 }, { session.spread_range(s, 3) })
    eq({ 4, 4 }, { session.spread_range(s, 4, 4) })
    eq(2, session.spread_step(s, 1, 1))
    eq(4, session.spread_step(s, 3, 1))
    eq(1, session.spread_step(s, 2, -1))
    eq(2, session.spread_step(s, 5, -1))
  end)

  it("steps a page at a time without spreads, and in e-books", function()
    eq({ 4, 4 }, { session.spread_range(viewer_with("off"), 4) })
    eq(6, session.spread_step(viewer_with("off"), 4, 2))
    local book = viewer_with("on")
    book.reflowable = true
    eq({ 4, 4 }, { session.spread_range(book, 4) })
    eq("off", session.spread_mode(book))
    eq(config.options.spread, session.spread_mode({}), "the configured mode until toggled")
  end)
end)
