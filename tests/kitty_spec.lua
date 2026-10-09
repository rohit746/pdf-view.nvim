local harness = require("tests.harness")
local eq = harness.eq
local kitty = require("pdf-view.kitty")
local fixture = require("tests.fixture")

local ESC = "\27"

describe("kitty", function()
  it("encodes a command with sorted keys and an APC terminator", function()
    eq(ESC .. "_Ga=p,c=3,i=7,r=2;" .. ESC .. "\\", kitty.sequence({ i = 7, a = "p", c = 3, r = 2 }, ""))
    eq(ESC .. "_Ga=d,i=7" .. ESC .. "\\", kitty.sequence({ i = 7, a = "d" }))
  end)

  it("uploads by path with the file medium", function()
    local commands = kitty.transmit(42, "/tmp/page.png", "file")
    eq(1, #commands)
    eq(ESC .. "_Ga=t,f=100,i=42,q=2,t=f;" .. vim.base64.encode("/tmp/page.png") .. ESC .. "\\", commands[1])
  end)

  it("uploads bytes in 4096-byte chunks with the direct medium", function()
    local dir = fixture.tmpdir()
    local path = dir .. "/blob.png"
    local blob = string.rep("0123456789", 2000) -- 20 kB -> ~27 kB of base64
    local file = assert(io.open(path, "wb"))
    file:write(blob)
    file:close()

    local commands = kitty.transmit(5, path, "direct")
    eq(true, #commands > 1)

    local payload = {}
    for index, command in ipairs(commands) do
      local keys, data = command:match("^" .. ESC .. "_G([^;]*);(.*)" .. ESC .. "\\$")
      eq(true, #data <= 4096, "chunk size")
      payload[#payload + 1] = data
      local more = index < #commands and "1" or "0"
      eq(more, keys:match("m=(%d)"), "m flag of chunk " .. index)
      eq(index == 1, keys:find("i=5", 1, true) ~= nil, "only the first chunk names the image")
    end
    eq(blob, vim.base64.decode(table.concat(payload)))
  end)

  it("places a virtual placement without moving the cursor", function()
    eq(ESC .. "_GC=1,U=1,a=p,c=80,i=9,q=2,r=24" .. ESC .. "\\", kitty.place(9, 80, 24))
  end)

  it("deletes an image and frees its data", function()
    eq(ESC .. "_Ga=d,d=I,i=9,q=2" .. ESC .. "\\", kitty.delete(9))
  end)

  it("wraps for tmux by doubling every escape", function()
    local plain = ESC .. "_Ga=d,i=1" .. ESC .. "\\"
    eq(plain, kitty.wrap(plain, false))
    eq(ESC .. "Ptmux;" .. ESC .. ESC .. "_Ga=d,i=1" .. ESC .. ESC .. "\\" .. ESC .. "\\", kitty.wrap(plain, true))
  end)

  it("sends each command through the replaceable writer", function()
    local original = kitty.write
    local written = {}
    kitty.write = function(data)
      written[#written + 1] = data
    end
    local saved = vim.env.TMUX
    vim.env.TMUX = nil
    kitty.send({ "a", "b" })
    kitty.send("c")
    vim.env.TMUX = saved
    kitty.write = original
    eq({ "a", "b", "c" }, written)
  end)
end)
