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
---@field max_x number how far the viewport can travel right
---@field max_y number how far the viewport can travel down
---@field scroll_x boolean whether the page is wider than the window, so horizontal movement scrolls
---@field scroll_y boolean
---@field cx number viewport centre as a fraction of the page width, clamped to what is reachable
---@field cy number

---@alias PdfView.FitMode "page"|"width"|"height"

--- The part of a zoomed page that is on screen.
---
--- Zoom 1 is the page at its fitted size: the whole page (`mode` "page", what `fit` draws), or the page as wide
--- ("width") or as tall ("height") as the window. Zoom z shows it z times larger. When the page then overflows the
--- window the viewport is a window-sized crop of it, positioned by its centre as a fraction of the page so that it
--- survives resizes and zoom changes. A side that still fits is centred and its sub-cell remainder is cropped,
--- which keeps the image an exact whole number of cells.
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
---@return PdfView.Viewport
function M.viewport(page_w, page_h, win_cols, win_rows, cell_w, cell_h, zoom, cx, cy, mode)
  local max_cols = math.max(1, math.min(win_cols, M.MAX_CELLS))
  local max_rows = math.max(1, math.min(win_rows, M.MAX_CELLS))
  local box_w, box_h = max_cols * cell_w, max_rows * cell_h

  local base
  if mode == "width" then
    base = box_w / page_w
  elseif mode == "height" then
    base = box_h / page_h
  else
    base = math.min(box_w / page_w, box_h / page_h)
  end
  local scale = base * zoom
  local full_w, full_h = page_w * scale, page_h * scale

  -- the epsilon keeps a page fitted exactly to the window from losing a cell to floating point error
  local scroll_x, scroll_y = full_w > box_w + 0.5, full_h > box_h + 0.5
  local cols = scroll_x and max_cols or math.max(1, math.min(max_cols, math.floor(full_w / cell_w + 1e-6)))
  local rows = scroll_y and max_rows or math.max(1, math.min(max_rows, math.floor(full_h / cell_h + 1e-6)))
  local view_w, view_h = cols * cell_w, rows * cell_h
  local max_x, max_y = math.max(0, full_w - view_w), math.max(0, full_h - view_h)

  local vx, vy = max_x / 2, max_y / 2
  if scroll_x then
    vx = math.min(math.max(cx * full_w - view_w / 2, 0), max_x)
    cx = (vx + view_w / 2) / full_w
  end
  if scroll_y then
    vy = math.min(math.max(cy * full_h - view_h / 2, 0), max_y)
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
    max_x = max_x,
    max_y = max_y,
    scroll_x = scroll_x,
    scroll_y = scroll_y,
    cx = cx,
    cy = cy,
  }
end

return M
