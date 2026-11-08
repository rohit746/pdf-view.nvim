// Keeps one document open and answers requests about it, so that turning a page does not start mutool and parse the
// document again.
//
// Usage: mutool run worker.js <file>
//
// A request is a JSON array, [<id>, <layout>, <password>, <command>, <arguments>...], sent as lines of at most 200 bytes (readline() reads
// at most 255): every line but the last starts with "+", the last with ":". The answer is one line,
// "@<id> ok <result>" or "@<id> error <message>". print() does not flush standard output, so every answer is followed
// by a line of padding longer than the stdio buffer, which pushes the answer out of it. The worker exits at the end
// of its input.
//
// <layout> is [<width>, <height>, <em>] or null. A reflowable document (EPUB, FB2, MOBI) is laid out on pages of
// <width> x <height> points with <em> point text before the command runs, and again whenever the layout changes; its
// page count and every page change with it. Other documents ignore it. null keeps MuPDF's own layout.
//
// <password> unlocks a password-protected document, the first time it is opened; null or "" for none. It comes on
// standard input rather than as an argument, where `ps` would show it. Without the right one, every command fails
// with "this PDF is password-protected" (none given) or "wrong password".
//
// Commands:
//
//   ["info", <page>, <content>, <of>]
//     "<page count> <resolved page> <width> <height> <reflowable>", followed by " <x0> <y0> <x1> <y1>" when <content>
//     is true. <reflowable> is 1 for a reflowable document, else 0. <page> is 1-based and clamped to the document, so
//     a huge number means "the last page". When <of> is a layout ([<width>, <height>, <em>]), <page> is a page of the
//     document as laid out that way, and stands for the page that holds the point of the text it starts at now (see
//     samePoint()). The size is the page's bounds in points after /Rotate, inherited boxes, /CropBox and /UserUnit
//     have been applied. (<x0>, <y0>, <x1>, <y1>) is the rectangle, in points from the page's top-left corner, that
//     holds everything drawn on the page that is not white: text, images and vector graphics alike. It is found by
//     rendering the page small and scanning for non-white pixels, so a white rectangle laid over the whole page does
//     not count as content. A blank page gives the whole page.
//
//   ["draw", <page>, <width>, <height>, <out.png>, <recolor>]
//     Renders a whole page to a PNG of exactly <width> x <height> pixels, stretched to it.
//
//   ["render", <page>, <scale_x>, <scale_y>, <x>, <y>, <width>, <height>, <out.png>, <highlights>, <recolor>]
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
//
//     <recolor> recolours the finished image, highlights included: "" leaves it alone, "invert" inverts its brightness
//     but keeps its hues (a dark page with light text, and colours still telling apart), and "tint,<rrggbb>,<rrggbb>"
//     maps black to the first colour and white to the second, the shades in between to the shades between them (a
//     page in the colours of the editor's text and background).
//
//   ["crop", <in.png>, <x>, <y>, <width>, <height>, <out>, <out_width>, <out_height>]
//     Copies the rectangle (<x>, <y>, <width>, <height>) of the image <in.png>, in its pixels, to the PNG <out>,
//     pixel for pixel, or stretched to <out_width> x <out_height> pixels when those are given. <out> is written as a
//     binary PNM (P6) instead when its name ends in ".pnm". It does not open the document: it cuts a page that was
//     rendered already into the pieces that are not covered by a floating window, for a terminal that cannot show
//     part of an image (iTerm2 inline images), and gives a sixel encoder the pixels of a page at its size on screen.
//
//   ["text", <page>]
//     The text of a page, as a JSON string: a line per line of text and an empty line after each block, in reading
//     order. <page> is 1-based and clamped to the document. Empty for a page without text, such as a scanned one.
//
//   ["links", <page>]
//     The links on a page, as a JSON array in reading order (top to bottom, then left to right). A link to a page of
//     the document is {"text": <text>, "page": <1-based page>}, any other (a web address, an e-mail) is
//     {"text": <text>, "uri": <uri>}. <text> is the text under the link, "" for an image. Links that lead nowhere
//     are left out. <page> is 1-based and clamped to the document.
var path = scriptArgs[0];

// Longer than any stdio buffer (glibc and macOS use the pipe's block size: 4 KiB to 64 KiB).
var PADDING = new Array(65537).join(" ");
// The longest side of the content scan in pixels: about a point per pixel for a letter-sized page.
var SCAN = 600;
// Lighter pixels count as paper: anti-aliasing leaves a faint grey next to content, scanning noise is darker.
var WHITE = 250;
// Display lists kept, most recent last: drawing a page again (scrolling, zooming) skips interpreting it.
var KEEP = 3;
// How much text, in characters other than spaces, stands for the point of a book that a page starts at: enough to be
// found nowhere else nearby.
var SNIPPET = 100;

var doc = null;
var kept = [];
var laidOut = "";
// The text of each page as laid out now, as bare() gives it, for the pages read so far.
var bareTexts = [];

// The password of the latest request.
var password = null;

function openDocument() {
  if (!doc) {
    var opened = Document.openDocument(path);
    if (opened.needsPassword()) {
      if (!password) {
        throw new Error("this PDF is password-protected");
      }
      // false or 0 for a wrong password, a number saying what it unlocked otherwise
      if (!opened.authenticatePassword(password)) {
        throw new Error("wrong password");
      }
    }
    doc = opened;
  }
  return doc;
}

// Lay the document out as <layout> says, if it is reflowable and was laid out differently.
function layout(size) {
  var d = openDocument();
  if (!size || !d.isReflowable()) {
    return;
  }
  var key = size.join(" ");
  if (key !== laidOut) {
    d.layout(size[0], size[1], size[2]);
    laidOut = key;
    kept = []; // the display lists are of the old pages
    bareTexts = [];
  }
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
  var reflowable = doc.isReflowable() ? 1 : 0;
  var line = entry.count + " " + entry.number + " " + width + " " + height + " " + reflowable;
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

// Recolour a rendered page as <recolor> says (see "render").
function recolor(pixmap, how) {
  if (how === "invert") {
    pixmap.invertLuminance();
  } else if (how && how.indexOf("tint,") === 0) {
    var colors = how.split(",");
    pixmap.tint(parseInt(colors[1], 16), parseInt(colors[2], 16));
  } else if (how) {
    throw new Error("unknown recolouring: " + how);
  }
}

function render(number, scaleX, scaleY, x, y, width, height, out, highlights, how) {
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
  recolor(pixmap, how);
  pixmap.saveAsPNG(out);
  return notes;
}

function crop(file, x, y, width, height, out, outWidth, outHeight) {
  var image = new Image(file);
  var sx = outWidth > 0 ? outWidth / width : 1;
  var sy = outHeight > 0 ? outHeight / height : 1;
  var pixmap = new Pixmap(ColorSpace.DeviceRGB, [0, 0, Math.round(width * sx), Math.round(height * sy)], false);
  pixmap.clear(255);
  var device = new DrawDevice(Matrix.identity, pixmap);
  // an image fills the unit square: scaled to its size in pixels, one image pixel lands on one pixel of the pixmap,
  // or on sx x sy of them; the rectangle's corner lands on the pixmap's
  var w = image.getWidth();
  var h = image.getHeight();
  device.fillImage(image, [w * sx, 0, 0, h * sy, -x * sx, -y * sy], 1);
  device.close();
  if (/\.pnm$/.test(out)) {
    pixmap.saveAsPNM(out);
  } else {
    pixmap.saveAsPNG(out);
  }
  return "";
}

// The text of a page (1-based, clamped to the document), as "text" gives it.
function plainText(number) {
  var count = openDocument().countPages();
  number = Math.max(1, Math.min(count, number || 1));
  var structured = doc.loadPage(number - 1).toStructuredText();
  if (typeof structured.asText === "function") {
    return structured.asText();
  }
  // MuPDF 1.23 (Ubuntu 24.04's package) has no asText(): walk the text the way it prints it
  var out = "";
  structured.walk({
    onChar: function (c) {
      out += c;
    },
    endLine: function () {
      out += "\n";
    },
    endTextBlock: function () {
      out += "\n";
    },
  });
  return out;
}

// The text of page <index> (0-based) without its spaces, line breaks and hyphens, which are all a new layout changes
// about the text: where the lines break, and so where words are hyphenated.
function bare(index) {
  if (bareTexts[index] === undefined) {
    bareTexts[index] = plainText(index + 1).replace(/[\s\-\u00ad\u2010]+/g, "");
  }
  return bareTexts[index];
}

// The page (1-based) of the document laid out as <now> that holds the point of the text that page <number> starts at
// when laid out as <before>. MuPDF can say this itself (bookmarks), but not to scripts, so the start of the page is
// found by its text: the first SNIPPET characters from the top of the page on, looked for on the pages around the one
// that has the same share of the page count, closest first. A page without text (a picture) is found by the text after
// it, and stays in front of it. Where the text is not found, as in a book without any, that page is the answer.
function samePoint(number, before, now) {
  layout(before);
  var of = doc.countPages();
  number = Math.max(1, Math.min(of, number || 1));
  var empty = 0;
  var snippet = "";
  for (var i = number - 1; i < of && snippet.length < SNIPPET; i++) {
    var own = bare(i);
    if (!snippet && !own) {
      empty++;
    }
    snippet += own;
  }
  snippet = snippet.slice(0, SNIPPET);

  layout(now);
  var count = doc.countPages();
  var guess = Math.floor(((number - 1) * count) / of);
  // whether the snippet starts on page p (0-based); it may go on over the pages after it
  function startsOn(p) {
    var own = bare(p);
    var text = own;
    for (var j = p + 1; j < count && text.length < own.length + snippet.length; j++) {
      text += bare(j);
    }
    var at = own ? text.indexOf(snippet) : -1;
    return at >= 0 && at < own.length;
  }
  for (var distance = 0; snippet && distance < count; distance++) {
    var candidates = distance === 0 ? [guess] : [guess + distance, guess - distance];
    for (var c = 0; c < candidates.length; c++) {
      var p = candidates[c];
      if (p >= 0 && p < count && startsOn(p)) {
        while (empty > 0 && p > 0 && !bare(p - 1)) {
          p--;
          empty--;
        }
        return p + 1;
      }
    }
  }
  return guess + 1;
}

// Where in page `target` (0-based) the link `uri` leads, as fractions of the page's width and height from its top-left
// corner: { x, y }, either missing when the link does not say (a link to a whole page, a horizontal or vertical fit).
function destination(target, uri) {
  var where = {};
  var dest = null;
  try {
    dest = doc.resolveLinkDestination(uri);
  } catch (e) {
    return where;
  }
  var bounds = doc.loadPage(target).getBounds();
  var w = bounds[2] - bounds[0];
  var h = bounds[3] - bounds[1];
  if (dest && typeof dest.x === "number" && isFinite(dest.x) && w > 0) {
    where.x = Math.max(0, Math.min(1, (dest.x - bounds[0]) / w));
  }
  if (dest && typeof dest.y === "number" && isFinite(dest.y) && h > 0) {
    where.y = Math.max(0, Math.min(1, (dest.y - bounds[1]) / h));
  }
  return where;
}

function pageLinks(number) {
  var count = openDocument().countPages();
  number = Math.max(1, Math.min(count, number || 1));
  var page = doc.loadPage(number - 1);
  var found = page.getLinks();
  var structured = null;
  var links = [];
  for (var i = 0; i < found.length; i++) {
    var bounds = found[i].getBounds();
    var uri = found[i].getURI();
    var link = { top: bounds[1], left: bounds[0] };
    if (found[i].isExternal()) {
      link.uri = uri;
    } else {
      var target = -1;
      try {
        target = doc.resolveLink(uri);
      } catch (e) {
        target = -1;
      }
      if (!(target >= 0 && target < count)) {
        continue;
      }
      link.page = target + 1;
      link.at = destination(target, uri);
    }
    structured = structured || page.toStructuredText();
    link.text = String(structured.copy([bounds[0], bounds[1]], [bounds[2], bounds[3]]) || "")
      .replace(/\s+/g, " ")
      .trim();
    links.push(link);
  }
  links.sort(function (a, b) {
    return a.top - b.top || a.left - b.left;
  });
  return JSON.stringify(
    links.map(function (link) {
      if (link.uri !== undefined) {
        return { text: link.text, uri: link.uri };
      }
      var out = { text: link.text, page: link.page };
      if (link.at.x !== undefined) {
        out.x = link.at.x;
      }
      if (link.at.y !== undefined) {
        out.y = link.at.y;
      }
      return out;
    })
  );
}

function answer(request) {
  if (request[3] === "crop") {
    // needs no document, so it works the same whatever the document's password and layout
    return crop(request[4], request[5], request[6], request[7], request[8], request[9], request[10], request[11]);
  }
  password = request[2];
  var size = request[1];
  request = [request[0]].concat(request.slice(3));
  if (request[1] === "info" && size && Array.isArray(request[4])) {
    // the page is found in the old layout first, which the document most likely still has
    return info(samePoint(request[2], request[4], size), request[3]);
  }
  layout(size);
  switch (request[1]) {
    case "info":
      return info(request[2], request[3]);
    case "draw":
      var bounds = load(request[2]).bounds;
      var sx = request[3] / (bounds[2] - bounds[0]);
      var sy = request[4] / (bounds[3] - bounds[1]);
      return render(request[2], sx, sy, 0, 0, request[3], request[4], request[5], "", request[6]);
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
        request[10],
        request[11]
      );
    case "text":
      return JSON.stringify(plainText(request[2]));
    case "links":
      return pageLinks(request[2]);
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
