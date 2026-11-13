--- Turning the view: a viewer can turn every page clockwise by 0, 90, 180 or 270 degrees. mutool draws the pages
--- turned (`scripts/worker.js`), and measures them turned; everything else in points or fractions of a page (search
--- matches, SyncTeX boxes, link and bookmark destinations) is read from the file unturned, and turned here.
local M = {}

---@alias PdfView.Rotation 0|90|180|270

--- `degrees` as one of the four rotations, turned to the nearest multiple of 90 and wrapped into 0 to 270.
---@param degrees any
---@return PdfView.Rotation
function M.normalize(degrees)
  if type(degrees) ~= "number" or degrees ~= degrees or degrees == math.huge or degrees == -math.huge then
    return 0
  end
  return (math.floor(degrees / 90 + 0.5) * 90) % 360 --[[@as PdfView.Rotation]]
end

--- Whether `degrees` is one of the four rotations exactly.
---@param degrees any
---@return boolean
function M.valid(degrees)
  return degrees == 0 or degrees == 90 or degrees == 180 or degrees == 270
end

--- The size of a `w` x `h` page turned by `rotation`.
---@param rotation PdfView.Rotation
---@param w number
---@param h number
---@return number w, number h
function M.size(rotation, w, h)
  if rotation == 90 or rotation == 270 then
    return h, w
  end
  return w, h
end

--- The point (`x`, `y`) of a `w` x `h` page, in points from its top-left corner, on the page turned clockwise by
--- `rotation`, from the turned page's top-left corner.
---@param rotation PdfView.Rotation
---@param w number
---@param h number
---@param x number
---@param y number
---@return number x, number y
function M.point(rotation, w, h, x, y)
  if rotation == 90 then
    return h - y, x
  elseif rotation == 180 then
    return w - x, h - y
  elseif rotation == 270 then
    return y, w - x
  end
  return x, y
end

--- The point (`x`, `y`) of a page turned by `rotation`, which is `w` x `h` turned, on the page before it was turned:
--- the inverse of `point()`.
---@param rotation PdfView.Rotation
---@param w number the width of the turned page
---@param h number its height
---@param x number
---@param y number
---@return number x, number y
function M.unpoint(rotation, w, h, x, y)
  return M.point((360 - rotation) % 360 --[[@as PdfView.Rotation]], w, h, x, y)
end

--- The rectangle `{ x0, y0, x1, y1 }` of a `w` x `h` page on the page turned by `rotation`.
---@param rotation PdfView.Rotation
---@param w number
---@param h number
---@param rect number[]
---@return number[]
function M.rect(rotation, w, h, rect)
  local x0, y0 = M.point(rotation, w, h, rect[1], rect[2])
  local x1, y1 = M.point(rotation, w, h, rect[3], rect[4])
  return { math.min(x0, x1), math.min(y0, y1), math.max(x0, x1), math.max(y0, y1) }
end

--- Where a link or a bookmark leads, (`x`, `y`) as fractions of the page's width and height, on the page turned by
--- `rotation`. Either may be missing (a destination that only says how far down the page it leads): the turned point
--- then misses the one that it becomes.
---@param rotation PdfView.Rotation
---@param x? number
---@param y? number
---@return number? x, number? y
function M.destination(rotation, x, y)
  if rotation == 90 then
    return y and 1 - y, x
  elseif rotation == 180 then
    return x and 1 - x, y and 1 - y
  elseif rotation == 270 then
    return y, x and 1 - x
  end
  return x, y
end

--- The point (`x`, `y`) of a page as fractions of its width and height, on the page turned by `rotation`.
---@param rotation PdfView.Rotation
---@param x number
---@param y number
---@return number x, number y
function M.fraction(rotation, x, y)
  ---@diagnostic disable-next-line: return-type-mismatch (a point that has both gives both)
  return M.destination(rotation, x, y)
end

return M
