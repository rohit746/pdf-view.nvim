--- Positioned placements, for zellij: it implements the Kitty graphics protocol but not Unicode placeholders.
---
--- Instead of placeholder text the buffer holds blank lines, and the page is placed at the screen position of its
--- window. Neovim knows nothing about such an image, so this module keeps it in step with the screen: the image is
--- cut around floating windows and the popup menu that cover it, it is taken away while its window is hidden, and it
--- is placed again after Neovim redraws the window (a clear or a scroll inside zellij moves or drops a placement).
---
--- zellij also forgets an image once nothing shows it any more, so an image that was taken away or cleared off the
--- screen is sent again before it is placed again.
local kitty = require("pdf-view.kitty")
local terminal = require("pdf-view.terminal")

local M = {}

local ns = vim.api.nvim_create_namespace("pdf-view-positioned")
local augroup = vim.api.nvim_create_augroup("PdfViewPositioned", { clear = true })

local ESC = "\27"
-- an image the terminal reports lost again this soon after it was sent again cannot be shown: stop sending it
local RESEND_GUARD = 2e9 -- ns
-- placement ids of a picture are 1.. or PLACEMENT_RANGE + 1.. (see refresh())
local PLACEMENT_RANGE = 1000

--- Whether Neovim passes the terminal's replies to graphics commands on (TermResponse, 0.12). Neovim 0.11 cannot read
--- them, and a reply would arrive as typed keys, so then the terminal is asked for none.
M.replies = vim.fn.has("nvim-0.12") == 1

---@class PdfView.Picture
---@field id integer image id
---@field path string the PNG it was sent from, to send it again
---@field cols integer size of the image in cells
---@field rows integer
---@field width integer size of the image in pixels
---@field height integer
---@field row integer rows above the image in the window's text area
---@field col integer columns left of the image
---@field exact boolean one image pixel per screen pixel, so a part needs no scaling
---@field sent_again? integer hrtime of the last time it was sent again

---@class PdfView.Rect
---@field row integer 0-based screen row of the top edge
---@field col integer 0-based screen column of the left edge
---@field rows integer
---@field cols integer

---@type table<integer, PdfView.Session> sessions with a picture, by buffer
local shown = {}

--- Show the page again from scratch, for a picture whose PNG has gone. Set by `render`.
---@type fun(s: PdfView.Session)
M.rerender = function() end

---@param border any `border` of nvim_win_get_config()
---@return integer top, integer right, integer bottom, integer left
local function border_sizes(border)
  if type(border) == "string" then
    if border == "" or border == "none" then
      return 0, 0, 0, 0
    elseif border == "shadow" then
      return 0, 1, 1, 0
    end
    return 1, 1, 1, 1
  elseif type(border) ~= "table" or #border == 0 then
    return 0, 0, 0, 0
  end
  local function side(index)
    local char = border[(index - 1) % #border + 1]
    if type(char) == "table" then
      char = char[1]
    end
    return (type(char) == "string" and char ~= "") and 1 or 0
  end
  return side(2), side(4), side(6), side(8)
end

--- Floating windows and the popup menu that are drawn over `win`, borders included.
---@param win integer
---@return PdfView.Rect[]
local function covers(win)
  local own = vim.api.nvim_win_get_config(win)
  local own_z = own.relative ~= "" and (own.zindex or 50) or nil
  local rects = {}
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if other ~= win then
      local c = vim.api.nvim_win_get_config(other)
      -- a float as high as a floating viewer was most likely opened after it, which puts it on top
      if c.relative ~= "" and not c.hide and not c.external and (own_z == nil or (c.zindex or 50) >= own_z) then
        local pos = vim.api.nvim_win_get_position(other)
        local top, right, bottom, left = border_sizes(c.border)
        rects[#rects + 1] = {
          row = pos[1],
          col = pos[2],
          rows = vim.api.nvim_win_get_height(other) + top + bottom,
          cols = vim.api.nvim_win_get_width(other) + left + right,
        }
      end
    end
  end
  local pum = vim.fn.pum_getpos()
  if pum.row then
    rects[#rects + 1] =
      { row = pum.row, col = pum.col, rows = pum.height, cols = pum.width + (pum.scrollbar and 1 or 0) }
  end
  return rects
end

--- `area` minus `holes`, as rectangles that do not overlap: one per run of uncovered columns in each band of rows,
--- with bands that have the same runs merged.
---@param area PdfView.Rect
---@param holes PdfView.Rect[]
---@return PdfView.Rect[]
function M.subtract(area, holes)
  local bottom, right = area.row + area.rows, area.col + area.cols
  local cuts = {}
  for _, hole in ipairs(holes) do
    local cut = {
      top = math.max(area.row, hole.row),
      bottom = math.min(bottom, hole.row + hole.rows),
      left = math.max(area.col, hole.col),
      right = math.min(right, hole.col + hole.cols),
    }
    if cut.top < cut.bottom and cut.left < cut.right then
      cuts[#cuts + 1] = cut
    end
  end
  if #cuts == 0 then
    return area.rows > 0 and area.cols > 0 and { area } or {}
  end

  local edges = { area.row, bottom }
  for _, cut in ipairs(cuts) do
    edges[#edges + 1] = cut.top
    edges[#edges + 1] = cut.bottom
  end
  table.sort(edges)

  local pieces = {}
  for index = 1, #edges - 1 do
    local band_top, band_bottom = edges[index], edges[index + 1]
    if band_top < band_bottom then
      local spans = {}
      for _, cut in ipairs(cuts) do
        if cut.top <= band_top and cut.bottom >= band_bottom then
          spans[#spans + 1] = cut
        end
      end
      table.sort(spans, function(a, b)
        return a.left < b.left
      end)
      local runs, x = {}, area.col
      for _, span in ipairs(spans) do
        if span.left > x then
          runs[#runs + 1] = { x, span.left }
        end
        x = math.max(x, span.right)
      end
      if x < right then
        runs[#runs + 1] = { x, right }
      end
      for _, run in ipairs(runs) do
        local merged = false
        for _, piece in ipairs(pieces) do
          if piece.col == run[1] and piece.cols == run[2] - run[1] and piece.row + piece.rows == band_top then
            piece.rows = piece.rows + band_bottom - band_top
            merged = true
            break
          end
        end
        if not merged then
          pieces[#pieces + 1] = { row = band_top, col = run[1], rows = band_bottom - band_top, cols = run[2] - run[1] }
        end
      end
    end
  end
  return pieces
end

--- The window of the current tab page to show the page of `s` in: the current window when it shows the PDF, else the
--- window the page was fitted to, else any. Only one of several windows on the same PDF can have the image.
---@param s PdfView.Session
---@return integer?
local function target_window(s)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == s.buf then
    return current
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local win = s.win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == s.buf then
    if vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
  for _, other in ipairs(vim.fn.win_findbuf(s.buf)) do
    if vim.api.nvim_win_get_tabpage(other) == tab then
      return other
    end
  end
end

--- Where the image of `s` is on screen and which parts of it are not covered. Nothing when its window is hidden.
---@param s PdfView.Session
---@return PdfView.Rect[] pieces, PdfView.Rect? image
local function visible(s)
  local pic, win = s.picture, target_window(s)
  if not (pic and win) then
    return {}
  end
  local info = vim.fn.getwininfo(win)[1]
  -- screenpos() knows about borders and the winbar; it is 0 when the first line is scrolled out of view
  local origin = vim.fn.screenpos(win, 1, 1)
  local top, left
  if origin.row > 0 then
    top, left = origin.row - 1, origin.col - 1
  else
    top, left = info.winrow - 1 + info.winbar, info.wincol - 1 + info.textoff
  end
  local area_rows, area_cols = info.height, info.width - info.textoff

  local image = { row = top + pic.row, col = left + pic.col, rows = pic.rows, cols = pic.cols }
  -- the window can be smaller than the image until the page is fitted to it again
  local row0, col0 = math.max(image.row, top, 0), math.max(image.col, left, 0)
  local row1 = math.min(image.row + image.rows, top + area_rows, vim.o.lines)
  local col1 = math.min(image.col + image.cols, left + area_cols, vim.o.columns)
  if row1 <= row0 or col1 <= col0 then
    return {}
  end
  local clipped = { row = row0, col = col0, rows = row1 - row0, cols = col1 - col0 }
  return M.subtract(clipped, covers(win)), image
end

--- `pieces` with no two of the same size: a piece the size of an earlier one is split in two (a 1x1 one is dropped).
---@param pieces PdfView.Rect[]
---@return PdfView.Rect[]
function M.distinct(pieces)
  local queue, seen, result = vim.deepcopy(pieces), {}, {}
  local index = 1
  while index <= #queue do
    local piece = queue[index]
    index = index + 1
    local size = piece.rows .. "x" .. piece.cols
    if not seen[size] then
      seen[size] = true
      result[#result + 1] = piece
    elseif piece.rows > 1 then
      queue[#queue + 1] = { row = piece.row, col = piece.col, rows = piece.rows - 1, cols = piece.cols }
      queue[#queue + 1] = { row = piece.row + piece.rows - 1, col = piece.col, rows = 1, cols = piece.cols }
    elseif piece.cols > 1 then
      queue[#queue + 1] = { row = piece.row, col = piece.col, rows = 1, cols = piece.cols - 1 }
      queue[#queue + 1] = { row = piece.row, col = piece.col + piece.cols - 1, rows = 1, cols = 1 }
    end
  end
  return result
end

--- The part of the picture that `piece` shows, in image pixels.
---@param pic PdfView.Picture
---@param image PdfView.Rect
---@param piece PdfView.Rect
---@param scaled boolean give the part a size in cells even when it needs no scaling
---@return PdfView.Crop
local function crop(pic, image, piece, scaled)
  local sx, sy = pic.width / pic.cols, pic.height / pic.rows
  local c0, r0 = piece.col - image.col, piece.row - image.row
  local x0, y0 = math.floor(c0 * sx + 0.5), math.floor(r0 * sy + 0.5)
  local x1, y1 = math.floor((c0 + piece.cols) * sx + 0.5), math.floor((r0 + piece.rows) * sy + 0.5)
  local result = { x = x0, y = y0, w = math.max(1, x1 - x0), h = math.max(1, y1 - y0) }
  if scaled or not pic.exact then
    result.cols, result.rows = piece.cols, piece.rows
  end
  return result
end

---@param s PdfView.Session
---@param pieces PdfView.Rect[]
---@return string
local function key_of(s, pieces)
  local parts = { tostring(s.picture.id) }
  for _, piece in ipairs(pieces) do
    parts[#parts + 1] = ("%d,%d,%d,%d"):format(piece.row, piece.col, piece.rows, piece.cols)
  end
  return table.concat(parts, ";")
end

--- Put the picture of `s` where it belongs on screen, if that changed or `s.dirty` says the screen may have lost it.
---@param s PdfView.Session
function M.refresh(s)
  local pic = s.picture
  if s.closed or not pic then
    return
  end
  local pieces, image = visible(s)
  -- zellij 0.45.1 draws a part of an image from the image's top-left corner, wherever the part starts, unless the part
  -- is scaled to a size in cells. It keeps one scaled copy per size and image: the parts of a page cut around a float
  -- get sizes of their own, and the page is sent again when they change, to drop the copies cut for the last float.
  local cut = #pieces > 1
    or (#pieces == 1 and image ~= nil and (pieces[1].row ~= image.row or pieces[1].col ~= image.col))
  if cut then
    pieces = M.distinct(pieces)
  end
  local key = key_of(s, pieces)
  local placed = s.placed
  if not s.dirty and placed and placed.key == key then
    return
  end
  s.dirty = false
  local before = (placed and placed.id == pic.id) and placed.count or 0
  -- Placement ids alternate between two ranges whenever the pieces change. zellij keeps each id on the host terminal
  -- as one placement, and when the same id goes on to show a different image (a piece cut around a float, then the
  -- whole page) it places the new one without removing the old one there. A fresh id is a fresh placement.
  local base = 0
  if placed and before > 0 then
    base = placed.key == key and placed.base or (placed.base == 0 and PLACEMENT_RANGE or 0)
  end

  if #pieces == 0 then
    if before > 0 then
      kitty.send(kitty.unplace(pic.id))
      s.lost = true -- zellij frees an image along with its last placement
    end
    s.placed = { id = pic.id, count = 0, key = key, base = 0 }
    return
  end

  if cut and s.cut_key and s.cut_key ~= key then
    s.lost = true
  end
  if s.lost then
    if not vim.uv.fs_stat(pic.path) then
      s.picture, s.placed = nil, nil
      shown[s.buf] = nil
      return M.rerender(s)
    end
    local ok, commands = pcall(kitty.transmit, pic.id, pic.path, terminal.transmission())
    if not ok then
      return
    end
    kitty.send(commands)
    s.lost, s.cut_key = false, nil
    pic.sent_again = vim.uv.hrtime()
  end
  if cut then
    s.cut_key = key
  end

  local quiet = M.replies and 1 or 2 -- with replies, an image the terminal has lost is reported and sent again
  local parts = { ESC .. "7" } -- save the cursor: Neovim does not know it is moved
  for index, piece in ipairs(pieces) do
    parts[#parts + 1] = ("%s[%d;%dH"):format(ESC, piece.row + 1, piece.col + 1)
    local part = crop(pic, image --[[@as PdfView.Rect]], piece, cut)
    parts[#parts + 1] = kitty.place_at(pic.id, base + index, part, quiet)
  end
  parts[#parts + 1] = ESC .. "8"
  kitty.send(table.concat(parts))
  -- the previous placements go after the new ones are up, so nothing flickers
  if placed and before > 0 then
    local first = placed.base == base and base + #pieces + 1 or placed.base + 1
    for id = first, placed.base + before do
      kitty.send(kitty.unplace(pic.id, id))
    end
  end
  s.placed = { id = pic.id, count = #pieces, key = key, base = base }
end

--- Show `pic`, which was just sent to the terminal, in place of the session's previous picture.
---@param s PdfView.Session
---@param pic PdfView.Picture
function M.show(s, pic)
  M.hook()
  local old = s.picture
  s.picture, s.lost, s.dirty, s.cut_key = pic, false, true, nil
  shown[s.buf] = s
  M.refresh(s)
  if old and old.id ~= pic.id then
    kitty.send(kitty.delete(old.id)) -- after the new page is up, so the window is never blank in between
  end
end

--- Take the picture of `s` off the screen and forget it, e.g. for a message in its place.
---@param s PdfView.Session
function M.clear(s)
  local pic = s.picture
  if pic and s.placed and s.placed.count > 0 then
    kitty.send(kitty.unplace(pic.id))
  end
  s.picture, s.placed, s.lost, s.dirty, s.cut_key = nil, nil, false, false, nil
  shown[s.buf] = nil
end

--- Forget session `s`, whose images are deleted by its owner.
---@param s PdfView.Session
function M.forget(s)
  s.picture, s.placed = nil, nil
  shown[s.buf] = nil
end

local check_pending = false

--- Mark every picture on screen as lost, to be sent again: the screen was left or scrolled under it.
local function all_lost()
  for _, s in pairs(shown) do
    if s.placed and s.placed.count > 0 then
      s.lost = true
    end
    s.dirty = true
  end
end

local function check()
  check_pending = false
  -- Without replies to tell that zellij dropped an image, a message that scrolled the screen (which may scroll the
  -- page out of zellij's screen) is taken to have done so. Neovim notes the first scroll in v:scrollstart.
  if not M.replies and vim.v.scrollstart ~= "" then
    vim.v.scrollstart = ""
    all_lost()
  end
  for _, s in pairs(shown) do
    M.refresh(s)
  end
end

local function schedule_check()
  if not check_pending then
    check_pending = true
    vim.schedule(check)
  end
end

--- Image id from a graphics protocol error reply saying that the terminal does not know the image.
---@param sequence string
---@return integer?
function M.lost_image(sequence)
  local keys = sequence:match("^\27_G([^;]*);ENOENT")
  local id = keys and keys:match("i=(%d+)")
  return id and tonumber(id)
end

local hooked = false

--- Follow the screen: re-check the placements after every redraw (that is when windows open, close, move, or get
--- drawn over), and send again an image the terminal reports lost.
function M.hook()
  if hooked then
    return
  end
  hooked = true
  vim.api.nvim_set_decoration_provider(ns, {
    on_start = function()
      if next(shown) == nil then
        return false
      end
      schedule_check() -- runs after this redraw has been sent to the terminal
      return true
    end,
    on_win = function(_, _, buf)
      local s = shown[buf]
      if s then
        s.dirty = true -- a clear or a scroll in zellij moves or drops the placement under redrawn text
      end
      return false
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = augroup,
    desc = "Send PDF pages again after Neovim was suspended",
    callback = function()
      all_lost() -- a suspended Neovim leaves the alternate screen, and zellij drops the images that were on it
      schedule_check()
    end,
  })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = augroup,
    desc = "Send a PDF page again when the terminal has lost it",
    callback = function(args)
      local sequence = (args.data and args.data.sequence) or vim.v.termresponse or ""
      local id = M.replies and M.lost_image(sequence)
      if not id then
        return
      end
      for _, s in pairs(shown) do
        local pic = s.picture
        if pic and pic.id == id and not (pic.sent_again and vim.uv.hrtime() - pic.sent_again < RESEND_GUARD) then
          s.lost, s.dirty = true, true
          schedule_check()
        end
      end
    end,
  })
end

return M
