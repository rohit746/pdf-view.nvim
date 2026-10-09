local harness = require("tests.harness")
local eq, near = harness.eq, harness.near
local layout = require("pdf-view.layout")

local LETTER = { 612, 792 }

describe("layout.fit", function()
  it("fits a portrait page into a landscape window by height", function()
    local fit = layout.fit(LETTER[1], LETTER[2], 200, 50, 10, 20, 4096)
    eq(true, fit.rows <= 50 and fit.cols <= 200)
    eq(50, fit.rows)
    near(612 / 792, (fit.cols * 10) / (fit.rows * 20), 0.012, "aspect ratio")
  end)

  it("fits a wide page into a narrow window by width", function()
    local fit = layout.fit(1280, 720, 80, 60, 10, 20, 4096)
    eq(80, fit.cols)
    -- 22.5 rows are ideal and half a row cannot be drawn: about 2% off is the best whole-cell answer
    near(1, (fit.cols * 10) / (fit.rows * 20) / (1280 / 720), 0.03, "aspect ratio")
  end)

  it("renders at exactly the pixel size of the cells it covers", function()
    local fit = layout.fit(LETTER[1], LETTER[2], 120, 40, 9, 18, 4096)
    eq(fit.cols * 9, fit.width)
    eq(fit.rows * 18, fit.height)
  end)

  it("centres the image", function()
    local fit = layout.fit(LETTER[1], LETTER[2], 200, 50, 10, 20, 4096)
    eq(math.floor((200 - fit.cols) / 2), fit.pad_left)
    eq(0, fit.pad_top)
    local small = layout.fit(LETTER[1], LETTER[2], 200, 50, 10, 20, 4096)
    eq(true, small.pad_left + small.cols <= 200)
  end)

  it("never exceeds the window", function()
    for _, window in ipairs({ { 1, 1 }, { 10, 3 }, { 40, 12 }, { 300, 100 }, { 500, 500 } }) do
      local fit = layout.fit(LETTER[1], LETTER[2], window[1], window[2], 8, 17, 4096)
      eq(true, fit.cols >= 1 and fit.rows >= 1, "at least one cell")
      eq(true, fit.cols <= window[1] and fit.rows <= window[2], "inside the window")
      eq(true, fit.cols <= layout.MAX_CELLS and fit.rows <= layout.MAX_CELLS, "inside the placeholder grid")
    end
  end)

  it("uses twice as many columns as rows for a square page in 1:2 cells", function()
    local fit = layout.fit(100, 100, 40, 40, 10, 20, 4096)
    eq(40, fit.cols)
    eq(20, fit.rows)
  end)

  it("picks the neighbouring cell counts that distort the page least", function()
    -- ideal size is 25.5 x 17.35 cells; plain rounding gives 26 x 17 (3.1% off), floor/ceil search finds better
    local fit = layout.fit(100, 68, 26, 40, 10, 15, 4096)
    local error_of = function(cols, rows)
      return math.abs((cols * 10) / (rows * 15) / (100 / 68) - 1)
    end
    eq(true, error_of(fit.cols, fit.rows) <= error_of(26, 17), "no worse than rounding")
  end)

  it("caps the pixel size without changing the cell grid", function()
    local fit = layout.fit(LETTER[1], LETTER[2], 200, 100, 40, 80, 1000)
    eq(true, fit.width <= 1000 and fit.height <= 1000)
    eq(true, fit.cols >= 1 and fit.rows >= 1)
    near((fit.cols * 40) / (fit.rows * 80), fit.width / fit.height, 0.01, "aspect survives the cap")
  end)

  it("handles a page much taller than the window", function()
    local fit = layout.fit(100, 5000, 100, 30, 10, 20, 4096)
    eq(30, fit.rows)
    eq(true, fit.cols >= 1)
  end)
end)

describe("layout.viewport", function()
  -- a 100x40 cell window of 10x20 px cells is a 1000x800 px box; a letter page fits it at scale 800/792
  local function view(zoom, cx, cy, page_w, page_h)
    return layout.viewport(page_w or 612, page_h or 792, 100, 40, 10, 20, zoom, cx or 0.5, cy or 0.5)
  end

  it("scales with the zoom, starting from the fit scale", function()
    local fit_scale = 800 / 792
    near(fit_scale, view(1).scale, 1e-9)
    near(2 * fit_scale, view(2).scale, 1e-9)
    near(5 * fit_scale, view(5).scale, 1e-9)
  end)

  it("fills the window along a side that overflows and centres the one that does not", function()
    local v = view(1.5) -- letter in a landscape window: height is the limit, so only it overflows
    eq(true, v.scroll_y)
    eq(false, v.scroll_x)
    eq(40, v.rows)
    eq(0, v.pad_top)
    eq(v.cols, math.floor(v.full_w / 10))
    eq(math.floor((100 - v.cols) / 2), v.pad_left)
    near(v.max_x / 2, v.vx, 1e-9, "a page that fits sideways is centred")
  end)

  it("fills the whole window when both sides overflow", function()
    local v = view(4)
    eq({ 100, 40 }, { v.cols, v.rows })
    eq({ 0, 0 }, { v.pad_left, v.pad_top })
    eq({ 1000, 800 }, { v.width, v.height })
    eq({ true, true }, { v.scroll_x, v.scroll_y })
  end)

  it("renders exactly the pixels of the cells it covers", function()
    for _, zoom in ipairs({ 1, 1.25, 1.9, 3, 8 }) do
      local v = view(zoom, 0.3, 0.7)
      eq({ v.cols * 10, v.rows * 20 }, { v.width, v.height }, "zoom " .. zoom)
    end
  end)

  it("positions the viewport by its centre", function()
    local v = view(4, 0.5, 0.5)
    near(0.5, v.cx, 1e-9)
    near(0.5, v.cy, 1e-9)
    near(v.full_w / 2 - v.view_w / 2, v.vx, 1e-6)
    near(v.full_h / 2 - v.view_h / 2, v.vy, 1e-6)
  end)

  it("clamps the centre to what can be reached and reports the clamped value", function()
    local top_left = view(4, -3, -3)
    eq({ 0, 0 }, { top_left.x, top_left.y })
    near(top_left.view_w / 2 / top_left.full_w, top_left.cx, 1e-9)
    near(top_left.view_h / 2 / top_left.full_h, top_left.cy, 1e-9)

    local bottom_right = view(4, 9, 9)
    near(bottom_right.max_x, bottom_right.vx, 1e-6)
    near(bottom_right.max_y, bottom_right.vy, 1e-6)
    near(1 - bottom_right.view_h / 2 / bottom_right.full_h, bottom_right.cy, 1e-9)
  end)

  it("keeps the viewport inside the page", function()
    for _, zoom in ipairs({ 1.25, 2, 4, 8 }) do
      for _, c in ipairs({ { 0, 0 }, { 1, 1 }, { 0.5, 0.2 }, { 0.9, 0.9 } }) do
        local v = view(zoom, c[1], c[2])
        eq(true, v.x >= 0 and v.y >= 0, "origin")
        eq(true, v.x + v.width <= v.full_w + 1 and v.y + v.height <= v.full_h + 1, "far edge")
      end
    end
  end)

  it("leaves the centre of a side that cannot scroll untouched", function()
    local v = view(1.5, 0.1, 0.5) -- width fits, so cx is irrelevant now but must survive for a later zoom
    eq(false, v.scroll_x)
    eq(0.1, v.cx)
  end)

  it("never exceeds the window", function()
    for _, window in ipairs({ { 1, 1 }, { 10, 3 }, { 40, 12 }, { 400, 120 } }) do
      local v = layout.viewport(612, 792, window[1], window[2], 8, 17, 2.5, 0.5, 0.5)
      eq(true, v.cols <= math.min(window[1], layout.MAX_CELLS) and v.rows <= math.min(window[2], layout.MAX_CELLS))
      eq(true, v.cols >= 1 and v.rows >= 1)
    end
  end)

  it("handles a wide page whose width is the limit", function()
    -- fit scale is 1.0 (1000 px box, 1000 pt page): height only overflows the 800 px box beyond 2.67x
    local v = view(3, 0.5, 0.5, 1000, 300)
    eq({ true, true }, { v.scroll_x, v.scroll_y })
    local v125 = view(1.25, 0.5, 0.5, 1000, 300)
    eq({ true, false }, { v125.scroll_x, v125.scroll_y })
    eq(100, v125.cols)
  end)
end)

describe("layout.viewport modes", function()
  -- a 100x40 cell window of 10x20 px cells is a 1000x800 px box
  local function view(mode, zoom, page_w, page_h, cx, cy)
    return layout.viewport(page_w or 612, page_h or 792, 100, 40, 10, 20, zoom or 1, cx or 0.5, cy or 0.5, mode)
  end

  it("treats a missing mode as fit-page", function()
    eq(view("page", 2).scale, view(nil, 2).scale)
  end)

  it("fits the width: the page is exactly as wide as the window and only overflows vertically", function()
    local v = view("width") -- letter: 1000/612 per point, so 1294 px tall
    near(1000 / 612, v.scale, 1e-9)
    eq({ false, true }, { v.scroll_x, v.scroll_y })
    eq({ 100, 40 }, { v.cols, v.rows }, "a page fitted to the width fills every column")
    eq({ 1000, 800 }, { v.width, v.height })
    eq(0, v.pad_left)
  end)

  it("fits the height: for a wide page the page is exactly as tall as the window", function()
    local v = view("height", 1, 1000, 300)
    near(800 / 300, v.scale, 1e-9)
    eq({ true, false }, { v.scroll_x, v.scroll_y })
    eq(40, v.rows)
  end)

  it("equals fit-page when the limiting side is the fitted one", function()
    -- a 1000x300 page is limited by width: fit-width is fit-page
    near(view("page", 1, 1000, 300).scale, view("width", 1, 1000, 300).scale, 1e-9)
    -- a letter page is limited by height: fit-height is fit-page
    near(view("page").scale, view("height").scale, 1e-9)
  end)

  it("multiplies the zoom onto the mode's fitted size", function()
    near(2 * view("width").scale, view("width", 2).scale, 1e-9)
    near(1.5 * view("height", 1, 1000, 300).scale, view("height", 1.5, 1000, 300).scale, 1e-9)
  end)

  it("does not lose a column to rounding when the width fits exactly", function()
    for _, width in ipairs({ 612, 595.28, 841.89, 1000, 333.3333 }) do
      eq(100, view("width", 1, width, 792).cols, "page width " .. width)
    end
  end)
end)
