--- Positioned placements, for zellij and for the terminals that implement the Kitty graphics protocol but not Unicode
--- placeholders (WezTerm, Konsole).
---
--- Instead of placeholder text the buffer holds blank lines, and the page is placed at the screen position of its
--- window. Neovim knows nothing about such an image, so this module keeps it in step with the screen: the image is
--- cut around floating windows and the popup menu that cover it, it is taken away while its window is hidden, and it
--- is placed again after Neovim redraws the window (a clear or a scroll moves or drops a placement).
---
--- zellij also forgets an image once nothing shows it any more, so there an image that was taken away or cleared off
--- the screen is sent again before it is placed again. A terminal keeps its images until they are deleted, and says
--- so when it has lost one (see `hook()`).
---
--- iTerm2 inline images (see `iterm2`) and sixel images (see `sixel`) are printed into the cells instead, and cannot
--- be cut or taken away by id: a piece cut around a float is an image of its own, cropped by mutool, the image is
--- printed again after every redraw of its window (which may have written over it), and what it leaves behind is
--- erased (see `refresh_printed()`). A sixel image is drawn pixel for pixel, so every piece of it, the whole page
--- too, is cut out at its size on screen and encoded once.
local iterm2 = require("pdf-view.iterm2")
local kitty = require("pdf-view.kitty")
local mupdf = require("pdf-view.mupdf")
local sixel = require("pdf-view.sixel")
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
---@field crops? table<string, string|boolean> printed images: the file of each part cut out of it (a PNG for iTerm2,
--- the encoded sixel), by the part's rectangle in image pixels and its size on screen; true while mutool cuts it,
--- false when it could not

---@class PdfView.Rect
---@field row integer 0-based screen row of the top edge
---@field col integer 0-based screen column of the left edge
---@field rows integer
---@field cols integer

---@type table<integer, PdfView.Session> sessions with a picture, by buffer
local shown = {}

-- tmux shows another window than Neovim's: the terminal under tmux would still show the page there
local tmux_hidden = false

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
--- Also the window, and its text area on screen.
---@param s PdfView.Session
---@return PdfView.Rect[] pieces, PdfView.Rect? image, integer? win, PdfView.Rect? area
local function visible(s)
  local pic, win = s.picture, target_window(s)
  if not (pic and win) or tmux_hidden then
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
  local area = { row = top, col = left, rows = area_rows, cols = area_cols }

  local image = { row = top + pic.row, col = left + pic.col, rows = pic.rows, cols = pic.cols }
  -- the window can be smaller than the image until the page is fitted to it again. An image printed down to the
  -- last row could scroll the screen, in a terminal that moves the cursor below it.
  local lines = terminal.printed() and vim.o.lines - 1 or vim.o.lines
  local row0, col0 = math.max(image.row, top, 0), math.max(image.col, left, 0)
  local row1 = math.min(image.row + image.rows, top + area_rows, lines)
  local col1 = math.min(image.col + image.cols, left + area_cols, vim.o.columns)
  if row1 <= row0 or col1 <= col0 then
    return {}, nil, win, area
  end
  local clipped = { row = row0, col = col0, rows = row1 - row0, cols = col1 - col0 }
  return M.subtract(clipped, covers(win)), image, win, area
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

local refresh_printed

--- Put the picture of `s` where it belongs on screen, if that changed or `s.dirty` says the screen may have lost it.
---@param s PdfView.Session
function M.refresh(s)
  local pic = s.picture
  if s.closed or not pic then
    return
  end
  if terminal.printed() then
    return refresh_printed(s)
  end
  local pieces, image = visible(s)
  local zellij = terminal.in_zellij()
  -- zellij 0.45.1 draws a part of an image from the image's top-left corner, wherever the part starts, unless the part
  -- is scaled to a size in cells. It keeps one scaled copy per size and image: the parts of a page cut around a float
  -- get sizes of their own, and the page is sent again when they change, to drop the copies cut for the last float.
  local cut = zellij
    and (#pieces > 1 or (#pieces == 1 and image ~= nil and (pieces[1].row ~= image.row or pieces[1].col ~= image.col)))
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
      s.lost = zellij -- zellij frees an image along with its last placement
    end
    s.placed = { id = pic.id, count = 0, key = key, base = 0 }
    return
  end

  if cut and s.cut_key and s.cut_key ~= key then
    s.lost = true
  end
  if s.lost then
    local ok, commands = vim.uv.fs_stat(pic.path) ~= nil, {} ---@type boolean, string[]
    if ok then
      ok, commands = pcall(kitty.transmit, pic.id, pic.path, terminal.transmission())
    end
    if not ok then
      -- the PNG is gone or cannot be read: the page is rendered and sent anew, or a message says why it cannot be
      s.picture, s.placed = nil, nil
      shown[s.buf] = nil
      return M.rerender(s)
    end
    kitty.send(commands)
    s.lost, s.cut_key = false, nil
    pic.sent_again = vim.uv.hrtime()
  end
  if cut then
    s.cut_key = key
  end

  local quiet = M.replies and 1 or 2 -- with replies, an image the terminal has lost is reported and sent again
  local over = terminal.hides_images_under_text()
  -- inside tmux the placement goes to the outer terminal, where the pane may not start in the top-left corner
  local top, left = terminal.pane_offset()
  local parts = { ESC .. "7" } -- save the cursor: Neovim does not know it is moved
  for index, piece in ipairs(pieces) do
    parts[#parts + 1] = ("%s[%d;%dH"):format(ESC, top + piece.row + 1, left + piece.col + 1)
    local part = crop(pic, image --[[@as PdfView.Rect]], piece, cut)
    parts[#parts + 1] = kitty.place_at(pic.id, base + index, part, quiet, over)
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

--- Remove the PNGs cut out of `pic`.
---@param pic? PdfView.Picture
local function drop_crops(pic)
  for _, file in pairs(pic and pic.crops or {}) do
    if type(file) == "string" then
      os.remove(file)
    end
  end
end

local redraw_screen, schedule_check

--- Where the iTerm2 image of `s` was printed, outside `keep`: the cells it left behind. `outside` when some are not
--- in the text area of its window, where Neovim may have drawn anything since. The ones under a float are left out:
--- Neovim drew the float over them.
---@param s PdfView.Session
---@param keep PdfView.Rect[]
---@param win? integer
---@param area? PdfView.Rect
---@return PdfView.Rect[] stale, boolean outside
local function leftovers(s, keep, win, area)
  local stale, outside = {}, false
  local holes = win and vim.list_extend(vim.deepcopy(keep), covers(win)) or keep
  for _, rect in ipairs(s.placed and s.placed.rects or {}) do
    for _, rest in ipairs(M.subtract(rect, holes)) do
      if
        area
        and rest.row >= area.row
        and rest.col >= area.col
        and rest.row + rest.rows <= area.row + area.rows
        and rest.col + rest.cols <= area.col + area.cols
      then
        stale[#stale + 1] = rest
      else
        outside = true
      end
    end
  end
  return stale, outside
end

--- The SGR parameters of the background Neovim draws the blank cells of `win` with.
---@param win integer
---@return string
function M.background(win)
  local mapped = {}
  for from, to in vim.wo[win].winhighlight:gmatch("([^,:]+):([^,]+)") do
    mapped[from] = to
  end
  local groups = {}
  if win ~= vim.api.nvim_get_current_win() then
    groups[#groups + 1] = "NormalNC"
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    groups[#groups + 1] = "NormalFloat"
  end
  groups[#groups + 1] = "Normal"
  for _, group in ipairs(groups) do
    local hl = vim.api.nvim_get_hl(0, { name = mapped[group] or group, link = false })
    if vim.o.termguicolors and hl.bg then
      return ("48;2;%d;%d;%d"):format(math.floor(hl.bg / 65536), math.floor(hl.bg / 256) % 256, hl.bg % 256)
    elseif not vim.o.termguicolors and hl.ctermbg then
      return ("48;5;%d"):format(hl.ctermbg)
    end
  end
  return "49"
end

--- Command that erases the cells of `rects` in the background of `win`'s blank cells, so that they look as Neovim
--- thinks they do. The cursor and its attributes are restored afterwards.
---@param rects PdfView.Rect[]
---@param win integer
---@return string
function M.erase(rects, win)
  local top, left = terminal.pane_offset()
  local parts = { ESC .. "7", ESC .. "[0;" .. M.background(win) .. "m" }
  for _, rect in ipairs(rects) do
    for row = rect.row, rect.row + rect.rows - 1 do
      parts[#parts + 1] = ("%s[%d;%dH%s[%dX"):format(ESC, top + row + 1, left + rect.col + 1, ESC, rect.cols)
    end
  end
  parts[#parts + 1] = ESC .. "8"
  return table.concat(parts)
end

--- Show `pic`, which was just sent to the terminal, in place of the session's previous picture.
---@param s PdfView.Session
---@param pic PdfView.Picture
function M.show(s, pic)
  M.hook()
  local old = s.picture
  s.picture, s.lost, s.dirty, s.cut_key = pic, false, true, nil
  shown[s.buf] = s
  if terminal.printed() then
    pic.crops = {}
    -- printed over the old one, erasing what that leaves uncovered, once Neovim has drawn the window: that may
    -- write over it, and it would have to be printed again
    schedule_check()
    if old ~= pic then
      drop_crops(old)
    end
    return
  end
  M.refresh(s)
  if old and old.id ~= pic.id then
    kitty.send(kitty.delete(old.id)) -- after the new page is up, so the window is never blank in between
  end
end

--- Take the picture of `s` off the screen and forget it, e.g. for a message in its place.
---@param s PdfView.Session
function M.clear(s)
  local pic = s.picture
  if terminal.printed() then
    if s.placed and not tmux_hidden then
      local _, _, win, area = visible(s)
      local stale, outside = leftovers(s, {}, win, area)
      if outside then
        redraw_screen()
      elseif #stale > 0 then
        kitty.send(M.erase(stale, win --[[@as integer]]))
      end
    end
    drop_crops(pic)
  elseif pic and s.placed and s.placed.count > 0 then
    kitty.send(kitty.unplace(pic.id))
  end
  s.picture, s.placed, s.lost, s.dirty, s.cut_key = nil, nil, false, false, nil
  shown[s.buf] = nil
end

--- Forget session `s`, whose images are deleted by its owner.
---@param s PdfView.Session
function M.forget(s)
  if terminal.printed() then
    if s.placed and s.placed.rects and #s.placed.rects > 0 and not tmux_hidden then
      redraw_screen() -- its window shows something else now, which may leave some of the page uncovered
    end
    drop_crops(s.picture)
  end
  s.picture, s.placed = nil, nil
  shown[s.buf] = nil
end

local check_pending = false

--- Mark every picture on screen as lost, to be sent again: the screen was left or scrolled under it.
local function all_lost()
  local printed = terminal.printed()
  for _, s in pairs(shown) do
    if printed then
      s.placed = nil -- the screen was drawn again from scratch, which took the image away
    elseif s.placed and s.placed.count > 0 then
      s.lost = true
    end
    s.dirty = true
  end
end

--- Mark every picture as possibly misplaced, to be placed again.
local function all_dirty()
  for _, s in pairs(shown) do
    s.dirty = true
  end
end

--- Whether a hit-enter or more prompt is up: a message over the screen, which an image printed now would hide.
---@return boolean
local function prompting()
  return vim.fn.mode():sub(1, 1) == "r"
end

local function check()
  check_pending = false
  -- Without replies to tell that zellij dropped an image, a message that scrolled the screen (which may scroll the
  -- page out of zellij's screen) is taken to have done so. A terminal scrolls the image with the text, and it is
  -- placed again where it belongs after the redraw. Neovim notes the first scroll in v:scrollstart.
  if not M.replies and vim.v.scrollstart ~= "" and terminal.in_zellij() then
    vim.v.scrollstart = ""
    all_lost()
  end
  -- A message that scrolled the screen took iTerm2 images with it in some terminals (VS Code), and Neovim puts back
  -- what was under the message without drawing the lines of the window again. Once the message has gone, the pages
  -- are printed again.
  if vim.v.scrollstart ~= "" and terminal.printed() and not prompting() then
    vim.v.scrollstart = ""
    all_lost()
  end
  for _, s in pairs(shown) do
    M.refresh(s)
  end
end

schedule_check = function()
  if not check_pending then
    check_pending = true
    vim.schedule(check)
  end
end

local crop_counter = 0

--- The file to print the part `part` of the picture of `s` from: nil while mutool cuts it out (`s` is refreshed once
--- it has), false when it could not. For iTerm2 it is a PNG, which the terminal stretches to the part's cells. For
--- sixel it is the part stretched to `size` (in screen pixels) and encoded, with the dither starting at `offset`.
---@param s PdfView.Session
---@param pic PdfView.Picture
---@param part PdfView.Crop
---@param size? integer[] sixel: width and height on screen
---@param offset? integer[] sixel: where the part starts on screen, in pixels from the picture's top-left corner
---@return string|false|nil
local function cut(s, pic, part, size, offset)
  local crops = pic.crops or {}
  pic.crops = crops
  local name = ("%d,%d,%d,%d"):format(part.x, part.y, part.w, part.h)
  if size then
    name = ("%s:%dx%d"):format(name, size[1], size[2])
  end
  local file = crops[name]
  if type(file) == "string" and vim.uv.fs_stat(file) then
    return file
  elseif file == false then
    return false -- it could not be cut
  elseif file == true then
    return nil -- it is being cut
  end
  crops[name] = true
  crop_counter = crop_counter + 1
  local out = ("%s/pdf-view-%d-part-%d.%s"):format(
    vim.fs.dirname(vim.fn.tempname()),
    s.buf,
    crop_counter,
    size and "pnm" or "png"
  )
  mupdf.crop(s.path, pic.path, part, out, function(err)
    if s.closed or s.picture ~= pic then
      os.remove(out)
      return
    end
    local result = (not err and out or false) --[[@as string|false]]
    if result and size then
      -- encoded once, here: printing it again only reads the file
      local encoded = out:gsub("%.pnm$", ".six")
      local ok = pcall(function()
        local data = sixel.encode_file(out, offset and offset[1], offset and offset[2])
        local file_out = assert(io.open(encoded, "wb"))
        file_out:write(data)
        file_out:close()
      end)
      os.remove(out)
      result = ok and encoded or false
    end
    crops[name] = result
    s.dirty = true
    schedule_check()
  end, size)
  return nil
end

--- Command that prints the file `file` of a part (see `cut()`) at the cursor, over `cols` x `rows` cells.
---@param file string
---@param cols integer
---@param rows integer
---@return string
local function print_part(file, cols, rows)
  if terminal.protocol() == "sixel" then
    local handle = assert(io.open(file, "rb"))
    local data = handle:read("*a")
    handle:close()
    return data
  end
  return iterm2.image_file(file, cols, rows)
end

--- `refresh()` for printed images (iTerm2, sixel): print the pieces of the picture of `s` that are on screen, each as
--- an image of its own, and erase what it left behind elsewhere. They are printed again whenever `s.dirty` says that
--- Neovim drew the window again, which may have written over them.
---@param s PdfView.Session
refresh_printed = function(s)
  local pic = s.picture --[[@as PdfView.Picture]]
  if tmux_hidden then
    s.placed = nil -- tmux drew another window over the page: nothing of it is left on screen
    return
  elseif prompting() then
    return -- printed once the message has gone
  end
  local pieces, image, win, area = visible(s)
  local key = key_of(s, pieces)
  local placed = s.placed
  if not s.dirty and placed and placed.key == key then
    return
  end

  local files = {}
  local pixels = terminal.protocol() == "sixel" and terminal.cell_size() or nil
  for index, piece in ipairs(pieces) do
    local whole = image
      and piece.row == image.row
      and piece.col == image.col
      and piece.rows == image.rows
      and piece.cols == image.cols
    if whole and not pixels then
      files[index] = pic.path
    else
      local size, offset
      if pixels then
        -- cells are whole pixels; what the terminal reports can include its padding, which makes them a fraction
        -- larger, and a page that size would reach into the row below
        local w, h = math.max(1, math.floor(pixels.w)), math.max(1, math.floor(pixels.h))
        ---@cast image PdfView.Rect
        size = { piece.cols * w, piece.rows * h }
        offset = { (piece.col - image.col) * w, (piece.row - image.row) * h }
      end
      local file = cut(s, pic, crop(pic, image --[[@as PdfView.Rect]], piece, true), size, offset)
      if file == nil then
        return -- printed once every piece is cut out; until then the old one stays
      end
      files[index] = file
    end
  end

  local stale, outside = leftovers(s, pieces, win, area)
  if outside then
    -- Neovim may have drawn anything there since, and would not draw it again: draw the whole screen again
    s.placed, s.dirty = nil, true
    return redraw_screen()
  end
  if #pieces > 0 and not vim.uv.fs_stat(pic.path) then
    s.picture, s.placed = nil, nil
    shown[s.buf] = nil
    return M.rerender(s)
  end
  s.dirty = false

  local commands = {}
  if #stale > 0 then
    commands[1] = M.erase(stale, win --[[@as integer]])
  end
  local top, left = terminal.pane_offset()
  for index, piece in ipairs(pieces) do
    local file = files[index]
    local ok, command = false, nil
    if file then
      ok, command = pcall(print_part, file, piece.cols, piece.rows)
    end
    if ok then
      -- the cursor is saved and restored around each print: Neovim does not know it is moved
      commands[#commands + 1] = ("%s7%s[%d;%dH%s%s8"):format(
        ESC,
        ESC,
        top + piece.row + 1,
        left + piece.col + 1,
        command,
        ESC
      )
    end
  end
  kitty.send(commands)
  s.placed = { id = pic.id, count = #pieces, key = key, base = 0, rects = pieces }
end

local redraw_pending = false

--- Clear the screen and draw it again (`:mode`), which erases every iTerm2 image on it, and print them again
--- afterwards. `:redraw!` would not do: Neovim draws again only the cells that differ from what it drew before.
redraw_screen = function()
  if redraw_pending then
    return
  end
  redraw_pending = true
  local function go()
    if prompting() then
      return vim.defer_fn(go, 100) -- clearing the screen would take the message away
    end
    redraw_pending = false
    for _, s in pairs(shown) do
      s.placed, s.dirty = nil, true
    end
    vim.cmd.mode()
  end
  vim.schedule(go)
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
      if not s then
        return false
      elseif terminal.printed() then
        return true -- an iTerm2 image is written over only by lines drawn over it (see on_line)
      end
      s.dirty = true -- a clear or a scroll in zellij moves or drops the placement under redrawn text
      return false
    end,
    on_line = function(_, _, buf)
      local s = shown[buf]
      if s then
        -- the line may differ from what Neovim drew before (a message in the window, a clear), and the terminal then
        -- writes over the image: it is printed again. A redraw of only the winbar leaves it alone.
        s.dirty = true
      end
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
  if terminal.printed() then
    vim.api.nvim_create_autocmd("VimResized", {
      group = augroup,
      desc = "Print PDF pages again after the terminal was resized",
      callback = function()
        all_lost() -- Neovim draws the resized screen from scratch
        schedule_check()
      end,
    })
  end
  if terminal.in_tmux() then
    -- tmux knows nothing of the page, which stays on the terminal's screen over another tmux window. With tmux's
    -- `focus-events` on, leaving the pane says so.
    vim.api.nvim_create_autocmd({ "FocusLost", "FocusGained", "VimResized" }, {
      group = augroup,
      desc = "Follow the tmux pane of PDF pages: where it is, and whether its window is on screen",
      callback = function(args)
        if args.event == "FocusLost" then
          terminal.tmux_window_shown(function(on_screen)
            if not on_screen and not tmux_hidden then
              tmux_hidden = true
              all_dirty()
              schedule_check()
            end
          end)
          return
        end
        terminal.pane_offset(true)
        if args.event == "FocusGained" then
          tmux_hidden = false
        end
        all_dirty()
        schedule_check()
      end,
    })
  end
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
