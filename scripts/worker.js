// Keeps one document open and answers requests about it, so that turning a page does not start mutool and parse the
// document again.
//
// Usage: mutool run worker.js <file>
//
// A request is a JSON array, [<id>, <command>, <arguments>...], sent as lines of at most 200 bytes (readline() reads
// at most 255): every line but the last starts with "+", the last with ":". The answer is one line,
// "@<id> ok <result>" or "@<id> error <message>". print() does not flush standard output, so every answer is followed
// by a line of padding longer than the stdio buffer, which pushes the answer out of it. The worker exits at the end
// of its input.
//
// Commands:
//
//   ["info", <page>, <content>]
//     "<page count> <resolved page> <width> <height>", followed by " <x0> <y0> <x1> <y1>" when <content> is true.
//     <page> is 1-based and clamped to the document, so a huge number means "the last page". The size is the page's
//     bounds in points after /Rotate, inherited boxes, /CropBox and /UserUnit have been applied. (<x0>, <y0>, <x1>,
//     <y1>) is the rectangle, in points from the page's top-left corner, that holds everything drawn on the page that
//     is not white: text, images and vector graphics alike. It is found by rendering the page small and scanning for
//     non-white pixels, so a white rectangle laid over the whole page does not count as content. A blank page gives
//     the whole page.
//
//   ["draw", <page>, <width>, <height>, <out.png>]
//     Renders a whole page to a PNG of exactly <width> x <height> pixels, stretched to it.
//
//   ["render", <page>, <scale_x>, <scale_y>, <x>, <y>, <width>, <height>, <out.png>, <highlights>]
//     Renders a rectangle of a page, at a given scale, to a PNG, optionally with highlighted rectangles on top. Only
//     the pixels inside the rectangle are rasterised, so zooming deep into a page costs the same as rendering a
//     window-sized image. <scale_x> and <scale_y> are device pixels per point (equal for a zoomed view, different
//     when a whole page is stretched to a whole number of terminal cells). (<x>, <y>, <width>, <height>) is the
//     rectangle in device pixels, measured from the top-left corner of the page as it is displayed (rotation, crop
//     box and /UserUnit applied).
//
//     <highlights> is "x0,y0,x1,y1,rrggbb;..." with rectangles in page points in that same displayed-page space (this
//     is what Page.search() returns), or "". They are multiplied onto the page, so dark text stays readable. MuPDF
//     before 1.27 cannot draw that (its JavaScript blend groups draw nothing), so there they are laid over the page as
//     a translucent fill instead. The result says which was used: "highlights: multiply" or "highlights: translucent",
//     and is empty without highlights.
var path = scriptArgs[0];

// Longer than any stdio buffer (glibc and macOS use the pipe's block size: 4 KiB to 64 KiB).
var PADDING = new Array(65537).join(" ");
// The longest side of the content scan in pixels: about a point per pixel for a letter-sized page.
var SCAN = 600;
// Lighter pixels count as paper: anti-aliasing leaves a faint grey next to content, scanning noise is darker.
var WHITE = 250;
// Display lists kept, most recent last: drawing a page again (scrolling, zooming) skips interpreting it.
var KEEP = 3;

var doc = null;
var kept = [];

function openDocument() {
  if (!doc) {
    var opened = Document.openDocument(path);
    if (opened.needsPassword()) {
      throw new Error("this PDF is password-protected");
    }
    doc = opened;
  }
  return doc;
}

// The page (1-based, clamped to the document), its bounds and its display list.
function load(number) {
  var count = openDocument().countPages();
  number = Math.max(1, Math.min(count, number || 1));
  for (var i = 0; i < kept.length; i++) {
    if (kept[i].number === number) {
      var hit = kept.splice(i, 1)[0];
      kept.push(hit);
      return hit;
    }
  }
  var page = doc.loadPage(number - 1);
  // Not page.run(device, ctm): MuPDF 1.23 (Ubuntu 24.04's package) silently draws nothing that way.
  var entry = { number: number, count: count, bounds: page.getBounds(), list: page.toDisplayList() };
  kept.push(entry);
  if (kept.length > KEEP) {
    kept.shift();
  }
  return entry;
}

function contentBox(entry, width, height) {
  var bounds = entry.bounds;
  var scale = Math.min(1, SCAN / Math.max(width, height));
  var pw = Math.max(1, Math.ceil(width * scale));
  var ph = Math.max(1, Math.ceil(height * scale));
  var pixmap = new Pixmap(ColorSpace.DeviceGray, [0, 0, pw, ph], false);
  pixmap.clear(255);
  var device = new DrawDevice(Matrix.identity, pixmap);
  entry.list.run(device, Matrix.concat(Matrix.translate(-bounds[0], -bounds[1]), Matrix.scale(scale, scale)));
  device.close();

  function inked(x, y) {
    return pixmap.getSample(x, y, 0) < WHITE;
  }
  function rowInked(y) {
    for (var x = 0; x < pw; x++) {
      if (inked(x, y)) return true;
    }
    return false;
  }
  function columnInked(x, top, bottom) {
    for (var y = top; y <= bottom; y++) {
      if (inked(x, y)) return true;
    }
    return false;
  }

  // Scan inwards from each edge and stop at the first ink, so only the margins are read.
  var top = 0;
  while (top < ph && !rowInked(top)) top++;
  if (top === ph) return [0, 0, width, height];
  var bottom = ph - 1;
  while (bottom > top && !rowInked(bottom)) bottom--;
  var left = 0;
  while (left < pw - 1 && !columnInked(left, top, bottom)) left++;
  var right = pw - 1;
  while (right > left && !columnInked(right, top, bottom)) right--;

  return [left / scale, top / scale, Math.min(width, (right + 1) / scale), Math.min(height, (bottom + 1) / scale)];
}

function info(number, content) {
  var entry = load(number);
  var bounds = entry.bounds;
  var width = bounds[2] - bounds[0];
  var height = bounds[3] - bounds[1];
  var line = entry.count + " " + entry.number + " " + width + " " + height;
  if (content) {
    line += " " + contentBox(entry, width, height).join(" ");
  }
  return line;
}

function rectangle(x0, y0, x1, y1) {
  var p = new Path();
  p.moveTo(x0, y0);
  p.lineTo(x1, y0);
  p.lineTo(x1, y1);
  p.lineTo(x0, y1);
  p.closePath();
  return p;
}

// Blend groups are silently ignored by MuPDF before 1.27, so find out whether they work before relying on them:
// multiplying white by black must give black.
var multiply = null;
function groupsWork() {
  if (multiply === null) {
    var probe = new Pixmap(ColorSpace.DeviceRGB, [0, 0, 4, 4], false);
    probe.clear(255);
    var scratch = new DrawDevice(Matrix.identity, probe);
    scratch.beginGroup([0, 0, 4, 4], ColorSpace.DeviceRGB, true, false, "Multiply", 1);
    scratch.fillPath(rectangle(0, 0, 4, 4), false, Matrix.identity, ColorSpace.DeviceRGB, [0, 0, 0], 1);
    scratch.endGroup();
    scratch.close();
    multiply = probe.getSample(2, 2, 0) < 128;
  }
  return multiply;
}

function render(number, scaleX, scaleY, x, y, width, height, out, highlights) {
  var count = openDocument().countPages();
  if (!(number >= 1 && number <= count)) {
    throw new Error("page " + number + " does not exist (the document has " + count + ")");
  }
  var entry = load(number);
  var bounds = entry.bounds;
  var ctm = Matrix.concat(Matrix.translate(-bounds[0], -bounds[1]), Matrix.scale(scaleX, scaleY));

  var pixmap = new Pixmap(ColorSpace.DeviceRGB, [x, y, x + width, y + height], false);
  pixmap.clear(255);
  var device = new DrawDevice(Matrix.identity, pixmap);
  entry.list.run(device, ctm);

  var notes = "";
  if (highlights) {
    var multiplied = groupsWork();
    notes = "highlights: " + (multiplied ? "multiply" : "translucent");
    highlights.split(";").forEach(function (item) {
      var f = item.split(",");
      var x0 = parseFloat(f[0]) + bounds[0];
      var y0 = parseFloat(f[1]) + bounds[1];
      var x1 = parseFloat(f[2]) + bounds[0];
      var y1 = parseFloat(f[3]) + bounds[1];
      var rgb = parseInt(f[4], 16);
      var color = [((rgb >> 16) & 255) / 255, ((rgb >> 8) & 255) / 255, (rgb & 255) / 255];

      var shape = rectangle(x0, y0, x1, y1);
      if (multiplied) {
        device.beginGroup(Rect.transform([x0, y0, x1, y1], ctm), ColorSpace.DeviceRGB, true, false, "Multiply", 1);
        device.fillPath(shape, false, ctm, ColorSpace.DeviceRGB, color, 1);
        device.endGroup();
      } else {
        device.fillPath(shape, false, ctm, ColorSpace.DeviceRGB, color, 0.45);
      }
    });
  }

  device.close();
  pixmap.saveAsPNG(out);
  return notes;
}

function answer(request) {
  switch (request[1]) {
    case "info":
      return info(request[2], request[3]);
    case "draw":
      var bounds = load(request[2]).bounds;
      var sx = request[3] / (bounds[2] - bounds[0]);
      var sy = request[4] / (bounds[3] - bounds[1]);
      return render(request[2], sx, sy, 0, 0, request[3], request[4], request[5], "");
    case "render":
      return render(
        request[2],
        request[3],
        request[4],
        request[5],
        request[6],
        request[7],
        request[8],
        request[9],
        request[10]
      );
  }
  throw new Error("unknown command: " + request[1]);
}

var text = "";
for (;;) {
  var line;
  try {
    line = readline();
  } catch (e) {
    break; // the end of the input: Neovim has let go of this worker
  }
  text += line.slice(1);
  if (line.charAt(0) === "+") {
    continue;
  }
  var request = null;
  var reply;
  try {
    request = JSON.parse(text);
    reply = "ok " + answer(request);
  } catch (e) {
    reply = "error " + String((e && e.message) || e).replace(/[\r\n]+/g, " ");
  }
  text = "";
  print("@" + (request ? request[0] : 0) + " " + reply);
  print(PADDING);
}
