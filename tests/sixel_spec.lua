local harness = require("tests.harness")
local eq, truthy = harness.eq, harness.truthy
local sixel = require("pdf-view.sixel")

--- A binary PNM of `width` x `height` pixels, coloured by `color(x, y)` (an { r, g, b }).
local function pnm(width, height, color)
  local bytes = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local c = color(x, y)
      bytes[#bytes + 1] = string.char(c[1], c[2], c[3])
    end
  end
  return ("P6\n%d %d\n255\n"):format(width, height) .. table.concat(bytes)
end

--- Decode a sixel image: its size from the raster attributes, and its pixels as "r,g,b" percentages by "x,y" (none
--- where no register drew).
local function decode(data)
  local body = data:match("^\27P0;1;0q(.*)\27\\$")
  truthy(body, "a sixel DCS")
  local width, height, rest = body:match('^"1;1;(%d+);(%d+)(.*)$')
  local palette, pixels = {}, {}
  local register, x, top = 0, 0, 0
  local index = 1
  while index <= #rest do
    local c = rest:sub(index, index)
    if c == "#" then
      local number, r, g, b, after = rest:match("^#(%d+);2;(%d+);(%d+);(%d+)()", index)
      if number then
        palette[tonumber(number)] = ("%s,%s,%s"):format(r, g, b)
      else
        number, after = rest:match("^#(%d+)()", index)
        register = tonumber(number)
      end
      index = after
    elseif c == "$" then
      x, index = 0, index + 1
    elseif c == "-" then
      x, top, index = 0, top + 6, index + 1
    else
      local count, char, after = rest:match("^!(%d+)(.)()", index)
      if not count then
        count, char, after = 1, c, index + 1
      end
      local bits = char:byte() - 63
      for _ = 1, tonumber(count) do
        for bit = 0, 5 do
          if math.floor(bits / 2 ^ bit) % 2 == 1 then
            pixels[x .. "," .. (top + bit)] = palette[register]
          end
        end
        x = x + 1
      end
      index = after
    end
  end
  return tonumber(width), tonumber(height), pixels
end

describe("sixel", function()
  it("encodes the pixels of a PNM, black text on white exactly", function()
    -- 13 rows: two full bands and one of a single row, which must not grow the image
    local data = pnm(10, 13, function(x, y)
      return (x == y or x == 9) and { 0, 0, 0 } or { 255, 255, 255 }
    end)
    local width, height, pixels = decode(sixel.encode(data))
    eq({ 10, 13 }, { width, height })
    for y = 0, 15 do
      for x = 0, 9 do
        local expected = y < 13 and ((x == y or x == 9) and "0,0,0" or "100,100,100") or nil
        eq(expected, pixels[x .. "," .. y], x .. "," .. y)
      end
    end
  end)

  it("keeps greys apart, and dithers colours the same way in every part of a picture", function()
    local _, _, pixels = decode(sixel.encode(pnm(4, 1, function()
      return { 128, 128, 128 }
    end)))
    -- the cube has 40% and 60% greys only
    eq("51,51,51", pixels["0,0"], "a grey from the grey ramp, not the colour cube")

    local function teal()
      return { 0, 128, 128 }
    end
    local _, _, whole = decode(sixel.encode(pnm(8, 8, teal)))
    local _, _, part = decode(sixel.encode(pnm(4, 4, teal), 4, 4))
    for y = 0, 3 do
      for x = 0, 3 do
        eq(whole[(x + 4) .. "," .. (y + 4)], part[x .. "," .. y], "the part's dither lines up with the whole's")
      end
    end
    local values = {}
    for _, value in pairs(whole) do
      values[value] = true
    end
    eq({ ["0,40,40"] = true, ["0,60,60"] = true }, values, "dithered between the two nearest levels")
  end)

  it("compresses runs of the same column", function()
    local encoded = sixel.encode(pnm(100, 6, function()
      return { 0, 0, 0 }
    end))
    truthy(encoded:find("!100~", 1, true), encoded)
    eq(nil, sixel.parse_pnm("P5\n1 1\n255\n\0"), "a greyscale PNM")
    eq(nil, sixel.parse_pnm("P6\n2 2\n255\n\0\0\0"), "too short")
    eq(false, (pcall(sixel.encode, "not a PNM")))
  end)
end)
