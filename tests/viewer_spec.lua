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
-- the terminal the tests run in is not asked about: they pretend to run in kitty
local real_detect = terminal.detect
terminal.detect = function()
  return { name = "kitty", term = "xterm-kitty", placeholders = true }
end

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
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    vim.wo[win].winfixbuf = false
  end
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

  it("frees the images of a viewer in no window, and sends its page again when a window shows it", function()
    reset()
    local s = open(make("hidden-images", pages(2)))
    press("j")
    on_page(s, 2)
    local held = {}
    for id in pairs(s.images) do
      held[#held + 1] = id
    end
    eq(2, #held, "pages 1 and 2 held by the terminal")
    local page = s.images[s.ids[s.slot]]

    writes = {}
    vim.cmd.enew()
    wait_for(function()
      return next(s.images) == nil
    end, "the images forgotten")
    for _, id in ipairs(held) do
      truthy(sent(("a=d,d=I,i=%d,q=2"):format(id)), "deleted image " .. id)
    end

    writes = {}
    vim.cmd.buffer(s.buf)
    wait_for(function()
      return #transmitted() == 1
    end, "the page sent again")
    eq({ page }, transmitted())
    eq(2, s.page)

    -- still in another window: the images stay
    vim.cmd("split")
    vim.wait(200) -- the page drawn again for the smaller window
    on_page(s, 2)
    writes = {}
    vim.cmd.enew()
    vim.wait(200)
    eq(false, sent("a=d,d=I"), "no image deleted")
    truthy(next(s.images), "the images kept")
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
    terminal.forget()
    local asked = vim.fn.has("nvim-0.12") == 1
    if asked then
      -- it is asked whether it draws sixel, and says it does not
      vim.defer_fn(function()
        vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;22c" } })
      end, 20)
    end
    open(make("unsupported", pages(1)))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    truthy(text:find("Unicode placeholder", 1, true), text)
    eq(asked and { "\27[c" } or {}, writes, "no image is sent to an unsupported terminal")
    terminal.forget()
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

  it("refuses :read of a PDF instead of inserting the raw bytes", function()
    reset()
    setup()
    local pdf = make("read-cmd", pages(1))
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/scratch.txt"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep me" })
    local comic = dir .. "/read-cmd.CBZ"
    vim.fn.writefile({ "not a PDF" }, comic)
    ---@param path string
    ---@return string[] notices
    local function read(path)
      local notices = {}
      local notify = vim.notify
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
      local ok, err = pcall(vim.cmd.read, vim.fn.fnameescape(path))
      vim.notify = notify
      assert(ok, err)
      return notices
    end
    for _, path in ipairs({ pdf, comic }) do
      local notices = read(path)
      eq({ "keep me" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), ":read must not insert the bytes of " .. path)
      truthy(vim.inspect(notices):find(":PdfView", 1, true), "error names :PdfView")
    end
    local notices = read(dir .. "/missing.pdf")
    eq({ "keep me" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    truthy(vim.inspect(notices):find("cannot read", 1, true), "a missing file is reported as missing")
    eq(nil, vim.inspect(notices):find(":PdfView", 1, true), "a missing file is not refused as a PDF")
    setup()
  end)

  it("opens CBZ files and extensions in any case", function()
    reset()
    local pdf = make("comic", { { w = 612, h = 792 }, { w = 400, h = 300 } })
    local cbz = dir .. "/comic.CbZ"
    local result = vim.system({ "mutool", "convert", "-o", cbz, pdf }):wait()
    eq(0, result.code, result.stderr)
    local s = open(cbz)
    eq("nofile", vim.bo.buftype)
    eq(2, s.count)
    truthy(s.slot ~= 0, "the first page of the CBZ is drawn")
    reset()
    local mixed = dir .. "/mixed.Pdf"
    vim.uv.fs_copyfile(pdf, mixed)
    eq(2, open(mixed).count)
  end)

  it("opens only the configured extensions, and :PdfView takes them without an argument", function()
    reset()
    local pdf = make("only-cbz", pages(2))
    local cbz = dir .. "/only-cbz.cbz"
    eq(0, vim.system({ "mutool", "convert", "-o", cbz, pdf }):wait().code)
    setup({ extensions = { "cbz" } })
    vim.cmd.edit(vim.fn.fnameescape(pdf))
    eq(nil, viewer.sessions[vim.api.nvim_get_current_buf()], "a .pdf is not taken any more")
    eq("", vim.bo.buftype)
    truthy(viewer.sessions[pdf_view.open(cbz)])
    setup({ auto_open = false })
    reset()
    vim.cmd.edit(vim.fn.fnameescape(cbz))
    eq(nil, viewer.sessions[vim.api.nvim_get_current_buf()], "auto_open is off")
    vim.cmd("PdfView")
    truthy(viewer.sessions[vim.api.nvim_get_current_buf()], ":PdfView opens the .cbz buffer")
    reset()
    local notices = {}
    local notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/notes.txt"))
    vim.cmd("PdfView")
    vim.notify = notify
    eq(nil, viewer.sessions[vim.api.nvim_get_current_buf()])
    truthy(notices[1] and notices[1]:find("usage", 1, true), vim.inspect(notices))
    reset()
    setup()
  end)

  it("lists the buffer it opens, as :edit does", function()
    reset()
    local buf = pdf_view.open(make("listed", pages(1)))
    eq(true, vim.bo[buf].buflisted)
  end)

  it("rejects an unreadable path in open()", function()
    local ok, err = pcall(pdf_view.open, dir .. "/nope.pdf")
    eq(false, ok)
    truthy(tostring(err):find("cannot read", 1, true), tostring(err))
  end)

  it("gives open viewers the keymaps of a later setup()", function()
    reset()
    local s = open(make("setup-keys", pages(3)))
    setup({ keymaps = { next = { "x" } } })
    eq("", vim.fn.maparg("<PageDown>", "n"), "the old key is unmapped")
    press("x")
    on_page(s, 2)
    setup({ keymaps = false })
    eq("", vim.fn.maparg("x", "n"), "keymaps = false unmaps every key")
    eq("", vim.fn.maparg("q", "n"))
    setup()
    press(vim.keycode("<PageDown>"))
    on_page(s, 3)
  end)

  it("lets a key the user maps do the user's action, not the default one that had it", function()
    reset()
    setup({ keymaps = { prev = { "n" } } })
    local s = open(make("taken-key", pages(3)))
    press(vim.keycode("<PageDown>"))
    on_page(s, 2)
    truthy(vim.fn.maparg("n", "n", false, true).desc:find("previous page", 1, true))
    press("n")
    on_page(s, 1)
    setup()
  end)

  it("drops the winbar of open viewers with a later setup({ winbar = false })", function()
    reset()
    local s = open(make("setup-winbar", pages(3)))
    truthy(vim.wo.winbar:find("1 / 3", 1, true), vim.wo.winbar)
    setup({ winbar = false })
    eq("", vim.wo.winbar)
    press(vim.keycode("<PageDown>"))
    on_page(s, 2)
    eq("", vim.wo.winbar, "not set again by a page turn")
    setup()
    truthy(vim.wo.winbar:find("2 / 3", 1, true), vim.wo.winbar)
  end)

  it("turns live reload of open viewers off and on with a later setup()", function()
    reset()
    local path = make("setup-live", pages(2))
    local s = open(path)
    setup({ live_reload = false })
    eq(nil, s.watcher)
    fixture.write(path, pages(3))
    vim.wait(500)
    eq(2, s.count, "not reloaded while live reload is off")

    setup()
    truthy(s.watcher, "watching again")
    fixture.write(path, pages(4))
    wait_for(function()
      return s.count == 4 and s.job == nil
    end, "live reload after setup()", 8000)
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

--- Wait until the pages next to the one on screen have been rendered ahead of time too.
local function idle(s)
  wait_for(function()
    return s.job == nil and s.target == nil and s.prefetch == nil and next(s.rendering) == nil
  end, "the renders ahead of time")
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

  it("keeps the worker when a zoomed page is scrolled faster than it renders", function()
    reset()
    local s = open(make("zoom-fast", pages(2)))
    press("4+")
    idle(s)
    local started = 0
    local system = vim.system
    vim.system = function(cmd, ...)
      if tostring(cmd[3]):match("worker%.js$") then
        started = started + 1
      end
      return system(cmd, ...)
    end
    local ok, err = pcall(function()
      press("j")
      vim.wait(0) -- the worker is drawing this scroll when the next one comes
      press("j")
      press("j")
      idle(s)
    end)
    vim.system = system
    if not ok then
      error(err, 0)
    end
    eq(0, started, "no mutool worker started again")
    truthy(s.cy > 0.5, "scrolled down")
    eq(1, s.page)
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

  it("scrolls and turns pages with the mouse wheel", function()
    reset()
    local s = open(make("zoom-wheel", pages(3)))
    local function wheel(dir)
      press(vim.keycode("<ScrollWheel" .. dir .. ">"))
      settle(s)
    end
    wheel("Down") -- not zoomed: a page turn
    on_page(s, 2)
    wheel("Up")
    on_page(s, 1)
    press("4+")
    settle(s)
    wheel("Down")
    truthy(s.cy > 0.5, "scrolled down, cy = " .. s.cy)
    eq(1, s.page)
    local cy = s.cy
    wheel("Up")
    truthy(s.cy < cy, "scrolled back up, cy = " .. s.cy)

    setup({ keymaps = { scroll_down = {} } })
    eq("", vim.fn.maparg("<ScrollWheelDown>", "n"), "an empty list turns the wheel off")
    setup()
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

local function with_stub(owner, key, replacement, body)
  local original = owner[key]
  owner[key] = replacement
  local ok, err = pcall(body)
  owner[key] = original
  if not ok then
    error(err, 0)
  end
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

  it("fits the content of each page, cropping its margins, and scrolls over the content only", function()
    reset()
    local function sparse(text)
      return { w = 612, h = 792, color = { 1, 1, 1 }, label = "", texts = { { x = 200, y = 300, text = text } } }
    end
    local s = open(make("fit-content", { sparse("Middle"), sparse("Second") }))
    local page_rows = select(2, placement())
    local clips, asked = {}, {}
    local info, render_clip = mupdf.info, mupdf.render_clip

    --- The part of the page on screen the last render of it showed, in points. The page next to it is rendered
    --- ahead of time too.
    local function shown()
      local clip
      for index = #clips, 1, -1 do
        if clips[index].page == s.page then
          clip = clips[index].clip
          break
        end
      end
      return {
        clip.x / clip.scale_x,
        clip.y / clip.scale_y,
        (clip.x + clip.width) / clip.scale_x,
        (clip.y + clip.height) / clip.scale_y,
      }
    end
    local function inside(box, rect, what)
      truthy(
        rect[1] >= box[1] - 0.5 and rect[2] >= box[2] - 0.5 and rect[3] <= box[3] + 0.5 and rect[4] <= box[4] + 0.5,
        ("%s: %s lies inside the content %s"):format(what, vim.inspect(rect), vim.inspect(box))
      )
    end

    with_stub(mupdf, "info", function(file, page, cb, content)
      asked[#asked + 1] = { page, content or false }
      return info(file, page, cb, content)
    end, function()
      with_stub(mupdf, "render_clip", function(file, page, clip, out, cb)
        clips[#clips + 1] = { page = page, clip = clip }
        return render_clip(file, page, clip, out, cb)
      end, function()
        press("c")
        settle(s)
        eq({ "content", 1 }, { s.mode, s.zoom })
        truthy(vim.wo.winbar:find("content", 1, true), vim.wo.winbar)
        eq("1 / 2 content", pdf_view.status())
        local box = s.geom.box
        truthy(box[1] > 150 and box[3] < 400 and box[2] > 400 and box[4] < 550, vim.inspect(box))
        local rect = shown()
        inside(box, rect, "the fitted content")
        local cols, rows = placement()
        truthy(cols == text_cols() or rows == text_rows(), "the content fills the window one way")
        truthy(clips[#clips].clip.scale_x > 3 * (text_rows() * 20 / 792), "much larger than the fitted page")

        press("++++")
        settle(s)
        for _, keys in ipairs({ "hhhhhhhhhh", "kkkkkkkkkk" }) do
          press(keys)
          settle(s)
          eq(1, s.page, keys .. " stops at the edge of the content")
          inside(box, shown(), "zoomed to the top-left")
        end
        harness.near(box[1], shown()[1], 1, "at the left edge of the content")
        harness.near(box[2], shown()[2], 1, "at the top edge of the content")

        press(vim.api.nvim_replace_termcodes("<PageDown>", true, false, true))
        on_page(s, 2)
        eq("content", s.mode)
        inside(s.geom.box, shown(), "the next page")
      end)
    end)
    eq({ { 1, true }, { 2, true } }, asked, "each page's content is found once, when it is first shown")

    press("0")
    settle(s)
    eq({ "page", 1 }, { s.mode, s.zoom })
    eq(page_rows, select(2, placement()), "0 shows the whole page again")
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

  it("says searching in the winbar until the search finishes", function()
    reset()
    local s = open(search_doc("progress"))
    holding_searches(function(calls)
      answering("alpha", function()
        press("/")
      end)
      truthy(vim.wo.winbar:find("/alpha searching…", 1, true), vim.wo.winbar)
      calls[1].finish(nil, matches_on(1), false)
      searched(s)
      truthy(vim.wo.winbar:find("/alpha 1/1", 1, true), vim.wo.winbar)

      answering("zzzz", function()
        press("/")
      end)
      truthy(vim.wo.winbar:find("/zzzz searching…", 1, true), vim.wo.winbar)
      press(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
      eq(false, vim.wo.winbar:find("searching", 1, true) ~= nil, "<Esc> stops it: " .. vim.wo.winbar)
    end)
  end)

  it("does not search when the viewer is closed while the prompt is open", function()
    reset()
    local s = open(search_doc("closed-prompt"))
    local confirm
    with_stub(vim.ui, "input", function(_, callback)
      confirm = callback -- an input plugin that answers later, after the key has been handled
    end, function()
      holding_searches(function(calls)
        press("/")
        vim.api.nvim_buf_delete(s.buf, { force = true })
        eq(true, s.closed)
        confirm("alpha")
        eq(0, #calls, "searched a closed viewer")
      end)
    end)
    eq(nil, s.search_job)
    eq(nil, s.searching)
  end)

  it("keeps a search history and searches again for the last text on an empty prompt", function()
    reset()
    local s = open(search_doc("history"))
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq("alpha", vim.fn.histget("search", -1))
    press(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
    settle(s)
    eq(nil, s.search)
    press("3G")
    on_page(s, 3)
    answering("", function()
      press("?")
      searched(s)
    end)
    eq({ "alpha", 3, 3 }, { s.search.needle, s.search.current, s.page }, "an empty ? searches backward for alpha")
  end)

  it("zooms a fitted page towards the current match", function()
    reset()
    local s = open(make("zoom-to-match", {
      {
        w = 612,
        h = 792,
        color = { 1, 1, 1 },
        label = "start",
        texts = { { x = 480, y = 40, text = "omega" } },
      },
    }))
    answering("omega", function()
      press("/")
      searched(s)
    end)
    local match = s.search.matches[1]
    truthy(
      match.cx > 0.8 and match.cy > 0.9,
      ("the match is near the bottom-right corner: %.2f %.2f"):format(match.cx, match.cy)
    )
    press("++++")
    settle(s)
    local paths = transmitted()
    local png = paths[#paths]
    local width, height = fixture.png_size(png)
    local points = {}
    for x = 1, width - 1, 5 do
      for y = 1, height - 1, 5 do
        points[#points + 1] = { x, y }
      end
    end
    local found = false
    for _, rgb in ipairs(fixture.pixels(png, points)) do
      -- the current match's colour on white paper, which `classify` cannot tell apart from black text: 255,140,26
      -- multiplied (MuPDF 1.27+) or 255,203,153 laid over translucently (older); yellow and text fall outside
      found = found or (rgb[1] >= 230 and rgb[2] >= 100 and rgb[2] <= 215 and rgb[3] <= rgb[2] - 30)
    end
    truthy(found, "the current match is still on screen after zooming in")
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

  it("reloads the file the same way when a window switch notices the change first", function()
    reset()
    setup({ live_reload = false }) -- the window switch is then the only thing that notices the change
    local path = search_doc("search-relayout")
    local s = open(path)
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq(3, #s.search.matches)
    s.synced = { id = 1, page = 1, rects = { { 72, 360, 372, 400 } } } -- a forward search into the old build
    fixture.write(path, {
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha alpha alpha" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha alpha" },
    })
    vim.api.nvim_exec_autocmds("WinEnter", {})
    wait_for(function()
      return s.count == 2 and s.search and #s.search.matches == 5 and s.job == nil and s.search_job == nil
    end, "the search to be repeated on the new file", 8000)
    eq(nil, s.synced, "the forward search highlight of the old build is dropped")

    -- a file still being written keeps the old page on screen and is tried again
    local file = assert(io.open(path, "wb"))
    file:write("%PDF-1.4\ntruncated")
    file:close()
    vim.api.nvim_exec_autocmds("WinEnter", {})
    vim.wait(300)
    eq(nil, vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)[1]:find("pdf%-view:"), "no error in place of the page")
    fixture.write(path, pages(3))
    wait_for(function()
      return s.count == 3 and s.job == nil
    end, "the retry to read the finished file", 8000)
    setup()
  end)

  it("searches a hidden viewer again only when a window shows it", function()
    reset()
    local path = search_doc("search-hidden")
    local s = open(path)
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    vim.cmd.enew()
    holding_searches(function(calls)
      fixture.write(path, {
        { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha alpha" },
        { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha" },
      })
      vim.wait(600, function() -- live reload waits 50 ms after the write
        return #calls > 0
      end)
      eq({ 0, true }, { #calls, s.search_stale }, "no search while the viewer is in no window")
      vim.cmd.buffer(s.buf)
      eq({ 1, "alpha" }, { #calls, calls[1] and calls[1].needle })
      calls[1].finish(nil, matches_on(1, 2), false)
    end)
    searched(s)
    eq({ 2, nil }, { #s.search.matches, s.search_stale })
  end)
end)

describe("viewer reflowable documents", function()
  setup()

  local layout = require("pdf-view.layout")

  ---@return number[]
  local function window_layout()
    local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
    return layout.reflow(info.width - info.textoff, info.height, 10, 20, 1)
  end

  it("lays an FB2 book out to fill the window", function()
    reset()
    local book = dir .. "/fill.FB2"
    fixture.write_fb2(book, { "One", "Two" }, 20)
    local s = open(book)
    eq(true, s.reflowable)
    local size = window_layout()
    eq({ size[1], size[2] }, { s.geom.w, s.geom.h })
    local cols, rows = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width, vim.api.nvim_win_get_height(0) - 1
    local fit = s.grid_key and vim.split(s.grid_key, "x") or {}
    eq({ tostring(cols), tostring(rows) }, { fit[1], fit[2] }, "the page covers the whole window")
  end)

  it("lays the book out again when the window changes, at the same point of the text, and searches again", function()
    reset()
    local book = dir .. "/resize.fb2"
    fixture.write_fb2(book, { "One", "Two", "Three" }, 30, true)
    local s = open(book)
    answering("Chapter 3 paragraph 1 ", function()
      press("/")
      searched(s)
    end)
    --- The text of a page as the book is laid out now, without what a layout changes (spaces, line breaks).
    local function bare_text(page)
      local done, text
      mupdf.text(book, page, function(_, result)
        done, text = true, result
      end)
      wait_for(function()
        return done
      end, "the text of the page")
      return (assert(text):gsub("[%s%-]+", ""))
    end
    local before = { page = s.page, count = s.count, key = s.laid_out.key, match = s.search.matches[1].page }
    truthy(before.page > 1, "the match is past the first page")
    local start = bare_text(s.page):sub(1, 40)

    vim.cmd("vsplit")
    wait_for(function()
      return s.laid_out and s.laid_out.key ~= before.key and s.job == nil and s.search_job == nil
    end, "the new layout")
    local size = window_layout()
    eq({ size[1], size[2] }, { s.geom.w, s.geom.h })
    truthy(s.count > before.count, ("narrower pages, more of them: %d, %d"):format(before.count, s.count))
    local own = bare_text(s.page)
    local at = (own .. bare_text(s.page + 1)):find(start, 1, true)
    truthy(
      at and at <= #own,
      ("page %d holds the text page %d started with (%s): %s"):format(s.page, before.page, start, own:sub(1, 80))
    )
    truthy(s.search.matches[1].page > before.match, "the match moved to a later page")
    press("n")
    searched(s)
    eq(s.search.matches[1].page, s.page, "n goes to where the match is now")
  end)
end)

--- Where the top left corner of the window is on the page on screen, as fractions of the page.
---@param s PdfView.Session
---@return { x: number, y: number, scroll_x: boolean, scroll_y: boolean }
local function corner(s)
  local cols, rows = require("pdf-view.session").text_area(vim.api.nvim_get_current_win())
  local cell = terminal.cell_size()
  local view = require("pdf-view.layout").viewport(
    s.geom.w,
    s.geom.h,
    cols,
    rows,
    cell.w,
    cell.h,
    s.zoom,
    s.cx,
    s.cy,
    s.mode,
    s.geom.box
  )
  return { x = view.vx / view.full_w, y = view.vy / view.full_h, scroll_x = view.scroll_x, scroll_y = view.scroll_y }
end

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

  it("brings the point a bookmark leads to to the top of the window", function()
    reset()
    local path = dir .. "/outline-at.pdf"
    fixture.write(path, pages(3), { outline = { { title = "Figure", page = 3, top = 500 } } })
    local s = open(path)
    press("w")
    settle(s)
    with_stub(vim.ui, "select", function(items, _, callback)
      callback(items[1])
    end, function()
      press("gO")
      on_page(s, 3)
    end)
    local at = corner(s)
    truthy(at.scroll_y, "a width fit scrolls")
    harness.near(292 / 792, at.y, 0.005, "500 points from the bottom of the page at the top of the window")
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

describe("viewer links", function()
  setup()

  local function linked(name)
    return make(name, {
      {
        w = 612,
        h = 792,
        label = "Contents",
        texts = { { x = 72, y = 600, text = "Website" }, { x = 72, y = 300, text = "Results" } },
        links = {
          { rect = { 70, 290, 250, 330 }, page = 3 },
          { rect = { 70, 590, 250, 630 }, uri = "https://example.com/" },
        },
      },
      LETTER,
      LETTER,
    })
  end

  --- Press `f` and pick the link the picker offers first that `choose` accepts (nil cancels).
  ---@return { items: PdfView.Link[], opts: table }
  local function follow(choose)
    local offered
    with_stub(vim.ui, "select", function(items, opts, callback)
      offered = { items = items, opts = opts }
      callback(choose(items))
    end, function()
      press("f")
      wait_for(function()
        return offered ~= nil
      end, "the link picker")
    end)
    return offered
  end

  it("offers the links on the page and jumps to the page one leads to, as a jump", function()
    reset()
    local s = open(linked("links"))
    local offered = follow(function(items)
      return items[2]
    end)
    eq("Links", offered.opts.prompt)
    eq({ "Website  (https://example.com/)", "Results  (p. 3)" }, vim.tbl_map(offered.opts.format_item, offered.items))
    on_page(s, 3)
    press(vim.keycode("<C-o>"))
    on_page(s, 1)
  end)

  it("brings the point a link leads to to the top left of the window", function()
    reset()
    local s = open(make("links-at", {
      vim.tbl_extend(
        "force",
        LETTER,
        { links = { { rect = { 70, 290, 250, 330 }, page = 3, top = 500, left = 61.2 } } }
      ),
      LETTER,
      LETTER,
    }))
    press("w+")
    settle(s)
    follow(function(items)
      return items[1]
    end)
    on_page(s, 3)
    local at = corner(s)
    truthy(at.scroll_x and at.scroll_y, "a zoomed width fit scrolls both ways")
    harness.near(0.1, at.x, 0.005, "61.2 points from the left of the page at the left of the window")
    harness.near(292 / 792, at.y, 0.005, "500 points from the bottom of the page at the top of the window")
    press(vim.keycode("<C-o>"))
    on_page(s, 1)
  end)

  it("opens an address with vim.ui.open()", function()
    reset()
    local s = open(linked("links-open"))
    local opened
    with_stub(vim.ui, "open", function(uri)
      opened = uri
      return nil, nil
    end, function()
      follow(function(items)
        return items[1]
      end)
    end)
    eq("https://example.com/", opened)
    eq(1, s.page)
  end)

  it("does nothing when the picker is cancelled", function()
    reset()
    local s = open(linked("links-cancel"))
    local opened = false
    with_stub(vim.ui, "open", function()
      opened = true
    end, function()
      follow(function()
        return nil
      end)
    end)
    eq(false, opened)
    eq(1, s.page)
  end)

  it("tells the user when the page has no links", function()
    reset()
    local s = open(linked("links-none"))
    press("2gg")
    on_page(s, 2)
    local notes, asked = {}, false
    with_stub(vim.ui, "select", function()
      asked = true
    end, function()
      with_stub(vim, "notify", function(message)
        notes[#notes + 1] = message
      end, function()
        press("f")
        wait_for(function()
          return #notes > 0
        end, "the notification")
      end)
    end)
    eq(false, asked)
    truthy(notes[1]:find("page 2 has no links", 1, true), vim.inspect(notes))
    eq(2, s.page)
  end)
end)

describe("viewer page text", function()
  setup()

  local function texts(name)
    return make(name, {
      { w = 612, h = 792, label = "Page 1" },
      { w = 612, h = 792, label = "Page 2", texts = { { x = 72, y = 200, text = "Far below" } } },
      { w = 612, h = 792, label = "" },
    })
  end

  --- Run `body` with notifications collected instead of shown.
  local function collecting(body)
    local notes = {}
    with_stub(vim, "notify", function(message)
      notes[#notes + 1] = message
    end, function()
      body(notes)
    end)
    return notes
  end

  it("yanks the text of the page on screen, linewise, into the register given", function()
    reset()
    local s = open(texts("yank"))
    press("2gg")
    on_page(s, 2)
    vim.fn.setreg('"', "")
    local notes = collecting(function(notes)
      press("y")
      wait_for(function()
        return #notes > 0
      end, "the yank")
    end)
    eq({ "Page 2", "", "Far below" }, vim.fn.getreg('"', 1, true))
    eq("V", vim.fn.getregtype('"'))
    truthy(notes[1]:find("page 2: 3 lines yanked", 1, true), vim.inspect(notes))

    vim.fn.setreg("a", "")
    collecting(function()
      press('"ay')
      wait_for(function()
        return vim.fn.getreg("a") ~= ""
      end, "the yank into register a")
    end)
    eq("Page 2\n\nFar below\n", vim.fn.getreg("a"))
  end)

  it("shows the text of the page in a scratch split next to the viewer, and reuses it", function()
    reset()
    local s = open(texts("show"))
    local viewer_win = vim.api.nvim_get_current_win()
    press("t")
    wait_for(function()
      return vim.api.nvim_get_current_buf() ~= s.buf
    end, "the text split")
    local buf = vim.api.nvim_get_current_buf()
    eq("pdf-view://show.pdf (page 1)", vim.api.nvim_buf_get_name(buf))
    eq({ "Page 1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq("nofile", vim.bo[buf].buftype)
    eq("wipe", vim.bo[buf].bufhidden)
    eq(false, vim.bo[buf].modified)
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    eq(s.buf, vim.api.nvim_win_get_buf(viewer_win))
    eq("", vim.wo.winbar, "the viewer's winbar stays with the viewer")

    -- the same page again: the split is filled again and focused, not opened twice
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
    vim.api.nvim_set_current_win(viewer_win)
    press("t")
    wait_for(function()
      return vim.api.nvim_get_current_win() ~= viewer_win
    end, "the text split again")
    eq(buf, vim.api.nvim_get_current_buf())
    eq({ "Page 1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq(2, #vim.api.nvim_tabpage_list_wins(0))

    -- another page: the same buffer and split take its text and its page number, no second split opens
    vim.api.nvim_set_current_win(viewer_win)
    press("2gg")
    on_page(s, 2)
    press("t")
    wait_for(function()
      return vim.api.nvim_get_current_win() ~= viewer_win
    end, "the text split for page 2")
    eq(buf, vim.api.nvim_get_current_buf())
    eq("pdf-view://show.pdf (page 2)", vim.api.nvim_buf_get_name(buf))
    eq({ "Page 2", "", "Far below" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    eq(-1, vim.fn.bufnr("pdf-view://show.pdf (page 1)"), "renaming leaves no buffer behind under the old name")

    vim.cmd.close()
    eq(false, vim.api.nvim_buf_is_valid(buf), "closing the split wipes the scratch buffer")
  end)

  it("keeps a text buffer for each document, also for documents of the same file name", function()
    reset()
    vim.fn.mkdir(dir .. "/other", "p")
    local first = open(texts("same"))
    press("t")
    wait_for(function()
      return vim.api.nvim_get_current_buf() ~= first.buf
    end, "the text split of the first document")
    local first_text = vim.api.nvim_get_current_buf()
    vim.cmd.wincmd("p")

    local second = open(texts("other/same"))
    press("2gg")
    on_page(second, 2)
    press("t")
    wait_for(function()
      local buf = vim.api.nvim_get_current_buf()
      return buf ~= second.buf and buf ~= first_text
    end, "the text split of the second document")
    local second_text = vim.api.nvim_get_current_buf()
    eq({ "Page 2", "", "Far below" }, vim.api.nvim_buf_get_lines(second_text, 0, -1, false))
    eq("pdf-view://same.pdf (page 1)", vim.api.nvim_buf_get_name(first_text))
    eq({ "Page 1" }, vim.api.nvim_buf_get_lines(first_text, 0, -1, false))

    -- the second document's page 1 takes the name the first one holds: its full path tells them apart
    vim.cmd.wincmd("p")
    press("gg")
    on_page(second, 1)
    press("t")
    wait_for(function()
      return vim.api.nvim_get_current_buf() == second_text
    end, "the text split of the second document again")
    eq({ "Page 1" }, vim.api.nvim_buf_get_lines(second_text, 0, -1, false))
    eq(("pdf-view://%s (page 1)"):format(second.path), vim.api.nvim_buf_get_name(second_text))
    eq("pdf-view://same.pdf (page 1)", vim.api.nvim_buf_get_name(first_text))
  end)

  it("says so when the page has no text, and changes nothing", function()
    reset()
    local s = open(texts("blank"))
    press("G")
    on_page(s, 3)
    vim.fn.setreg('"', "kept")
    for _, key in ipairs({ "y", "t" }) do
      local notes = collecting(function(notes)
        press(key)
        wait_for(function()
          return #notes > 0
        end, "the notification")
      end)
      truthy(notes[1]:find("page 3 has no text", 1, true), vim.inspect(notes))
    end
    eq("kept", vim.fn.getreg('"'))
    eq(s.buf, vim.api.nvim_get_current_buf())
    eq(1, #vim.api.nvim_tabpage_list_wins(0))
  end)
end)

describe("viewer jumps and marks", function()
  setup()

  local back, forward = vim.keycode("<C-o>"), vim.keycode("<C-i>")

  --- Where the viewer is, as the jump list and marks keep it.
  local function where(s)
    return { s.page, s.mode, s.zoom, s.cx, s.cy }
  end

  --- Run `body` and return what it notified.
  local function notes_of(body)
    local notes = {}
    with_stub(vim, "notify", function(message)
      notes[#notes + 1] = message
    end, body)
    return notes
  end

  it("goes back and forward through gg, G and {count}G with <C-o> and <C-i>", function()
    reset()
    local s = open(make("jumps", pages(6)))
    press("4G")
    on_page(s, 4)
    press("G")
    on_page(s, 6)
    press("gg")
    on_page(s, 1)
    press(back)
    on_page(s, 6)
    press(back)
    on_page(s, 4)
    press(back)
    settle(s)
    eq(4, s.page, "page 1 is now the newest entry, not the oldest")
    press(forward)
    on_page(s, 6)
    press(forward)
    on_page(s, 1)
    press(forward)
    settle(s)
    eq(1, s.page, "nothing past the newest entry")
    press(vim.keycode("<Tab>"))
    settle(s)
    eq(1, s.page, "<Tab> is <C-i>")
    press("2" .. back)
    on_page(s, 4)
    press(vim.keycode("<Tab>"))
    on_page(s, 6)
  end)

  it("does not count page turns and scrolling as jumps", function()
    reset()
    local s = open(make("no-jumps", pages(5)))
    press("jj")
    on_page(s, 3)
    press(vim.keycode("<PageDown>"))
    on_page(s, 4)
    press(back)
    settle(s)
    eq(4, s.page)
    press("gg")
    on_page(s, 1)
    press("jj")
    on_page(s, 3)
    press(back)
    on_page(s, 4)
  end)

  it("swaps with the previous position with ''", function()
    reset()
    local s = open(make("swap", pages(5)))
    local notes = notes_of(function()
      press("''")
    end)
    eq(1, s.page)
    truthy(notes[1] and notes[1]:find("not set", 1, true), vim.inspect(notes))
    press("5G")
    on_page(s, 5)
    press("''")
    on_page(s, 1)
    press("''")
    on_page(s, 5)
    press("``")
    on_page(s, 1)
  end)

  it("brings back the fit, zoom and view of the jump's start", function()
    reset()
    local s = open(make("jump-view", pages(4)))
    press("w")
    settle(s)
    press("++jj")
    settle(s)
    local before = where(s)
    press("3G")
    on_page(s, 3)
    press("0")
    settle(s)
    press(back)
    settle(s)
    eq(before, where(s))
  end)

  it("counts search and outline jumps", function()
    reset()
    local path = dir .. "/jump-search.pdf"
    fixture.write(path, {
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "nothing" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "alpha" },
      { w = 612, h = 792, color = { 1, 1, 1 }, label = "end" },
    }, { outline = { { title = "End", page = 4 } } })
    local s = open(path)
    press("j")
    on_page(s, 2)
    answering("alpha", function()
      press("/")
      searched(s)
    end)
    eq(3, s.page)
    press("n")
    on_page(s, 1)
    with_stub(vim.ui, "select", function(items, _, callback)
      callback(items[1])
    end, function()
      press("gO")
      on_page(s, 4)
    end)
    press(back)
    on_page(s, 1)
    press(back)
    on_page(s, 3)
    press(back)
    on_page(s, 2)
  end)

  it("goes on through Vim's jump list past the ends of its own, back to the file it was opened from", function()
    reset()
    local notes = dir .. "/jump-out.txt"
    vim.fn.writefile({ "notes" }, notes)
    vim.cmd.edit(vim.fn.fnameescape(notes))
    local text = vim.api.nvim_get_current_buf()
    local s = open(make("jump-out", pages(4)))
    press("3G")
    on_page(s, 3)
    press(back)
    on_page(s, 1)
    press(back)
    eq(text, vim.api.nvim_get_current_buf(), "<C-o> at the oldest entry goes back to the file")
    press(forward)
    eq(s.buf, vim.api.nvim_get_current_buf(), "<C-i> comes back to the viewer")
    eq(viewer.sessions[s.buf], s)
    press(forward)
    on_page(s, 3)
    press("2" .. back)
    eq(text, vim.api.nvim_get_current_buf(), "the rest of the count goes on past the oldest entry")
    eq(1, s.page)
    press(forward)
    eq(s.buf, vim.api.nvim_get_current_buf())
    press("5" .. forward)
    on_page(s, 3)
    eq(s.buf, vim.api.nvim_get_current_buf(), "nothing in Vim's jump list after the viewer")
  end)

  it("marks a page with m{a-z} and goes back to it with '{a-z} and `{a-z}", function()
    reset()
    local s = open(make("marks", pages(5)))
    press("2G")
    on_page(s, 2)
    press("w")
    settle(s)
    press("+jj")
    settle(s)
    local marked = where(s)
    press("ma")
    press("4G")
    on_page(s, 4)
    press("0mb")
    settle(s)
    press("'a")
    settle(s)
    eq(marked, where(s))
    press("`b")
    on_page(s, 4)
    eq({ "page", 1 }, { s.mode, s.zoom })
    press("`a")
    settle(s)
    eq(marked, where(s))
    press(back)
    on_page(s, 4)
    press("''")
    settle(s)
    eq(marked, where(s), "'' goes back over a mark jump too")
  end)

  it("warns about marks that are not set or not a to z, and ignores <Esc>", function()
    reset()
    local s = open(make("bad-marks", pages(3)))
    press("2G")
    on_page(s, 2)
    local notes = notes_of(function()
      press("'z")
      press("mA")
      press("'1")
      press("m" .. vim.keycode("<Esc>"))
      press("'" .. vim.keycode("<Esc>"))
    end)
    eq(3, #notes, vim.inspect(notes))
    truthy(notes[1]:find("mark `z` is not set", 1, true), notes[1])
    truthy(notes[2]:find("`A` is not a mark", 1, true), notes[2])
    truthy(notes[3]:find("`1` is not a mark", 1, true), notes[3])
    eq(2, s.page)
    eq(nil, s.marks.A)
  end)

  it("keeps the marks and the jump list after :edit", function()
    reset()
    local s = open(make("marks-edit", pages(5)))
    press("3Gma5G")
    on_page(s, 5)
    vim.cmd("edit")
    local again = viewer.sessions[vim.api.nvim_get_current_buf()]
    truthy(again and again ~= s, "a fresh session")
    wait_for(function()
      return again.slot ~= 0 and again.job == nil
    end, "the render after :edit")
    eq(5, again.page)
    press("'a")
    on_page(again, 3)
    press(back)
    on_page(again, 5)
    press(back)
    on_page(again, 1)
  end)

  it("keeps marks apart in each viewer", function()
    reset()
    local one = open(make("marks-one", pages(4)))
    press("3Gma")
    on_page(one, 3)
    local two = open(make("marks-two", pages(4)))
    local notes = notes_of(function()
      press("'a")
    end)
    eq(1, two.page)
    eq(1, #notes, vim.inspect(notes))
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

  it("clears the hidden cursor before restoring an empty 'guicursor'", function()
    reset()
    local original = vim.o.guicursor
    vim.o.guicursor = ""
    local s = open(make("cursor-empty", pages(1)))
    truthy(hidden())
    local flushed = {}
    with_stub(vim.cmd, "redraw", function()
      flushed[#flushed + 1] = vim.o.guicursor
    end, function()
      vim.cmd.enew()
    end)
    -- the TUI keeps a blended cursor invisible once styles are off, so a group-free value has to reach it first
    eq({ "a:block" }, flushed)
    eq("", vim.o.guicursor)
    vim.api.nvim_set_current_buf(s.buf)
    truthy(hidden(), "hidden again on return")
    vim.cmd.enew()
    eq("", vim.o.guicursor)
    vim.o.guicursor = original
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

  it("applies a hide_cursor changed by setup() to the focused viewer", function()
    reset()
    local original = vim.o.guicursor
    open(make("cursor-toggle", pages(1)))
    truthy(hidden())
    setup({ hide_cursor = false })
    eq(original, vim.o.guicursor, "shown once the option is off")
    setup()
    truthy(hidden(), "hidden again once it is back on")
    vim.cmd.enew()
    eq(original, vim.o.guicursor)
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

  it("sets only the window options that changed when it turns a page", function()
    reset()
    local s = open(make("optionset", pages(3)))
    local set = {}
    local id = vim.api.nvim_create_autocmd("OptionSet", {
      callback = function(args)
        set[#set + 1] = args.match
      end,
    })
    press("j")
    on_page(s, 2)
    vim.api.nvim_del_autocmd(id)
    eq({ "winbar" }, set, "only the page number in the winbar changes")

    vim.wo.number = true -- e.g. another plugin
    press("j")
    on_page(s, 3)
    eq(false, vim.wo.number, "an option changed meanwhile is set back")
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

  it("keeps reloading after a clean build deletes and recreates the PDF's directory", function()
    reset()
    local build = dir .. "/build"
    vim.fn.mkdir(build, "p")
    local path = build .. "/out.pdf"
    fixture.write(path, pages(2))
    local s = open(path)
    eq(2, s.count)

    for round, count in ipairs({ 3, 4 }) do
      vim.fn.delete(build, "rf")
      vim.fn.mkdir(build, "p")
      fixture.write(path, pages(count))
      wait_for(function()
        return s.count == count and s.job == nil
      end, "a reload after clean build " .. round, 8000)
    end

    fixture.write(path, pages(5))
    wait_for(function()
      return s.count == 5 and s.job == nil
    end, "a reload of a plain write into the new directory", 8000)

    -- gone for longer than the reload delay: the file is polled until the directory is back
    vim.fn.delete(build, "rf")
    vim.wait(300)
    vim.fn.mkdir(build, "p")
    fixture.write(path, pages(6))
    wait_for(function()
      return s.count == 6 and s.job == nil
    end, "a reload once the directory came back", 8000)
    fixture.write(path, pages(7))
    wait_for(function()
      return s.count == 7 and s.job == nil
    end, "a reload of a write after the directory came back", 8000)
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

  it("reopens a PDF where it was left, from the state file, after its buffer is gone", function()
    reset()
    local path = make("remembered", pages(5))
    local s = open(path)
    press("w")
    settle(s)
    press("4G")
    on_page(s, 4)
    vim.cmd("silent! %bwipeout!") -- forgets the in-memory position: only the state file is left
    local again = open(path)
    wait_for(function()
      return again.slot ~= 0 and again.job == nil
    end, "the render of the reopened PDF")
    eq({ 4, "width" }, { again.page, again.mode })
  end)

  it("clamps restored zoom and viewport centres to their valid ranges", function()
    reset()
    setup({ max_zoom = 4 })
    local path = make("remembered-out-of-range", pages(2))
    local positions = require("pdf-view.positions")
    local initial = open(path)
    local remembered_path = initial.path
    vim.cmd("silent! %bwipeout!")
    positions.set(remembered_path, { page = 1, mode = "page", zoom = 100000, cx = 2.5, cy = -3 })
    vim.cmd.edit(vim.fn.fnameescape(path))
    local s = viewer.sessions[vim.api.nvim_get_current_buf()]
    truthy(s, "no viewer session for " .. path)
    eq({ 1, 0 }, { s.cx, s.cy })
    wait_for(function()
      return s.slot ~= 0 or vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("pdf%-view:") ~= nil
    end, "first render")
    eq(4, s.zoom)
    truthy(s.cx > 0.5 and s.cx <= 1 and s.cy < 0.5 and s.cy >= 0, "centre clamped toward the top right")

    reset()
    local other = make("remembered-below-range", pages(2))
    initial = open(other)
    remembered_path = initial.path
    vim.cmd("silent! %bwipeout!")
    positions.set(remembered_path, { page = 2, mode = "page", zoom = 0.25, cx = -2, cy = 3 })
    local restored = open(other)
    eq({ 2, 1, 0, 1 }, { restored.page, restored.zoom, restored.cx, restored.cy })
    setup()
  end)

  it("remembers the viewers that are open when Neovim exits", function()
    reset()
    local path = make("remembered-on-exit", pages(5))
    local s = open(path)
    press("3G")
    on_page(s, 3)
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    eq(true, s.closed)
    eq(3, require("pdf-view.positions").get(s.path).page)
  end)

  it("starts on the first page when remember_position is off", function()
    reset()
    setup({ remember_position = false })
    local path = make("not-remembered", pages(5))
    local s = open(path)
    press("3G")
    on_page(s, 3)
    vim.cmd("silent! %bwipeout!")
    eq(nil, require("pdf-view.positions").get(s.path), "nothing was stored")
    local again = open(path)
    wait_for(function()
      return again.slot ~= 0 and again.job == nil
    end, "the render of the reopened PDF")
    eq(1, again.page)
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
      local seen = {}
      for _, page in ipairs(asked) do
        truthy(page ~= 1 and not seen[page], "asked once for each page not shown yet: " .. vim.inspect(asked))
        seen[page] = true
      end

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
    local saved_tmux, saved_system, saved_detect = vim.env.TMUX, vim.system, terminal.detect
    local client = { pid = "100", termname = "xterm-kitty" }
    vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
    terminal.detect = real_detect -- tmux names the terminal of the attached client
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
    vim.env.TMUX, vim.system, terminal.detect = saved_tmux, saved_system, saved_detect
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
      idle(s)
      local path = s.images[s.ids[s.slot]]
      local renders = vim.tbl_count(s.cache)
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
      idle(s)
      eq(renders, vim.tbl_count(s.cache), "nothing rendered again")
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
  vim.env.ZELLIJ = "0"
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

  --- Hide the page of `name` (zellij drops the image), then show it again while `kitty.transmit` fails `failures` times.
  local function shown_again_failing(name, failures)
    reset()
    local s = open(make(name, pages(1)))
    vim.cmd.enew()
    vim.cmd.redraw()
    wait_for(function()
      return s.lost
    end, "the page taken away")
    writes = {}
    local transmit = kitty.transmit
    with_stub(kitty, "transmit", function(...)
      if failures > 0 then
        failures = failures - 1
        error("cannot read the PNG")
      end
      return transmit(...)
    end, function()
      vim.cmd.buffer(s.buf)
      vim.cmd.redraw()
      wait_for(function()
        return #last_batch() == 1 or vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:find("pdf%-view:") ~= nil
      end, "the page or a message")
    end)
    return s
  end

  it("renders the page again when it cannot send the lost page again", function()
    local s = shown_again_failing("zellij-resend-once", 1)
    eq(1, #last_batch(), "the page placed")
    eq(1, #transmitted(), "sent once rendered again")
    eq(false, s.lost)
  end)

  it("says why when it cannot send the lost page at all", function()
    local s = shown_again_failing("zellij-resend-never", math.huge)
    truthy(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:find("cannot read the PNG", 1, true))
    eq(0, #last_batch(), "nothing placed")
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
    local replies = terminal.replies_readable
    terminal.replies_readable = function()
      return false -- as on Neovim 0.11
    end
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
    terminal.replies_readable = replies
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

  vim.env.ZELLIJ = nil
  setup()
end)

describe("viewer with positioned placements outside zellij (WezTerm, Konsole)", function()
  local detect = terminal.detect
  local function as_terminal(name)
    terminal.detect = function()
      return { name = name, term = name, placeholders = false }
    end
  end
  as_terminal("wezterm")
  setup()

  it("places the page at its window's position, under the text", function()
    reset()
    eq("positioned", terminal.placement(), "chosen for a terminal without placeholders")
    open(make("wezterm-basic", pages(1)))
    eq(false, sent("U=1"), "no virtual placement")
    local batch = last_batch()
    eq(1, #batch)
    eq(-1, batch[1].keys.z)
  end)

  it("keeps the page in the terminal while its window shows another buffer", function()
    reset()
    local s = open(make("wezterm-hide", pages(1)))
    local id = s.ids[s.slot]
    writes = {}
    vim.cmd.enew()
    vim.cmd.redraw()
    wait_for(function()
      return sent(("a=d,d=i,i=%d,q=2"):format(id))
    end, "the page taken away")
    eq(false, s.lost, "a terminal keeps an image without placements")

    writes = {}
    vim.cmd.buffer(s.buf)
    vim.cmd.redraw()
    wait_for(function()
      return #last_batch() == 1
    end, "the page placed again")
    eq({}, transmitted(), "not sent again")
  end)

  it("cuts the page around a floating window without sending it again when the float moves", function()
    reset()
    local s = open(make("wezterm-float", pages(1)))
    local image = image_rect(s)
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = image.row + 2,
      col = image.col + 3,
      width = 4,
      height = 2,
      border = "single",
    })
    local before = #writes
    vim.cmd.redraw()
    wait_for(function()
      return select(2, last_batch()) > before
    end, "the page placed around the float")
    -- above, left of, right of and below the float: pieces of equal size are not split as for zellij
    eq(4, #last_batch())
    writes = {}
    vim.api.nvim_win_set_config(float, { relative = "editor", row = image.row + 3, col = image.col + 3 })
    vim.cmd.redraw()
    wait_for(function()
      return #last_batch() == 4
    end, "the page placed around the moved float")
    eq({}, transmitted(), "the terminal still has the page")
    vim.api.nvim_win_close(float, true)
    eq(s.picture ~= nil, true)
  end)

  it("does not send the page again after a message scrolled the screen, when replies cannot be read", function()
    reset()
    local replies = terminal.replies_readable
    terminal.replies_readable = function()
      return false -- as on Neovim 0.11
    end
    local ok, err = pcall(function()
      open(make("wezterm-scrolled", pages(1)))
      writes = {}
      vim.v.scrollstart = "Unknown"
      vim.cmd("redraw!")
      wait_for(function()
        return #last_batch() == 1
      end, "placed again")
      eq({}, transmitted(), "the terminal scrolled the image with the text")
    end)
    terminal.replies_readable = replies
    vim.v.scrollstart = ""
    if not ok then
      error(err, 0)
    end
  end)

  it("asks for no replies behind tmux with extended keys, which would type them into the viewer", function()
    reset()
    local saved_tmux, saved_system = vim.env.TMUX, vim.system
    local extended_keys = "on"
    vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] ~= "tmux" then
        return saved_system(cmd, opts, on_exit)
      end
      local stdout = ""
      if cmd[2] == "show-options" then
        stdout = extended_keys
      elseif cmd[2] == "display-message" then
        stdout = "0 0 off bottom" -- the pane fills the window
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
    --- The `q` key of the last placement, which says which replies the terminal is asked for.
    local function quiet()
      for index = #writes, 1, -1 do
        local q = writes[index]:match("a=p,[^\27]-q=(%d)")
        if q then
          return tonumber(q)
        end
      end
    end
    terminal.forget()
    local ok, err = pcall(function()
      local s = open(make("wezterm-tmux-extended-keys", pages(1)))
      eq(2, quiet(), "no replies asked for")
      local reply = ("\27_Gi=%d,p=1;ENOENT:unknown image id\27\\"):format(s.ids[s.slot])
      writes = {}
      vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = reply } })
      vim.wait(100)
      eq({}, transmitted(), "a reply that cannot have been read is not taken for one")

      if vim.fn.has("nvim-0.12") == 1 then
        extended_keys = "off"
        terminal.forget() -- as when tmux is attached from another terminal
        s.dirty = true
        require("pdf-view.positioned").refresh(s)
        eq(1, quiet(), "asked again when placing: an image the terminal lost is reported")
      end
    end)
    vim.env.TMUX, vim.system = saved_tmux, saved_system
    terminal.forget()
    if not ok then
      error(err, 0)
    end
  end)

  it("places the page over the text in Konsole, which hides it under a coloured cell", function()
    reset()
    as_terminal("konsole")
    setup({ transmission = "auto" })
    eq("direct", terminal.transmission(), "Konsole takes no image files")
    open(make("konsole-basic", pages(1)))
    local batch = last_batch()
    eq(1, #batch)
    eq(nil, batch[1].keys.z)
    truthy(sent("t=d"), "sent as bytes")
    as_terminal("wezterm")
  end)

  terminal.detect = detect
  setup()
end)

describe("viewer with iTerm2 inline images (iTerm2, VS Code)", function()
  local detect = terminal.detect
  terminal.detect = function()
    return { name = "iterm2", term = "iterm.app", placeholders = false }
  end
  setup()

  --- The images printed by the writes from `from` on: `{ row, col, args, png }`, rows and columns 1-based.
  local function prints(from)
    local list = {}
    for index = from or 1, #writes do
      for row, col, args, data in writes[index]:gmatch("\27%[(%d+);(%d+)H\27%]1337;File=([^:]*):([^\a]*)\a") do
        local parsed = {}
        for key, value in args:gmatch("(%w+)=(%w+)") do
          parsed[key] = tonumber(value) or value
        end
        list[#list + 1] = { row = tonumber(row), col = tonumber(col), args = parsed, png = vim.base64.decode(data) }
      end
    end
    return list
  end

  --- The cells erased by the writes, as "row:col", 1-based.
  local function erased()
    local cells = {}
    for _, data in ipairs(writes) do
      for row, col, count in data:gmatch("\27%[(%d+);(%d+)H\27%[(%d+)X") do
        for offset = 0, tonumber(count) - 1 do
          cells[row .. ":" .. (tonumber(col) + offset)] = true
        end
      end
    end
    return cells
  end

  --- The cells of `rects`, as "row:col", 1-based.
  local function cells_of(rects)
    local cells = {}
    for _, r in ipairs(rects) do
      for row = r.row, r.row + r.rows - 1 do
        for col = r.col, r.col + r.cols - 1 do
          cells[(row + 1) .. ":" .. (col + 1)] = true
        end
      end
    end
    return cells
  end

  local function printed(s, count)
    wait_for(function()
      return s.placed ~= nil and s.placed.rects ~= nil and #s.placed.rects == count and not s.dirty
    end, count .. " pieces printed")
  end

  it("prints the page at its window's position, and sends no Kitty graphics", function()
    reset()
    eq("iterm2", terminal.protocol())
    eq("positioned", terminal.placement())
    local s = open(make("iterm2-basic", pages(1)))
    printed(s, 1)
    eq({ "" }, vim.fn.uniq(vim.api.nvim_buf_get_lines(0, 0, -1, false)), "the buffer is blank")
    local list = prints()
    local last, image = list[#list], image_rect(s)
    eq({ image.row + 1, image.col + 1 }, { last.row, last.col })
    eq({ s.picture.cols, s.picture.rows, 0, 1 }, {
      last.args.width,
      last.args.height,
      last.args.preserveAspectRatio,
      last.args.doNotMoveCursor,
    })
    eq(slurp(s.picture.path), last.png, "the rendered page, as it is")
    eq(false, sent("\27_G"), "no Kitty graphics command")
    truthy(writes[#writes]:find("^\0277") and writes[#writes]:find("\0278$"), "the cursor is saved and restored")
  end)

  it("prints the parts around a float as PNGs of their own, and the whole page once it closes", function()
    reset()
    local s = open(make("iterm2-float", pages(1)))
    printed(s, 1)
    local image = image_rect(s)
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = image.row + 2,
      col = image.col + 3,
      width = 4,
      height = 2,
      border = "single",
    })
    writes = {}
    vim.cmd.redraw()
    printed(s, 4)
    local list = prints()
    local area = 0
    for index = #list - 3, #list do
      local piece = list[index]
      area = area + piece.args.width * piece.args.height
      local function u32(offset)
        local a, b, c, d = piece.png:byte(offset, offset + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
      end
      local w, h = u32(17), u32(21)
      truthy(w < s.picture.width or h < s.picture.height, "a part of the page, not all of it")
    end
    eq(image.rows * image.cols - 6 * 4, area, "every cell but the float's (with its border)")
    eq({}, erased(), "nothing to erase: the float was drawn over the page")

    writes = {}
    vim.api.nvim_win_close(float, true)
    vim.cmd.redraw()
    printed(s, 1)
    eq(slurp(s.picture.path), prints()[#prints()].png, "whole again")
  end)

  it("erases what the zoomed page leaves uncovered when it zooms out", function()
    reset()
    local s = open(make("iterm2-zoom", pages(1)))
    printed(s, 1)
    press("+")
    wait_for(function()
      return s.zoom > 1 and s.job == nil and s.placed and s.placed.id == s.picture.id and not s.dirty
    end, "zoomed in")
    local zoomed = vim.deepcopy(s.placed.rects)
    writes = {}
    press("0")
    wait_for(function()
      return s.zoom == 1 and s.job == nil and next(erased()) ~= nil
    end, "the zoomed page erased")
    local expected = cells_of(zoomed)
    for cell in pairs(cells_of(s.placed.rects)) do
      expected[cell] = nil
    end
    eq(expected, erased(), "exactly the cells the fitted page does not cover")
  end)

  it("clears the screen when the window shows another buffer, which may not draw over all of the page", function()
    reset()
    local s = open(make("iterm2-hide", pages(1)))
    printed(s, 1)
    local cleared = 0
    with_stub(vim.cmd, "mode", function()
      cleared = cleared + 1
    end, function()
      vim.cmd.enew()
      vim.cmd.redraw()
      wait_for(function()
        return cleared > 0
      end, ":mode")
      eq({}, erased(), "nothing erased by hand: the other buffer is drawn there")

      writes = {}
      vim.cmd.buffer(s.buf)
      vim.cmd.redraw()
      printed(s, 1)
    end)
  end)

  it("erases the page for a message in its place", function()
    reset()
    local path = make("iterm2-message", pages(1))
    local s = open(path)
    printed(s, 1)
    local rects = vim.deepcopy(s.placed.rects)
    writes = {}
    os.remove(path)
    press("r")
    wait_for(function()
      return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("pdf%-view:") ~= nil
    end, "the message")
    eq(cells_of(rects), erased())
    eq({}, prints())
  end)

  terminal.detect = detect
  setup()
end)

describe("viewer in a terminal that cannot show pages", function()
  it("shows the text of the page under the reason, and turns the pages", function()
    reset()
    setup({ force = false, protocol = "kitty", placement = "placeholders" })
    local detect = terminal.detect
    terminal.detect = function()
      return { name = "wezterm", term = "wezterm", placeholders = false }
    end
    local ok, err = pcall(function()
      local s = open(make("text-instead", pages(3)))
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      end
      wait_for(function()
        return text():find("Page 1", 1, true) ~= nil
      end, "the text of page 1")
      truthy(text():find("^pdf%-view: wezterm has no Unicode placeholders"), text())
      eq({ 1, 3 }, { s.page, s.count })
      eq(0, s.slot, "no image")
      press(vim.keycode("<PageDown>"))
      wait_for(function()
        return text():find("Page 2", 1, true) ~= nil
      end, "the text of page 2")
      eq(2, s.page)
      truthy(not text():find("Page 1", 1, true), text())
      press("G")
      wait_for(function()
        return s.page == 3 and text():find("Page 3", 1, true) ~= nil
      end, "the last page")
      eq({}, writes, "nothing sent to the terminal")
    end)
    terminal.detect = detect
    setup()
    assert(ok, err)
  end)

  it("scrolls to the end of a long page, and does not read it again on a window switch", function()
    reset()
    setup({ force = false, protocol = "kitty", placement = "placeholders" })
    local detect = terminal.detect
    terminal.detect = function()
      return { name = "wezterm", term = "wezterm", placeholders = false }
    end
    local ok, err = pcall(function()
      local texts = {}
      for line = 1, 60 do
        texts[line] = { x = 30, y = 3000 - 45 * line, text = "Line " .. line }
      end
      local s = open(make("text-long", { { w = 612, h = 3100, label = "Top", texts = texts } }))
      wait_for(function()
        return vim.fn.search("Line 60", "nw") > 0
      end, "the text of the page")
      local win = vim.api.nvim_get_current_win()
      local last = vim.api.nvim_buf_line_count(0)
      truthy(last > vim.api.nvim_win_get_height(win), "taller than the window")
      local function settle()
        vim.api.nvim_exec_autocmds("WinScrolled", {}) -- Neovim fires it from its main loop, which a test never reaches
        vim.wait(100, function()
          return false
        end)
      end
      press(vim.keycode("<C-e><C-e><C-e>"))
      settle()
      eq(4, vim.fn.line("w0", win), "scrolled, not put back at the top")
      press(vim.keycode("<C-d><C-d><C-d><C-d><C-d><C-d><C-d><C-d>"))
      settle()
      eq(last, vim.fn.line("w$", win), "the last line can be reached")

      local reads = 0
      local info = mupdf.info
      with_stub(mupdf, "info", function(...)
        reads = reads + 1
        return info(...)
      end, function()
        -- a float leaves the viewer's window as it is: its layout did not change
        local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
          relative = "editor",
          row = 1,
          col = 1,
          width = 10,
          height = 2,
        })
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_close(float, true)
        vim.wait(300, function()
          return false
        end)
      end)
      eq(0, reads, "the text was not read again")
      truthy(s.page_text, "still the text")
    end)
    terminal.detect = detect
    setup()
    assert(ok, err)
  end)
end)

describe("viewer with sixel (foot, Windows Terminal, xterm)", function()
  local detect = terminal.detect
  terminal.detect = function()
    return { name = "foot", term = "foot", placeholders = false }
  end
  setup()

  --- The sixel images printed by the writes from `from` on: `{ row, col, width, height }`, rows and columns 1-based,
  --- the size in pixels from the raster attributes.
  local function sixels(from)
    local list = {}
    for index = from or 1, #writes do
      for row, col, width, height in writes[index]:gmatch('\27%[(%d+);(%d+)H\27P0;1;0q"1;1;(%d+);(%d+)') do
        list[#list + 1] = { tonumber(row), tonumber(col), tonumber(width), tonumber(height) }
      end
    end
    return list
  end

  local function printed(s, count)
    wait_for(function()
      return s.placed ~= nil and s.placed.rects ~= nil and #s.placed.rects == count and not s.dirty
    end, count .. " pieces printed")
  end

  it("prints the page at its window's position, pixel for pixel at the size of its cells", function()
    reset()
    eq("sixel", terminal.protocol())
    eq("positioned", terminal.placement())
    local s = open(make("sixel-basic", pages(1)))
    printed(s, 1)
    local image = image_rect(s)
    eq({ { image.row + 1, image.col + 1, image.cols * 10, image.rows * 20 } }, sixels())
    eq(false, sent("\27_G"), "no Kitty graphics command")
    eq(false, sent("\27]1337"), "no iTerm2 image")
    truthy(writes[#writes]:find("^\0277") and writes[#writes]:find("\0278$"), "the cursor is saved and restored")

    writes = {}
    vim.cmd("mode") -- the screen is drawn again: the page is printed again, without encoding it again
    vim.cmd.redraw()
    printed(s, 1)
    eq(1, #sixels())
    local files = 0
    for _, file in pairs(s.picture.crops) do
      files = files + ((type(file) == "string" and file:find("%.six$")) and 1 or 0)
    end
    eq(1, files, "encoded once")
  end)

  it("prints the parts around a float as images of their own, at their size on screen", function()
    reset()
    local s = open(make("sixel-float", pages(1)))
    printed(s, 1)
    local image = image_rect(s)
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = image.row + 2,
      col = image.col + 3,
      width = 4,
      height = 2,
      border = "single",
    })
    writes = {}
    vim.cmd.redraw()
    printed(s, 4)
    local area = 0
    for _, print in ipairs(sixels()) do
      area = area + print[3] * print[4]
    end
    eq((image.rows * image.cols - 6 * 4) * 10 * 20, area, "every pixel but the float's (with its border)")

    writes = {}
    vim.api.nvim_win_close(float, true)
    vim.cmd.redraw()
    printed(s, 1)
    eq({ { image.row + 1, image.col + 1, image.cols * 10, image.rows * 20 } }, sixels(), "whole again")
  end)

  terminal.detect = detect
  setup()
end)

describe("viewer page turns", function()
  setup()

  it("reuses rendered pages instead of rendering them again", function()
    reset()
    local s = open(make("cache", pages(30)))
    idle(s)
    local first = transmitted()[1]
    for _, keys in ipairs({ "10G", "20G", "30G", "5G" }) do -- more pages than the terminal keeps
      press(keys)
      idle(s)
    end
    local renders = vim.tbl_count(s.cache)
    writes = {}
    press("gg")
    on_page(s, 1)
    eq({ first }, transmitted(), "the same PNG is sent again")
    idle(s)
    eq(renders, vim.tbl_count(s.cache), "nothing was rendered again")
  end)

  it("keeps a page shown from the cache over the ones shown less recently", function()
    reset()
    local s = open(make("cache-recent", pages(30)))
    idle(s)
    local first = transmitted()[1]
    for _, keys in ipairs({ "10G", "15G", "20G", "25G", "30G" }) do -- fills the cache, the first page the oldest
      press(keys)
      idle(s)
    end
    eq(16, #s.cache_order, "the cache is full")
    press("gg")
    on_page(s, 1)
    idle(s)
    press("5G") -- renders more pages, which evict the least recently shown ones
    idle(s)
    eq(true, vim.tbl_contains(vim.tbl_values(s.cache), first), "the first page is still cached")
    truthy(vim.uv.fs_stat(first), "its PNG is still there")
  end)

  it("renders the next and the previous page ahead of time", function()
    reset()
    local s = open(make("prefetch", pages(7)))
    press("5G")
    on_page(s, 5)
    idle(s)
    local drawn = {}
    local render = mupdf.render
    with_stub(mupdf, "render", function(file, page, width, height, out, cb)
      drawn[#drawn + 1] = page
      return render(file, page, width, height, out, cb)
    end, function()
      press("j")
      on_page(s, 6)
      eq({}, drawn, "page 6 was already rendered")
      idle(s)
      eq({ 7 }, drawn, "then page 7 is, and page 5 is still there")
      press("k")
      press("k")
      on_page(s, 4)
      idle(s)
      eq({ 7, 3 }, drawn, "page 3 is rendered ahead of time once 4 is shown")
    end)
  end)

  it("waits for the page being rendered ahead of time instead of rendering it again", function()
    reset()
    local s = open(make("prefetch-wait", pages(3)))
    idle(s)
    local drawn, finish = {}, {}
    local render = mupdf.render
    with_stub(mupdf, "render", function(file, page, width, height, out, cb)
      drawn[#drawn + 1] = page
      -- held back until the test lets it finish
      return render(file, page, width, height, out, function(...)
        local args = { ... }
        finish[#finish + 1] = function()
          cb(unpack(args))
        end
      end)
    end, function()
      press("j")
      on_page(s, 2)
      wait_for(function()
        return #drawn == 1 and s.rendering ~= nil and next(s.rendering) ~= nil
      end, "page 3 being rendered ahead of time")
      eq({ 3 }, drawn)
      press("j")
      vim.wait(100)
      eq({ 3 }, drawn, "page 3 is not rendered twice")
      eq(2, s.page, "page 3 is not on screen before its render is done")
      wait_for(function()
        return #finish == 1
      end, "the render")
      finish[1]()
      on_page(s, 3)
    end)
  end)

  it("shows a page it turns back to without sending it to the terminal again", function()
    reset()
    local s = open(make("terminal-cache", pages(3)))
    local first, first_id = transmitted()[1], s.ids[s.slot]
    press("j")
    on_page(s, 2)
    local second_id = s.ids[s.slot]
    truthy(second_id ~= first_id, "the next page has another id")
    eq(2, #transmitted())
    writes = {}
    press("k")
    on_page(s, 1)
    eq({}, transmitted(), "the terminal still has page 1")
    eq(first_id, s.ids[s.slot])
    truthy(sent(kitty.place(first_id, placement())), "placed again")
    press("j")
    on_page(s, 2)
    eq({}, transmitted(), "and page 2")
    eq(second_id, s.ids[s.slot])
    eq(first, s.images[first_id])

    -- `r` sends the page again, in case the terminal dropped it
    press("r")
    settle(s)
    eq(1, #transmitted())
  end)

  it("sends the bytes of a page only once over SSH", function()
    reset()
    setup({ transmission = "direct" })
    local s = open(make("terminal-cache-direct", pages(2)))
    local function uploads()
      local count = 0
      for _, data in ipairs(writes) do
        if data:find("\27_Ga=t,f=100,") then
          count = count + 1
        end
      end
      return count
    end
    eq(1, uploads())
    press("j")
    on_page(s, 2)
    press("k")
    on_page(s, 1)
    press("j")
    on_page(s, 2)
    eq(2, uploads(), "each page is uploaded once")
    setup()
  end)
end)

describe("viewer password-protected documents", function()
  setup()

  --- A copy of a fresh PDF of `count` pages locked with the password "secret".
  local function locked(name, count)
    local plain = make(name .. "-plain", pages(count))
    local path = dir .. "/" .. name .. ".pdf"
    local made = vim
      .system({ "mutool", "clean", "-E", "aes-256", "-U", "secret", "-O", "owner", plain, path }, { text = true })
      :wait()
    assert(made.code == 0, made.stderr)
    return path
  end

  --- Answer the password prompts with `answers` in turn, and record the prompts.
  local function answer(answers)
    local prompts = {}
    vim.fn.inputsecret = function(prompt) ---@diagnostic disable-line: duplicate-set-field
      prompts[#prompts + 1] = prompt
      return table.remove(answers, 1) or ""
    end
    return prompts
  end

  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end

  it("asks for the password, shows the pages, and remembers it for the session", function()
    reset()
    local path = locked("asked", 3)
    local prompts = answer({ "secret" })
    local s = open(path)
    eq({ "Password for asked.pdf: " }, prompts)
    eq(3, s.count)
    truthy(s.slot ~= 0, "the page is not on screen")
    press("j")
    on_page(s, 2)

    -- the search reads the document in a process of its own, which is given the password too
    local input = vim.ui.input
    vim.ui.input = function(_, cb) ---@diagnostic disable-line: duplicate-set-field
      cb("Page")
    end
    press("/")
    vim.ui.input = input
    wait_for(function()
      return s.search ~= nil and s.search_job == nil
    end, "search")
    eq(3, #s.search.matches)

    -- reopened, it is not asked for again
    reset()
    s = open(path)
    eq(1, #prompts, "asked again")
    truthy(s.slot ~= 0, "the page is not on screen")
    vim.fn.inputsecret = nil
  end)

  it("asks again after a wrong password", function()
    reset()
    local prompts = answer({ "nope", "secret" })
    local s = open(locked("wrong", 2))
    eq({ "Password for wrong.pdf: ", "Wrong password for wrong.pdf, try again: " }, prompts)
    eq(2, s.count)
    truthy(s.slot ~= 0, "the page is not on screen")
    vim.fn.inputsecret = nil
  end)

  it("says so when the prompt is cancelled, and asks again on :edit only", function()
    reset()
    local prompts = answer({ "" })
    local s = open(locked("cancelled", 2))
    eq(1, #prompts)
    eq(0, s.slot)
    truthy(text():find("pdf-view: cancelled.pdf is password-protected", 1, true), text())

    -- a resized window shows the page again, which keeps the message and does not ask
    local before = s.requested_key
    vim.cmd("vsplit")
    wait_for(function()
      return s.requested_key ~= before and s.job == nil
    end, "re-layout after the split")
    eq(1, #prompts, "asked again after a resize")
    eq(0, s.slot)
    truthy(text():find("password-protected", 1, true), text()) -- wrapped to the narrower window
    vim.cmd("only")

    answer({ "secret" })
    vim.cmd.edit()
    s = viewer.sessions[vim.api.nvim_get_current_buf()]
    wait_for(function()
      return s.slot ~= 0
    end, "the page after :edit")
    eq(2, s.count)
    vim.fn.inputsecret = nil
  end)

  it("asks for the password in a terminal that cannot show pages, and shows the text", function()
    reset()
    setup({ force = false, protocol = "kitty", placement = "placeholders" })
    local detect = terminal.detect
    terminal.detect = function()
      return { name = "wezterm", term = "wezterm", placeholders = false }
    end
    local ok, err = pcall(function()
      local prompts = answer({ "nope", "secret" })
      local s = open(locked("text-locked", 2))
      wait_for(function()
        return text():find("Page 1", 1, true) ~= nil
      end, "the text of page 1")
      eq({ "Password for text-locked.pdf: ", "Wrong password for text-locked.pdf, try again: " }, prompts)
      truthy(text():find("^pdf%-view: wezterm has no Unicode placeholders"), text())
      eq({ 1, 2 }, { s.page, s.count })
      eq(0, s.slot, "no image")
    end)
    terminal.detect = detect
    vim.fn.inputsecret = nil
    setup()
    assert(ok, err)
  end)

  it("stays put on G while the page count is unknown, with facing pages", function()
    for _, spread in ipairs({ "on", "cover", "off" }) do
      setup({ spread = spread })
      reset()
      answer({ "" })
      local s = open(locked("unknown-count-" .. spread, 3))
      eq(nil, s.count)
      local jumps = #s.jumps
      press("G")
      eq(nil, s.target, spread)
      eq(jumps, #s.jumps, "a jump recorded with " .. spread)
      settle(s)
      eq(0, s.slot, spread)
    end
    setup()
    vim.fn.inputsecret = nil
  end)
end)

describe("viewer recolouring", function()
  --- RGB of the paper (top-left corner) of the page on screen.
  local function paper(s)
    local png = s.images[s.ids[s.slot]]
    truthy(png, "no page on screen")
    return fixture.pixels(png, { { 2, 2 } })[1]
  end

  local function dark(rgb)
    return rgb[1] < 40 and rgb[2] < 40 and rgb[3] < 40
  end

  local white = { w = 612, h = 792, color = { 1, 1, 1 }, label = "Page 1" }

  it("switches the recolouring on and off with a key", function()
    setup()
    reset()
    local s = open(make("recolor-toggle", { white, white }))
    eq({ 255, 255, 255 }, paper(s))

    press("i")
    on_page(s, 1)
    truthy(dark(paper(s)), "inverted: " .. vim.inspect(paper(s)))

    -- a page turned to is recoloured too, also when it was drawn ahead of time before the switch
    press(vim.keycode("<PageDown>"))
    on_page(s, 2)
    truthy(dark(paper(s)), "page 2 inverted: " .. vim.inspect(paper(s)))

    press("i")
    on_page(s, 2)
    eq({ 255, 255, 255 }, paper(s))
  end)

  it("recolours the page on screen with a later setup()", function()
    setup()
    reset()
    local s = open(make("recolor-setup", { white }))
    eq({ 255, 255, 255 }, paper(s))
    setup({ recolor = "invert" })
    wait_for(function()
      return s.job == nil and dark(paper(s))
    end, "the page inverted")
    setup()
    wait_for(function()
      return s.job == nil and vim.deep_equal(paper(s), { 255, 255, 255 })
    end, "the page in its own colours")
  end)

  it("draws the pages in the colorscheme's colours, and again when the colorscheme changes", function()
    setup({ recolor = "colorscheme" })
    reset()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xe0e0e0, bg = 0x102030 })
    local s = open(make("recolor-colorscheme", { white }))
    eq({ 16, 32, 48 }, paper(s))

    vim.api.nvim_set_hl(0, "Normal", { fg = 0x203040, bg = 0xf0e0d0 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    wait_for(function()
      return s.job == nil and vim.deep_equal(paper(s), { 240, 224, 208 })
    end, "the page in the new colours")

    -- the key stops recolouring, and switches it back to the configured kind
    press("i")
    on_page(s, 1)
    eq({ 255, 255, 255 }, paper(s))
    press("i")
    on_page(s, 1)
    eq({ 240, 224, 208 }, paper(s))
    setup()
  end)
end)

describe("viewer SyncTeX", function()
  -- a stand-in for `synctex`: it logs its arguments and prints what the test put in `<dir>/synctex-<subcommand>`
  local fake = dir .. "/synctex"
  local log = dir .. "/synctex.log"
  local script = io.open(fake, "w")
  assert(script)
  script:write(
    "#!/bin/sh\n",
    ('printf "%%s\\n" "$*" >> "%s"\n'):format(log),
    ('cat "%s/synctex-$1" 2>/dev/null\n'):format(dir)
  )
  script:close()
  vim.uv.fs_chmod(fake, 493) -- 0755

  local function answer(subcommand, lines)
    local file = assert(io.open(dir .. "/synctex-" .. subcommand, "w"))
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
  end

  local function logged()
    local text = slurp(log) or ""
    return vim.split(vim.trim(text), "\n", { plain = true, trimempty = true })
  end

  --- A PDF and the TeX file it was "built" from, next to it.
  local function project(name)
    local pdf = make(name, pages(3, { color = { 1, 1, 1 } }))
    local tex = dir .. "/" .. name .. ".tex"
    local lines = {}
    for index = 1, 20 do
      lines[index] = "line " .. index
    end
    vim.fn.writefile(lines, tex)
    return vim.uv.fs_realpath(pdf), vim.uv.fs_realpath(tex)
  end

  local function session_of(path)
    for _, s in pairs(viewer.sessions) do
      if s.path == path then
        return s
      end
    end
  end

  it(
    "forward search shows where the cursor's line is typeset, in a split, and leaves the cursor in the source",
    function()
      setup({ synctex = fake })
      reset()
      os.remove(log)
      local original = vim.o.guicursor
      local pdf, tex = project("sync-forward")
      answer("view", {
        "SyncTeX result begin",
        "Output:" .. pdf,
        "Page:2",
        "x:72",
        "y:400",
        "h:72",
        "v:400",
        "W:300",
        "H:40",
        "SyncTeX result end",
      })
      vim.cmd.edit(vim.fn.fnameescape(tex))
      local source = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 12, 3 })
      vim.cmd("PdfViewForward")
      local s
      wait_for(function()
        s = session_of(pdf)
        return s ~= nil and s.synced ~= nil and s.page == 2 and s.job == nil and s.target == nil
      end, "the viewer on page 2")
      eq(("view -i 12:4:%s -o %s"):format(tex, pdf), logged()[1])
      eq(source, vim.api.nvim_get_current_win(), "the cursor stays in the source")
      eq(original, vim.o.guicursor, "the source's cursor is not hidden by the viewer opened beside it")
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      eq({ { 72, 360, 372, 400 } }, s.synced.rects)
      -- the typeset line is highlighted like the current search match
      eq("orange", classify(colour_at({ rects = s.synced.rects, width = 612, height = 792 })))

      -- a second search reuses the viewer on screen
      local first_id = s.synced.id
      vim.cmd("PdfViewForward")
      wait_for(function()
        return s.synced.id > first_id and s.job == nil and s.target == nil
      end, "the second search")
      eq(2, #vim.api.nvim_tabpage_list_wins(0))

      -- <Esc> in the viewer removes the highlight
      vim.api.nvim_set_current_win(vim.fn.bufwinid(s.buf))
      press(vim.keycode("<Esc>"))
      settle(s)
      eq(nil, s.synced)
      eq("white", classify(colour_at({ rects = { { 72, 360, 372, 400 } }, width = 612, height = 792 })))
      setup()
    end
  )

  it("forward search reuses the viewer on screen when the PDF is named through a symlink", function()
    setup({ synctex = fake })
    reset()
    local pdf, tex = project("sync-symlink")
    local link = dir .. "/sync-symlink-link.pdf"
    os.remove(link)
    assert(vim.uv.fs_symlink(pdf, link))
    answer("view", {
      "SyncTeX result begin",
      "Output:" .. pdf,
      "Page:2",
      "x:72",
      "y:400",
      "h:72",
      "v:400",
      "W:300",
      "H:40",
      "SyncTeX result end",
    })
    vim.cmd.edit(vim.fn.fnameescape(tex))
    local source = vim.api.nvim_get_current_win()
    vim.cmd("vertical rightbelow split")
    local s = open(pdf)
    vim.api.nvim_set_current_win(source)
    vim.cmd("PdfViewForward " .. vim.fn.fnameescape(link))
    wait_for(function()
      return s.synced ~= nil and s.page == 2 and s.job == nil and s.target == nil
    end, "the viewer on page 2")
    eq(2, #vim.api.nvim_tabpage_list_wins(0), "no other split opens")
    setup()
  end)

  it("forward search says so when the line is not in the SyncTeX data", function()
    setup({ synctex = fake })
    reset()
    local _, tex = project("sync-missing")
    answer("view", { "SyncTeX Warning: No tag for " .. tex })
    vim.cmd.edit(vim.fn.fnameescape(tex))
    local messages = {}
    with_stub(vim, "notify", function(message)
      messages[#messages + 1] = message
    end, function()
      vim.cmd("PdfViewForward")
      wait_for(function()
        return #messages > 0
      end, "the notification")
    end)
    truthy(messages[1]:find("sync-missing.tex:1 is not in the SyncTeX data of sync-missing.pdf", 1, true), messages[1])
    eq(1, #vim.api.nvim_tabpage_list_wins(0), "no viewer was opened")
    setup()
  end)

  it("inverse search opens the source at the line the point under the mouse was typeset from", function()
    setup({ synctex = fake })
    reset()
    os.remove(log)
    local pdf, tex = project("sync-inverse")
    answer("edit", {
      "SyncTeX result begin",
      "Output:" .. pdf,
      "Input:./sync-inverse.tex", -- relative to the PDF's directory
      "Line:7",
      "Column:-1",
      "SyncTeX result end",
    })
    local s = open(pdf)
    press("2G")
    on_page(s, 2)
    local win = vim.api.nvim_get_current_win()
    local fit = s.fit
    local row, col = fit.pad_top + math.floor(fit.rows / 2), fit.pad_left + math.floor(fit.cols / 2)
    with_stub(vim.fn, "getmousepos", function()
      -- the winbar is the window's first row
      return { winid = win, winrow = row + 2, wincol = col + 1 }
    end, function()
      press(vim.keycode("<2-LeftMouse>"))
      wait_for(function()
        return vim.api.nvim_buf_get_name(0) == tex
      end, "the source")
    end)
    eq(7, vim.api.nvim_win_get_cursor(0)[1])
    eq(2, #vim.api.nvim_tabpage_list_wins(0), "the source opens in a split next to the viewer")
    local page, x, y = logged()[1]:match("^edit %-o (%d+):([%d.]+):([%d.]+):" .. vim.pesc(pdf) .. "$")
    eq("2", page)
    harness.near(306, tonumber(x), 612 / fit.cols, "x")
    harness.near(396, tonumber(y), 792 / fit.rows, "y")
    setup()
  end)

  it("inverse search opens the source, not another file whose path ends with the source's", function()
    setup({ synctex = fake })
    reset()
    local pdf, tex = project("sync-elsewhere")
    answer("edit", {
      "SyncTeX result begin",
      "Output:" .. pdf,
      "Input:./sync-elsewhere.tex",
      "Line:7",
      "Column:-1",
      "SyncTeX result end",
    })
    -- bufnr(tex) takes this buffer for the source's
    local backup = dir .. "/backup" .. tex
    vim.fn.mkdir(vim.fs.dirname(backup), "p")
    vim.fn.writefile({ "backup" }, backup)
    vim.cmd.edit(vim.fn.fnameescape(backup))
    local backup_win = vim.api.nvim_get_current_win()
    vim.cmd("vertical rightbelow split")
    local s = open(pdf)
    local win = vim.api.nvim_get_current_win()
    local fit = s.fit
    local row, col = fit.pad_top + math.floor(fit.rows / 2), fit.pad_left + math.floor(fit.cols / 2)
    with_stub(vim.fn, "getmousepos", function()
      return { winid = win, winrow = row + 2, wincol = col + 1 }
    end, function()
      press(vim.keycode("<2-LeftMouse>"))
      wait_for(function()
        return vim.api.nvim_buf_get_name(0) == tex
      end, "the source")
    end)
    eq(7, vim.api.nvim_win_get_cursor(0)[1])
    eq(backup_win, vim.api.nvim_get_current_win(), "the source replaces the backup in the window before the viewer")
    setup()
  end)

  for _, case in ipairs({
    {
      what = "a sidebar",
      make = function()
        vim.cmd.enew()
        vim.bo.buftype = "nofile"
      end,
    },
    {
      what = "a 'winfixbuf' window",
      make = function(other)
        vim.cmd.edit(vim.fn.fnameescape(other))
        vim.wo.winfixbuf = true
      end,
    },
    {
      what = "a floating window",
      float = true,
      make = function(other)
        vim.cmd.badd(vim.fn.fnameescape(other))
        local buf = vim.fn.bufnr(other)
        vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
      end,
    },
  }) do
    it("inverse search leaves " .. case.what .. " before the viewer as it is, and opens a split", function()
      setup({ synctex = fake })
      reset()
      local pdf, tex = project("sync-special")
      answer("edit", {
        "SyncTeX result begin",
        "Output:" .. pdf,
        "Input:./sync-special.tex",
        "Line:7",
        "Column:-1",
        "SyncTeX result end",
      })
      local other = dir .. "/sync-special-other.txt"
      vim.fn.writefile({ "other" }, other)
      local s, win, before_win, before_buf
      if case.float then -- the viewer in the only window, and a floating window entered and left
        s = open(pdf)
        win = vim.api.nvim_get_current_win()
        case.make(other)
        before_win, before_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        vim.api.nvim_set_current_win(win)
      else
        case.make(other)
        before_win, before_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        vim.cmd("vertical rightbelow split")
        s = open(pdf)
        win = vim.api.nvim_get_current_win()
      end
      eq(before_win, vim.fn.win_getid(vim.fn.winnr("#")), "the previous window")
      local fit = s.fit
      local row, col = fit.pad_top + math.floor(fit.rows / 2), fit.pad_left + math.floor(fit.cols / 2)
      local errors = {}
      with_stub(vim, "notify", function(message, level)
        if level == vim.log.levels.ERROR then
          errors[#errors + 1] = message
        end
      end, function()
        with_stub(vim.fn, "getmousepos", function()
          return { winid = win, winrow = row + 2, wincol = col + 1 }
        end, function()
          press(vim.keycode("<2-LeftMouse>"))
          wait_for(function()
            return vim.api.nvim_buf_get_name(0) == tex
          end, "the source")
        end)
      end)
      eq(0, #errors, table.concat(errors, "\n"))
      eq(7, vim.api.nvim_win_get_cursor(0)[1])
      eq(before_buf, vim.api.nvim_win_get_buf(before_win), case.what .. " keeps its buffer")
      eq(3, #vim.api.nvim_tabpage_list_wins(0), "the source opens in a split")
      eq("", vim.api.nvim_win_get_config(0).relative, "the source is not in a floating window")
      setup()
    end)
  end
end)

describe("viewer spreads", function()
  -- a colour per page, to tell in the image which page is where
  local COLOURS = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 1, 0 }, { 0, 1, 1 } }
  local RGB = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 0 }, { 0, 255, 255 } }

  local function coloured(name, count)
    local list = {}
    for index = 1, count do
      list[index] = vim.tbl_extend("force", LETTER, { label = "Page " .. index, color = COLOURS[index] })
    end
    return make(name, list)
  end

  --- The colours of the latest image at a quarter and three quarters of its width, half way down.
  local function halves()
    local paths = transmitted()
    local png = paths[#paths]
    local width, height = fixture.png_size(png)
    local y = math.floor(height * 0.75)
    return fixture.pixels(png, { { math.floor(width / 4), y }, { math.floor(width * 3 / 4), y } })
  end

  it("shows facing pages side by side and turns them two at a time", function()
    setup({ spread = "on" })
    reset()
    local s = open(coloured("spread", 5))
    settle(s)
    eq(1, s.page)
    eq(2, s.last)
    eq({ RGB[1], RGB[2] }, halves())
    local png = transmitted()[#transmitted()]
    local png_w, png_h = fixture.png_size(png)
    eq(
      { { 192, 192, 192 } },
      fixture.pixels(png, { { math.floor(png_w / 2), math.floor(png_h / 2) } }),
      "grey between them"
    )
    truthy(vim.wo.winbar:find("1-2 / 5", 1, true), vim.wo.winbar)
    eq("1-2 / 5", pdf_view.status())
    local width, height = fixture.png_size(transmitted()[#transmitted()])
    truthy(width > height, ("two pages are wider than tall: %dx%d"):format(width, height))

    press("j")
    on_page(s, 3)
    eq(4, s.last)
    eq({ RGB[3], RGB[4] }, halves())
    press("j")
    on_page(s, 5)
    eq(5, s.last, "the last page of an odd count is alone")
    press("k")
    on_page(s, 3)
    press("2gg") -- the spread that holds page 2
    on_page(s, 1)
    eq(2, s.last)

    -- `d` shows one page at a time again, and side by side again
    press("d")
    on_page(s, 1)
    eq(1, s.last)
    press("j")
    on_page(s, 2)
    press("d")
    on_page(s, 1)
    eq(2, s.last)
    setup()
  end)

  it("shows the first page alone with cover, then pages 2 and 3", function()
    setup({ spread = "cover" })
    reset()
    local s = open(coloured("spread-cover", 4))
    settle(s)
    eq(1, s.last)
    press("j")
    on_page(s, 2)
    eq(3, s.last)
    eq({ RGB[2], RGB[3] }, halves())
    setup()
  end)

  it("turns spreads on with d, and finds matches on either page", function()
    reset()
    local s = open(coloured("spread-search", 4))
    press("d")
    on_page(s, 1)
    eq(2, s.last)
    answering("Page 4", function()
      press("/")
      searched(s)
    end)
    eq(3, s.page, "the spread that holds the match")
    eq(4, s.last)
    eq({ RGB[3], RGB[4] }, halves(), "both pages, the match on the right one")

    -- the text and the links of both pages
    vim.fn.setreg('"', "")
    with_stub(vim, "notify", function() end, function()
      press("y")
      wait_for(function()
        return vim.fn.getreg('"') ~= ""
      end, "the yank")
    end)
    eq({ "Page 3", "", "Page 4" }, vim.fn.getreg('"', 1, true))
  end)

  it("zooms into a spread and scrolls across both pages", function()
    setup({ spread = "on" })
    reset()
    local s = open(coloured("spread-zoom", 2))
    settle(s)
    press("w") -- the spread as wide as the window
    settle(s)
    eq(1, s.page)
    eq(2, s.last)
    press("4+")
    settle(s)
    local steps = 0
    while s.cx < 0.9 and steps < 40 do
      press("l")
      settle(s)
      steps = steps + 1
    end
    eq(1, s.page, "scrolling right stays on the spread")
    local colours = halves()
    eq(RGB[2], colours[2], "the right page")
    setup()
  end)
end)

describe("viewer continuous scrolling", function()
  local COLOURS = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
  local RGB = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 } }

  local function coloured(name)
    local list = {}
    for index = 1, 3 do
      list[index] = vim.tbl_extend("force", LETTER, { label = "", color = COLOURS[index] })
    end
    return make(name, list)
  end

  --- The colours of the image on screen near its top and its bottom edge, half way across.
  local function ends(s)
    local png = s.images[s.ids[s.slot]]
    local width, height = fixture.png_size(png)
    local x = math.floor(width / 2)
    return fixture.pixels(png, { { x, 2 }, { x, height - 3 } })
  end

  --- Press `key` until `done()`, at most `limit` times.
  local function until_done(s, key, done, limit)
    for _ = 1, limit do
      if done() then
        return
      end
      press(key)
      settle(s)
    end
    truthy(done(), "pressed " .. key .. " " .. limit .. " times")
  end

  it("scrolls from the end of a page into the next, with both on screen", function()
    setup({ continuous = true })
    reset()
    local s = open(coloured("continuous"))
    press("w")
    settle(s)
    until_done(s, "j", function()
      local colours = ends(s)
      return s.page == 1 and vim.deep_equal(colours, { RGB[1], RGB[2] })
    end, 20)
    eq(1, s.page, "the page at the top of the window")

    -- on into page 2, and back up the same way
    local cy = s.cy
    until_done(s, "j", function()
      return s.page == 2
    end, 20)
    local steps = 0
    until_done(s, "k", function()
      steps = steps + 1
      return s.page == 1
    end, 20)
    truthy(math.abs(s.cy - cy) < 1, "back on page 1, cy = " .. s.cy)

    -- the end of the document stops it: the last page's bottom at the bottom of the window
    press("G")
    settle(s)
    eq(3, s.page)
    eq(nil, s.scrolled, "a jump keeps the view inside the page")
    eq({ RGB[3], RGB[3] }, ends(s), "the top of the page, alone")
    until_done(s, "j", function()
      local before = s.cy
      press("j")
      settle(s)
      return s.cy == before
    end, 20)
    eq(3, s.page)
    eq({ RGB[3], RGB[3] }, ends(s))

    -- and the start of the document
    press("gg")
    settle(s)
    press("k")
    settle(s)
    eq(1, s.page)
    eq({ RGB[1], RGB[1] }, ends(s))
    setup()
  end)

  it("turns pages that fit the window, as without it", function()
    setup({ continuous = true })
    reset()
    local s = open(coloured("continuous-page"))
    press("j")
    on_page(s, 2)
    eq(nil, s.scrolled)
    setup()
  end)
end)
