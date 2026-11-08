local M = {}

--- Number of row/column diacritics the Kitty protocol defines. An image cannot span more cells than this.
M.MAX_CELLS = 297

---@class PdfView.Fit
---@field cols integer image width in terminal cells
---@field rows integer image height in terminal cells
---@field width integer pixel width to render the page at
---@field height integer pixel height to render the page at
---@field pad_left integer blank cells left of the image
---@field pad_top integer blank rows above the image

local function round(value)
  return math.floor(value + 0.5)
end

--- Fit a page into a window, in whole terminal cells, distorting the page as little as possible.
---
--- The page is rendered at exactly `cols * cell_w` by `rows * cell_h` pixels so the terminal can map it
--- one-to-one onto the cells. Rounding to whole cells can skew the aspect ratio by up to half a cell per
--- side, so the four floor/ceil neighbours of the ideal size are compared and the least distorted wins.
---@param page_w number page width in points (any unit works, only the ratio matters)
---@param page_h number page height
---@param win_cols integer window width in cells
---@param win_rows integer window height in cells
---@param cell_w number cell width in pixels
---@param cell_h number cell height in pixels
---@param max_pixels integer cap for either side of the rendered image
---@return PdfView.Fit
function M.fit(page_w, page_h, win_cols, win_rows, cell_w, cell_h, max_pixels)
  local max_cols = math.max(1, math.min(win_cols, M.MAX_CELLS))
  local max_rows = math.max(1, math.min(win_rows, M.MAX_CELLS))

  local scale = math.min(max_cols * cell_w / page_w, max_rows * cell_h / page_h)
  local ideal_cols = page_w * scale / cell_w
  local ideal_rows = page_h * scale / cell_h
  local aspect = page_w / page_h

  local cols, rows, best_error = 1, 1, math.huge
  for _, c in ipairs({ math.floor(ideal_cols), math.ceil(ideal_cols) }) do
    for _, r in ipairs({ math.floor(ideal_rows), math.ceil(ideal_rows) }) do
      if c >= 1 and r >= 1 and c <= max_cols and r <= max_rows then
        local err = math.abs(math.log((c * cell_w) / (r * cell_h) / aspect))
        local larger = c * r > cols * rows
        if err < best_error - 1e-9 or (math.abs(err - best_error) <= 1e-9 and larger) then
          cols, rows, best_error = c, r, err
        end
      end
    end
  end

  local shrink = math.min(1, max_pixels / (cols * cell_w), max_pixels / (rows * cell_h))
  return {
    cols = cols,
    rows = rows,
    width = math.max(1, round(cols * cell_w * shrink)),
    height = math.max(1, round(rows * cell_h * shrink)),
    pad_left = math.floor((win_cols - cols) / 2),
    pad_top = math.floor((win_rows - rows) / 2),
  }
end

---@class PdfView.Viewport : PdfView.Fit
---@field scale number device pixels per point
---@field x integer left edge of the viewport inside the zoomed page, in device pixels
---@field y integer top edge
---@field vx number the same, unrounded
---@field vy number
---@field view_w number viewport width in device pixels
---@field view_h number viewport height
---@field full_w number the zoomed page's width in device pixels
---@field full_h number
---@field min_x number how far left the viewport can travel: the left edge of the content in a "content" fit, else 0
---@field min_y number how far up the viewport can travel
---@field max_x number how far the viewport can travel right
---@field max_y number how far the viewport can travel down
---@field scroll_x boolean whether the page is wider than the window, so horizontal movement scrolls
---@field scroll_y boolean
---@field cx number viewport centre as a fraction of the page width, clamped to what is reachable
---@field cy number

---@alias PdfView.FitMode "page"|"width"|"height"|"content"

--- The part of a zoomed page that is on screen.
---
--- Zoom 1 is the page at its fitted size: the whole page (`mode` "page", what `fit` draws), the page as wide
--- ("width") or as tall ("height") as the window, or the part of the page with content on it, `box`, as large as fits
--- ("content"). Zoom z shows it z times larger. When the page then overflows the window the viewport is a window-sized
--- crop of it, positioned by its centre as a fraction of the page so that it survives resizes and zoom changes. A
--- "content" fit only travels over `box`, leaving the margins out. A side that still fits is centred and its sub-cell
--- remainder is cropped, which keeps the image an exact whole number of cells.
---@param page_w number
---@param page_h number
---@param win_cols integer
---@param win_rows integer
---@param cell_w number
---@param cell_h number
---@param zoom number >= 1
---@param cx number desired viewport centre, 0..1 of the page width
---@param cy number desired viewport centre, 0..1 of the page height
---@param mode? PdfView.FitMode what zoom 1 means, "page" by default
---@param box? number[] `{ x0, y0, x1, y1 }` in points from the page's top-left corner, for "content"; the whole page
--- when missing
---@return PdfView.Viewport
function M.viewport(page_w, page_h, win_cols, win_rows, cell_w, cell_h, zoom, cx, cy, mode, box)
  local max_cols = math.max(1, math.min(win_cols, M.MAX_CELLS))
  local max_rows = math.max(1, math.min(win_rows, M.MAX_CELLS))
  local box_w, box_h = max_cols * cell_w, max_rows * cell_h

  local x0, y0, x1, y1 = 0, 0, page_w, page_h
  if mode == "content" and box then
    x0, y0, x1, y1 = box[1], box[2], box[3], box[4]
  end
  local shown_w, shown_h = x1 - x0, y1 - y0

  local base
  if mode == "width" then
    base = box_w / shown_w
  elseif mode == "height" then
    base = box_h / shown_h
  else
    base = math.min(box_w / shown_w, box_h / shown_h)
  end
  local scale = base * zoom
  local full_w, full_h = page_w * scale, page_h * scale
  local reach_w, reach_h = shown_w * scale, shown_h * scale

  -- the epsilon keeps a page fitted exactly to the window from losing a cell to floating point error
  local scroll_x, scroll_y = reach_w > box_w + 0.5, reach_h > box_h + 0.5
  local cols = scroll_x and max_cols or math.max(1, math.min(max_cols, math.floor(reach_w / cell_w + 1e-6)))
  local rows = scroll_y and max_rows or math.max(1, math.min(max_rows, math.floor(reach_h / cell_h + 1e-6)))
  local view_w, view_h = cols * cell_w, rows * cell_h
  local min_x, min_y = x0 * scale, y0 * scale
  local max_x, max_y = min_x + math.max(0, reach_w - view_w), min_y + math.max(0, reach_h - view_h)

  local vx, vy = (min_x + max_x) / 2, (min_y + max_y) / 2
  if scroll_x then
    vx = math.min(math.max(cx * full_w - view_w / 2, min_x), max_x)
    cx = (vx + view_w / 2) / full_w
  end
  if scroll_y then
    vy = math.min(math.max(cy * full_h - view_h / 2, min_y), max_y)
    cy = (vy + view_h / 2) / full_h
  end

  return {
    cols = cols,
    rows = rows,
    width = math.max(1, round(view_w)),
    height = math.max(1, round(view_h)),
    pad_left = math.floor((win_cols - cols) / 2),
    pad_top = math.floor((win_rows - rows) / 2),
    scale = scale,
    x = round(vx),
    y = round(vy),
    vx = vx,
    vy = vy,
    view_w = view_w,
    view_h = view_h,
    full_w = full_w,
    full_h = full_h,
    min_x = min_x,
    min_y = min_y,
    max_x = max_x,
    max_y = max_y,
    scroll_x = scroll_x,
    scroll_y = scroll_y,
    cx = cx,
    cy = cy,
  }
end

---@class PdfView.SheetLayout
---@field page? integer
---@field x number where the page's top-left corner lies on the sheet, in points
---@field y number
---@field width number the page's size, in points
---@field height number

--- Pages side by side, `gap` points apart and centred on each other vertically, as one page: the sheet's size, and
--- what its content is when every page says (`content`). `infos` with one page give that page.
---@param infos PdfView.PageInfo[]
---@param gap number
---@return PdfView.PageInfo sheet with `parts` (`PdfView.SheetLayout`, page by page) and `last` when there are two
function M.sheet(infos, gap)
  if #infos == 1 then
    return infos[1]
  end
  local height = 0
  for _, info in ipairs(infos) do
    height = math.max(height, info.height)
  end
  local parts, content = {}, { math.huge, math.huge, -math.huge, -math.huge }
  local x = 0
  for index, info in ipairs(infos) do
    if index > 1 then
      x = x + gap
    end
    local y = (height - info.height) / 2
    parts[index] = { page = info.page, x = x, y = y, width = info.width, height = info.height }
    local box = info.content
    if content and box then
      content = {
        math.min(content[1], x + box[1]),
        math.min(content[2], y + box[2]),
        math.max(content[3], x + box[3]),
        math.max(content[4], y + box[4]),
      }
    else
      content = nil
    end
    x = x + info.width
  end
  return {
    count = infos[1].count,
    page = infos[1].page,
    last = infos[#infos].page,
    width = x,
    height = height,
    reflowable = false,
    content = content,
    parts = parts,
  }
end

--- Text size, in points, that reflowable documents are laid out with.
M.REFLOW_EM = 12
--- How many pixels of a terminal cell's height one point of text takes at `text_scale` 1: twelve-point text is then
--- about as tall as the terminal's own.
local REFLOW_POINTS_PER_CELL = 14
--- The smallest side of a reflowed page, in points: smaller pages would hold a word or two each.
local REFLOW_MIN_SIDE = 72

--- The page a reflowable document (EPUB, FB2, MOBI) is laid out on in a window of `win_cols` x `win_rows` cells: as
--- large as the window, so that a fitted page fills it, with text `text_scale` times the size of the terminal's.
---@param win_cols integer
---@param win_rows integer
---@param cell_w number
---@param cell_h number
---@param text_scale number
---@return PdfView.Layout
function M.reflow(win_cols, win_rows, cell_w, cell_h, text_scale)
  local cols = math.max(1, math.min(win_cols, M.MAX_CELLS))
  local rows = math.max(1, math.min(win_rows, M.MAX_CELLS))
  local points_per_pixel = REFLOW_POINTS_PER_CELL / (cell_h * text_scale)
  local width = math.max(REFLOW_MIN_SIDE, round(cols * cell_w * points_per_pixel))
  local height = math.max(REFLOW_MIN_SIDE, round(rows * cell_h * points_per_pixel))
  return { width, height, M.REFLOW_EM }
end

return M
