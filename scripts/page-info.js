// Prints "<page count> <resolved page> <width> <height>" for one page of a document.
//
// Usage: mutool run page-info.js <file> <page>
//
// <page> is 1-based and clamped to the document, so a huge number means "the last page". The size is the
// page's bounds in points after /Rotate, inherited boxes, /CropBox and /UserUnit have been applied, which
// is what `mutool draw` will render.
var doc = Document.openDocument(scriptArgs[0]);
var count = doc.countPages();
var page = Math.max(1, Math.min(count, parseInt(scriptArgs[1], 10) || 1));
var bounds = doc.loadPage(page - 1).getBounds();
print(count + " " + page + " " + (bounds[2] - bounds[0]) + " " + (bounds[3] - bounds[1]));
