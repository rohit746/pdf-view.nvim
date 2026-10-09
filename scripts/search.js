// Finds every occurrence of a string in a document.
//
// Usage: mutool run search.js <file> <needle> <max hits>
//
// Prints one line per hit, in reading order:
//
//   <page> <hit> <page width> <page height> <x0,y0,x1,y1>;<x0,y0,x1,y1>...
//
// <page> is 1-based. A hit that wraps over several lines has one rectangle per line. Rectangles are in points,
// measured from the top-left corner of the displayed page: the space `render-clip.js` draws highlights in. The
// search ignores case. If <max hits> was reached a final line "truncated" is printed.
var doc = Document.openDocument(scriptArgs[0]);
var needle = scriptArgs[1];
var limit = parseInt(scriptArgs[2], 10) || 5000;
var count = doc.countPages();
var total = 0;

// bounding rectangle of a quad, measured from the page's top-left corner
function rect(quad, bounds) {
  var xs = [quad[0], quad[2], quad[4], quad[6]];
  var ys = [quad[1], quad[3], quad[5], quad[7]];
  return [
    Math.min.apply(null, xs) - bounds[0],
    Math.min.apply(null, ys) - bounds[1],
    Math.max.apply(null, xs) - bounds[0],
    Math.max.apply(null, ys) - bounds[1],
  ]
    .map(function (v) {
      return v.toFixed(2);
    })
    .join(",");
}

if (needle) {
  for (var i = 0; i < count && total < limit; i++) {
    var page = doc.loadPage(i);
    var bounds = page.getBounds();
    var hits = page.search(needle);
    for (var h = 0; h < hits.length && total < limit; h++) {
      var rects = hits[h].map(function (quad) {
        return rect(quad, bounds);
      });
      print((i + 1) + " " + h + " " + (bounds[2] - bounds[0]) + " " + (bounds[3] - bounds[1]) + " " + rects.join(";"));
      total++;
    }
  }
}
if (total >= limit) {
  print("truncated");
}
