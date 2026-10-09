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
// is what Page.search() returns). They are multiplied onto the page, so dark text stays readable.
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
page.run(device, ctm);

if (highlights) {
  highlights.split(";").forEach(function (entry) {
    var f = entry.split(",");
    var x0 = parseFloat(f[0]) + bounds[0];
    var y0 = parseFloat(f[1]) + bounds[1];
    var x1 = parseFloat(f[2]) + bounds[0];
    var y1 = parseFloat(f[3]) + bounds[1];
    var rgb = parseInt(f[4], 16);
    var color = [((rgb >> 16) & 255) / 255, ((rgb >> 8) & 255) / 255, (rgb & 255) / 255];

    var path = new Path();
    path.moveTo(x0, y0);
    path.lineTo(x1, y0);
    path.lineTo(x1, y1);
    path.lineTo(x0, y1);
    path.closePath();
    device.beginGroup(Rect.transform([x0, y0, x1, y1], ctm), ColorSpace.DeviceRGB, true, false, "Multiply", 1);
    device.fillPath(path, false, ctm, ColorSpace.DeviceRGB, color, 1);
    device.endGroup();
  });
}

device.close();
pixmap.saveAsPNG(scriptArgs[8]);
