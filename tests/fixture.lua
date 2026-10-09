--- Generates small valid PDFs for tests.
local M = {}

---@class PdfView.FixturePage
---@field w integer width in points
---@field h integer height in points
---@field label? string text drawn on the page
---@field texts? { x: number, y: number, text: string }[] more text, positioned from the bottom-left corner in points
---@field color? number[] background {r, g, b} in 0..1
---@field rotate? integer /Rotate in degrees (a multiple of 90)

---@class PdfView.FixtureOutline
---@field title string
---@field page integer 1-based
---@field children? PdfView.FixtureOutline[]

--- Write a PDF with one page per entry of `pages` (a proper xref table, so no repair warnings).
---@param path string
---@param pages PdfView.FixturePage[]
---@param opts? { outline?: PdfView.FixtureOutline[] } bookmarks to add
function M.write(path, pages, opts)
  opts = opts or {}
  local objects = {}
  local function add(body)
    objects[#objects + 1] = body
    return #objects
  end

  add("") -- /Catalog, filled in below once the outline exists
  add("") -- /Pages, filled in below once the page objects exist
  add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

  local page_objects = {}
  local kids = {}
  for index, page in ipairs(pages) do
    local color = page.color or { 0.9, 0.9, 1 }
    local content = ("%g %g %g rg 0 0 %d %d re f 0 g BT /F1 36 Tf 30 %d Td (%s) Tj ET"):format(
      color[1],
      color[2],
      color[3],
      page.w,
      page.h,
      page.h / 2,
      page.label or ("Page " .. index)
    )
    for _, extra in ipairs(page.texts or {}) do
      content = content .. (" BT /F1 36 Tf %d %d Td (%s) Tj ET"):format(extra.x, extra.y, extra.text)
    end
    local contents = add(("<< /Length %d >>\nstream\n%s\nendstream"):format(#content, content))
    local object = add(
      (
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Rotate %d /Contents %d 0 R "
        .. "/Resources << /Font << /F1 3 0 R >> >> >>"
      ):format(page.w, page.h, page.rotate or 0, contents)
    )
    page_objects[index] = object
    kids[#kids + 1] = object .. " 0 R"
  end
  objects[2] = ("<< /Type /Pages /Kids [%s] /Count %d >>"):format(table.concat(kids, " "), #pages)

  local catalog = "<< /Type /Catalog /Pages 2 0 R >>"
  if opts.outline then
    --- Emit the sibling list `items` under object `parent`; returns first, last and the number of items below.
    local function build(items, parent)
      local numbers = {}
      for index = 1, #items do
        numbers[index] = add("")
      end
      local total = #items
      for index, item in ipairs(items) do
        local fields = {
          ("/Title (%s)"):format(item.title),
          ("/Parent %d 0 R"):format(parent),
          ("/Dest [%d 0 R /Fit]"):format(page_objects[item.page]),
        }
        if index > 1 then
          fields[#fields + 1] = ("/Prev %d 0 R"):format(numbers[index - 1])
        end
        if index < #items then
          fields[#fields + 1] = ("/Next %d 0 R"):format(numbers[index + 1])
        end
        if item.children then
          local first, last, below = build(item.children, numbers[index])
          fields[#fields + 1] = ("/First %d 0 R /Last %d 0 R /Count %d"):format(first, last, below)
          total = total + below
        end
        objects[numbers[index]] = "<< " .. table.concat(fields, " ") .. " >>"
      end
      return numbers[1], numbers[#numbers], total
    end

    local root = add("")
    local first, last, count = build(opts.outline, root)
    objects[root] = ("<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>"):format(first, last, count)
    catalog = ("<< /Type /Catalog /Pages 2 0 R /Outlines %d 0 R >>"):format(root)
  end
  objects[1] = catalog

  local out = { "%PDF-1.4\n" }
  local offsets = {}
  local size = #out[1]
  for index, body in ipairs(objects) do
    offsets[index] = size
    local text = ("%d 0 obj\n%s\nendobj\n"):format(index, body)
    out[#out + 1] = text
    size = size + #text
  end
  out[#out + 1] = ("xref\n0 %d\n0000000000 65535 f \n"):format(#objects + 1)
  for _, offset in ipairs(offsets) do
    out[#out + 1] = ("%010d 00000 n \n"):format(offset)
  end
  out[#out + 1] = ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"):format(#objects + 1, size)

  local file = assert(io.open(path, "wb"))
  file:write(table.concat(out))
  file:close()
end

--- Pixel size of a PNG file, read from its IHDR chunk.
---@param path string
---@return integer width, integer height
function M.png_size(path)
  local file = assert(io.open(path, "rb"))
  local header = file:read(24)
  file:close()
  local function u32(offset)
    local a, b, c, d = header:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

--- RGB values of pixels in a PNG, read with mutool.
---@param path string
---@param points integer[][] list of `{ x, y }`
---@return integer[][] list of `{ r, g, b }`
function M.pixels(path, points)
  local script = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "pixels.js")
  local cmd = { "mutool", "run", script, path }
  for _, point in ipairs(points) do
    vim.list_extend(cmd, { tostring(point[1]), tostring(point[2]) })
  end
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  local colours = {}
  for r, g, b in result.stdout:gmatch("(%d+) (%d+) (%d+)") do
    colours[#colours + 1] = { tonumber(r), tonumber(g), tonumber(b) }
  end
  return colours
end

--- A fresh directory for one test.
---@return string
function M.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

return M
