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
local unpack = table.unpack or unpack

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
    eq({ count = 3, page = 2, width = 400, height = 300, reflowable = false }, info)
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

  it("finds the part of the page with content on it, with a margin", function()
    local sparse = dir .. "/sparse.pdf"
    fixture.write(sparse, {
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "", texts = { { x = 200, y = 300, text = "Middle" } } },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "" },
      { w = 400, h = 300 },
    })
    local err, info = await(function(cb)
      mupdf.info(sparse, 1, cb, true)
    end)
    eq(nil, err)
    local box = info.content
    -- 36 pt Helvetica from x = 200 on the baseline y = 300 (492 from the top), plus 8 points of margin
    truthy(box[1] > 185 and box[1] < 200, "left " .. box[1])
    truthy(box[2] > 450 and box[2] < 480, "top " .. box[2])
    truthy(box[3] > 300 and box[3] < 340, "right " .. box[3])
    truthy(box[4] > 492 and box[4] < 510, "bottom " .. box[4])

    local _, blank = await(function(cb)
      mupdf.info(sparse, 2, cb, true)
    end)
    eq({ 0, 0, 612, 792 }, blank.content, "a blank page is shown whole")
    local _, coloured = await(function(cb)
      mupdf.info(sparse, 3, cb, true)
    end)
    eq({ 0, 0, 400, 300 }, coloured.content, "so is a page with a coloured background")
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

  it("reports an empty image as a failure", function()
    -- a mutool whose worker answers every request without drawing anything
    local fake = dir .. "/empty-mutool"
    local file = assert(io.open(fake, "w"))
    file:write([[#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    :*) echo "@$(printf '%s' "$line" | sed 's/^:\[\([0-9]*\),.*/\1/') ok" ;;
  esac
done
]])
    file:close()
    vim.uv.fs_chmod(fake, 493) -- 0755
    config.setup({ mutool = fake })
    local out = dir .. "/empty.png"
    local err = await(function(cb)
      mupdf.render(pdf, 1, 10, 10, out, cb)
    end)
    config.setup()
    eq(nil, vim.uv.fs_stat(out), "the fake mutool made no image")
    eq("mutool did not produce an image", err)
  end)

  it("keeps the document open between requests, and opens it again once it changed", function()
    local changing = dir .. "/changing.pdf"
    fixture.write(changing, { { w = 100, h = 100 } })
    local _, before = await(function(cb)
      mupdf.info(changing, 1, cb)
    end)
    eq(1, before.count)
    truthy(mupdf.has_worker(changing), "a worker is left running")
    fixture.write(changing, { { w = 100, h = 100 }, { w = 200, h = 300 } })
    local _, after = await(function(cb)
      mupdf.info(changing, 2, cb)
    end)
    eq({ count = 2, page = 2, width = 200, height = 300, reflowable = false }, after)
    mupdf.release(changing)
    eq(false, mupdf.has_worker(changing))
  end)

  it("stops an idle worker and keeps the layout, but leaves a busy one running", function()
    local book = dir .. "/idle.fb2"
    fixture.write_fb2(book, { "One", "Two" }, 30, true)
    mupdf.set_layout(book, { 300, 200, 12 })
    local _, before = await(function(cb)
      mupdf.info(book, 1, cb)
    end)
    truthy(mupdf.has_worker(book), "a worker is left running")

    local answered
    mupdf.info(book, 1, function(err)
      answered = err or false
    end)
    eq(true, mupdf.stop_idle(book), "a worker with a request waiting is busy")
    vim.wait(0) -- the request is handed to the worker
    eq(true, mupdf.stop_idle(book), "a worker with a request in progress is busy")
    wait_for(function()
      return answered ~= nil
    end, "the request answered")
    eq(false, answered, "the busy worker was left to answer")

    eq(false, mupdf.stop_idle(book))
    eq(false, mupdf.has_worker(book), "the idle worker is stopped")
    local _, after = await(function(cb)
      mupdf.info(book, 1, cb)
    end)
    truthy(mupdf.has_worker(book), "the next request starts another")
    eq({ before.count, 300, 200 }, { after.count, after.width, after.height }, "laid out as before")
    mupdf.release(book)
    eq(false, mupdf.stop_idle(book), "no worker")
  end)

  --- The text of page `page` of `book` laid out as `size`, without what a layout changes: spaces, line breaks and
  --- the hyphens of words broken across lines.
  ---@return string
  local function bare_text(book, size, page)
    mupdf.set_layout(book, size)
    local err, text = await(function(cb)
      mupdf.text(book, page, cb)
    end)
    assert(not err, err)
    return (text:gsub("[%s%-]+", ""))
  end

  --- Assert that page `page` of `book` laid out as `now` holds the point of the text that page `number` starts at
  --- when laid out as `before`.
  local function holds_start(book, before, number, now, page)
    local start = bare_text(book, before, number):sub(1, 40)
    local own = bare_text(book, now, page)
    local at = (own .. bare_text(book, now, page + 1)):find(start, 1, true)
    truthy(
      at and at <= #own,
      ("page %d holds the start of page %d (%s): %s"):format(page, number, start, own:sub(1, 80))
    )
  end

  it("lays a reflowable document out to the page size it is given, and leaves a PDF alone", function()
    local book = dir .. "/book.fb2"
    fixture.write_fb2(book, { "One", "Two" }, 30, true)
    mupdf.set_layout(book, { 300, 200, 12 })
    local _, small = await(function(cb)
      mupdf.info(book, 1, cb)
    end)
    eq({ true, 300, 200 }, { small.reflowable, small.width, small.height })
    mupdf.set_layout(book, { 600, 400, 12 })
    local _, large = await(function(cb)
      mupdf.info(book, 1, cb)
    end)
    eq({ 600, 400 }, { large.width, large.height })
    truthy(large.count < small.count, ("fewer pages when they are larger: %d, %d"):format(large.count, small.count))

    -- the page that holds the point of the text the page starts at
    local _, mapped = await(function(cb)
      mupdf.info(book, small.count, cb, false, { 300, 200, 12 })
    end)
    eq({ large.count, 600, 400 }, { mapped.count, mapped.width, mapped.height }, "the answer is about the new layout")
    holds_start(book, { 300, 200, 12 }, small.count, { 600, 400, 12 }, mapped.page)
    mupdf.set_layout(book, { 600, 400, 12 })
    local _, first = await(function(cb)
      mupdf.info(book, 1, cb, false, { 300, 200, 12 })
    end)
    eq(1, first.page)

    mupdf.set_layout(pdf, { 300, 200, 12 })
    local _, page = await(function(cb)
      mupdf.info(pdf, 2, cb)
    end)
    eq({ 3, 400, 300 }, { page.count, page.width, page.height })
    mupdf.release(book)
    mupdf.release(pdf)
  end)

  it("lays a book out again at the same point of the text, however unevenly the text fills its pages", function()
    -- short chapters fill their pages with titles more than with text: the page with the same share of the page
    -- count is pages away from the same text
    local book = dir .. "/uneven.fb2"
    local titles, paragraphs = {}, {}
    for c = 1, 14 do
      titles[c] = "Chapter title " .. c
      paragraphs[c] = (c == 1 or c == 14) and 25 or 1
    end
    fixture.write_fb2(book, titles, paragraphs, true)
    local small, large = { 300, 200, 12 }, { 600, 500, 12 }
    mupdf.set_layout(book, small)
    local _, before = await(function(cb)
      mupdf.info(book, 1, cb)
    end)
    for number = 1, before.count, 3 do
      mupdf.set_layout(book, large)
      local err, mapped = await(function(cb)
        mupdf.info(book, number, cb, false, small)
      end)
      assert(not err, err)
      holds_start(book, small, number, large, mapped.page)
    end
    mupdf.release(book)
  end)

  it("searches and reads the outline of a reflowable document as laid out", function()
    local book = dir .. "/outline.fb2"
    fixture.write_fb2(book, { "One", "Two" }, 30)
    local function last_chapter_page()
      local _, entries = await(function(cb)
        mupdf.outline(book, cb)
      end)
      eq({ "One", "Two" }, { entries[1].title, entries[2].title })
      local _, matches = await(function(cb)
        mupdf.search(book, "Chapter 2 paragraph 1 ", 10, cb)
      end)
      eq(1, #matches)
      return entries[2].page, matches[1].page
    end
    for _, size in ipairs({ { 300, 200 }, { 600, 400 } }) do
      mupdf.set_layout(book, { size[1], size[2], 12 })
      local _, info = await(function(cb)
        mupdf.info(book, 1, cb)
      end)
      local chapter, match = last_chapter_page()
      truthy(chapter > 1 and chapter <= info.count, "chapter two is on a page of the layout")
      eq(chapter, match, "chapter two's first paragraph is on its first page")
    end
    mupdf.release(book)
  end)

  it("answers requests in order, with requests longer than a line", function()
    local results = {}
    local long = ("1,1,2,2,ffe14d;"):rep(60) .. "1,1,2,2,ffe14d"
    for index = 1, 3 do
      local clip = { scale_x = 1, scale_y = 1, x = 0, y = 0, width = 10 * index, height = 10, highlights = long }
      mupdf.render_clip(pdf, 1, clip, ("%s/long-%d.png"):format(dir, index), function(err, notes)
        results[#results + 1] = { index, err, (notes or ""):match("^highlights: ") ~= nil }
      end)
    end
    wait_for(function()
      return #results == 3
    end, "three renders")
    eq({ { 1, nil, true }, { 2, nil, true }, { 3, nil, true } }, results)
    eq({ 30, 10 }, { png_size(dir .. "/long-3.png") })
  end)

  it("drops a waiting request that is killed, and lets the one in progress finish", function()
    local errors = {}
    local function record(name)
      return function(err)
        errors[name] = err or false
      end
    end
    local first = mupdf.info(pdf, 1, record("first"))
    local second = mupdf.info(pdf, 2, record("second"))
    mupdf.info(pdf, 3, record("third"))
    eq(true, second:kill(15), "the waiting request is dropped")
    vim.wait(0) -- the first request is handed to the worker
    truthy(mupdf.has_worker(pdf), "the first request is in progress")
    eq(false, first:kill(15), "the request in progress is left to finish")
    wait_for(function()
      return errors.first ~= nil and errors.second ~= nil and errors.third ~= nil
    end, "every request answered")
    eq(false, errors.first, "the request in progress is answered, by the same worker")
    truthy(tostring(errors.second):find("killed", 1, true), tostring(errors.second))
    eq(false, errors.third)
  end)

  it("fails a request the worker cannot read, and goes on with the next one", function()
    -- the real worker, sent the first request with its JSON broken, so that it answers with id 0
    local mutool = vim.fn.exepath("mutool")
    local fake = dir .. "/garbling-mutool"
    local file = assert(io.open(fake, "w"))
    file:write(([[#!/bin/sh
awk 'NR == 1 { sub(/^:/, ":x") } { print; fflush() }' | exec '%s' "$@"
]]):format(mutool))
    file:close()
    vim.uv.fs_chmod(fake, 493) -- 0755
    config.setup({ mutool = fake })
    local garbled = dir .. "/garbled.pdf"
    fixture.write(garbled, { { w = 100, h = 100 } })
    local results = {}
    mupdf.info(garbled, 1, function(err, info)
      results.first = { err, info }
    end)
    mupdf.info(garbled, 1, function(err, info)
      results.second = { err, info and info.count }
    end)
    local ok = vim.wait(5000, function()
      return results.first ~= nil and results.second ~= nil
    end, 10)
    mupdf.release(garbled)
    config.setup()
    truthy(ok, "both requests answered: " .. vim.inspect(results))
    truthy(results.first[1] and results.first[2] == nil, "the unreadable request fails: " .. vim.inspect(results))
    eq({ nil, 1 }, results.second, "the next request is answered by the same worker")
  end)

  it("starts over after killing a request that has been in progress too long", function()
    local errors = {}
    local function record(name)
      return function(err)
        errors[name] = err or false
      end
    end
    local kill_after = mupdf.kill_after
    mupdf.kill_after = 0
    local first = mupdf.info(pdf, 1, record("first"))
    mupdf.info(pdf, 2, record("second"))
    vim.wait(0) -- the first request is handed to the worker
    local killed = first:kill(15)
    mupdf.kill_after = kill_after
    eq(true, killed)
    wait_for(function()
      return errors.first ~= nil and errors.second ~= nil
    end, "every request answered")
    truthy(tostring(errors.first):find("killed", 1, true), tostring(errors.first))
    eq(false, errors.second, "the request after it is answered by a new worker")
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

    it("draws highlights onto the page, multiplied where MuPDF can", function()
      -- scale 1: a yellow box over blank page, in page points from the top-left corner
      local out = clip(white, 1, 1, 0, 0, 300, 300, "100.00,100.00,200.00,150.00,ffe14d")
      local inside, above, right = unpack(fixture.pixels(out, { { 150, 125 }, { 50, 50 }, { 250, 125 } }))
      eq("yellow", fixture.classify(inside))
      eq({ 255, 255, 255 }, above, "outside the box")
      eq({ 255, 255, 255 }, right, "outside the box")
      if fixture.highlight_mode() == "multiply" then
        eq({ 255, 225, 77 }, inside, "white multiplied by the highlight colour is that colour")
      end
    end)

    it("keeps text readable under a highlight", function()
      -- the label is drawn near x=30, y=396 (792 / 2) from the bottom: cover it and compare ink with background
      local points = {}
      for gx = 30, 130, 4 do
        for gy = 365, 400, 2 do
          points[#points + 1] = { gx, gy }
        end
      end
      local out = clip(white, 1, 1, 0, 0, 300, 500, "20.00,360.00,140.00,405.00,ffe14d")
      local darkest, brightest = math.huge, 0
      for _, rgb in ipairs(fixture.pixels(out, points)) do
        local sum = rgb[1] + rgb[2] + rgb[3]
        darkest, brightest = math.min(darkest, sum), math.max(brightest, sum)
      end
      truthy(brightest < 765, "the background under the highlight is tinted")
      truthy(
        darkest < 0.6 * brightest,
        ("text stays much darker than the tinted background (%d vs %d)"):format(darkest, brightest)
      )
    end)

    it("draws each highlight in its own colour", function()
      local out = clip(white, 1, 1, 0, 0, 300, 300, "10.00,10.00,60.00,60.00,ffe14d;100.00,10.00,150.00,60.00,ff8c1a")
      local first, second = unpack(fixture.pixels(out, { { 30, 30 }, { 120, 30 } }))
      eq({ "yellow", "orange" }, { fixture.classify(first), fixture.classify(second) })
      if fixture.highlight_mode() == "multiply" then
        eq({ { 255, 225, 77 }, { 255, 140, 26 } }, { first, second })
      end
    end)

    it("inverts the brightness of the page but keeps its hues", function()
      counter = counter + 1
      local out = ("%s/clip-%d.png"):format(dir, counter)
      local clip_spec = { scale_x = 2, scale_y = 2, x = 1200, y = 10, width = 50, height = 40, recolor = "invert" }
      eq(
        nil,
        await(function(cb)
          mupdf.render_clip(red, 1, clip_spec, out, cb)
        end)
      )
      local page, paper = unpack(fixture.pixels(out, { { 0, 20 }, { 49, 20 } }))
      truthy(paper[1] < 16 and paper[2] < 16 and paper[3] < 16, "white turns (nearly) black: " .. vim.inspect(paper))
      truthy(page[1] > 100 and page[1] > 2 * page[2] and page[1] > 2 * page[3], "red stays red: " .. vim.inspect(page))
    end)

    it("tints the page, highlights included, black to one colour and white to another", function()
      counter = counter + 1
      local out = ("%s/clip-%d.png"):format(dir, counter)
      local clip_spec = {
        scale_x = 1,
        scale_y = 1,
        x = 0,
        y = 0,
        width = 300,
        height = 500,
        highlights = "100.00,100.00,200.00,150.00,ffffff",
        recolor = "tint,e0f0ff,102030",
      }
      eq(
        nil,
        await(function(cb)
          mupdf.render_clip(white, 1, clip_spec, out, cb)
        end)
      )
      local points = {}
      for gx = 30, 130, 2 do
        for gy = 365, 400, 2 do
          points[#points + 1] = { gx, gy }
        end
      end
      local found_text = false
      for _, rgb in ipairs(fixture.pixels(out, points)) do
        found_text = found_text or vim.deep_equal(rgb, { 224, 240, 255 })
      end
      truthy(found_text, "black text takes the first colour")
      eq(
        { { 16, 32, 48 }, { 16, 32, 48 } },
        fixture.pixels(out, { { 50, 50 }, { 150, 125 } }),
        "white takes the second"
      )
    end)

    it("recolours a whole page drawn to a size", function()
      local out = dir .. "/drawn-inverted.png"
      eq(
        nil,
        await(function(cb)
          mupdf.render(white, 1, 100, 100, out, cb, "invert")
        end)
      )
      local paper = fixture.pixels(out, { { 5, 5 } })[1]
      truthy(paper[1] < 16 and paper[2] < 16 and paper[3] < 16, "white turns (nearly) black: " .. vim.inspect(paper))
    end)

    it("says how it drew the highlights", function()
      local _, notes = await(function(cb)
        mupdf.render_clip(
          white,
          1,
          { scale_x = 1, scale_y = 1, x = 0, y = 0, width = 50, height = 50, highlights = "0,0,10,10,ffe14d" },
          dir .. "/notes.png",
          function(err, text)
            cb(err, text)
          end
        )
      end)
      truthy(notes == "highlights: multiply" or notes == "highlights: translucent", tostring(notes))
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

    it("cuts a rectangle out of a rendered page, pixel for pixel", function()
      -- the right edge of the page: columns 0..11 are red page, 12..39 white outside it
      local page = clip(red, 1, 1, 600, 0, 40, 30)
      local out = dir .. "/crop.png"
      local err = await(function(cb)
        mupdf.crop(red, page, { x = 5, y = 10, w = 20, h = 15 }, out, cb)
      end)
      eq(nil, err)
      eq({ 20, 15 }, { png_size(out) })
      eq(
        { { 255, 0, 0 }, { 255, 0, 0 }, { 255, 255, 255 }, { 255, 255, 255 } },
        fixture.pixels(out, { { 0, 0 }, { 6, 14 }, { 7, 0 }, { 19, 14 } })
      )
    end)

    it("cuts a rectangle out stretched to a size, as a PNM", function()
      local page = clip(red, 1, 1, 600, 0, 40, 30)
      local out = dir .. "/crop.pnm"
      local err = await(function(cb)
        mupdf.crop(red, page, { x = 5, y = 10, w = 20, h = 15 }, out, cb, { 40, 45 })
      end)
      eq(nil, err)
      local file = assert(io.open(out, "rb"))
      local data = file:read("*a")
      file:close()
      local width, height, offset = require("pdf-view.sixel").parse_pnm(data)
      eq({ 40, 45 }, { width, height })
      local function pixel(x, y)
        local i = offset + (y * width + x) * 3
        return { data:byte(i, i + 2) }
      end
      -- the red part is 7 columns of 20, so 14 of 40 once stretched
      eq({ { 255, 0, 0 }, { 255, 0, 0 }, { 255, 255, 255 }, { 255, 255, 255 } }, {
        pixel(0, 0),
        pixel(12, 44),
        pixel(16, 0),
        pixel(39, 44),
      })
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

    it("does not call a list cut short when it has exactly as many matches as the limit", function()
      local matches, truncated = find("alpha", 4)
      eq({ 4, false }, { #matches, truncated })
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

    it("reports a search that was killed as failed, not as one without matches", function()
      local done, err, matches = false, nil, nil
      local job = mupdf.search(path, "alpha", 100, function(e, m)
        done, err, matches = true, e, m
      end)
      job:kill(15)
      wait_for(function()
        return done
      end, "the killed search")
      truthy(tostring(err):find("killed", 1, true), tostring(err))
      eq(nil, matches)
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
        { depth = 1, page = 9, x = 0.25, y = 0.5, title = "Two words" },
      }, mupdf.parse_outline("0\t2\t\t\tOne\n1\t9\t0.25\t0.50000\t  Two words \nnot a line\n"))
    end)

    it("says where on its page a bookmark leads", function()
      local path = dir .. "/outline-at.pdf"
      fixture.write(path, { { w = 612, h = 792 }, { w = 612, h = 792 } }, {
        outline = {
          { title = "Whole page", page = 1 },
          { title = "Figure", page = 2, top = 500, left = 153 },
          { title = "Section", page = 2, top = 198 },
        },
      })
      local err, entries = await(function(cb)
        mupdf.outline(path, cb)
      end)
      eq(nil, err)
      eq({ depth = 0, page = 1, title = "Whole page" }, entries[1])
      eq(2, entries[2].page)
      harness.near(0.25, entries[2].x, 1e-4, "153 points from the left of a page 612 points wide")
      harness.near(292 / 792, entries[2].y, 1e-4, "500 points from the bottom of a page 792 points high")
      eq(nil, entries[3].x)
      harness.near(594 / 792, entries[3].y, 1e-4, "198 points from the bottom")
    end)
  end)

  describe("text", function()
    local texts = dir .. "/texts.pdf"
    fixture.write(texts, {
      { w = 612, h = 792, label = "Page 1" },
      {
        w = 612,
        h = 792,
        label = "Page 2",
        texts = { { x = 72, y = 600, text = "Second line" }, { x = 72, y = 200, text = "Far below" } },
      },
      { w = 612, h = 792, label = "" },
    })

    it("reads a page's text in reading order, a block after another", function()
      local err, text = await(function(cb)
        mupdf.text(texts, 2, cb)
      end)
      eq(nil, err)
      eq("Page 2\n\nSecond line\n\nFar below\n\n", text)
    end)

    it("clamps the page to the document", function()
      local _, first = await(function(cb)
        mupdf.text(texts, -3, cb)
      end)
      eq("Page 1\n\n", first)
    end)

    it("is empty for a page without text", function()
      local err, text = await(function(cb)
        mupdf.text(texts, 3, cb)
      end)
      eq(nil, err)
      eq("", text)
    end)

    it("reads the pages of a reflowable document as laid out", function()
      local book = dir .. "/text.fb2"
      fixture.write_fb2(book, { "One", "Two" }, 30)
      mupdf.set_layout(book, { 300, 200, 12 })
      local _, small = await(function(cb)
        mupdf.text(book, 2, cb)
      end)
      mupdf.set_layout(book, { 600, 400, 12 })
      local _, large = await(function(cb)
        mupdf.text(book, 2, cb)
      end)
      truthy(small:find("lorem", 1, true), small)
      truthy(#large > #small, "a larger page holds more text")
      mupdf.release(book)
    end)
  end)

  describe("links", function()
    local linked = dir .. "/links.pdf"
    fixture.write(linked, {
      {
        w = 612,
        h = 792,
        label = "Contents",
        texts = { { x = 72, y = 600, text = "Website" }, { x = 72, y = 300, text = "Results" } },
        links = {
          { rect = { 70, 290, 250, 330 }, page = 3 }, -- under "Results", listed after the links above it
          { rect = { 70, 590, 250, 630 }, uri = "https://example.com/" }, -- under "Website"
          { rect = { 400, 50, 500, 100 }, page = 2 }, -- over no text
          { rect = { 300, 590, 400, 630 }, uri = "mailto:someone@example.com" }, -- right of "Website"
        },
      },
      {
        w = 612,
        h = 792,
        links = { { rect = { 70, 290, 250, 330 }, page = 3, top = 500, left = 153 } },
      },
      { w = 612, h = 792 },
    })

    it("lists a page's links in reading order, with their text and where they lead", function()
      local err, links = await(function(cb)
        mupdf.links(linked, 1, cb)
      end)
      eq(nil, err)
      eq({
        { text = "Website", uri = "https://example.com/" },
        { text = "", uri = "mailto:someone@example.com" },
        { text = "Results", page = 3 },
        { text = "", page = 2 },
      }, links)
    end)

    it("says where on its page a link leads", function()
      local err, links = await(function(cb)
        mupdf.links(linked, 2, cb)
      end)
      eq(nil, err)
      eq(1, #links)
      eq(3, links[1].page)
      harness.near(0.25, links[1].x, 1e-4, "153 points from the left of a page 612 points wide")
      harness.near(292 / 792, links[1].y, 1e-4, "500 points from the bottom of a page 792 points high")
    end)

    it("is empty for a page without links", function()
      local err, links = await(function(cb)
        mupdf.links(linked, 3, cb)
      end)
      eq(nil, err)
      eq({}, links)
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

  describe("a password-protected document", function()
    local locked = dir .. "/locked.pdf"
    local made = vim
      .system({ "mutool", "clean", "-E", "aes-256", "-U", "secret", "-O", "owner", pdf, locked }, { text = true })
      :wait()
    assert(made.code == 0, made.stderr)

    it("is reported as such instead of being read", function()
      local err = await(function(cb)
        mupdf.info(locked, 1, cb)
      end)
      eq("this PDF is password-protected", err)
    end)

    it("is reported as such when it is drawn", function()
      local err = await(function(cb)
        mupdf.render(locked, 1, 40, 40, dir .. "/locked.png", cb)
      end)
      eq("this PDF is password-protected", err)
      eq("missing", mupdf.password_error(err))
    end)

    it("says a wrong password is wrong", function()
      mupdf.release(locked)
      mupdf.set_password(locked, "nope")
      local err = await(function(cb)
        mupdf.info(locked, 1, cb)
      end)
      eq("wrong password", err)
      eq("wrong", mupdf.password_error(err))
      local search_err = await(function(cb)
        mupdf.search(locked, "Page", 10, cb)
      end)
      eq("wrong password", search_err)
      mupdf.set_password(locked, nil)
    end)

    it("is read, drawn, searched and outlined with its password, which never goes on a command line", function()
      mupdf.release(locked)
      local commands = {}
      local system = vim.system
      vim.system = function(cmd, ...) ---@diagnostic disable-line: duplicate-set-field
        commands[#commands + 1] = table.concat(cmd, " ")
        return system(cmd, ...)
      end
      local ok, problem = pcall(function()
        -- the worker may already be running from a request without a password: the next one unlocks it
        local err = await(function(cb)
          mupdf.info(locked, 1, cb)
        end)
        eq("this PDF is password-protected", err)
        mupdf.set_password(locked, "secret")
        local info_err, info = await(function(cb)
          mupdf.info(locked, 2, cb)
        end)
        eq(nil, info_err)
        eq({ count = 3, page = 2, width = 400, height = 300, reflowable = false }, info)

        local png = dir .. "/unlocked.png"
        local render_err = await(function(cb)
          mupdf.render(locked, 1, 40, 50, png, cb)
        end)
        eq(nil, render_err)
        eq({ 40, 50 }, { png_size(png) })

        local search_err, matches = await(function(cb)
          mupdf.search(locked, "Page", 10, cb)
        end)
        eq(nil, search_err)
        eq(3, #matches)

        local outline_err, entries = await(function(cb)
          mupdf.outline(locked, cb)
        end)
        eq(nil, outline_err)
        eq({}, entries)

        local text_err, text = await(function(cb)
          mupdf.text(locked, 1, cb)
        end)
        eq(nil, text_err)
        eq("Page 1\n\n", text)
      end)
      vim.system = system
      mupdf.set_password(locked, nil)
      mupdf.release(locked)
      assert(ok, problem)
      truthy(#commands >= 3, "mutool was not run: " .. vim.inspect(commands))
      for _, command in ipairs(commands) do
        eq(nil, command:find("secret", 1, true), "the password is on a command line: " .. command)
      end
    end)
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
