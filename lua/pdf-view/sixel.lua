--- Encoding of sixel images, which foot, Windows Terminal, xterm (as a VT340), Contour, mlterm, WezTerm and Konsole
--- draw.
---
--- A sixel image is printed into the cells at the cursor, like an iTerm2 image (see `iterm2`): it has no id, and it is
--- printed again to move it (see `positioned`). It is drawn pixel for pixel, so it is encoded at the size it takes on
--- screen. mutool cannot write sixel; it writes the pixels as a PNM (`mupdf.crop()`), and they are encoded here.
---
--- The palette is fixed, so that the pieces of a page cut around a float match each other: a ramp of greys, which
--- is what most of a page is (black text on white, and its anti-aliasing), and a 6x6x6 colour cube for the rest,
--- dithered with a 4x4 Bayer matrix.
local M = {}

local ESC = "\27"

local byte, char, rep, floor = string.byte, string.char, string.rep, math.floor

-- registers 0..215 are the colour cube, 216.. the grey ramp
local CUBE = 216
local GREYS = 40
-- a pixel whose channels are this close together is grey
local GREY_SPREAD = 12

local BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

-- the level (0..5) of a channel value v at the dither threshold t: CUBE_LEVEL[t * 256 + v + 1]
local CUBE_LEVEL = {}
for t = 0, 15 do
  local threshold = (BAYER[t + 1] + 0.5) / 16
  for v = 0, 255 do
    CUBE_LEVEL[t * 256 + v + 1] = math.min(5, floor(v * 5 / 255 + threshold))
  end
end
-- the register of the grey nearest to v
local GREY_REGISTER = {}
for v = 0, 255 do
  GREY_REGISTER[v + 1] = CUBE + floor(v * (GREYS - 1) / 255 + 0.5)
end

--- The colour of register `index`, in sixel's percentages.
---@param index integer
---@return integer r, integer g, integer b
local function color(index)
  local function percent(level, levels)
    return floor(level * 100 / (levels - 1) + 0.5)
  end
  if index >= CUBE then
    local grey = percent(index - CUBE, GREYS)
    return grey, grey, grey
  end
  return percent(floor(index / 36), 6), percent(floor(index / 6) % 6, 6), percent(index % 6, 6)
end

--- The size and the offset of the pixels of a binary PNM (P6, 8 bits), or nil when `data` is not one.
---@param data string
---@return integer? width, integer? height, integer? offset 1-based index of the first pixel's first byte
function M.parse_pnm(data)
  local width, height, maxval, offset = data:match("^P6%s+(%d+)%s+(%d+)%s+(%d+)%s()")
  if not width or tonumber(maxval) ~= 255 then
    return nil
  end
  width, height = tonumber(width), tonumber(height)
  if #data < offset - 1 + width * height * 3 then
    return nil
  end
  return width, height, offset
end

--- Command that prints the pixels of the PNM `data` as a sixel image at the cursor, one pixel per screen pixel.
--- `dx` and `dy` are where the image starts in the picture it is a part of, so that the dither of the parts of a
--- picture lines up. Raises when `data` is not a binary 8-bit PNM.
---@param data string
---@param dx? integer
---@param dy? integer
---@return string
function M.encode(data, dx, dy)
  local width, height, offset = M.parse_pnm(data)
  if not width then
    error("not a binary PNM")
  end
  dx, dy = dx or 0, dy or 0
  local stride = width * 3

  local used = {} ---@type table<integer, boolean>
  local out = {}
  -- per register, the sixel of each column of the band being encoded, and the registers the band uses
  local masks = {} ---@type table<integer, integer[]>
  local band_colors = {} ---@type integer[]
  local in_band = {} ---@type table<integer, integer>

  for top = 0, height - 1, 6 do
    local count = 0
    local band = top / 6 + 1
    for row = top, math.min(top + 5, height - 1) do
      local bit = 2 ^ (row - top)
      local base = offset + row * stride
      local dither = ((row + dy) % 4) * 4
      for x = 0, width - 1 do
        local i = base + x * 3
        local r, g, b = byte(data, i, i + 2)
        local high, low = r, r
        if g > high then
          high = g
        elseif g < low then
          low = g
        end
        if b > high then
          high = b
        elseif b < low then
          low = b
        end
        local register
        if high - low <= GREY_SPREAD then
          register = GREY_REGISTER[floor((r + g + b) / 3) + 1]
        else
          local t = (dither + (x + dx) % 4) * 256 + 1
          register = CUBE_LEVEL[t + r] * 36 + CUBE_LEVEL[t + g] * 6 + CUBE_LEVEL[t + b]
        end
        local mask = masks[register]
        if in_band[register] ~= band then
          in_band[register] = band
          count = count + 1
          band_colors[count] = register
          if not mask then
            mask = {}
            masks[register] = mask
          end
          for column = 1, width do
            mask[column] = 0
          end
        end
        ---@cast mask integer[]
        mask[x + 1] = mask[x + 1] + bit -- every pixel of a column is one bit of one register
      end
    end

    for index = 1, count do
      local register = band_colors[index]
      used[register] = true
      local mask = masks[register]
      out[#out + 1] = "#" .. register
      -- columns of the same sixel are run-length encoded; empty ones at the end are left out
      local last = width
      while last > 0 and mask[last] == 0 do
        last = last - 1
      end
      local x = 1
      while x <= last do
        local value = mask[x]
        local run = x
        while run < last and mask[run + 1] == value do
          run = run + 1
        end
        local length = run - x + 1
        local sixel = char(63 + value)
        if length > 3 then
          out[#out + 1] = "!" .. length .. sixel
        else
          out[#out + 1] = rep(sixel, length)
        end
        x = run + 1
      end
      out[#out + 1] = index < count and "$" or "-" -- back to the band's start for the next register, or the next band
    end
    if count == 0 then
      out[#out + 1] = "-"
    end
  end

  local palette = {}
  for register = 0, CUBE + GREYS - 1 do
    if used[register] then
      local r, g, b = color(register)
      palette[#palette + 1] = ("#%d;2;%d;%d;%d"):format(register, r, g, b)
    end
  end
  -- P2 = 1: pixels no register is drawn in are left alone. The raster attributes give the aspect ratio (1:1) and
  -- the size, so a band that sticks out below the image is not part of it.
  return ESC
    .. "P0;1;0q"
    .. ('"1;1;%d;%d'):format(width, height)
    .. table.concat(palette)
    .. table.concat(out)
    .. ESC
    .. "\\"
end

--- `encode()` of the PNM at `path`. Raises when the file cannot be read.
---@param path string
---@param dx? integer
---@param dy? integer
---@return string
function M.encode_file(path, dx, dy)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return M.encode(data, dx, dy)
end

return M
