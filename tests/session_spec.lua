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
