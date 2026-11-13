local harness = require("tests.harness")
local eq, truthy = harness.eq, harness.truthy
local positions = require("pdf-view.positions")

describe("positions", function()
  local saved = positions.file
  local function use(name)
    positions.file = vim.fn.tempname() .. "/" .. name .. ".json"
  end

  it("reads back what was stored for a path", function()
    use("roundtrip")
    eq(nil, positions.get("/a.pdf"))
    positions.set("/a.pdf", { page = 7, mode = "width", zoom = 1.5625, cx = 0.25, cy = 0.75 })
    eq({ page = 7, mode = "width", zoom = 1.5625, cx = 0.25, cy = 0.75 }, positions.get("/a.pdf"))
    eq(nil, positions.get("/b.pdf"))
  end)

  it("keeps the layout of an e-book, and drops a malformed one", function()
    use("layout")
    positions.set("/a.fb2", { page = 25, mode = "page", zoom = 1, cx = 0.5, cy = 0.5, layout = { 400, 600.5, 12 } })
    eq({ 400, 600.5, 12 }, positions.get("/a.fb2").layout)
    positions.set("/b.fb2", { page = 3, mode = "page", zoom = 1, cx = 0.5, cy = 0.5, layout = { 400, "x", 12 } })
    eq({ 3, nil }, { positions.get("/b.fb2").page, positions.get("/b.fb2").layout })
    positions.set("/c.fb2", { page = 3, mode = "page", zoom = 1, cx = 0.5, cy = 0.5, layout = { 400, 0, 12 } })
    eq(nil, positions.get("/c.fb2").layout)
  end)

  it("keeps a content fit", function()
    use("content")
    positions.set("/a.pdf", { page = 2, mode = "content", zoom = 1, cx = 0.5, cy = 0 })
    eq("content", positions.get("/a.pdf").mode)
  end)

  it("keeps only the 100 most recently stored files", function()
    use("limit")
    local entries = {}
    for index = 1, 100 do
      entries["/old" .. index .. ".pdf"] = { page = index, mode = "page", zoom = 1, cx = 0.5, cy = 0.5, time = index }
    end
    vim.fn.mkdir(vim.fs.dirname(positions.file), "p")
    vim.fn.writefile({ vim.json.encode(entries) }, positions.file)
    positions.set("/new.pdf", { page = 2, mode = "page", zoom = 1, cx = 0.5, cy = 0.5 })
    local stored = vim.json.decode(table.concat(vim.fn.readfile(positions.file), "\n"))
    eq(100, vim.tbl_count(stored))
    eq(nil, stored["/old1.pdf"], "the oldest entry is dropped")
    truthy(stored["/old2.pdf"])
    eq(2, positions.get("/new.pdf").page)
  end)

  it("does not call an entry less than itself when breaking a tie", function()
    use("self-compare")
    -- more than LIMIT entries, all stored in the same second, so every comparison
    -- is a tie and the entry just written is one side of it
    local entries = {}
    local now = os.time()
    for index = 1, 100 do
      entries["/old" .. index .. ".pdf"] = { page = index, mode = "page", zoom = 1, cx = 0.5, cy = 0.5, time = now }
    end
    vim.fn.mkdir(vim.fs.dirname(positions.file), "p")
    vim.fn.writefile({ vim.json.encode(entries) }, positions.file)

    local sort = table.sort
    local comparator
    table.sort = function(list, compare)
      comparator = comparator or compare
      return sort(list, compare)
    end
    local ok, err = pcall(positions.set, "/new.pdf", { page = 2, mode = "page", zoom = 1, cx = 0.5, cy = 0.5 })
    table.sort = sort

    assert(ok, err)
    truthy(comparator, "set() should have sorted the entries")
    eq(false, comparator("/new.pdf", "/new.pdf"), "the entry just written must not compare less than itself")
  end)

  it("ignores a corrupt file and malformed entries", function()
    use("corrupt")
    vim.fn.mkdir(vim.fs.dirname(positions.file), "p")
    vim.fn.writefile({ "{not json" }, positions.file)
    eq(nil, positions.get("/a.pdf"))
    positions.set("/a.pdf", { page = 3, mode = "page", zoom = 1, cx = 0.5, cy = 0.5 })
    eq(3, positions.get("/a.pdf").page)
    vim.fn.writefile({ vim.json.encode({ ["/a.pdf"] = { page = "x", mode = "page" } }) }, positions.file)
    eq(nil, positions.get("/a.pdf"))
  end)

  positions.file = saved
end)
