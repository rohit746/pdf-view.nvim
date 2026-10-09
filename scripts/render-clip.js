// Renders a rectangle of a page, at a given scale, to a PNG, optionally with highlighted rectangles on top. Only
// the pixels inside the rectangle are rasterised, so zooming deep into a page costs the same as rendering a
// window-sized image.
//
// Usage: mutool run render-clip.js <file> <page> <scale_x> <scale_y> <x> <y> <width> <height> <out.png> [highlights]
//
// <page> is 1-based. <scale_x> and <scale_y> are device pixels per point (equal for a zoomed view, slightly
// different when a whole page is stretched to a whole number of terminal cells). (<x>, <y>, <width>, <height>) is
// the rectangle in device pixels, measured from the top-left corner of the page as it is displayed (rotation, crop
// box and /UserUnit applied) -- the same coordinate system `mutool draw` renders into.
//
// [highlights] is "x0,y0,x1,y1,rrggbb;..." with rectangles in page points in that same displayed-page space (this
// is what Page.search() returns). They are multiplied onto the page, so dark text stays readable. MuPDF before 1.27
// cannot draw that (its JavaScript blend groups draw nothing), so there they are laid over the page as a translucent
// fill instead. Standard output says which was used: "highlights: multiply" or "highlights: translucent".
var doc = Document.openDocument(scriptArgs[0]);
var page = doc.loadPage(parseInt(scriptArgs[1], 10) - 1);
var scaleX = parseFloat(scriptArgs[2]);
var scaleY = parseFloat(scriptArgs[3]);
var x = parseInt(scriptArgs[4], 10);
var y = parseInt(scriptArgs[5], 10);
var width = parseInt(scriptArgs[6], 10);
var height = parseInt(scriptArgs[7], 10);
var highlights = scriptArgs[9] || "";

var bounds = page.getBounds();
var ctm = Matrix.concat(Matrix.translate(-bounds[0], -bounds[1]), Matrix.scale(scaleX, scaleY));

var pixmap = new Pixmap(ColorSpace.DeviceRGB, [x, y, x + width, y + height], false);
pixmap.clear(255);
var device = new DrawDevice(Matrix.identity, pixmap);
// Not page.run(device, ctm): MuPDF 1.23 (Ubuntu 24.04's package) silently draws nothing that way.
page.toDisplayList().run(device, ctm);

function rectangle(x0, y0, x1, y1) {
  var path = new Path();
  path.moveTo(x0, y0);
  path.lineTo(x1, y0);
  path.lineTo(x1, y1);
  path.lineTo(x0, y1);
  path.closePath();
  return path;
}

// Blend groups are silently ignored by MuPDF before 1.27, so find out whether they work before relying on them:
// multiplying white by black must give black.
function groupsWork() {
  var probe = new Pixmap(ColorSpace.DeviceRGB, [0, 0, 4, 4], false);
  probe.clear(255);
  var scratch = new DrawDevice(Matrix.identity, probe);
  scratch.beginGroup([0, 0, 4, 4], ColorSpace.DeviceRGB, true, false, "Multiply", 1);
  scratch.fillPath(rectangle(0, 0, 4, 4), false, Matrix.identity, ColorSpace.DeviceRGB, [0, 0, 0], 1);
  scratch.endGroup();
  scratch.close();
  return probe.getSample(2, 2, 0) < 128;
}

if (highlights) {
  var multiply = groupsWork();
  print("highlights: " + (multiply ? "multiply" : "translucent"));
  highlights.split(";").forEach(function (entry) {
    var f = entry.split(",");
    var x0 = parseFloat(f[0]) + bounds[0];
    var y0 = parseFloat(f[1]) + bounds[1];
    var x1 = parseFloat(f[2]) + bounds[0];
    var y1 = parseFloat(f[3]) + bounds[1];
    var rgb = parseInt(f[4], 16);
    var color = [((rgb >> 16) & 255) / 255, ((rgb >> 8) & 255) / 255, (rgb & 255) / 255];

    var path = rectangle(x0, y0, x1, y1);
    if (multiply) {
      device.beginGroup(Rect.transform([x0, y0, x1, y1], ctm), ColorSpace.DeviceRGB, true, false, "Multiply", 1);
      device.fillPath(path, false, ctm, ColorSpace.DeviceRGB, color, 1);
      device.endGroup();
    } else {
      device.fillPath(path, false, ctm, ColorSpace.DeviceRGB, color, 0.45);
    }
  });
}

device.close();
pixmap.saveAsPNG(scriptArgs[8]);
