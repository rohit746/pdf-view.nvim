// Finds every occurrence of a string in a document.
//
// Usage: mutool run search.js <file> <needle> <max hits> [<width> <height> <em>]
//
// Prints one line per hit, in reading order:
//
//   <page> <hit> <page width> <page height> <x0,y0,x1,y1>;<x0,y0,x1,y1>...\t<text>
//
// <page> is 1-based. A hit that wraps over several lines has one rectangle per line. Rectangles are in points,
// measured from the top-left corner of the displayed page: the space `worker.js` draws highlights in. <text> is the
// line of text that the hit starts on, with its white space collapsed and, on a long line, cut down to the part around
// the hit ("…" marks a cut); it is empty when that line is not found. The search ignores case. If there are more than
// <max hits> hits, a final line "truncated" is printed.
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
if (scriptArgs.length >= 6 && doc.isReflowable()) {
  doc.layout(parseFloat(scriptArgs[3]), parseFloat(scriptArgs[4]), parseFloat(scriptArgs[5]));
}
var needle = scriptArgs[1];
var limit = parseInt(scriptArgs[2], 10) || 5000;
var count = doc.countPages();
var total = 0;
var truncated = false;

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

// characters of context kept before a hit, and in all, when the line it is on is cut down
var BEFORE = 30;
var WIDTH = 80;

// The bounding boxes of the lines of a page's structured text. Only beginLine is walked: a walker that takes every
// character is many times slower.
function linesOf(structured) {
  var lines = [];
  structured.walk({
    beginLine: function (bbox) {
      lines.push({ bbox: bbox });
    },
  });
  return lines;
}

// The text between two points of the page, on one line with its white space collapsed.
function copyText(structured, from, to) {
  return String(structured.copy(from, to) || "")
    .replace(/[\s\u0000-\u001f\u007f]+/g, " ")
    .trim();
}

// Whether the box <b> holds the point <x>, <y>.
function holds(b, x, y) {
  return x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3];
}

// The line that holds the point <x>, <y>: the smallest line whose box holds it, or else the nearest line. <near> is
// the index of the line the previous hit was on, which the next hit is most often on too, or on the line after it.
function lineAt(lines, x, y, near) {
  for (var n = near; n <= near + 1 && n < lines.length; n++) {
    if (n >= 0 && holds(lines[n].bbox, x, y)) {
      return n;
    }
  }
  var best = -1;
  var bestScore = Infinity;
  for (var l = 0; l < lines.length; l++) {
    var b = lines[l].bbox;
    // the distance from the point to the box, 0 inside it, where the area of the box breaks ties
    var dx = Math.max(b[0] - x, 0, x - b[2]);
    var dy = Math.max(b[1] - y, 0, y - b[3]);
    var score = (dx * dx + dy * dy) * 1e9 + (b[2] - b[0]) * (b[3] - b[1]);
    if (score < bestScore) {
      best = l;
      bestScore = score;
    }
  }
  return best;
}

// The text of <line>, cut down to the part around the point <left> on it when the line is long.
function lineText(structured, line, left) {
  var box = line.bbox;
  if (line.text === undefined) {
    var mid = (box[1] + box[3]) / 2;
    line.text = copyText(structured, [box[0] + 0.01, mid], [box[2] - 0.01, mid]);
  }
  var text = line.text;
  if (text.length <= WIDTH) {
    return text;
  }
  // where the hit starts in the line, from where it lies across the line's box
  var width = box[2] - box[0];
  var start = width > 0 ? Math.round(((left - box[0]) / width) * text.length) : 0;
  var from = Math.max(0, Math.min(start - BEFORE, text.length - WIDTH));
  var to = from + WIDTH;
  var part = text.slice(from, to);
  // a cut in a word drops what is left of the word, when the part keeps most of its width
  if (from > 0 && text.charAt(from - 1) !== " ") {
    var space = part.indexOf(" ");
    part = space >= 0 && space < 15 ? part.slice(space + 1) : part;
  }
  if (to < text.length && text.charAt(to) !== " ") {
    var last = part.lastIndexOf(" ");
    part = last >= part.length - 15 ? part.slice(0, last) : part;
  }
  return (from > 0 ? "…" : "") + part.trim() + (to < text.length ? "…" : "");
}

if (needle) {
  for (var i = 0; i < count && !truncated; i++) {
    var page = doc.loadPage(i);
    var bounds = page.getBounds();
    // Not page.search(needle): it returns nothing at all in MuPDF 1.27.0 and 1.28.0. Searching the page's structured
    // text gives the same hits on every version.
    var structured = page.toStructuredText();
    var hits = structured.search(needle);
    var lines = hits.length > 0 ? linesOf(structured) : [];
    var near = 0;
    for (var h = 0; h < hits.length; h++) {
      if (total >= limit) {
        // only a hit past the limit means the list is incomplete: exactly <max hits> of them is the whole list
        truncated = true;
        break;
      }
      var rects = hits[h].map(function (quad) {
        return rect(quad, bounds);
      });
      // the line of text that the hit starts on: the one that holds the centre of its first quad
      var text = "";
      var first = hits[h][0];
      if (first) {
        var x = (first[0] + first[2] + first[4] + first[6]) / 4;
        var y = (first[1] + first[3] + first[5] + first[7]) / 4;
        var at = lineAt(lines, x, y, near);
        if (at >= 0) {
          near = at;
          text = lineText(structured, lines[at], Math.min(first[0], first[2], first[4], first[6]));
        }
      }
      print(
        i + 1 + " " + h + " " + (bounds[2] - bounds[0]) + " " + (bounds[3] - bounds[1]) + " " + rects.join(";") + "\t" + text
      );
      total++;
    }
  }
}
if (truncated) {
  print("truncated");
}
