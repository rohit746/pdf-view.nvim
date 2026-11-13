local harness = require("tests.harness")
local eq, truthy, wait_for = harness.eq, harness.truthy, harness.wait_for
local actions = require("pdf-view.actions")
local config = require("pdf-view.config")
local fixture = require("tests.fixture")
local kitty = require("pdf-view.kitty")
local terminal = require("pdf-view.terminal")
local viewer = require("pdf-view.viewer")
local pdf_view = require("pdf-view")

describe("api", function()
  it("has a <Plug> mapping for every action, so actions added later have one too", function()
    eq(actions.names(), config.actions(), "every action has a `keymaps` entry")
    pdf_view._init()
    for _, name in ipairs(actions.names()) do
      truthy(vim.fn.maparg(("<Plug>(pdf-view-%s)"):format(name), "n") ~= "", "no <Plug> mapping for " .. name)
    end
  end)

  it("reads the count of every action through action_count(), never v:count", function()
    -- `action({ count = 3 })` cannot set v:count: an action that read it would ignore the count it is given
    local source = vim.fn.readfile(vim.api.nvim_get_runtime_file("lua/pdf-view/actions.lua", false)[1])
    local readers = {}
    for _, line in ipairs(source) do
      if line:find("vim%.v%.count") and not line:find("^%s*%-%-") then
        readers[#readers + 1] = vim.trim(line)
      end
    end
    eq({ "return given_count or vim.v.count" }, readers)
  end)

  it("rejects an unknown action and bad arguments", function()
    for _, call in ipairs({
      function()
        pdf_view.action("nope")
      end,
      function()
        pdf_view.action("next", { count = -1 })
      end,
      function()
        pdf_view.goto_page(1.5)
      end,
      function()
        pdf_view.set_zoom("2")
      end,
      function()
        pdf_view.set_fit("wide")
      end,
      function()
        pdf_view.search("")
      end,
    }) do
      local ok, err = pcall(call)
      eq(false, ok)
      truthy(tostring(err):find("pdf-view:", 1, true), tostring(err))
    end
  end)
end)

if vim.fn.executable("mutool") ~= 1 then
  io.stdout:write("  skip  api viewers (mutool not installed)\n")
  return
end

-- as in viewer_spec.lua: no TUI, so pretend one is attached (to kitty) and drop what would be written to it; put back
-- at the end for the specs that run after this one
local real = { ui_attached = terminal.ui_attached, write = kitty.write, detect = terminal.detect }
terminal.ui_attached = function()
  return true
end
kitty.write = function() end
terminal.detect = function()
  return { name = "kitty", term = "xterm-kitty", placeholders = true }
end
local env = { TMUX = vim.env.TMUX, ZELLIJ = vim.env.ZELLIJ }
vim.env.TMUX, vim.env.ZELLIJ = nil, nil

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
end

local function make(name, count)
  local path = dir .. "/" .. name .. ".pdf"
  local pages = {}
  for index = 1, count do
    pages[index] = { w = 612, h = 792, label = ("Page %d of %s"):format(index, name) }
  end
  fixture.write(path, pages)
  return path
end

---@return PdfView.Session
local function open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local s = viewer.sessions[vim.api.nvim_get_current_buf()]
  truthy(s, "no viewer session for " .. path)
  wait_for(function()
    return s.slot ~= 0
  end, "first render")
  return s
end

local function on_page(s, page)
  wait_for(function()
    return s.page == page and s.target == nil and s.job == nil
  end, "page " .. page)
end

local function settle(s)
  wait_for(function()
    return s.job == nil and s.target == nil and s.search_job == nil
  end, "the render to settle")
end

describe("api viewers", function()
  setup()

  it("runs an action with a count, in the viewer of another buffer too", function()
    reset()
    local s = open(make("action", 6))
    eq(true, pdf_view.action("next", { count = 2 }))
    on_page(s, 3)
    eq(true, pdf_view.action("prev"))
    on_page(s, 2)
    eq(true, pdf_view.action("last", { count = 5 }), "page {count}")
    on_page(s, 5)
    eq(true, pdf_view.action("jump_back"))
    on_page(s, 2)

    vim.cmd("new") -- another buffer is current; the viewer is in the window below
    local scratch = vim.api.nvim_get_current_buf()
    eq(true, pdf_view.action("first", { buf = s.buf }))
    on_page(s, 1)
    eq(scratch, vim.api.nvim_get_current_buf(), "the current window stays where it was")
    eq(true, pdf_view.action("scroll_down", { buf = s.buf }), "the wheel's actions move the viewer given")
    on_page(s, 2)

    local warned
    local notify = vim.notify
    vim.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
      warned = message
    end
    local ok = pdf_view.action("next")
    vim.notify = notify
    eq(false, ok, "the current buffer is no viewer")
    truthy(warned and warned:find("not a PDF viewer", 1, true), warned)
    eq(2, s.page)

    eq(true, pdf_view.action("close", { buf = s.buf }))
    eq(false, vim.api.nvim_buf_is_valid(s.buf), "closed from another window")
    eq(scratch, vim.api.nvim_get_current_buf())
  end)

  it("goes to a page, zooms, fits and searches with arguments, and tells where it is", function()
    reset()
    local path = make("args", 5)
    local s = open(path)
    eq(
      { buf = s.buf, path = s.path, page = 1, last = 1, count = 5, fit = "page", zoom = 1 },
      pdf_view.get(),
      "a fresh viewer"
    )
    eq(nil, pdf_view.get(vim.api.nvim_create_buf(false, true)), "not a viewer")

    eq(true, pdf_view.goto_page(4))
    eq(4, pdf_view.get().page, "the page it is going to, before it is on screen")
    on_page(s, 4)
    pdf_view.goto_page(99)
    on_page(s, 5)
    pdf_view.action("jump_back")
    on_page(s, 4)

    pdf_view.set_zoom(2)
    settle(s)
    eq({ "page", 2 }, { pdf_view.get().fit, pdf_view.get().zoom })
    pdf_view.set_zoom(100)
    settle(s)
    eq(config.options.max_zoom, s.zoom)
    pdf_view.set_fit("width")
    settle(s)
    eq({ "width", 1 }, { pdf_view.get().fit, pdf_view.get().zoom })

    eq(true, pdf_view.search("Page 2 of args"))
    settle(s)
    on_page(s, 2)
    eq(1, #s.search.matches)
    eq("Page 2 of args", s.last_needle, "an empty / searches for it again")
    pdf_view.goto_page(4)
    on_page(s, 4)
    pdf_view.search("of args", { backward = true })
    settle(s)
    on_page(s, 4) -- the match on the page, going backward
    eq(5, #s.search.matches)
    pdf_view.action("search_next", { count = 2 }) -- in the direction of the search: two matches back
    settle(s)
    on_page(s, 2)
  end)

  it("drives a viewer with keymaps = false through <Plug> mappings, with their count", function()
    reset()
    setup({ keymaps = false })
    local id = vim.api.nvim_create_autocmd("FileType", { -- as the README does it
      pattern = "pdf-view",
      callback = function(args)
        vim.keymap.set("n", "J", "<Plug>(pdf-view-next)", { buffer = args.buf })
      end,
    })
    local s = open(make("plug", 6))
    vim.api.nvim_del_autocmd(id)
    eq("", vim.fn.maparg("<PageDown>", "n"), "no keys of the plugin")
    vim.api.nvim_feedkeys("J", "x", false)
    on_page(s, 2)
    vim.api.nvim_feedkeys("3J", "x", false)
    on_page(s, 5)
    vim.keymap.set("n", "K", function()
      pdf_view.action("prev")
    end, { buffer = s.buf })
    vim.api.nvim_feedkeys("2K", "x", false)
    on_page(s, 3)
    setup()
  end)

  it("tells User PdfViewPage autocommands when another page is on screen", function()
    reset()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "PdfViewPage",
      callback = function(args)
        seen[#seen + 1] = args.data
      end,
    })
    local s = open(make("event", 4))
    wait_for(function()
      return #seen == 1
    end, "the first page")
    eq({ buf = s.buf, page = 1, last = 1, count = 4 }, seen[1])
    pdf_view.goto_page(3)
    on_page(s, 3)
    wait_for(function()
      return #seen == 2
    end, "page 3")
    eq({ buf = s.buf, page = 3, last = 3, count = 4 }, seen[2])
    pdf_view.set_zoom(2) -- the same page, drawn again
    settle(s)
    vim.wait(50)
    eq(2, #seen, "no autocommand for the page that was on screen already")
    vim.api.nvim_del_autocmd(id)
  end)

  reset()
  terminal.ui_attached, kitty.write, terminal.detect = real.ui_attached, real.write, real.detect
  vim.env.TMUX, vim.env.ZELLIJ = env.TMUX, env.ZELLIJ
end)
