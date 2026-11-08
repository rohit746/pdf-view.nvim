local harness = require("tests.harness")
local eq, near, truthy = harness.eq, harness.near, harness.truthy
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

describe("layout.viewport content fit", function()
  -- a 100x40 cell window of 10x20 px cells is a 1000x800 px box; the content is 200x100 points, 100 points in
  local BOX = { 100, 300, 300, 400 }
  local function view(zoom, cx, cy, box)
    return layout.viewport(612, 792, 100, 40, 10, 20, zoom or 1, cx or 0.5, cy or 0.5, "content", box or BOX)
  end

  it("fits the content box as large as the window allows", function()
    local v = view()
    near(math.min(1000 / 200, 800 / 100), v.scale, 1e-9)
    eq({ false, false }, { v.scroll_x, v.scroll_y })
    eq({ 100, 25 }, { v.cols, v.rows })
    eq({ 1000, 500 }, { v.width, v.height })
    eq({ 500, 1500 }, { v.x, v.y }, "the image starts at the content, not at the page's corner")
  end)

  it("travels over the content only once zoomed in", function()
    local scale = 2 * 5
    local left = view(2, 0, 0)
    eq({ true, true }, { left.scroll_x, left.scroll_y })
    eq({ 100 * scale, 300 * scale }, { left.x, left.y }, "stops at the content's top-left corner")
    local right = view(2, 1, 1)
    eq({ 300 * scale - right.view_w, 400 * scale - right.view_h }, { right.x, right.y }, "and at its bottom-right")
    eq({ left.min_x, left.min_y, left.max_x, left.max_y }, { 1000, 3000, 3000 - 1000, 4000 - 800 })
  end)

  it("reports the centre as a fraction of the whole page", function()
    local v = view(2, 0, 0)
    harness.near((v.vx + v.view_w / 2) / (612 * v.scale), v.cx, 1e-9)
    harness.near((v.vy + v.view_h / 2) / (792 * v.scale), v.cy, 1e-9)
  end)

  it("fits the whole page when the content is not known", function()
    local whole = layout.viewport(612, 792, 100, 40, 10, 20, 1, 0.5, 0.5, "page")
    local v = layout.viewport(612, 792, 100, 40, 10, 20, 1, 0.5, 0.5, "content")
    eq({ whole.scale, whole.cols, whole.rows, whole.x, whole.y }, { v.scale, v.cols, v.rows, v.x, v.y })
  end)

  it("ignores the box in the other modes", function()
    local plain = layout.viewport(612, 792, 100, 40, 10, 20, 2, 0.5, 0.5, "width")
    local boxed = layout.viewport(612, 792, 100, 40, 10, 20, 2, 0.5, 0.5, "width", BOX)
    eq({ plain.scale, plain.x, plain.y, plain.min_x }, { boxed.scale, boxed.x, boxed.y, boxed.min_x })
  end)
end)

describe("layout.reflow", function()
  it("lays a page out as large as the window, with text about the size of the terminal's", function()
    local size = layout.reflow(80, 24, 10, 20, 1)
    eq(12, size[3])
    near(80 * 10 / (24 * 20), size[1] / size[2], 0.01, "the window's aspect ratio")
    -- a cell is 14 points tall, so twelve-point text is a little smaller than a line of the terminal
    eq(24 * 14, size[2])
  end)

  it("gives larger text on a smaller page", function()
    local normal = layout.reflow(80, 24, 10, 20, 1)
    local large = layout.reflow(80, 24, 10, 20, 2)
    eq({ normal[1] / 2, normal[2] / 2, 12 }, large)
  end)

  it("stays as large as what is drawn, and is never tiny", function()
    eq(layout.reflow(layout.MAX_CELLS, 40, 10, 20, 1), layout.reflow(1000, 40, 10, 20, 1))
    local tiny = layout.reflow(1, 1, 10, 20, 1)
    eq(true, tiny[1] >= 72 and tiny[2] >= 72)
  end)
end)

describe("layout.sheet", function()
  it("gives a single page as it is", function()
    local info = { count = 3, page = 2, width = 612, height = 792, reflowable = false }
    eq(info, layout.sheet({ info }, 8))
  end)

  it("lays facing pages side by side, centred on each other, as one page", function()
    local sheet = layout.sheet({
      { count = 5, page = 2, width = 600, height = 800, reflowable = false, content = { 50, 60, 550, 700 } },
      { count = 5, page = 3, width = 400, height = 600, reflowable = false, content = { 10, 10, 390, 590 } },
    }, 8)
    eq(2, sheet.page)
    eq(3, sheet.last)
    eq(5, sheet.count)
    eq(1008, sheet.width)
    eq(800, sheet.height)
    eq({
      { page = 2, x = 0, y = 0, width = 600, height = 800 },
      { page = 3, x = 608, y = 100, width = 400, height = 600 },
    }, sheet.parts)
    eq({ 50, 60, 998, 700 }, sheet.content, "the content of both pages")
  end)

  it("has no content box unless both pages have one", function()
    local sheet = layout.sheet({
      { count = 2, page = 1, width = 600, height = 800, reflowable = false, content = { 0, 0, 600, 800 } },
      { count = 2, page = 2, width = 600, height = 800, reflowable = false },
    }, 8)
    eq(nil, sheet.content)
  end)
end)

describe("layout.viewport for continuous scrolling", function()
  it("follows the centre past the page's edges when free", function()
    -- a width fit of a letter page in 80 x 20 cells of 10 x 20 px: 800 px wide, 1035 px tall, a 400 px window
    local bound = layout.viewport(612, 792, 80, 20, 10, 20, 1, 0.5, 1.2, "width")
    local free = layout.viewport(612, 792, 80, 20, 10, 20, 1, 0.5, 1.2, "width", nil, true)
    eq(bound.max_y, bound.vy, "kept inside the page")
    near(1.2 * free.full_h - 200, free.vy, 1e-6, "past the bottom of the page")
    eq(1.2, free.cy)
    near(free.full_h, free.reach_h, 1e-6)
    local above = layout.viewport(612, 792, 80, 20, 10, 20, 1, 0.5, -0.1, "width", nil, true)
    truthy(above.vy < 0, "past the top")
  end)
end)
