local harness = require("tests.harness")
local eq = harness.eq
local synctex = require("pdf-view.synctex")

describe("synctex", function()
  it("reads the boxes a line was typeset into from `synctex view`", function()
    local stdout = table.concat({
      "This is SyncTeX command line utility, version 1.5",
      "SyncTeX result begin",
      "Output:/tmp/doc/main.pdf",
      "Page:2",
      "x:187.765869",
      "y:168.601929",
      "h:133.768372",
      "v:170.654221",
      "W:343.711060",
      "H:9.185539",
      "before:",
      "offset:-1",
      "middle:",
      "after:",
      "Output:/tmp/doc/main.pdf",
      "Page:3",
      "x:72",
      "y:80",
      "h:72",
      "v:80",
      "W:100",
      "H:10",
      "SyncTeX result end",
    }, "\n")
    local boxes = synctex.parse_view(stdout)
    eq(2, #boxes)
    eq(2, boxes[1].page)
    harness.near(133.768372, boxes[1].rect[1], 1e-6)
    harness.near(170.654221 - 9.185539, boxes[1].rect[2], 1e-6)
    harness.near(133.768372 + 343.711060, boxes[1].rect[3], 1e-6)
    harness.near(170.654221, boxes[1].rect[4], 1e-6)
    eq({ page = 3, rect = { 72, 70, 172, 80 } }, boxes[2])
  end)

  it("finds no boxes when SyncTeX knows nothing of the line", function()
    eq({}, synctex.parse_view("This is SyncTeX command line utility, version 1.5\nSyncTeX Warning: No tag for x.tex\n"))
  end)

  it("reads the source line from `synctex edit`, relative to the PDF's directory", function()
    local stdout = table.concat({
      "SyncTeX result begin",
      "Output:main.pdf",
      "Input:/tmp/doc/./chapter.tex",
      "Line:10",
      "Column:-1",
      "Offset:0",
      "Context:",
      "SyncTeX result end",
    }, "\n")
    eq({ file = "/tmp/doc/chapter.tex", line = 10, column = 0 }, synctex.parse_edit(stdout, "/tmp/doc"))
    eq(
      { file = "/tmp/doc/sub/main.tex", line = 3, column = 5 },
      synctex.parse_edit("Input:./sub/main.tex\nLine:3\nColumn:5\n", "/tmp/doc")
    )
    eq(nil, synctex.parse_edit("This is SyncTeX command line utility, version 1.5\n", "/tmp/doc"))
  end)
end)
