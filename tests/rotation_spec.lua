local harness = require("tests.harness")
local eq = harness.eq
local rotation = require("pdf-view.rotation")

describe("rotation", function()
  it("wraps any number of degrees into a quarter turn", function()
    eq({ 0, 90, 180, 270, 0, 270, 90, 0, 0 }, {
      rotation.normalize(0),
      rotation.normalize(90),
      rotation.normalize(180),
      rotation.normalize(270),
      rotation.normalize(360),
      rotation.normalize(-90),
      rotation.normalize(450),
      rotation.normalize("90"),
      rotation.normalize(0 / 0),
    })
    eq({ true, true, false, false }, {
      rotation.valid(0),
      rotation.valid(270),
      rotation.valid(45),
      rotation.valid("90"),
    })
  end)

  it("swaps the sides of a page turned a quarter", function()
    eq({ 600, 400 }, { rotation.size(0, 600, 400) })
    eq({ 400, 600 }, { rotation.size(90, 600, 400) })
    eq({ 600, 400 }, { rotation.size(180, 600, 400) })
    eq({ 400, 600 }, { rotation.size(270, 600, 400) })
  end)

  it("turns the corners of a page clockwise", function()
    -- a 600 x 400 page: its top-left corner goes to the top-right of the turned page, and so on around
    eq({ 400, 0 }, { rotation.point(90, 600, 400, 0, 0) })
    eq({ 400, 600 }, { rotation.point(90, 600, 400, 600, 0) })
    eq({ 600, 400 }, { rotation.point(180, 600, 400, 0, 0) })
    eq({ 0, 600 }, { rotation.point(270, 600, 400, 0, 0) })
    eq({ 10, 20 }, { rotation.point(0, 600, 400, 10, 20) })
  end)

  it("takes a point of the turned page back to the page", function()
    for _, degrees in ipairs({ 0, 90, 180, 270 }) do
      local w, h = rotation.size(degrees, 600, 400)
      local x, y = rotation.point(degrees, 600, 400, 150, 30)
      eq({ 150, 30 }, { rotation.unpoint(degrees, w, h, x, y) }, degrees .. " degrees")
    end
  end)

  it("turns a rectangle, smallest corner first", function()
    eq({ 350, 10, 400, 100 }, rotation.rect(90, 600, 400, { 10, 0, 100, 50 }))
    eq({ 500, 350, 590, 400 }, rotation.rect(180, 600, 400, { 10, 0, 100, 50 }))
    eq({ 0, 500, 50, 590 }, rotation.rect(270, 600, 400, { 10, 0, 100, 50 }))
  end)

  it("turns fractions of a page, and destinations that say only one of them", function()
    eq({ 0.75, 0.1 }, { rotation.fraction(90, 0.1, 0.25) })
    eq({ 0.9, 0.75 }, { rotation.fraction(180, 0.1, 0.25) })
    eq({ 0.25, 0.9 }, { rotation.fraction(270, 0.1, 0.25) })
    -- a destination 25% down the page: on a page turned clockwise, 75% across it
    eq({ 0.75, nil }, { rotation.destination(90, nil, 0.25) })
    eq({ nil, 0.75 }, { rotation.destination(180, nil, 0.25) })
    eq({ 0.25, nil }, { rotation.destination(270, nil, 0.25) })
    eq({ nil, 0.1 }, { rotation.destination(90, 0.1, nil) })
  end)
end)
