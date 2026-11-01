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
vim.env.ZELLIJ = nil

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
  vim.v.scrollstart = "" -- in zellij without replies (Neovim 0.11) a scrolled screen sends the page again
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
    data = data:gsub("^\27Ptmux;(.*)\27\\$", function(inner) -- tmux passthrough
      return (inner:gsub("\27\27", "\27"))
    end)
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

---@return string? bytes of the file, nil when it does not exist
local function slurp(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
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

  it("goes to the top of the page with gg and G when that page is already on screen", function()
    reset()
    local s = open(make("fit-jump-here", pages(1)))
    press("w")
    settle(s)
    local top = s.cy
    press("jjj")
    settle(s)
    truthy(s.cy > top, "scrolled down from " .. top .. " to " .. s.cy)
    press("gg")
    settle(s)
    harness.near(top, s.cy, 1e-9, "gg on page 1 goes to its top")
    press("jjj")
    settle(s)
    press("G")
    settle(s)
    harness.near(top, s.cy, 1e-9, "G on the last page goes to its top")
  end)

  it("leaves the view alone when a page turn has nowhere to go", function()
    reset()
    local s = open(make("fit-turn-end", pages(2)))
    press("w")
    settle(s)
    press("G")
    on_page(s, 2)
    press("jj")
    settle(s)
    local cy = s.cy
    press(vim.api.nvim_replace_termcodes("<PageDown>", true, false, true))
    settle(s)
    eq({ 2, cy }, { s.page, s.cy }, "<PageDown> on the last page does not scroll to its top")
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

  --- Messages `nvim_echo` shows while `body` runs.
  local function echoed(body)
    local messages = {}
    with_stub(vim.api, "nvim_echo", function(chunks)
      messages[#messages + 1] = chunks[1][1]
    end, body)
    return messages
  end

  it("reports a wrap that happens partway through {count}n", function()
    reset()
    local s = open(search_doc("count-wrap"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    press("2n")
    on_page(s, 3)
    eq(3, s.search.current)
    local messages = echoed(function()
      press("2n")
      on_page(s, 1)
    end)
    eq(2, s.search.current, "3 -> 1 -> 2")
    eq({ "search hit BOTTOM, continuing at TOP" }, messages)
  end)

  it("applies the count, and reports a wrap, after the user turns pages", function()
    reset()
    local s = open(search_doc("count-moved"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    press("2G")
    on_page(s, 2)
    local messages = echoed(function()
      press("2n")
      on_page(s, 1)
    end)
    eq(1, s.search.current, "starts at match 3 on page 3, then one more step wraps to match 1")
    eq({ "search hit BOTTOM, continuing at TOP" }, messages)

    press("4G")
    on_page(s, 4)
    messages = echoed(function()
      press("n")
      on_page(s, 1)
    end)
    eq(1, s.search.current, "no match after page 4: wraps to the first")
    eq({ "search hit BOTTOM, continuing at TOP" }, messages)
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

  it("goes to the top of the chosen page when it is already on screen", function()
    reset()
    local s = open(outlined("outline-here"))
    press("w")
    settle(s)
    local top = s.cy
    press("jjj")
    settle(s)
    truthy(s.cy > top, "scrolled down from " .. top .. " to " .. s.cy)
    local chosen = false
    with_stub(vim.ui, "select", function(items, _, callback)
      chosen = true
      callback(items[1]) -- "Introduction", page 1
    end, function()
      press("gO")
      wait_for(function()
        return chosen
      end, "the outline picker")
    end)
    settle(s)
    eq(1, s.page)
    harness.near(top, s.cy, 1e-9, "the bookmark's page from its top")
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
    eq(
      "Normal:NormalFloat,Search:PdfViewNone,CurSearch:PdfViewNone,IncSearch:PdfViewNone,"
        .. "Visual:PdfViewNone,VisualNOS:PdfViewNone",
      vim.wo.winhighlight
    )

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

  it("keeps the visual selection off the page", function()
    reset()
    local visual = vim.api.nvim_get_hl(0, { name = "Visual" })
    vim.api.nvim_set_hl(0, "Visual", { fg = "#112233", bg = "#445566" })
    local s = open(make("visual", pages(1)))
    vim.api.nvim_win_set_cursor(0, { s.grid.row + 1, s.grid.col })
    press("vj")
    eq("v", vim.fn.mode())
    vim.cmd("redraw!")
    local at = vim.fn.screenpos(0, s.grid.row + 1, s.grid.col + 1)
    local cell = vim.api.nvim__inspect_cell(1, at.row - 1, at.col - 1)
    eq(s.ids[s.slot], cell[2].foreground, "the selected cell still carries the image id")
    press(vim.keycode("<Esc>"))
    vim.api.nvim_set_hl(0, "Visual", visual)
  end)

  it("does not let the page be scrolled out of its window", function()
    reset()
    open(make("pinned", pages(1)))
    press(vim.api.nvim_replace_termcodes("<C-e><C-e><C-e>", true, false, true))
    eq(4, vim.fn.winsaveview().topline, "the keys scroll the buffer")
    vim.api.nvim_exec_autocmds("WinScrolled", {}) -- Neovim fires it from its main loop, which a test never reaches
    eq(1, vim.fn.winsaveview().topline)
  end)

  it("removes the image of a render that failed", function()
    reset()
    local s = open(make("failed-render", pages(2)))
    local broken = dir .. "/broken.pdf"
    local file = assert(io.open(broken, "wb"))
    file:write("%PDF-1.4\n1 0 obj<<")
    file:close()
    local render, outs = mupdf.render, {}
    -- the page geometry is read from the good file; drawing the broken one fails and leaves an empty PNG behind
    with_stub(mupdf, "render", function(_, page, width, height, out, cb)
      outs[#outs + 1] = out
      return render(broken, page, width, height, out, cb)
    end, function()
      press("j")
      wait_for(function()
        return s.job == nil and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("pdf%-view:") ~= nil
      end, "the failed render")
    end)
    eq(1, #outs)
    eq(nil, vim.uv.fs_stat(outs[1]), "the failed render's PNG is removed")
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

  it("polls the file when its directory cannot be watched", function()
    reset()
    local path = make("no-events", pages(2))
    with_stub(vim.uv, "new_fs_event", function()
      return nil
    end, function()
      local s = open(path)
      fixture.write(path, pages(4))
      wait_for(function()
        return s.count == 4 and s.job == nil
      end, "a reload found by polling", 8000)
    end)
  end)

  it("polls a file on a network filesystem, where directory events miss changes made elsewhere", function()
    reset()
    local path = make("nfs", pages(2))
    -- A watch that starts but never hears anything, like inotify on NFS for a write from another machine.
    local deaf = {
      start = function()
        return true
      end,
      stop = function() end,
      close = function() end,
      is_closing = function()
        return false
      end,
    }
    with_stub(vim.uv, "fs_statfs", function()
      return { type = 0x6969 } -- NFS_SUPER_MAGIC
    end, function()
      with_stub(vim.uv, "new_fs_event", function()
        return deaf
      end, function()
        local s = open(path)
        fixture.write(path, pages(4))
        wait_for(function()
          return s.count == 4 and s.job == nil
        end, "a reload found by polling", 8000)
      end)
    end)
  end)

  it("says once that live reload is off when the file cannot be watched", function()
    reset()
    local notices = {}
    with_stub(vim, "notify", function(message)
      notices[#notices + 1] = message
    end, function()
      with_stub(vim.uv, "new_fs_event", function()
        return nil
      end, function()
        with_stub(vim.uv, "new_fs_poll", function()
          return nil
        end, function()
          open(make("unwatched-1", pages(1)))
          open(make("unwatched-2", pages(1)))
        end)
      end)
    end)
    eq(1, #notices)
    truthy(notices[1]:find("live reload is off", 1, true), notices[1])
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

  it("comes back to the same page and fit after :edit", function()
    reset()
    local s = open(make("re-edit", pages(4)))
    press("w")
    settle(s)
    press("3G")
    on_page(s, 3)
    vim.cmd("edit")
    local again = viewer.sessions[vim.api.nvim_get_current_buf()]
    truthy(again and again ~= s, "a fresh session")
    wait_for(function()
      return again.slot ~= 0 and again.job == nil
    end, "the render after :edit")
    eq({ 3, "width", 4 }, { again.page, again.mode, again.count })
  end)

  it("comes back after :edit when auto_open is off", function()
    reset()
    setup({ auto_open = false })
    local buf = pdf_view.open(make("re-edit-manual", pages(4)))
    local s = viewer.sessions[buf]
    wait_for(function()
      return s.slot ~= 0
    end, "first render")
    press("3G")
    on_page(s, 3)
    vim.cmd("edit")
    local again = viewer.sessions[vim.api.nvim_get_current_buf()]
    truthy(again and again ~= s, "a fresh session")
    eq("nofile", vim.bo.buftype)
    wait_for(function()
      return again.slot ~= 0 and again.job == nil
    end, "the render after :edit")
    eq({ 3, 4 }, { again.page, again.count })
    press("j")
    on_page(again, 4)
    setup()
  end)

  it("saves a copy of the PDF with :w {file}, never the placeholder text", function()
    reset()
    local path = make("write-copy", pages(2))
    open(path)
    local original = slurp(path)
    local copy = dir .. "/write-copy-out.pdf"
    os.remove(copy)
    vim.cmd("silent write " .. vim.fn.fnameescape(copy))
    eq(original, slurp(copy), ":w {file}")

    local ok, err = pcall(vim.cmd, "silent write " .. vim.fn.fnameescape(copy))
    eq(false, ok)
    truthy(tostring(err):find("E13", 1, true), tostring(err))
    fixture.write(copy, pages(1))
    vim.cmd("silent write! " .. vim.fn.fnameescape(copy))
    eq(original, slurp(copy), ":w! {file}")

    local part = dir .. "/write-copy-part.pdf"
    os.remove(part)
    for _, command in ipairs({ "1write " .. vim.fn.fnameescape(part), "write >> " .. vim.fn.fnameescape(copy) }) do
      ok, err = pcall(vim.cmd, "silent " .. command)
      eq(false, ok, command)
      truthy(tostring(err):find("only the whole PDF", 1, true), tostring(err))
    end
    eq(nil, vim.uv.fs_stat(part), "a range is not written")
    eq(original, slurp(copy), "nothing is appended")
    eq(original, slurp(path), "the original is untouched")
  end)

  it("saves a copy and views it with :saveas", function()
    reset()
    local path = make("saveas", pages(3))
    local s = open(path)
    press("2G")
    on_page(s, 2)
    local copy = dir .. "/saveas-out.pdf"
    os.remove(copy)
    vim.cmd("silent saveas " .. vim.fn.fnameescape(copy))
    eq(slurp(path), slurp(copy))
    local again = viewer.sessions[vim.api.nvim_get_current_buf()]
    truthy(again and again ~= s, "a fresh session")
    eq(vim.uv.fs_realpath(copy), vim.uv.fs_realpath(again.path))
    wait_for(function()
      return again.slot ~= 0 and again.job == nil
    end, "the render after :saveas")
    eq(2, again.page)
  end)

  it("reads a page's geometry once, until the file changes", function()
    reset()
    local path = make("geometry-once", pages(3))
    local s = open(path)
    local asked = {}
    local info = mupdf.info
    with_stub(mupdf, "info", function(file, page, cb)
      asked[#asked + 1] = page
      return info(file, page, cb)
    end, function()
      press("j")
      on_page(s, 2)
      press("k")
      on_page(s, 1)
      press("+")
      settle(s)
      press("j") -- scrolls the zoomed page
      settle(s)
      eq({ 2 }, asked, "only the page that had not been shown yet")

      fixture.write(path, pages(5))
      wait_for(function()
        return s.count == 5 and s.job == nil
      end, "live reload", 8000)
      truthy(#asked > 1, "asked again for the new file")
    end)
  end)
end)

describe("viewer in tmux", function()
  --- Run `body` inside a pretend tmux whose attached client, and that client's $TERM, can be changed.
  ---@param body fun(attach: fun(pid: string, termname: string))
  local function in_tmux(body)
    local saved_tmux, saved_system = vim.env.TMUX, vim.system
    local client = { pid = "100", termname = "xterm-kitty" }
    vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] ~= "tmux" then
        return saved_system(cmd, opts, on_exit)
      end
      local stdout = ""
      if cmd[2] == "display-message" then
        stdout = cmd[4]:gsub("#{client_pid}", client.pid):gsub("#{client_termname}", client.termname)
      end
      local result = { code = 0, stdout = stdout .. "\n", stderr = "" }
      if on_exit then
        on_exit(result)
      end
      return {
        wait = function()
          return result
        end,
      }
    end
    local ok, err = pcall(body, function(pid, termname)
      client.pid, client.termname = pid, termname
      vim.api.nvim_exec_autocmds("FocusGained", {})
      vim.wait(100) -- the client is asked in the background
    end)
    vim.env.TMUX, vim.system = saved_tmux, saved_system
    if not ok then
      error(err, 0)
    end
  end

  it("sends the pages again, without rendering them, when tmux is attached from another terminal", function()
    reset()
    in_tmux(function(attach)
      local s = open(make("tmux-reattach", pages(2)))
      attach("100", "xterm-kitty") -- whatever the client was before this test, it is this one now
      on_page(s, 1)
      local path = s.cache[next(s.cache)]
      eq("kitty", terminal.detect().name)

      writes = {}
      attach("100", "xterm-kitty")
      eq({}, transmitted(), "nothing is sent again while the same client is attached")

      local slot = s.slot
      attach("200", "xterm-ghostty")
      wait_for(function()
        return #transmitted() == 1
      end, "the page sent again")
      eq({ path }, transmitted(), "the PNG that was already rendered")
      eq(1, vim.tbl_count(s.cache), "nothing rendered again")
      eq(true, s.slot ~= slot, "placed under the other image id")
      eq("ghostty", terminal.detect().name, "the new terminal is detected again")
    end)
  end)

  it("sends a viewer that was in no window when a window shows it again", function()
    reset()
    in_tmux(function(attach)
      local s = open(make("tmux-hidden", pages(1)))
      attach("300", "xterm-kitty")
      on_page(s, 1)
      local path = s.cache[next(s.cache)]
      local other = open(make("tmux-shown", pages(1)))
      on_page(other, 1)

      writes = {}
      attach("400", "xterm-kitty")
      wait_for(function()
        return #transmitted() == 1
      end, "the viewer on screen sent again")
      eq(false, vim.tbl_contains(transmitted(), path), "the hidden viewer is not sent yet")

      writes = {}
      vim.cmd.buffer(s.buf)
      wait_for(function()
        return #transmitted() == 1
      end, "the hidden viewer sent once shown")
      eq({ path }, transmitted())
    end)
  end)
end)

--- Placements at a screen position in the latest write that has any: `{ row, col, keys }`, rows and columns 1-based.
local function last_batch()
  for index = #writes, 1, -1 do
    local list = {}
    for row, col, keys in writes[index]:gmatch("\27%[(%d+);(%d+)H\27_G([^;\27]*)\27\\") do
      local parsed = {}
      for key, value in keys:gmatch("(%a)=(-?%w+)") do
        parsed[key] = tonumber(value) or value
      end
      list[#list + 1] = { row = tonumber(row), col = tonumber(col), keys = parsed }
    end
    if #list > 0 then
      return list, index
    end
  end
  return {}, 0
end

--- Index of the first write that contains `needle`, or nil.
local function write_index(needle)
  for index, data in ipairs(writes) do
    if data:find(needle, 1, true) then
      return index
    end
  end
end

--- 0-based screen rectangle of the page image.
local function image_rect(s, win)
  local origin = vim.fn.screenpos(win or 0, 1, 1)
  local pic = s.picture
  return { row = origin.row - 1 + pic.row, col = origin.col - 1 + pic.col, rows = pic.rows, cols = pic.cols }
end

local function overlaps(a, b)
  return a.row < b.row + b.rows and b.row < a.row + a.rows and a.col < b.col + b.cols and b.col < a.col + a.cols
end

describe("viewer in zellij", function()
  setup({ placement = "positioned" })
  local quiet = vim.fn.has("nvim-0.12") == 1 and 1 or 2

  it("leaves the buffer blank and places the page at its window's position", function()
    reset()
    local s = open(make("zellij-basic", pages(2)))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    eq(text_rows(), #lines, "as tall as the window, so it cannot scroll")
    eq({ "" }, vim.fn.uniq(lines), "no placeholders")
    eq(false, sent("U=1"), "no virtual placement")

    local batch = last_batch()
    eq(1, #batch)
    local pic, image = s.picture, image_rect(s)
    eq({ image.row + 1, image.col + 1 }, { batch[1].row, batch[1].col })
    eq({
      C = 1,
      a = "p",
      c = pic.cols,
      h = pic.height,
      i = s.ids[s.slot],
      p = 1,
      q = quiet,
      r = pic.rows,
      w = pic.width,
      x = 0,
      y = 0,
      z = -1,
    }, batch[1].keys)
    truthy(pic.col > 0, "centred: " .. pic.col)
    truthy(writes[#writes]:find("^\0277") and writes[#writes]:find("\0278$"), "the cursor is saved and restored")
  end)

  it("follows its window when another one opens above it", function()
    reset()
    local s = open(make("zellij-split", pages(1)))
    local win = vim.api.nvim_get_current_win()
    vim.cmd("aboveleft new")
    wait_for(function()
      local batch = last_batch()
      return s.job == nil and #batch == 1 and batch[1].row == image_rect(s, win).row + 1
    end, "the page placed in the moved window")
  end)

  it("cuts the page around a floating window and makes it whole again when it closes", function()
    reset()
    local s = open(make("zellij-float", pages(1)))
    local image = image_rect(s)
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = image.row + 2,
      col = image.col + 3,
      width = 4,
      height = 2,
      border = "single",
    })
    local hole = { row = image.row + 2, col = image.col + 3, rows = 4, cols = 6 } -- the border included
    local before = #writes
    vim.cmd.redraw()
    wait_for(function()
      return select(2, last_batch()) > before
    end, "the page placed around the float")
    local batch = last_batch()
    truthy(#batch > 1, "in pieces")
    local area, pic = 0, s.picture
    for _, piece in ipairs(batch) do
      local rect = { row = piece.row - 1, col = piece.col - 1, rows = piece.keys.r, cols = piece.keys.c }
      eq(false, overlaps(rect, hole), "a piece overlaps the float: " .. vim.inspect(piece))
      area = area + rect.rows * rect.cols
      -- each piece shows the part of the page that is under it
      eq((rect.col - image.col) * pic.width / pic.cols, piece.keys.x)
      eq((rect.row - image.row) * pic.height / pic.rows, piece.keys.y)
    end
    eq(image.rows * image.cols - hole.rows * hole.cols, area, "everything else is covered")

    local sent_before = #transmitted()
    vim.api.nvim_win_set_config(float, { relative = "editor", row = image.row + 3, col = image.col + 3 })
    before = #writes
    vim.cmd.redraw()
    wait_for(function()
      return select(2, last_batch()) > before
    end, "the page placed around the moved float")
    eq(sent_before + 1, #transmitted(), "zellij keeps one copy of a cut piece per size: the page is sent again")

    local cut_ids = {}
    for _, piece in ipairs(last_batch()) do
      cut_ids[#cut_ids + 1] = piece.keys.p
    end
    before = #writes
    vim.api.nvim_win_close(float, true)
    vim.cmd.redraw()
    wait_for(function()
      return select(2, last_batch()) > before
    end, "the page placed again")
    local whole = last_batch()
    eq(1, #whole)
    for _, id in ipairs(cut_ids) do
      -- zellij would leave a piece on the host terminal if its placement id went on to show the whole page
      truthy(id ~= whole[1].keys.p, "the whole page has a placement id of its own")
      truthy(sent(("a=d,d=i,i=%d,p=%d,q=2"):format(s.ids[s.slot], id)), "removed piece " .. id)
    end
  end)

  it("takes the page away while its window shows another buffer, and sends it again after", function()
    reset()
    local s = open(make("zellij-hide", pages(1)))
    local id, path = s.ids[s.slot], transmitted()[1]
    writes = {}
    vim.cmd.enew()
    vim.cmd.redraw()
    wait_for(function()
      return sent(("a=d,d=i,i=%d,q=2"):format(id))
    end, "the page taken away")
    eq(true, s.lost, "zellij frees an image with its last placement")

    writes = {}
    vim.cmd.buffer(s.buf)
    vim.cmd.redraw()
    wait_for(function()
      return #last_batch() == 1
    end, "the page placed again")
    eq({ path }, transmitted(), "sent again first")
  end)

  it("takes the page away in another tab page", function()
    reset()
    local s = open(make("zellij-tab", pages(1)))
    local id = s.ids[s.slot]
    writes = {}
    vim.cmd.tabnew()
    vim.cmd.redraw()
    wait_for(function()
      return sent(("a=d,d=i,i=%d,q=2"):format(id))
    end, "the page taken away")
    writes = {}
    vim.cmd.tabprevious()
    vim.cmd.redraw()
    wait_for(function()
      return #last_batch() == 1
    end, "the page placed again")
    vim.cmd("silent! tabonly")
  end)

  it("places the page again after its window is redrawn, without sending it again", function()
    reset()
    open(make("zellij-redraw", pages(1)))
    writes = {}
    vim.cmd("redraw!")
    wait_for(function()
      return #last_batch() == 1
    end, "the page placed again")
    eq({}, transmitted())
  end)

  it("removes the previous page only after the next one is placed", function()
    reset()
    local s = open(make("zellij-turn", pages(2)))
    local old = s.ids[s.slot]
    writes = {}
    press("j")
    on_page(s, 2)
    local new = s.ids[s.slot]
    local placed = write_index(("i=%d,p=1"):format(new))
    local removed = write_index(("a=d,d=I,i=%d"):format(old))
    truthy(placed and removed and placed < removed, ("placed at %s, removed at %s"):format(placed, removed))
  end)

  it("takes the page away for a message", function()
    reset()
    local s = open(make("zellij-message", pages(1)))
    local id = s.ids[s.slot]
    writes = {}
    require("pdf-view.session").display_message(s, vim.api.nvim_get_current_win(), "pdf-view: a message")
    truthy(sent(("a=d,d=i,i=%d,q=2"):format(id)))
    eq(nil, s.picture)
  end)

  it("takes a message that scrolled the screen to have dropped the page, when replies cannot be read", function()
    reset()
    local positioned = require("pdf-view.positioned")
    local replies = positioned.replies
    positioned.replies = false -- as on Neovim 0.11
    local ok, err = pcall(function()
      local s = open(make("zellij-scrolled", pages(1)))
      local path = transmitted()[1]
      eq(2, last_batch()[1].keys.q, "no replies asked for")
      writes = {}
      vim.v.scrollstart = "Unknown" -- what a message that scrolls the screen leaves behind
      vim.cmd("redraw!")
      wait_for(function()
        return #transmitted() == 1 and #last_batch() == 1
      end, "sent and placed again")
      eq({ path }, transmitted())
      eq("", vim.v.scrollstart, "ready for the next scroll")
      eq(false, s.lost)
    end)
    positioned.replies = replies
    if not ok then
      error(err, 0)
    end
  end)

  if vim.fn.has("nvim-0.12") == 1 then
    it("sends the page again when the terminal says it lost it, once", function()
      reset()
      local s = open(make("zellij-lost", pages(1)))
      local id, path = s.ids[s.slot], transmitted()[1]
      local reply = ("\27_Gi=%d,p=1;ENOENT:unknown image id\27\\"):format(id)
      writes = {}
      vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = reply } })
      wait_for(function()
        return #transmitted() == 1 and #last_batch() == 1
      end, "sent and placed again")
      eq({ path }, transmitted())

      writes = {}
      vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = reply } })
      vim.wait(100)
      eq({}, transmitted(), "a terminal that cannot keep the image is not flooded with it")
    end)
  end

  setup()
end)
