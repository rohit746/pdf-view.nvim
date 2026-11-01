--- Thin async wrapper around the `mutool` command line. Page geometry, rendering, page text and links go to a worker
--- per document (`scripts/worker.js`), which keeps the document open between requests; search and the outline run a
--- script each.
local config = require("pdf-view.config")

local M = {}

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local WORKER = vim.fs.joinpath(ROOT, "scripts", "worker.js")
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
---@field reflowable boolean the document is laid out to a page size (EPUB, FB2, MOBI), so its pages follow the layout
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
---@param stdin? string written to the command's standard input
---@return PdfView.Job
local function run(cmd, cb, stdin)
  local started, job = pcall(vim.system, cmd, { text = true, stdin = stdin }, vim.schedule_wrap(cb))
  if started then
    return job
  end
  vim.schedule(function()
    cb({ code = -1, signal = 0, stdout = "", stderr = ("cannot run `%s`: %s"):format(cmd[1], job) })
  end)
  return { kill = function() end }
end

---@class PdfView.Request
---@field id integer
---@field lines string[] the request as `worker.js` reads it
---@field cb fun(err?: string, result?: string)
---@field done? boolean

---@class PdfView.WorkerProcess
---@field system? vim.SystemObj
---@field current? PdfView.Request the request it is working on
---@field stdout string what it printed that is not a whole line yet
---@field stderr string the end of what it printed on stderr, for the reason it failed
---@field gone? boolean stopped on purpose: what it still says is not listened to

---@class PdfView.Worker
---@field path string
---@field stamp? string the file as of when the running process opened it
---@field exe? string the mutool it runs
---@field queue PdfView.Request[] requests waiting for the process
---@field process? PdfView.WorkerProcess

--- One worker per document: a `mutool run worker.js` that keeps the document open between requests.
---@type table<string, PdfView.Worker>
local workers = {}

---@alias PdfView.Layout number[] `{ width, height, em }`: the page size in points and the text size a reflowable
--- document is laid out with

--- The layout of each document, as set by `set_layout()`: every request about the document carries it.
---@type table<string, PdfView.Layout>
local layouts = {}
--- The password of each password-protected document, as set by `set_password()`, for the rest of the Neovim
--- session. It reaches mutool on standard input, never as an argument, where `ps` would show it.
---@type table<string, string>
local passwords = {}
local next_request = 0

-- longest line `worker.js` is sent: its readline() reads at most 255 bytes
local LINE = 200
-- what is kept of a worker's stderr
local STDERR_LIMIT = 4096

---@param path string
---@return string
local function file_stamp(path)
  local stat = vim.uv.fs_stat(path)
  return stat and ("%d.%09d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or ""
end

--- A request as lines of at most `LINE` bytes, cut between characters: "+" starts every line but the last, ":" the
--- last.
---@param request any[]
---@return string[]
local function encode(request)
  local json = vim.json.encode(request)
  local lines, position = {}, 1
  while true do
    local stop = position + LINE - 1
    if stop >= #json then
      lines[#lines + 1] = ":" .. json:sub(position) .. "\n"
      return lines
    end
    while stop > position and json:byte(stop + 1) >= 0x80 and json:byte(stop + 1) < 0xC0 do
      stop = stop - 1 -- the next byte continues a character
    end
    lines[#lines + 1] = "+" .. json:sub(position, stop) .. "\n"
    position = stop + 1
  end
end

---@param request PdfView.Request
---@param err? string
---@param result? string
local function finish(request, err, result)
  if request.done then
    return
  end
  request.done = true
  request.cb(err, result)
end

local pump

---@param w PdfView.Worker
---@param process PdfView.WorkerProcess
---@param line string
local function on_answer(w, process, line)
  local request = process.current
  local id, status, rest = line:match("^@(%d+) (%a+) ?(.*)$")
  if process.gone or not request or tonumber(id) ~= request.id then
    return
  end
  process.current = nil
  if status == "ok" then
    finish(request, nil, rest)
  else
    finish(request, (rest:gsub("^%a* ?[Ee]rror: ", "")))
  end
  pump(w)
end

---@param w PdfView.Worker
---@param process PdfView.WorkerProcess
---@param result vim.SystemCompleted
local function on_exit(w, process, result)
  if w.process == process then
    w.process = nil
  end
  if process.gone then
    return
  end
  process.gone = true
  local request = process.current
  process.current = nil
  if request then
    local why = result.signal ~= 0 and ("mutool was killed (signal %d)"):format(result.signal) or nil
    finish(request, process.stderr:match("%S") and reason(process.stderr) or why or "mutool exited")
  end
  pump(w)
end

--- Start the process of `w`.
---@param w PdfView.Worker
---@return PdfView.WorkerProcess? process
---@return string? err why it could not be started
local function spawn(w)
  ---@type PdfView.WorkerProcess
  local process = { stdout = "", stderr = "" }
  local function on_stdout(_, data)
    if not data then
      return
    end
    local text = process.stdout .. data
    local start = 1
    while true do
      local newline = text:find("\n", start, true)
      if not newline then
        break
      end
      if text:byte(start) == 64 then -- "@": an answer; the rest is padding
        local line = text:sub(start, newline - 1)
        vim.schedule(function()
          on_answer(w, process, line)
        end)
      end
      start = newline + 1
    end
    -- padding needs no keeping, only the start of a line that may be an answer
    local rest = text:sub(start)
    process.stdout = rest:byte(1) == 64 and rest or ""
  end
  local function on_stderr(_, data)
    if data then
      process.stderr = (process.stderr .. data):sub(-STDERR_LIMIT)
    end
  end
  w.stamp, w.exe = file_stamp(w.path), config.options.mutool
  local cmd = { w.exe, "run", WORKER, w.path }
  local started, system = pcall(vim.system, cmd, {
    stdin = true,
    stdout = on_stdout,
    stderr = on_stderr,
  }, function(result)
    vim.schedule(function()
      on_exit(w, process, result)
    end)
  end)
  if not started then
    return nil, ("cannot run `%s`: %s"):format(cmd[1], system)
  end
  process.system = system
  return process
end

--- Stop the process of `w`, failing the request it is working on.
---@param w PdfView.Worker
---@param why string
local function stop(w, why)
  local process = w.process
  if not process then
    return
  end
  w.process, process.gone = nil, true
  pcall(process.system.kill, process.system, 15)
  local request = process.current
  process.current = nil
  if request then
    finish(request, why)
  end
end

--- Hand the next request to the process of `w`, starting one first if needed.
---@param w PdfView.Worker
pump = function(w)
  if w.process and w.process.current then
    return
  end
  local request = table.remove(w.queue, 1)
  if not request then
    return
  end
  -- a worker that has the file open as it was, or runs another mutool, is replaced
  if w.process and (w.stamp ~= file_stamp(w.path) or w.exe ~= config.options.mutool) then
    stop(w, "the file changed")
  end
  if not w.process then
    local process, err = spawn(w)
    if not process then
      finish(request, err)
      return pump(w)
    end
    w.process = process
  end
  w.process.current = request
  local ok, err = pcall(function()
    for _, line in ipairs(request.lines) do
      w.process.system:write(line)
    end
  end)
  if not ok then
    stop(w, "cannot talk to mutool: " .. tostring(err))
    pump(w)
  end
end

--- Ask the worker of `path` for something. `cb` is called on the main loop, also when the request is killed.
---@param path string
---@param request any[] command and arguments, as `worker.js` takes them
---@param cb fun(err?: string, result?: string)
---@return PdfView.Job
local function ask(path, request, cb)
  local w = workers[path]
  if not w then
    w = { path = path, queue = {} }
    workers[path] = w
  end
  next_request = next_request + 1
  table.insert(request, 1, passwords[path] or vim.NIL)
  table.insert(request, 1, layouts[path] or vim.NIL)
  table.insert(request, 1, next_request)
  ---@type PdfView.Request
  local entry = { id = next_request, lines = encode(request), cb = cb }
  w.queue[#w.queue + 1] = entry
  vim.schedule(function()
    pump(w)
  end)
  return {
    --- A waiting request is dropped; one that is being worked on stops its worker, so that a page that is slow to
    --- draw does not hold up the next one, and the next request starts another worker.
    kill = function()
      if entry.done then
        return
      end
      for index, queued in ipairs(w.queue) do
        if queued == entry then
          table.remove(w.queue, index)
          return vim.schedule(function()
            finish(entry, "mutool was killed (signal 15)")
          end)
        end
      end
      if w.process and w.process.current == entry then
        stop(w, "mutool was killed (signal 15)")
        vim.schedule(function()
          pump(w)
        end)
      end
    end,
  }
end

--- Stop the worker of `path`, if it has one, and drop what it was asked. The next request starts another.
---@param path string
function M.release(path)
  layouts[path] = nil
  local w = workers[path]
  if not w then
    return
  end
  workers[path] = nil
  local queue = w.queue
  w.queue = {}
  stop(w, "mutool was killed (signal 15)")
  for _, request in ipairs(queue) do
    finish(request, "mutool was killed (signal 15)")
  end
end

--- Unlock `path` with `password` from the next request on; nil forgets it. It is kept until Neovim exits, also after
--- `release()`, so that the document opens again without asking.
---@param path string
---@param password? string
function M.set_password(path, password)
  passwords[path] = password
end

-- what the scripts fail with without a password, and with one that does not unlock the document
M.LOCKED = "this PDF is password-protected"
M.WRONG_PASSWORD = "wrong password"

--- Whether `err`, from any request about a document, means that it needs a password: "missing" when none was
--- given, "wrong" when the one given does not unlock it.
---@param err? string
---@return "missing"|"wrong"|nil
function M.password_error(err)
  if err == M.LOCKED then
    return "missing"
  elseif err == M.WRONG_PASSWORD then
    return "wrong"
  end
end

--- The password of `path` as the standard input of a script, nil without one.
---@param path string
---@return string?
local function password_input(path)
  return passwords[path] and (passwords[path] .. "\n") or nil
end

--- Lay `path` out with `layout` from the next request on, if it is a reflowable document. Other documents ignore it.
---@param path string
---@param layout PdfView.Layout
function M.set_layout(path, layout)
  layouts[path] = layout
end

--- The layout of `path` as script arguments: none until one is set.
---@param path string
---@return string[]
local function layout_args(path)
  local layout = layouts[path]
  if not layout then
    return {}
  end
  return vim.tbl_map(function(value)
    return ("%g"):format(value)
  end, layout)
end

--- Whether `path` has a worker process running, for tests.
---@param path string
---@return boolean
function M.has_worker(path)
  return workers[path] ~= nil and workers[path].process ~= nil
end

--- What a render request answers with: an error, or success once a non-empty PNG exists.
---@param out string
---@param cb fun(err?: string, notes?: string) `notes` is what the worker said, e.g. "highlights: multiply"
---@return fun(err?: string, result?: string)
local function rendered(out, cb)
  return function(err, result)
    if err then
      return cb(err)
    end
    local stat = vim.uv.fs_stat(out)
    if not stat or stat.size == 0 then
      return cb("mutool did not produce an image")
    end
    cb(nil, vim.trim(result or ""))
  end
end

--- Page count and geometry of one page.
---@param path string
---@param page integer 1-based; clamped to the document
---@param cb fun(err?: string, info?: PdfView.PageInfo)
---@param content? boolean also find the part of the page that has content (`info.content`), which renders the page
---@param of? integer `page` is a page of a reflowable document as it was laid out before, with this many pages: the
--- answer is the page that now starts at the same point of the text
---@return PdfView.Job
function M.info(path, page, cb, content, of)
  local request = { "info", math.min(math.max(math.floor(page), 1), MAX_PAGE), content == true, of or vim.NIL }
  return ask(path, request, function(err, result)
    if err then
      return cb(err)
    end
    local fields = vim.split(vim.trim(result or ""), "%s+")
    local count, resolved, width, height =
      tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
    if not count or count < 1 or not resolved or not width or not height or width <= 0 or height <= 0 then
      return cb("could not read the page geometry (is mutool built with JavaScript support?)")
    end
    local info = { count = count, page = resolved, width = width, height = height, reflowable = fields[5] == "1" }
    if content then
      local x0, y0, x1, y1 = tonumber(fields[6]), tonumber(fields[7]), tonumber(fields[8]), tonumber(fields[9])
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

---@class PdfView.Clip
---@field scale_x number device pixels per point, horizontally
---@field scale_y number device pixels per point, vertically (equal to `scale_x` unless a page is stretched to cells)
---@field x integer left edge of the rectangle, in device pixels from the page's top-left corner
---@field y integer top edge
---@field width integer
---@field height integer
---@field highlights? string rectangles to multiply onto the page, as built by `search.highlights()`
---@field recolor? string how to recolour the image, as built by `session.recolor_spec()`: "" (or nil) for not at all

--- Render a rectangle of a page to a PNG of exactly `clip.width` x `clip.height` pixels. Only that rectangle is
--- rasterised, so the cost does not grow with the zoom level.
---@param path string
---@param page integer
---@param clip PdfView.Clip
---@param out string destination PNG
---@param cb fun(err?: string, notes?: string) `notes` says how highlights were drawn: "highlights: multiply" or "highlights: translucent"
---@return PdfView.Job
function M.render_clip(path, page, clip, out, cb)
  local request = {
    "render",
    page,
    clip.scale_x,
    clip.scale_y,
    math.floor(clip.x),
    math.floor(clip.y),
    math.floor(clip.width),
    math.floor(clip.height),
    out,
    clip.highlights or "",
    clip.recolor or "",
  }
  return ask(path, request, rendered(out, cb))
end

--- Render one page to a PNG of exactly `width` x `height` pixels.
---@param path string
---@param page integer
---@param width integer
---@param height integer
---@param out string destination PNG
---@param cb fun(err?: string)
---@param recolor? string how to recolour the image, as built by `session.recolor_spec()`
---@return PdfView.Job
function M.render(path, page, width, height, out, cb, recolor)
  local done = rendered(out, function(err)
    cb(err)
  end)
  return ask(path, { "draw", page, math.floor(width), math.floor(height), out, recolor or "" }, done)
end

--- The text of one page: a line per line of text and an empty line after each block, in reading order. Empty for a
--- page without text, such as a scanned one.
---@param path string
---@param page integer 1-based; clamped to the document
---@param cb fun(err?: string, text?: string)
---@return PdfView.Job
function M.text(path, page, cb)
  return ask(path, { "text", math.min(math.max(math.floor(page), 1), MAX_PAGE) }, function(err, result)
    if err then
      return cb(err)
    end
    local ok, text = pcall(vim.json.decode, result or "")
    if not ok or type(text) ~= "string" then
      return cb("could not read the text of the page")
    end
    cb(nil, text)
  end)
end

---@class PdfView.Link
---@field text string the text under the link, "" for an image
---@field page? integer 1-based page of the document it leads to
---@field uri? string where it leads otherwise: a web address, an e-mail

--- The links on one page, top to bottom, then left to right. Links that lead nowhere are left out.
---@param path string
---@param page integer 1-based; clamped to the document
---@param cb fun(err?: string, links?: PdfView.Link[])
---@return PdfView.Job
function M.links(path, page, cb)
  return ask(path, { "links", math.min(math.max(math.floor(page), 1), MAX_PAGE) }, function(err, result)
    if err then
      return cb(err)
    end
    local ok, links = pcall(vim.json.decode, result or "")
    if not ok or type(links) ~= "table" then
      return cb("could not read the links of the page")
    end
    cb(nil, links)
  end)
end

--- Find every occurrence of `needle` in the document (ignoring case).
---@param path string
---@param needle string
---@param limit integer stop after this many matches
---@param cb fun(err?: string, matches?: PdfView.Match[], truncated?: boolean)
---@return PdfView.Job
function M.search(path, needle, limit, cb)
  local cmd = { config.options.mutool, "run", SEARCH, path, needle, ("%d"):format(limit), unpack(layout_args(path)) }
  return run(cmd, function(result)
    local err = failure(result)
    if err then
      return cb(err)
    end
    local matches, truncated = require("pdf-view.search").parse(result.stdout)
    cb(nil, matches, truncated)
  end, password_input(path))
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
  return run({ config.options.mutool, "run", OUTLINE, path, unpack(layout_args(path)) }, function(result)
    local err = failure(result)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_outline(result.stdout))
  end, password_input(path))
end

return M
