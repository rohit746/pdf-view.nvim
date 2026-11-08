// Prints a document's outline (bookmarks) as a flat list in reading order.
//
// Usage: mutool run outline.js <file> [<width> <height> <em>]
//
// One line per entry: "<depth>\t<page>\t<x>\t<y>\t<title>", with depth 0 for top-level entries and page 1-based.
// <x> and <y> are where on the page the entry leads, as fractions of its width and height from its top-left corner,
// each empty when the entry does not say. Entries that do not point at a page of the document are skipped. A document
// without an outline prints nothing.
var doc = Document.openDocument(scriptArgs[0]);
// a password-protected document is unlocked with the first line of standard input, which `ps` does not show
if (doc.needsPassword()) {
  var password = "";
  try {
    password = readline();
  } catch (e) {
    password = "";
  }
  if (!password) {
    throw new Error("this PDF is password-protected");
  }
  if (!doc.authenticatePassword(password)) {
    throw new Error("wrong password");
  }
}
// a reflowable document is laid out as worker.js lays it out, so that the pages are the same
if (scriptArgs.length >= 4 && doc.isReflowable()) {
  doc.layout(parseFloat(scriptArgs[1]), parseFloat(scriptArgs[2]), parseFloat(scriptArgs[3]));
}
var count = doc.countPages();
var bounds = {};

// where in page `page` (0-based) the link `uri` leads, as fractions of the page: [x, y], "" for what it does not say
function destination(page, uri) {
  var dest = null;
  try {
    dest = doc.resolveLinkDestination(uri);
  } catch (e) {
    return ["", ""];
  }
  var b = bounds[page] || (bounds[page] = doc.loadPage(page).getBounds());
  function fraction(value, start, size) {
    if (typeof value !== "number" || !isFinite(value) || !(size > 0)) {
      return "";
    }
    return Math.max(0, Math.min(1, (value - start) / size)).toFixed(5);
  }
  return [fraction(dest && dest.x, b[0], b[2] - b[0]), fraction(dest && dest.y, b[1], b[3] - b[1])];
}

function walk(items, depth) {
  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    var page = -1;
    try {
      page = doc.resolveLink(item.uri);
    } catch (e) {
      page = -1;
    }
    if (page >= 0 && page < count) {
      var at = destination(page, item.uri);
      print(depth + "\t" + (page + 1) + "\t" + at.join("\t") + "\t" + (item.title || "").replace(/[\t\r\n]+/g, " "));
    }
    if (item.down) {
      walk(item.down, depth + 1);
    }
  }
}

var outline = doc.loadOutline();
if (outline) {
  walk(outline, 0);
}
