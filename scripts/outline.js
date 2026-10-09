// Prints a document's outline (bookmarks) as a flat list in reading order.
//
// Usage: mutool run outline.js <file>
//
// One line per entry: "<depth>\t<page>\t<title>", with depth 0 for top-level entries and page 1-based. Entries
// that do not point at a page of the document are skipped. A document without an outline prints nothing.
var doc = Document.openDocument(scriptArgs[0]);
var count = doc.countPages();

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
      print(depth + "\t" + (page + 1) + "\t" + (item.title || "").replace(/[\t\r\n]+/g, " "));
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
