local harness = require("tests.harness")
local eq, truthy, wait_for = harness.eq, harness.truthy, harness.wait_for
local fixture = require("tests.fixture")
local config = require("pdf-view.config")
local mupdf = require("pdf-view.mupdf")

--- Run an async mupdf call and return its callback arguments.
local function await(start)
  local done, a, b = false, nil, nil
  start(function(first, second)
    done, a, b = true, first, second
  end)
  wait_for(function()
    return done
  end, "mutool")
  return a, b
end

local png_size = fixture.png_size

if vim.fn.executable("mutool") ~= 1 then
  io.stdout:write("  skip  mupdf (mutool not installed)\n")
  return
end

describe("mupdf", function()
  config.setup()
  local dir = fixture.tmpdir()
  local pdf = dir .. "/doc.pdf"
  fixture.write(pdf, { { w = 612, h = 792 }, { w = 400, h = 300 }, { w = 200, h = 200 } })

  it("reads the page count and geometry", function()
    local err, info = await(function(cb)
      mupdf.info(pdf, 2, cb)
    end)
    eq(nil, err)
    eq({ count = 3, page = 2, width = 400, height = 300 }, info)
  end)

  it("clamps the page to the document", function()
    local _, last = await(function(cb)
      mupdf.info(pdf, 1e9, cb)
    end)
    eq(3, last.page)
    local _, first = await(function(cb)
      mupdf.info(pdf, -4, cb)
    end)
    eq(1, first.page)
  end)

  it("accounts for page rotation", function()
    local rotated = dir .. "/rotated.pdf"
    fixture.write(rotated, { { w = 600, h = 400, rotate = 90 } })
    local _, info = await(function(cb)
      mupdf.info(rotated, 1, cb)
    end)
    eq({ 400, 600 }, { info.width, info.height })
  end)

  it("renders a PNG of exactly the requested size", function()
    local out = dir .. "/page.png"
    local err = await(function(cb)
      mupdf.render(pdf, 1, 300, 400, out, cb)
    end)
    eq(nil, err)
    eq({ 300, 400 }, { png_size(out) })
  end)

  it("fills the box even when the aspect ratio differs", function()
    local out = dir .. "/stretched.png"
    await(function(cb)
      mupdf.render(pdf, 3, 321, 123, out, cb)
    end)
    eq({ 321, 123 }, { png_size(out) })
  end)

  describe("render_clip", function()
    local red = dir .. "/red.pdf"
    fixture.write(
      red,
      { { w = 612, h = 792, color = { 1, 0, 0 } }, { w = 600, h = 400, color = { 0, 0, 1 }, rotate = 90 } }
    )
    local white = dir .. "/white.pdf"
    fixture.write(white, { { w = 612, h = 792, color = { 1, 1, 1 }, label = "Page 1" } })

    local counter = 0
    --- Render a rectangle; `scale` may be a number or `{ x, y }`.
    local function clip(path, page, scale, x, y, w, h, highlights)
      counter = counter + 1
      local out = ("%s/clip-%d.png"):format(dir, counter)
      local sx, sy = scale, scale
      if type(scale) == "table" then
        sx, sy = scale[1], scale[2]
      end
      local err = await(function(cb)
        mupdf.render_clip(
          path,
          page,
          { scale_x = sx, scale_y = sy, x = x, y = y, width = w, height = h, highlights = highlights },
          out,
          cb
        )
      end)
      eq(nil, err)
      eq({ w, h }, { png_size(out) }, "PNG size")
      return out
    end

    it("renders exactly the requested rectangle", function()
      clip(red, 1, 3, 1000, 2000, 640, 480)
    end)

    it("places the rectangle in the scaled page", function()
      -- at scale 2 the page is 1224 px wide: columns 0..23 of this clip are page, the rest is outside it
      local out = clip(red, 1, 2, 1200, 10, 50, 40)
      eq(
        { { 255, 0, 0 }, { 255, 0, 0 }, { 255, 255, 255 }, { 255, 255, 255 } },
        fixture.pixels(out, {
          { 0, 20 },
          { 22, 20 },
          { 26, 20 },
          { 49, 20 },
        })
      )
    end)

    it("scales the two axes independently", function()
      -- 2x horizontally, 1x vertically: 1224 px wide, 792 px tall
      local out = clip(red, 1, { 2, 1 }, 1200, 780, 50, 40)
      eq(
        { { 255, 0, 0 }, { 255, 255, 255 }, { 255, 255, 255 } },
        fixture.pixels(out, { { 10, 5 }, { 10, 20 }, { 40, 5 } })
      )
    end)

    it("measures from the top-left of a rotated page", function()
      -- 600x400 rotated by 90 degrees is displayed 400 wide and 600 tall
      local out = clip(red, 2, 1, 380, 100, 40, 40)
      eq({ { 0, 0, 255 }, { 255, 255, 255 } }, fixture.pixels(out, { { 10, 20 }, { 30, 20 } }))
    end)

    it("renders deep zooms without a large image", function()
      clip(red, 1, 40, 10000, 20000, 800, 600)
    end)

    it("multiplies highlights onto the page", function()
      -- scale 1: a yellow box over blank page, in page points from the top-left corner
      local out = clip(white, 1, 1, 0, 0, 300, 300, "100.00,100.00,200.00,150.00,ffe14d")
      eq(
        { { 255, 225, 77 }, { 255, 255, 255 }, { 255, 255, 255 } },
        fixture.pixels(out, { { 150, 125 }, { 50, 50 }, { 250, 125 } })
      )
    end)

    it("keeps text readable under a highlight", function()
      -- the label is drawn near x=30, y=396 (792 / 2) from the bottom: cover it and look for ink and for tint
      local points = {}
      for gx = 30, 130, 4 do
        for gy = 365, 400, 2 do
          points[#points + 1] = { gx, gy }
        end
      end
      local out = clip(white, 1, 1, 0, 0, 300, 500, "20.00,360.00,140.00,405.00,ffe14d")
      local ink, tint = false, false
      for _, rgb in ipairs(fixture.pixels(out, points)) do
        ink = ink or (rgb[1] + rgb[2] + rgb[3] < 150)
        tint = tint or (rgb[1] == 255 and rgb[2] == 225 and rgb[3] == 77)
      end
      eq({ true, true }, { ink, tint }, "dark text and yellow background are both present")
    end)

    it("draws each highlight in its own colour", function()
      local out = clip(white, 1, 1, 0, 0, 300, 300, "10.00,10.00,60.00,60.00,ffe14d;100.00,10.00,150.00,60.00,ff8c1a")
      eq({ { 255, 225, 77 }, { 255, 140, 26 } }, fixture.pixels(out, { { 30, 30 }, { 120, 30 } }))
    end)

    it("reports a page that does not exist", function()
      local err = await(function(cb)
        mupdf.render_clip(
          red,
          9,
          { scale_x = 1, scale_y = 1, x = 0, y = 0, width = 10, height = 10 },
          dir .. "/none.png",
          cb
        )
      end)
      eq("string", type(err))
    end)
  end)

  describe("search", function()
    local path = dir .. "/search.pdf"
    fixture.write(path, {
      { w = 612, h = 792, label = "alpha beta alpha" },
      { w = 612, h = 792, label = "nothing here" },
      { w = 612, h = 792, label = "ALPHA gamma" },
      { w = 800, h = 500, label = "dash -x here alpha" },
    })

    local function find(needle, limit)
      local err, matches, truncated = await(function(cb)
        mupdf.search(path, needle, limit or 100, function(e, m, t)
          cb(e, { m, t })
        end)
      end)
      eq(nil, err)
      return matches[1], matches[2]
    end

    it("finds every match in reading order, ignoring case", function()
      local matches = find("alpha")
      eq(
        { 1, 1, 3, 4 },
        vim.tbl_map(function(m)
          return m.page
        end, matches)
      )
    end)

    it("reports the page size and where the text is", function()
      local matches = find("gamma")
      eq(1, #matches)
      local m = matches[1]
      eq({ 3, 612, 792 }, { m.page, m.width, m.height })
      local rect = m.rects[1]
      harness.near(30 + 36 * 0.55 * 6, rect[1], 25, "x of 'gamma' after 'ALPHA '")
      truthy(rect[3] > rect[1] and rect[4] > rect[2], "a real rectangle")
      truthy(m.cy > 0.4 and m.cy < 0.55, "the label is drawn at mid-height, cy = " .. m.cy)
    end)

    it("finds a phrase and text that starts with a dash", function()
      eq(1, #find("alpha beta"))
      eq(1, #find("-x"))
    end)

    it("stops at the limit and says so", function()
      local matches, truncated = find("alpha", 2)
      eq({ 2, true }, { #matches, truncated })
      local _, complete = find("alpha", 100)
      eq(false, complete)
    end)

    it("returns nothing when the text does not occur", function()
      local matches, truncated = find("zzzz")
      eq({ 0, false }, { #matches, truncated })
    end)

    it("reports an unreadable document", function()
      local err = await(function(cb)
        mupdf.search(dir .. "/missing.pdf", "x", 10, cb)
      end)
      eq("string", type(err))
    end)
  end)

  describe("outline", function()
    it("lists bookmarks depth first with their pages", function()
      local path = dir .. "/outline.pdf"
      local pages = {}
      for index = 1, 6 do
        pages[index] = { w = 612, h = 792 }
      end
      fixture.write(path, pages, {
        outline = {
          { title = "Introduction", page = 1 },
          {
            title = "Methods",
            page = 3,
            children = {
              { title = "Data", page = 3 },
              { title = "Models", page = 4, children = { { title = "Deep", page = 5 } } },
            },
          },
          { title = "Results\tand\ndiscussion", page = 6 },
        },
      })
      local err, entries = await(function(cb)
        mupdf.outline(path, cb)
      end)
      eq(nil, err)
      eq({
        { depth = 0, page = 1, title = "Introduction" },
        { depth = 0, page = 3, title = "Methods" },
        { depth = 1, page = 3, title = "Data" },
        { depth = 1, page = 4, title = "Models" },
        { depth = 2, page = 5, title = "Deep" },
        { depth = 0, page = 6, title = "Results and discussion" },
      }, entries)
    end)

    it("is empty for a document without bookmarks", function()
      local err, entries = await(function(cb)
        mupdf.outline(pdf, cb)
      end)
      eq(nil, err)
      eq({}, entries)
    end)

    it("parses the script's output", function()
      eq({
        { depth = 0, page = 2, title = "One" },
        { depth = 1, page = 9, title = "Two words" },
      }, mupdf.parse_outline("0\t2\tOne\n1\t9\t  Two words \nnot a line\n"))
    end)
  end)

  it("reports an unreadable document", function()
    local broken = dir .. "/broken.pdf"
    local file = assert(io.open(broken, "wb"))
    file:write("this is not a pdf")
    file:close()
    local err = await(function(cb)
      mupdf.info(broken, 1, cb)
    end)
    eq("string", type(err))
  end)

  it("reports a missing mutool instead of throwing", function()
    config.setup({ mutool = "definitely-not-mutool" })
    local err = await(function(cb)
      mupdf.info(pdf, 1, cb)
    end)
    eq(true, err:find("definitely%-not%-mutool") ~= nil)
    config.setup()
  end)
end)
