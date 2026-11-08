--- Where each PDF was being read, kept across Neovim restarts in a JSON file under `stdpath("state")`. Keyed by the
--- absolute path of the PDF; only the `LIMIT` most recently left files are kept.
local M = {}

local uv = vim.uv

local LIMIT = 100
local MODES = { page = true, width = true, height = true, content = true }

--- The JSON file. Tests point it somewhere else.
---@type string?
M.file = nil

local function file()
  return M.file or (vim.fn.stdpath("state") .. "/pdf-view/positions.json")
end

---@return table<string, table>
local function load()
  local fd = io.open(file(), "rb")
  if not fd then
    return {}
  end
  local data = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, data)
  return ok and type(decoded) == "table" and decoded or {}
end

--- A position read from the file, or nil when it is missing or malformed.
---@param entry any
---@return { page: integer, mode: PdfView.FitMode, zoom: number, cx: number, cy: number }?
local function sanitize(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local page, mode, zoom, cx, cy = entry.page, entry.mode, entry.zoom, entry.cx, entry.cy
  if
    type(page) ~= "number"
    or page < 1
    or not MODES[mode]
    or type(zoom) ~= "number"
    or type(cx) ~= "number"
    or type(cy) ~= "number"
  then
    return nil
  end
  return { page = math.floor(page), mode = mode, zoom = zoom, cx = cx, cy = cy }
end

--- The position `path` was left at, if it is remembered.
---@param path string absolute
function M.get(path)
  return sanitize(load()[path])
end

--- Remember `position` for `path`, dropping the oldest entries past `LIMIT`.
---@param path string absolute
---@param position { page: integer, mode: PdfView.FitMode, zoom: number, cx: number, cy: number }
function M.set(path, position)
  local entries = load()
  entries[path] = vim.tbl_extend("force", position, { time = os.time() })

  local paths = vim.tbl_keys(entries)
  if #paths > LIMIT then
    local function time(key)
      return type(entries[key]) == "table" and tonumber(entries[key].time) or 0
    end
    table.sort(paths, function(a, b)
      if a == b then
        return false -- a comparator must never call an entry less than itself
      end
      local ta, tb = time(a), time(b)
      if ta ~= tb then
        return ta > tb
      end
      if a == path or b == path then
        return a == path -- the entry just written survives a tie
      end
      return a < b
    end)
    for index = LIMIT + 1, #paths do
      entries[paths[index]] = nil
    end
  end

  local target = file()
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  -- write a temp file and rename it, so another Neovim reading the file never sees half of it
  local temp = ("%s.%d.tmp"):format(target, uv.os_getpid())
  local fd = io.open(temp, "wb")
  if not fd then
    return
  end
  fd:write(vim.json.encode(entries))
  fd:close()
  if not uv.fs_rename(temp, target) then
    os.remove(temp)
  end
end

return M
