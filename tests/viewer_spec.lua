local harness = require("tests.harness")
local eq, truthy, wait_for = harness.eq, harness.truthy, harness.wait_for
local fixture = require("tests.fixture")
local kitty = require("pdf-view.kitty")
local mupdf = require("pdf-view.mupdf")
local placeholder = require("pdf-view.placeholder")
local terminal = require("pdf-view.terminal")
local viewer = require("pdf-view.viewer")
local pdf_view = require("pdf-view")

if vim.fn.executable("mutool") ~= 1 then
  io.stdout:write("  skip  viewer (mutool not installed)\n")
  return
end

-- The test instance has no TUI: pretend one is attached and capture what would be written to it.
local writes = {}
terminal.ui_attached = function()
  return true
end
kitty.write = function(data)
  writes[#writes + 1] = data
end
vim.env.TMUX = nil

local ns = vim.api.nvim_create_namespace("pdf-view")
local dir = fixture.tmpdir()

local function setup(opts)
  pdf_view.setup(vim.tbl_extend("force", {
    force = true,
    cell_size = { 10, 20 },
    reload_delay = 50,
    transmission = "file",
  }, opts or {}))
  pdf_view._init()
end

local function reset()
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  writes = {}
end

---@return PdfView.Session
local function open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local s = viewer.sessions[vim.api.nvim_get_current_buf()]
  truthy(s, "no viewer session for " .. path)
  wait_for(function()
    return s.slot ~= 0 or vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("pdf%-view:") ~= nil
  end, "first render")
  return s
end

local function press(keys)
  vim.api.nvim_feedkeys(keys, "x", false)
end

local function on_page(s, page)
  wait_for(function()
    return s.page == page and s.target == nil and s.job == nil
  end, "page " .. page)
end

--- Paths the plugin asked the terminal to load (file medium), in order.
local function transmitted()
  local paths = {}
  for _, data in ipairs(writes) do
    local payload = data:match("\27_Ga=t,f=100,i=%d+,q=2,t=f;([^\27]+)\27\\")
    if payload then
      paths[#paths + 1] = vim.base64.decode(payload)
    end
  end
  return paths
end

local function sent(needle)
  for _, data in ipairs(writes) do
    if data:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function make(name, pages)
  local path = dir .. "/" .. name .. ".pdf"
  fixture.write(path, pages)
  return path
end

local LETTER = { w = 612, h = 792 }
local function pages(count, spec)
  local list = {}
  for index = 1, count do
    list[index] = vim.tbl_extend("force", LETTER, spec or {}, { label = "Page " .. index })
  end
  return list
end

describe("viewer", function()
  setup()

  it("turns :edit of a PDF into a viewer instead of reading its bytes", function()
    reset()
    local path = make("open", pages(3))
    local s = open(path)
    eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0))) -- /var is a symlink on macOS
    eq("nofile", vim.bo.buftype)
    eq("pdf-view", vim.bo.filetype)
    eq(false, vim.bo.modifiable)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      eq(false, line:find("%PDF", 1, true) ~= nil, "binary content leaked into the buffer")
    end
    eq(1, s.page)
    eq(3, s.count)
  end)

  it("fills the window with placeholders highlighted with the image id", function()
    reset()
    local s = open(make("grid", pages(2)))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    -- the winbar takes one of the rows nvim_win_get_height() counts; drawing into it would clip the page
    local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
    eq(1, info.winbar)
    eq(vim.api.nvim_win_get_height(0) - 1, info.height)
    eq(info.height, #lines)
    local widest = 0
    for _, line in ipairs(lines) do
      widest = math.max(widest, vim.fn.strdisplaywidth(line))
    end
    truthy(widest > 0 and widest <= vim.api.nvim_win_get_width(0), "image width fits the window")
    truthy(table.concat(lines):find(placeholder.PLACEHOLDER, 1, true), "contains placeholder cells")

    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    eq(1, #marks)
    local group = marks[1][4].hl_group
    eq("PdfViewImage" .. s.ids[s.slot], group)
    eq(s.ids[s.slot], vim.api.nvim_get_hl(0, { name = group }).fg)
  end)

  it("uploads the rendered page and places it", function()
    reset()
    local s = open(make("upload", pages(1)))
    local paths = transmitted()
    eq(1, #paths)
    truthy(vim.uv.fs_stat(paths[1]), "the PNG exists")
    truthy(paths[1]:match("%.png$"))
    local id = s.ids[s.slot]
    truthy(sent("U=1,a=p"), "virtual placement")
    truthy(sent("i=" .. id), "mentions the image id")
  end)

  it("turns pages with keys, counts and absolute jumps", function()
    reset()
    local s = open(make("keys", pages(5)))
    press("j")
    on_page(s, 2)
    press("jj")
    on_page(s, 4)
    press("k")
    on_page(s, 3)
    press("G")
    on_page(s, 5)
    press("gg")
    on_page(s, 1)
    press("4G")
    on_page(s, 4)
    press("2gg")
    on_page(s, 2)
    press("9j")
    on_page(s, 5)
    press("9k")
    on_page(s, 1)
  end)

  it("shows the page in the winbar and exposes it for statuslines", function()
    reset()
    local s = open(make("bar", pages(3)))
    press("j")
    on_page(s, 2)
    truthy(vim.wo.winbar:find("bar.pdf", 1, true))
    truthy(vim.wo.winbar:find("2 / 3", 1, true), vim.wo.winbar)
    eq("2 / 3", pdf_view.status())
  end)

  it("reuses rendered pages instead of rendering them again", function()
    reset()
    local s = open(make("cache", pages(3)))
    local first = transmitted()[1]
    press("j")
    on_page(s, 2)
    truthy(transmitted()[2] ~= first)
    press("k")
    on_page(s, 1)
    eq(first, transmitted()[3])
  end)

  it("keeps window options for the viewer only", function()
    reset()
    vim.o.number = true
    open(make("opts", pages(1)))
    eq(false, vim.wo.number)
    eq(false, vim.wo.wrap)
    eq("no", vim.wo.signcolumn)
    vim.cmd.enew()
    eq(true, vim.wo.number, "number restored for other buffers")
    vim.o.number = false
  end)

  it("closes with q, frees the images and never quits Neovim", function()
    reset()
    local s = open(make("close", pages(2)))
    local buf, ids = s.buf, vim.deepcopy(s.ids)
    press("q")
    eq(false, vim.api.nvim_buf_is_valid(buf))
    eq(nil, viewer.sessions[buf])
    for _, id in ipairs(ids) do
      truthy(sent(("a=d,d=I,i=%d,q=2"):format(id)), "deleted image " .. id)
    end
    eq(1, #vim.api.nvim_list_wins())
  end)

  it("follows the file when it changes on disk and keeps the current page", function()
    reset()
    local path = make("live", pages(2))
    local s = open(path)
    press("j")
    on_page(s, 2)
    local before = #transmitted()

    fixture.write(path, pages(4, { color = { 1, 0.8, 0.8 } }))
    wait_for(function()
      return s.count == 4 and s.job == nil
    end, "live reload", 8000)
    eq(2, s.page)
    truthy(#transmitted() > before, "uploaded the new render")
  end)

  it("survives a PDF that is briefly invalid while being rewritten", function()
    reset()
    local path = make("partial", pages(2))
    local s = open(path)
    local file = assert(io.open(path, "wb"))
    file:write("%PDF-1.4\ntruncated")
    file:close()
    vim.wait(600)
    eq(2, s.count, "the old page stays on screen")
    fixture.write(path, pages(3))
    wait_for(function()
      return s.count == 3 and s.job == nil
    end, "recovery after a bad write", 8000)
  end)

  it("re-fits the page when the window is resized", function()
    reset()
    local s = open(make("resize", pages(1)))
    local before = s.grid_key
    vim.cmd("vsplit")
    wait_for(function()
      return s.grid_key ~= before and s.job == nil
    end, "re-layout after the split")
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      truthy(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(0))
    end
  end)

  it("tells the user when mutool fails instead of throwing", function()
    reset()
    setup({ mutool = "definitely-not-mutool" })
    open(make("nomutool", pages(1)))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    truthy(text:find("pdf-view:", 1, true) and text:find("definitely-not-mutool", 1, true), text)
    setup()
  end)

  it("explains an unsupported terminal in the buffer", function()
    reset()
    setup({ force = false })
    local detect = terminal.detect
    terminal.detect = function()
      return { term = "xterm-256color" }
    end
    open(make("unsupported", pages(1)))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    truthy(text:find("Unicode placeholder", 1, true), text)
    eq(0, #writes, "nothing is sent to an unsupported terminal")
    terminal.detect = detect
    setup()
  end)

  it("leaves paths that are not readable files alone", function()
    reset()
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/does-not-exist.pdf"))
    eq(nil, viewer.sessions[vim.api.nvim_get_current_buf()])
    eq("", vim.bo.buftype)
  end)

  it("opens through the API without reading the PDF when auto_open is off", function()
    reset()
    setup({ auto_open = false })
    local path = make("manual", pages(2))
    local buf = pdf_view.open(path)
    local s = viewer.sessions[buf]
    truthy(s)
    wait_for(function()
      return s.slot ~= 0
    end, "render")
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      eq(false, line:find("%PDF", 1, true) ~= nil, "binary content leaked into the buffer")
    end
    setup()
  end)

  it("rejects an unreadable path in open()", function()
    local ok, err = pcall(pdf_view.open, dir .. "/nope.pdf")
    eq(false, ok)
    truthy(tostring(err):find("cannot read", 1, true), tostring(err))
  end)
end)

--- Cells of the latest virtual placement sent to the terminal.
local function placement()
  for index = #writes, 1, -1 do
    local cols, rows = writes[index]:match("C=1,U=1,a=p,c=(%d+),i=%d+,q=2,r=(%d+)")
    if cols then
      return tonumber(cols), tonumber(rows)
    end
  end
end

--- Wait until the viewer has nothing left to render.
local function settle(s)
  wait_for(function()
    return s.job == nil and s.target == nil
  end, "the render to settle")
end

local function text_rows()
  return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].height
end

describe("viewer zoom", function()
  setup()

  it("zooms in by one step and renders a window-sized crop of the page", function()
    reset()
    local s = open(make("zoom-in", pages(3)))
    eq(1, s.zoom)
    local fit_cols = placement()

    press("+")
    settle(s)
    harness.near(1.25, s.zoom, 1e-9)
    local cols, rows = placement()
    eq(text_rows(), rows, "the overflowing side fills the window")
    truthy(cols > fit_cols, "the page is wider than when it was fitted")
    local paths = transmitted()
    eq({ cols * 10, rows * 20 }, { fixture.png_size(paths[#paths]) }, "one pixel per cell, nothing to crop on screen")
    truthy(vim.wo.winbar:find("125%", 1, true), vim.wo.winbar)
    eq("1 / 3 x1.25", pdf_view.status())
  end)

  it("zooms by counts and stops at both ends", function()
    reset()
    local s = open(make("zoom-count", pages(2)))
    press("3+")
    settle(s)
    harness.near(1.25 ^ 3, s.zoom, 1e-9)
    press("30+")
    settle(s)
    eq(8, s.zoom)
    press("30-")
    settle(s)
    eq(1, s.zoom)
  end)

  it("returns to the fitted page with 0 and with zooming out", function()
    reset()
    local s = open(make("zoom-reset", pages(2)))
    local fit = { placement() }
    press("4+")
    settle(s)
    press("0")
    settle(s)
    eq(1, s.zoom)
    eq(fit, { placement() })
    press("+")
    settle(s)
    press("-")
    settle(s)
    eq(1, s.zoom)
    eq(fit, { placement() })
    eq("1 / 2", pdf_view.status())
  end)

  it("keeps the zoom when the page turns and starts the new page at its top", function()
    reset()
    local s = open(make("zoom-turn", pages(3)))
    press("+")
    settle(s)
    press(vim.api.nvim_replace_termcodes("<PageDown>", true, false, true))
    on_page(s, 2)
    harness.near(1.25, s.zoom, 1e-9)
    truthy(s.cy > 0 and s.cy < 0.45, "viewing the top of the page, cy = " .. s.cy)
  end)

  it("scrolls a zoomed page and turns to the next one at the bottom edge", function()
    reset()
    local s = open(make("zoom-scroll", pages(3)))
    press("4+")
    settle(s)
    eq(0.5, s.cy)
    press("j")
    settle(s)
    truthy(s.cy > 0.5, "scrolled down")
    eq(1, s.page)

    local steps = 1
    while s.page == 1 and steps < 40 do
      press("j")
      settle(s)
      steps = steps + 1
    end
    eq(2, s.page)
    truthy(steps >= 4, "reaching the bottom took several scrolls, not one: " .. steps)
    truthy(s.cy < 0.3, "the next page starts at its top, cy = " .. s.cy)
  end)

  it("turns to the end of the previous page when scrolling up past the top", function()
    reset()
    local s = open(make("zoom-up", pages(3)))
    press("2G")
    on_page(s, 2)
    press("4+")
    settle(s)
    local steps = 0
    while s.page == 2 and steps < 40 do
      press("k")
      settle(s)
      steps = steps + 1
    end
    eq(1, s.page)
    truthy(steps >= 4, "steps: " .. steps)
    truthy(s.cy > 0.7, "the previous page is shown from its bottom, cy = " .. s.cy)
  end)

  it("scrolls sideways only while the page is wider than the window", function()
    reset()
    local s = open(make("zoom-wide", pages(3, { w = 1000, h = 300 })))
    press("+")
    settle(s)
    eq(0.5, s.cx)
    press("l")
    settle(s)
    eq(1, s.page)
    truthy(s.cx > 0.5, "scrolled right")

    local steps = 1
    while s.page == 1 and steps < 40 do
      press("l")
      settle(s)
      steps = steps + 1
    end
    eq(2, s.page)
    truthy(s.cx > 0 and s.cx < 0.5, "the next page starts at its left edge, cx = " .. s.cx)

    press("j") -- nothing scrolls vertically, so this is a plain page turn
    on_page(s, 3)
  end)

  it("treats movement keys as page turns when nothing is zoomed", function()
    reset()
    local s = open(make("zoom-none", pages(4)))
    press("l")
    on_page(s, 2)
    press("2j")
    on_page(s, 4)
    press("h")
    on_page(s, 3)
    press("k")
    on_page(s, 2)
  end)

  it("zooms about the middle of the page, whatever page turns came before", function()
    reset()
    local s = open(make("zoom-centre", pages(3)))
    press("3G")
    on_page(s, 3)
    press("+")
    settle(s)
    eq(0.5, s.cy)
  end)

  it("stays valid when the window is resized while zoomed", function()
    reset()
    local s = open(make("zoom-resize", pages(2)))
    press("3+")
    settle(s)
    local before = s.grid_key
    vim.cmd("vsplit")
    wait_for(function()
      return s.grid_key ~= before and s.job == nil
    end, "re-layout after the split")
    eq(false, vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("pdf-view:", 1, true) ~= nil)
    local cols, rows = placement()
    eq(text_rows(), rows)
    truthy(cols <= vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width)
  end)

  it("keeps the zoom across a live reload", function()
    reset()
    local path = make("zoom-live", pages(2))
    local s = open(path)
    press("2+")
    settle(s)
    fixture.write(path, pages(4, { color = { 1, 0.8, 0.8 } }))
    wait_for(function()
      return s.count == 4 and s.job == nil
    end, "live reload", 8000)
    harness.near(1.25 ^ 2, s.zoom, 1e-9)
  end)
end)

local function text_cols()
  return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width
end

describe("viewer fit modes", function()
  setup()

  it("fits the width: full window width, scrolling vertically, starting at the top", function()
    reset()
    local s = open(make("fit-width", pages(3)))
    press("w")
    settle(s)
    eq("width", s.mode)
    eq(1, s.zoom)
    local cols, rows = placement()
    eq(text_cols(), cols, "every column is used")
    eq(text_rows(), rows)
    truthy(s.cy < 0.3, "the top of the page, cy = " .. s.cy)
    truthy(vim.wo.winbar:find("width", 1, true), vim.wo.winbar)
    eq("1 / 3 width", pdf_view.status())
  end)

  it("scrolls a width-fitted page and turns to the next one at the bottom", function()
    reset()
    local s = open(make("fit-width-scroll", pages(3)))
    press("w")
    settle(s)
    local top = s.cy
    press("j")
    settle(s)
    truthy(s.cy > top, "scrolled down from " .. top .. " to " .. s.cy)
    eq(1, s.page)
    local steps = 1
    while s.page == 1 and steps < 40 do
      press("j")
      settle(s)
      steps = steps + 1
    end
    eq(2, s.page)
    truthy(steps >= 3, "steps: " .. steps)
    truthy(s.cy < 0.3, "the next page starts at its top, cy = " .. s.cy)
    eq("width", s.mode, "the mode survives a page turn")
  end)

  it("fits the height of a wide page and scrolls it sideways", function()
    reset()
    local s = open(make("fit-height", pages(2, { w = 1000, h = 300 })))
    press("W")
    settle(s)
    eq("height", s.mode)
    local cols, rows = placement()
    eq({ text_cols(), text_rows() }, { cols, rows })
    local left = s.cx
    truthy(left < 0.5, "starts at the left edge, cx = " .. left)
    press("l")
    settle(s)
    truthy(s.cx > left and s.page == 1, "scrolled right from " .. left .. " to " .. s.cx)
  end)

  it("returns to the whole page with 0", function()
    reset()
    local s = open(make("fit-reset", pages(2)))
    local fit = { placement() }
    press("w")
    settle(s)
    press("0")
    settle(s)
    eq({ "page", 1 }, { s.mode, s.zoom })
    eq(fit, { placement() })
    eq("1 / 2", pdf_view.status())
  end)

  it("zooms relative to the fitted width and steps back out to the whole page", function()
    reset()
    local s = open(make("fit-zoom", pages(2)))
    press("w")
    settle(s)
    press("+")
    settle(s)
    harness.near(1.25, s.zoom, 1e-9)
    truthy(vim.wo.winbar:find("width 125%", 1, true), vim.wo.winbar)
    press("-")
    settle(s)
    eq({ "width", 1 }, { s.mode, s.zoom }, "zooming out stops at the width fit first")
    press("-")
    settle(s)
    eq({ "page", 1 }, { s.mode, s.zoom }, "and then returns to the whole page")
  end)

  it("keeps fitting each page's own width", function()
    reset()
    local s = open(make("fit-mixed", {
      { w = 612, h = 792, label = "Page 1" },
      { w = 1000, h = 300, label = "Page 2" },
    }))
    press("w")
    settle(s)
    eq(text_cols(), (placement()))
    press(vim.api.nvim_replace_termcodes("<PageDown>", true, false, true))
    on_page(s, 2)
    eq(text_cols(), (placement()), "a landscape page is fitted to the width too")
  end)

  it("follows the window when it is resized", function()
    reset()
    local s = open(make("fit-resize", pages(2)))
    press("w")
    settle(s)
    local before = s.grid_key
    vim.cmd("vsplit")
    wait_for(function()
      return s.grid_key ~= before and s.job == nil
    end, "re-layout after the split")
    eq(text_cols(), (placement()), "still as wide as the (narrower) window")
  end)
end)

local function with_stub(owner, key, replacement, body)
  local original = owner[key]
  owner[key] = replacement
  local ok, err = pcall(body)
  owner[key] = original
  if not ok then
    error(err, 0)
  end
end

--- Run `body` while `vim.ui.input` answers every prompt with `text`.
local function answering(text, body)
  with_stub(vim.ui, "input", function(_, callback)
    callback(text)
  end, body)
end

--- Wait for a search and the render that follows it.
local function searched(s)
  wait_for(function()
    return s.search_job == nil and s.job == nil and s.target == nil
  end, "the search and its render")
end

--- Run `body` while searches only finish when the test says so: `calls` lists them in order, each with the `needle`,
--- whether it was `killed`, and `finish(err, matches, truncated)` to deliver its result.
local function holding_searches(body)
  local calls = {}
  with_stub(mupdf, "search", function(_, needle, _, cb)
    local call = { needle = needle, killed = false, finish = cb }
    calls[#calls + 1] = call
    return {
      kill = function()
        call.killed = true
      end,
    }
  end, function()
    body(calls)
  end)
end

--- A search result as `mupdf.search` reports it: one match per page given.
local function matches_on(...)
  local matches = {}
  for _, page in ipairs({ ... }) do
    matches[#matches + 1] =
      { page = page, width = 612, height = 792, rects = { { 30, 370, 130, 400 } }, cx = 0.13, cy = 0.49 }
  end
  return matches
end

--- Colour of the latest rendered PNG just inside the top-left corner of a match rectangle.
local function colour_at(match)
  local paths = transmitted()
  local png = paths[#paths]
  local width, height = fixture.png_size(png)
  local x = math.floor(match.rects[1][1] * width / match.width) + 1
  local y = math.floor(match.rects[1][2] * height / match.height) + 1
  return fixture.pixels(png, { { x, y } })[1]
end

local classify = fixture.classify

describe("viewer search", function()
  setup()

  local function search_doc(name)
    return make(name, {
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha beta alpha" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "nothing here" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "gamma alpha" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "the end" },
    })
  end

  it("finds the text, highlights every match and marks the current one", function()
    reset()
    local s = open(search_doc("find"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq(3, #s.search.matches)
    eq({ 1, 1 }, { s.search.current, s.page })
    eq("orange", classify(colour_at(s.search.matches[1])), "the current match")
    eq("yellow", classify(colour_at(s.search.matches[2])), "another match")
    truthy(vim.wo.winbar:find("/alpha 1/3", 1, true), vim.wo.winbar)
  end)

  it("steps through the matches with n and N, wrapping around the document", function()
    reset()
    local s = open(search_doc("step"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    press("n")
    searched(s)
    eq({ 2, 1 }, { s.search.current, s.page })
    eq("orange", classify(colour_at(s.search.matches[2])))
    eq("yellow", classify(colour_at(s.search.matches[1])), "the previous current match goes back to yellow")
    press("n")
    on_page(s, 3)
    eq(3, s.search.current)
    press("n")
    on_page(s, 1)
    eq(1, s.search.current, "wrapped to the top")
    press("N")
    on_page(s, 3)
    eq(3, s.search.current, "wrapped to the bottom")
    press("N")
    searched(s)
    eq(2, s.search.current)
    truthy(vim.wo.winbar:find("2/3", 1, true), vim.wo.winbar)
  end)

  it("starts from the page being read", function()
    reset()
    local s = open(search_doc("from-page"))
    press("2G")
    on_page(s, 2)
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq({ 3, 3 }, { s.page, s.search.current }, "the next match after page 2 is on page 3")
  end)

  it("searches backward with ? and keeps n going the same way", function()
    reset()
    local s = open(search_doc("backward"))
    press("3G")
    on_page(s, 3)
    answering("alpha", function()
      press("?")
      searched(s)
    end)
    eq(3, s.search.current, "the last match on or before page 3")
    press("n")
    searched(s)
    eq(2, s.search.current, "n repeats the backward search")
    press("N")
    on_page(s, 3)
    eq(3, s.search.current, "N reverses it")
  end)

  it("continues from where the user is after they turn pages", function()
    reset()
    local s = open(search_doc("moved-on"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    press("3G")
    on_page(s, 3)
    press("n")
    on_page(s, 3)
    eq(3, s.search.current, "the match on the page being read, not the one after the old current match")
  end)

  it("says so, and drops old highlights, when nothing matches", function()
    reset()
    local s = open(search_doc("nomatch"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    local notes = {}
    with_stub(vim, "notify", function(message)
      notes[#notes + 1] = message
    end, function()
      answering("zzzz", function()
        press("/")
        searched(s)
      end)
    end)
    eq(nil, s.search)
    truthy(notes[1] and notes[1]:find("no matches for `zzzz`", 1, true), vim.inspect(notes))
    eq("white", classify(colour_at({ rects = { { 20, 395, 0, 0 } }, width = 612, height = 792 })), "no highlight left")
  end)

  it("explains n without a search", function()
    reset()
    local s = open(search_doc("n-without"))
    local notes = {}
    with_stub(vim, "notify", function(message)
      notes[#notes + 1] = message
    end, function()
      press("n")
    end)
    eq(1, s.page)
    truthy(notes[1] and notes[1]:find("press /", 1, true), vim.inspect(notes))
  end)

  it("clears the search with <Esc>", function()
    reset()
    local s = open(search_doc("clear"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    press(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
    settle(s)
    eq(nil, s.search)
    eq(false, vim.wo.winbar:find("/alpha", 1, true) ~= nil)
  end)

  it("ignores an empty or cancelled prompt", function()
    reset()
    local s = open(search_doc("cancel"))
    answering(nil, function()
      press("/")
    end)
    answering("", function()
      press("/")
    end)
    eq(nil, s.search)
    eq(nil, s.search_job)
  end)

  it("says nothing about a search that <Esc> stopped", function()
    reset()
    local s = open(search_doc("stopped"))
    local notes = {}
    with_stub(vim, "notify", function(message)
      notes[#notes + 1] = message
    end, function()
      holding_searches(function(calls)
        answering("alpha", function()
          press("/")
        end)
        eq(1, #calls)
        press(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
        eq(true, calls[1].killed)
        eq(nil, s.search_job)
        calls[1].finish(nil, {}, false) -- whatever a stopped search still reports is ignored
      end)
    end)
    eq({}, notes)
    eq(nil, s.search)
  end)

  it("lets a new search replace one that is still running", function()
    reset()
    local s = open(search_doc("replaced"))
    local notes = {}
    with_stub(vim, "notify", function(message)
      notes[#notes + 1] = message
    end, function()
      holding_searches(function(calls)
        answering("alpha", function()
          press("/")
        end)
        answering("beta", function()
          press("/")
        end)
        eq({ "alpha", "beta" }, { calls[1].needle, calls[2].needle })
        eq({ true, false }, { calls[1].killed, calls[2].killed })
        local running = s.search_job
        calls[1].finish(nil, {}, false)
        eq(running, s.search_job, "the new search can still be stopped")
        calls[2].finish(nil, matches_on(1), false)
      end)
    end)
    searched(s)
    eq({}, notes)
    eq({ "beta", 1 }, { s.search.needle, #s.search.matches })
  end)

  it("keeps the matches when the file changes again before the search has been repeated", function()
    reset()
    local s = open(search_doc("repeated-twice"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    holding_searches(function(calls)
      pdf_view.reload()
      pdf_view.reload()
      eq({ "alpha", "alpha" }, { calls[1].needle, calls[2].needle })
      eq({ true, false }, { calls[1].killed, calls[2].killed })
      calls[1].finish(nil, {}, false)
      calls[2].finish(nil, matches_on(1, 3), false)
    end)
    searched(s)
    eq(2, #s.search.matches)
  end)

  it("starts a running search over when the file changes under it", function()
    reset()
    local s = open(search_doc("restarted"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    holding_searches(function(calls)
      answering("beta", function()
        press("/")
      end)
      pdf_view.reload()
      eq({ "beta", "beta" }, { calls[1].needle, calls[2].needle }, "the search being waited for, not the old one")
      eq({ true, false }, { calls[1].killed, calls[2].killed })
      calls[1].finish(nil, {}, false)
      calls[2].finish(nil, matches_on(1), false)
    end)
    searched(s)
    eq({ "beta", 1 }, { s.search.needle, #s.search.matches })
  end)

  it("scrolls a zoomed page to a match that is out of view and leaves visible ones alone", function()
    reset()
    local s = open(make("scroll-to", {
      {
        w = 2400,
        h = 300,
        color = { 1, 1, 1 },
        label = "alpha",
        texts = { { x = 400, y = 150, text = "alpha" }, { x = 2000, y = 150, text = "alpha" } },
      },
    }))
    press("+")
    settle(s)
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq(3, #s.search.matches)
    local first_cx = s.cx
    truthy(first_cx < 0.45, "the first match is at the left edge, cx = " .. first_cx)
    press("n")
    searched(s)
    eq(2, s.search.current)
    eq(first_cx, s.cx, "the second match was already on screen: nothing scrolled")
    press("n")
    searched(s)
    eq(3, s.search.current)
    truthy(s.cx > 0.55, "the third match is far right, so the view moved there, cx = " .. s.cx)
  end)

  it("keeps the highlights when the page is zoomed and scrolled", function()
    reset()
    local s = open(search_doc("zoomed-highlight"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    press("+")
    settle(s)
    local paths = transmitted()
    local png = paths[#paths]
    local width, height = fixture.png_size(png)
    -- sample the whole image: some orange (current match) must be there
    local points = {}
    for x = 1, width - 1, 7 do
      for y = 1, height - 1, 7 do
        points[#points + 1] = { x, y }
      end
    end
    local found = false
    for _, rgb in ipairs(fixture.pixels(png, points)) do
      found = found or classify(rgb) == "orange"
    end
    truthy(found, "the current match is drawn in the zoomed render")
  end)

  it("searches again after the file changes", function()
    reset()
    local path = search_doc("search-live")
    local s = open(path)
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq(3, #s.search.matches)
    fixture.write(path, {
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha alpha alpha" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha alpha" },
    })
    wait_for(function()
      return s.search and #s.search.matches == 5 and s.job == nil and s.search_job == nil
    end, "the search to be repeated on the new file", 8000)
    eq(2, s.count)
  end)
end)

describe("viewer outline", function()
  setup()

  local function outlined(name)
    local list = {}
    for index = 1, 6 do
      list[index] = { w = 612, h = 792, label = "Page " .. index }
    end
    local path = dir .. "/" .. name .. ".pdf"
    fixture.write(path, list, {
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
        { title = "Results", page = 6 },
      },
    })
    return path
  end

  it("offers the bookmarks, indented by depth, and jumps to the chosen page", function()
    reset()
    local s = open(outlined("outline"))
    local offered
    with_stub(vim.ui, "select", function(items, opts, callback)
      offered = { items = items, opts = opts }
      callback(items[5])
    end, function()
      press("gO")
      wait_for(function()
        return offered ~= nil
      end, "the outline picker")
    end)
    eq(6, #offered.items)
    eq("Outline", offered.opts.prompt)
    eq("Introduction  (p. 1)", offered.opts.format_item(offered.items[1]))
    eq("  Data  (p. 3)", offered.opts.format_item(offered.items[3]))
    eq("    Deep  (p. 5)", offered.opts.format_item(offered.items[5]))
    on_page(s, 5)
  end)

  it("does nothing when the picker is cancelled", function()
    reset()
    local s = open(outlined("outline-cancel"))
    local asked = false
    with_stub(vim.ui, "select", function(_, _, callback)
      asked = true
      callback(nil)
    end, function()
      press("gO")
      wait_for(function()
        return asked
      end, "the outline picker")
    end)
    eq(1, s.page)
  end)

  it("tells the user when there is no outline", function()
    reset()
    local s = open(make("no-outline", pages(2)))
    local notes, asked = {}, false
    with_stub(vim.ui, "select", function()
      asked = true
    end, function()
      with_stub(vim, "notify", function(message)
        notes[#notes + 1] = message
      end, function()
        press("gO")
        wait_for(function()
          return #notes > 0
        end, "the notification")
      end)
    end)
    eq(false, asked)
    truthy(notes[1]:find("no outline", 1, true), vim.inspect(notes))
    eq(1, s.page)
  end)
end)

describe("viewer cursor", function()
  setup()

  local function hidden()
    return vim.o.guicursor:find("PdfViewCursor", 1, true) ~= nil
  end

  it("hides the cursor while a viewer is focused, in normal and visual mode only", function()
    reset()
    local original = vim.o.guicursor
    open(make("cursor-hide", pages(1)))
    truthy(hidden(), vim.o.guicursor)
    eq(
      original .. ",n-v-o:PdfViewCursor",
      vim.o.guicursor,
      "appended, so command-line and other modes keep their cursor"
    )
    local hl = vim.api.nvim_get_hl(0, { name = "PdfViewCursor" })
    eq(100, hl.blend)
    truthy(hl.fg and hl.bg, "a blend alone is ignored by the TUI: the group needs colours")
  end)

  it("brings the cursor back when another buffer is entered, and hides it again on return", function()
    reset()
    local original = vim.o.guicursor
    local s = open(make("cursor-leave", pages(1)))
    vim.cmd.enew()
    eq(original, vim.o.guicursor)
    vim.api.nvim_set_current_buf(s.buf)
    truthy(hidden())
  end)

  it("brings the cursor back when the viewer is closed", function()
    reset()
    local original = vim.o.guicursor
    open(make("cursor-close", pages(1)))
    press("q")
    eq(original, vim.o.guicursor)
  end)

  it("shows the cursor in a floating window opened over the viewer", function()
    reset()
    local original = vim.o.guicursor
    open(make("cursor-float", pages(1)))
    local scratch = vim.api.nvim_create_buf(false, true)
    local float =
      vim.api.nvim_open_win(scratch, true, { relative = "editor", row = 1, col = 1, width = 20, height = 1 })
    eq(original, vim.o.guicursor, "the prompt needs its cursor")
    vim.api.nvim_win_close(float, true)
    truthy(hidden(), "hidden again once the float is gone")
  end)

  it("keeps the cursor hidden when a different viewer is closed in the background", function()
    reset()
    local original = vim.o.guicursor
    local first = open(make("cursor-a", pages(1)))
    open(make("cursor-b", pages(1)))
    truthy(hidden())
    vim.api.nvim_buf_delete(first.buf, { force = true })
    truthy(hidden(), "the focused viewer still owns the hidden cursor")
    vim.cmd("silent! %bwipeout!")
    eq(original, vim.o.guicursor)
  end)

  it("restores the highlight after a colorscheme clears it", function()
    reset()
    open(make("cursor-colors", pages(1)))
    vim.cmd("highlight clear PdfViewCursor")
    eq(nil, vim.api.nvim_get_hl(0, { name = "PdfViewCursor" }).blend)
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    eq(100, vim.api.nvim_get_hl(0, { name = "PdfViewCursor" }).blend)
  end)

  it("leaves the cursor alone when hide_cursor is off", function()
    reset()
    setup({ hide_cursor = false })
    local original = vim.o.guicursor
    open(make("cursor-off", pages(1)))
    eq(original, vim.o.guicursor)
    setup()
  end)
end)

describe("viewer robustness", function()
  setup()

  it("wraps an error message to the window instead of cutting it off", function()
    reset()
    setup({ force = false })
    vim.cmd("vsplit | vertical resize 40")
    with_stub(terminal, "detect", function()
      return { term = "xterm-256color" }
    end, function()
      open(make("narrow", pages(1)))
    end)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    truthy(#lines > 1, "more than one line")
    for _, line in ipairs(lines) do
      truthy(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(0), "too wide: " .. line)
    end
    local text = table.concat(lines, " ")
    truthy(text:find("Set `force = true` in setup() to try anyway.", 1, true), text)
    setup()
  end)

  it("is not folded away by an indent 'foldmethod'", function()
    reset()
    vim.o.foldmethod = "indent"
    local s = open(make("folds", pages(1)))
    truthy(s.grid.col > 0, "the page is indented to centre it")
    eq(-1, vim.fn.foldclosed(s.grid.row + 1))
    vim.o.foldmethod = "manual"
  end)

  it("keeps search highlighting off the page, and the window's own 'winhighlight'", function()
    reset()
    local search = vim.api.nvim_get_hl(0, { name = "Search" })
    vim.api.nvim_set_hl(0, "Search", { fg = "#112233", bg = "#445566" })
    vim.wo.winhighlight = "Normal:NormalFloat"
    local s = open(make("hlsearch", pages(1)))
    eq("Normal:NormalFloat,Search:PdfViewNone,CurSearch:PdfViewNone,IncSearch:PdfViewNone", vim.wo.winhighlight)

    vim.fn.setreg("/", ".") -- matches every placeholder cell
    vim.o.hlsearch = true
    vim.cmd("redraw!")
    local at = vim.fn.screenpos(0, s.grid.row + 1, s.grid.col + 1)
    local cell = vim.api.nvim__inspect_cell(1, at.row - 1, at.col - 1)
    eq(s.ids[s.slot], cell[2].foreground, "the cell still carries the image id")

    vim.cmd.enew()
    eq("Normal:NormalFloat", vim.wo.winhighlight, "other buffers keep their own")
    vim.o.hlsearch = false
    vim.wo.winhighlight = ""
    vim.api.nvim_set_hl(0, "Search", search)
  end)

  it("does not let the page be scrolled out of its window", function()
    reset()
    open(make("pinned", pages(1)))
    press(vim.api.nvim_replace_termcodes("<C-e><C-e><C-e>", true, false, true))
    eq(4, vim.fn.winsaveview().topline, "the keys scroll the buffer")
    vim.api.nvim_exec_autocmds("WinScrolled", {}) -- Neovim fires it from its main loop, which a test never reaches
    eq(1, vim.fn.winsaveview().topline)
  end)

  it("asks Neovim for its temp dir every time, in case it was cleaned away", function()
    reset()
    local s = open(make("temp-dir", pages(2)))
    local elsewhere = fixture.tmpdir()
    with_stub(vim.fn, "tempname", function()
      return elsewhere .. "/0"
    end, function()
      press("j")
      on_page(s, 2)
    end)
    local paths = transmitted()
    eq(elsewhere, vim.fs.dirname(paths[#paths]))
  end)

  it("follows a PDF that was opened through a symbolic link", function()
    reset()
    local real_dir = dir .. "/linked"
    vim.fn.mkdir(real_dir, "p")
    local first, second, link = real_dir .. "/first.pdf", real_dir .. "/second.pdf", dir .. "/link.pdf"
    fixture.write(first, pages(2))
    assert(vim.uv.fs_symlink(first, link))
    local s = open(link)
    eq(2, s.count)

    fixture.write(first, pages(4))
    wait_for(function()
      return s.count == 4 and s.job == nil
    end, "a reload after the file behind the link changed", 8000)

    fixture.write(second, pages(3))
    os.remove(link)
    assert(vim.uv.fs_symlink(second, link))
    wait_for(function()
      return s.count == 3 and s.job == nil
    end, "a reload after the link was pointed at another file", 8000)

    fixture.write(second, pages(5))
    wait_for(function()
      return s.count == 5 and s.job == nil
    end, "a reload after the new file behind the link changed", 8000)
  end)

  it("opens files whose names have characters that expand() would rewrite", function()
    reset()
    for _, name in ipairs({ "a{b,c}", "price $HOME", "tick`x`", "notes [draft]" }) do
      local path = make(name, pages(1))
      local buf = pdf_view.open(path)
      eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)), "open()")
      vim.cmd("silent! %bwipeout!")
      vim.cmd("PdfView " .. vim.fn.fnameescape(path))
      eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), ":PdfView")
      truthy(viewer.sessions[vim.api.nvim_get_current_buf()], "a viewer for " .. name)
      vim.cmd("silent! %bwipeout!")
    end
  end)
end)
