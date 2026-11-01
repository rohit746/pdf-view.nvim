// Prints "<page count> <resolved page> <width> <height>" for one page of a document, followed by
// " <x0> <y0> <x1> <y1>" when [content] is given.
//
// Usage: mutool run page-info.js <file> <page> [content]
//
// <page> is 1-based and clamped to the document, so a huge number means "the last page". The size is the
// page's bounds in points after /Rotate, inherited boxes, /CropBox and /UserUnit have been applied, which
// is what `mutool draw` will render.
//
// (<x0>, <y0>, <x1>, <y1>) is the rectangle, in points from the page's top-left corner, that holds everything drawn
// on the page that is not white: text, images and vector graphics alike. It is found by rendering the page small and
// scanning for non-white pixels, so a white rectangle laid over the whole page does not count as content. A blank
// page gives the whole page.
var doc = Document.openDocument(scriptArgs[0]);
if (doc.needsPassword()) {
  throw new Error("this PDF is password-protected");
}
var count = doc.countPages();
var number = Math.max(1, Math.min(count, parseInt(scriptArgs[1], 10) || 1));
var page = doc.loadPage(number - 1);
var bounds = page.getBounds();
var width = bounds[2] - bounds[0];
var height = bounds[3] - bounds[1];
var line = count + " " + number + " " + width + " " + height;

// The longest side of the scan in pixels: about a point per pixel for a letter-sized page.
var SCAN = 600;
// Lighter pixels count as paper: anti-aliasing leaves a faint grey next to content, scanning noise is darker.
var WHITE = 250;

function contentBox() {
  var scale = Math.min(1, SCAN / Math.max(width, height));
  var pw = Math.max(1, Math.ceil(width * scale));
  var ph = Math.max(1, Math.ceil(height * scale));
  var pixmap = new Pixmap(ColorSpace.DeviceGray, [0, 0, pw, ph], false);
  pixmap.clear(255);
  var device = new DrawDevice(Matrix.identity, pixmap);
  // Not page.run(device, ctm): MuPDF 1.23 (Ubuntu 24.04's package) silently draws nothing that way.
  page.toDisplayList().run(device, Matrix.concat(Matrix.translate(-bounds[0], -bounds[1]), Matrix.scale(scale, scale)));
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

  return [
    left / scale,
    top / scale,
    Math.min(width, (right + 1) / scale),
    Math.min(height, (bottom + 1) / scale),
  ];
}

if (scriptArgs[2] === "content") {
  line += " " + contentBox().join(" ");
}
print(line);
