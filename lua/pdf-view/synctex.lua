--- SyncTeX: from a line of a TeX file to where it is typeset in the PDF (`synctex view`), and from a point of a page
--- back to the line (`synctex edit`). Runs the `synctex` command line tool and reads what it prints; no editor state.
local config = require("pdf-view.config")

local M = {}

---@class PdfView.SyncBox
---@field page integer 1-based
---@field rect number[] `{ x0, y0, x1, y1 }`: the typeset line, in points from the page's top-left corner

---@class PdfView.SyncSource
---@field file string absolute path of the TeX file
---@field line integer 1-based
---@field column integer 1-based, or 0 when SyncTeX does not say

--- The records of `synctex view` output: one per box the line was typeset into, in the order given.
---@param stdout string
---@return PdfView.SyncBox[]
function M.parse_view(stdout)
  local boxes, record = {}, nil
  local function close()
    if record and record.Page and record.h and record.v and record.W and record.H then
      local x0, bottom = record.h, record.v
      boxes[#boxes + 1] = { page = record.Page, rect = { x0, bottom - record.H, x0 + record.W, bottom } }
    end
  end
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^(%a+):(.*)$")
    if key == "Output" then -- every record starts with the output file
      close()
      record = {}
    elseif record and key and (key == "Page" or #key == 1) then
      record[key] = tonumber(value)
    end
  end
  close()
  return boxes
end

--- The source location of `synctex edit` output, its first record. A relative input is relative to `dir`, the
--- directory of the PDF, where the TeX engine ran.
---@param stdout string
---@param dir string
---@return PdfView.SyncSource?
function M.parse_edit(stdout, dir)
  local input, line, column
  for text in (stdout or ""):gmatch("[^\r\n]+") do
    local key, value = text:match("^(%a+):(.*)$")
    if key == "Input" and not input then
      input = value
    elseif key == "Line" and input and not line then
      line = tonumber(value)
    elseif key == "Column" and line and not column then
      column = tonumber(value)
    end
  end
  if not (input and input ~= "" and line and line > 0) then
    return nil
  end
  if not vim.startswith(input, "/") and not input:match("^%a:[/\\]") then
    input = dir .. "/" .. input
  end
  return { file = vim.fn.simplify(input), line = line, column = math.max(0, column or 0) }
end

--- Run `synctex` with `args`, calling `cb` on the main loop with its standard output or why it failed.
---@param args string[]
---@param cb fun(err?: string, stdout?: string)
local function run(args, cb)
  local cmd = { config.options.synctex, unpack(args) }
  local started, err = pcall(vim.system, cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        -- the first line says why ("SyncTeX ERROR: No SyncTeX available for ..."), the usage text follows
        local why = (result.stderr or ""):match("[^\r\n]*%S[^\r\n]*")
        return cb(why and vim.trim(why) or ("`%s` failed (exit code %d)"):format(cmd[1], result.code))
      end
      cb(nil, result.stdout)
    end)
  end)
  if not started then
    vim.schedule(function()
      cb(("cannot run `%s`: %s"):format(cmd[1], err))
    end)
  end
end

--- Where line `line`, column `column` of the TeX file `file` is typeset in `pdf`. No boxes when the PDF has no
--- SyncTeX data, or none for that line.
---@param pdf string
---@param file string absolute path, as the TeX engine names its files
---@param line integer
---@param column integer
---@param cb fun(err?: string, boxes?: PdfView.SyncBox[])
function M.view(pdf, file, line, column, cb)
  run({ "view", "-i", ("%d:%d:%s"):format(line, column, file), "-o", pdf }, function(err, stdout)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_view(stdout --[[@as string]]))
  end)
end

--- The source line that the point (`x`, `y`) of page `page` of `pdf` was typeset from, in points from the page's
--- top-left corner. Nil when SyncTeX does not know.
---@param pdf string
---@param page integer
---@param x number
---@param y number
---@param cb fun(err?: string, source?: PdfView.SyncSource)
function M.edit(pdf, page, x, y, cb)
  run({ "edit", "-o", ("%d:%.2f:%.2f:%s"):format(page, x, y, pdf) }, function(err, stdout)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_edit(stdout --[[@as string]], vim.fs.dirname(pdf)))
  end)
end

return M
