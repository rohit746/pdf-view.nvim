--- Thin async wrapper around the `mutool` command line.
local config = require("pdf-view.config")

local M = {}

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local PAGE_INFO = vim.fs.joinpath(ROOT, "scripts", "page-info.js")
local RENDER_CLIP = vim.fs.joinpath(ROOT, "scripts", "render-clip.js")
local SEARCH = vim.fs.joinpath(ROOT, "scripts", "search.js")
local OUTLINE = vim.fs.joinpath(ROOT, "scripts", "outline.js")

local MAX_PAGE = 2 ^ 31 - 1

--- Points of paper kept around the content of a page, so that fitting the content does not put text against the
--- edge of the window.
local CONTENT_MARGIN = 8

---@class PdfView.Job
---@field kill fun(self: PdfView.Job, signal?: integer)

---@class PdfView.PageInfo
---@field count integer pages in the document
---@field page integer the requested page, clamped to the document
---@field width number page width in points
---@field height number page height in points
---@field content? number[] `{ x0, y0, x1, y1 }`: the part of the page with something drawn on it, in points from the
--- page's top-left corner, with a margin of `CONTENT_MARGIN` (the whole page when it is blank). Only read when asked for

--- The line of mutool's stderr that says why it failed: the last error, or else the last line. mutool ends with a
--- summary such as "cannot draw 'file.pdf'" that does not say why, and a script's exception is followed by its stack.
---@param stderr? string
---@return string
local function reason(stderr)
  local last, last_error
  for line in (stderr or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then
      last = line
      if line:match("^%a* ?[Ee]rror: ") then
        last_error = line
      end
    end
  end
  local message = (last_error or last or "mutool failed"):gsub("^%a* ?[Ee]rror: ", "")
  return message
end

--- Why a finished process counts as failed, or nil when it succeeded. A killed process is a failure too:
--- `vim.system` reports it with exit code 0, and whatever it printed up to then is incomplete.
---@param result vim.SystemCompleted
---@return string?
local function failure(result)
  if result.code ~= 0 then
    return reason(result.stderr)
  end
  if result.signal ~= 0 then
    return ("mutool was killed (signal %d)"):format(result.signal)
  end
end

--- Run a command asynchronously. Calls `cb` on the main loop, even when the process cannot be started.
---@param cmd string[]
---@param cb fun(result: vim.SystemCompleted)
---@return PdfView.Job
local function run(cmd, cb)
  local started, job = pcall(vim.system, cmd, { text = true }, vim.schedule_wrap(cb))
  if started then
    return job
  end
  vim.schedule(function()
    cb({ code = -1, signal = 0, stdout = "", stderr = ("cannot run `%s`: %s"):format(cmd[1], job) })
  end)
  return { kill = function() end }
end

--- Completion handler shared by the renderers: an error, or success once a non-empty PNG exists.
---@param out string
---@param cb fun(err?: string, notes?: string) `notes` is what the script printed, e.g. "highlights: multiply"
---@return fun(result: vim.SystemCompleted)
local function rendered(out, cb)
  return function(result)
    local err = failure(result)
    if err then
      return cb(err)
    end
    local stat = vim.uv.fs_stat(out)
    if not stat or stat.size == 0 then
      return cb("mutool did not produce an image")
    end
    cb(nil, vim.trim(result.stdout or ""))
  end
end

--- Page count and geometry of one page.
---@param path string
---@param page integer 1-based; clamped to the document
---@param cb fun(err?: string, info?: PdfView.PageInfo)
---@param content? boolean also find the part of the page that has content (`info.content`), which renders the page
---@return PdfView.Job
function M.info(path, page, cb, content)
  local cmd = { config.options.mutool, "run", PAGE_INFO, path, ("%d"):format(math.min(math.max(page, 1), MAX_PAGE)) }
  if content then
    cmd[#cmd + 1] = "content"
  end
  return run(cmd, function(result)
    local err = failure(result)
    if err then
      return cb(err)
    end
    local fields = vim.split(vim.trim(result.stdout or ""), "%s+")
    local count, resolved, width, height =
      tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
    if not count or count < 1 or not resolved or not width or not height or width <= 0 or height <= 0 then
      return cb("could not read the page geometry (is mutool built with JavaScript support?)")
    end
    local info = { count = count, page = resolved, width = width, height = height }
    if content then
      local x0, y0, x1, y1 = tonumber(fields[5]), tonumber(fields[6]), tonumber(fields[7]), tonumber(fields[8])
      if not (x0 and y0 and x1 and y1 and x1 > x0 and y1 > y0) then
        x0, y0, x1, y1 = 0, 0, width, height
      end
      info.content = {
        math.max(0, x0 - CONTENT_MARGIN),
        math.max(0, y0 - CONTENT_MARGIN),
        math.min(width, x1 + CONTENT_MARGIN),
        math.min(height, y1 + CONTENT_MARGIN),
      }
    end
    cb(nil, info)
  end)
end

--- Render one page to a PNG of exactly `width` x `height` pixels.
---@param path string
---@param page integer
---@param width integer
---@param height integer
---@param out string destination PNG
---@param cb fun(err?: string)
---@return PdfView.Job
function M.render(path, page, width, height, out, cb)
  local cmd = {
    config.options.mutool,
    "draw",
    "-q",
    "-o",
    out,
    "-w",
    ("%d"):format(width),
    "-h",
    ("%d"):format(height),
    "-f",
    path,
    ("%d"):format(page),
  }
  return run(cmd, rendered(out, cb))
end

---@class PdfView.Clip
---@field scale_x number device pixels per point, horizontally
---@field scale_y number device pixels per point, vertically (equal to `scale_x` unless a page is stretched to cells)
---@field x integer left edge of the rectangle, in device pixels from the page's top-left corner
---@field y integer top edge
---@field width integer
---@field height integer
---@field highlights? string rectangles to multiply onto the page, as built by `search.highlights()`

--- Render a rectangle of a page to a PNG of exactly `clip.width` x `clip.height` pixels. Only that rectangle is
--- rasterised, so the cost does not grow with the zoom level.
---@param path string
---@param page integer
---@param clip PdfView.Clip
---@param out string destination PNG
---@param cb fun(err?: string, notes?: string) `notes` says how highlights were drawn: "highlights: multiply" or "highlights: translucent"
---@return PdfView.Job
function M.render_clip(path, page, clip, out, cb)
  local cmd = {
    config.options.mutool,
    "run",
    RENDER_CLIP,
    path,
    ("%d"):format(page),
    ("%.6f"):format(clip.scale_x),
    ("%.6f"):format(clip.scale_y),
    ("%d"):format(clip.x),
    ("%d"):format(clip.y),
    ("%d"):format(clip.width),
    ("%d"):format(clip.height),
    out,
  }
  if clip.highlights and clip.highlights ~= "" then
    cmd[#cmd + 1] = clip.highlights
  end
  return run(cmd, rendered(out, cb))
end

--- Find every occurrence of `needle` in the document (ignoring case).
---@param path string
---@param needle string
---@param limit integer stop after this many matches
---@param cb fun(err?: string, matches?: PdfView.Match[], truncated?: boolean)
---@return PdfView.Job
function M.search(path, needle, limit, cb)
  local cmd = { config.options.mutool, "run", SEARCH, path, needle, ("%d"):format(limit) }
  return run(cmd, function(result)
    local err = failure(result)
    if err then
      return cb(err)
    end
    local matches, truncated = require("pdf-view.search").parse(result.stdout)
    cb(nil, matches, truncated)
  end)
end

---@class PdfView.OutlineEntry
---@field depth integer 0 for top-level entries
---@field page integer 1-based
---@field title string

--- Parse the output of `scripts/outline.js`.
---@param stdout string
---@return PdfView.OutlineEntry[]
function M.parse_outline(stdout)
  local entries = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local depth, page, title = line:match("^(%d+)\t(%d+)\t(.*)$")
    if depth then
      entries[#entries + 1] = { depth = tonumber(depth), page = tonumber(page), title = vim.trim(title) }
    end
  end
  return entries
end

--- The document's outline (bookmarks), empty when it has none.
---@param path string
---@param cb fun(err?: string, entries?: PdfView.OutlineEntry[])
---@return PdfView.Job
function M.outline(path, cb)
  return run({ config.options.mutool, "run", OUTLINE, path }, function(result)
    local err = failure(result)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_outline(result.stdout))
  end)
end

return M
