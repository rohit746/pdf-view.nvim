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
