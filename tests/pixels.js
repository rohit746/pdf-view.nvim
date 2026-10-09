// Test helper. Usage: mutool run pixels.js <png> <x> <y> [<x> <y> ...]
// Prints one "r g b" line per coordinate pair.
var pixmap = new Image(scriptArgs[0]).toPixmap();
for (var i = 1; i + 1 < scriptArgs.length; i += 2) {
  var x = parseInt(scriptArgs[i], 10);
  var y = parseInt(scriptArgs[i + 1], 10);
  print(pixmap.getSample(x, y, 0) + " " + pixmap.getSample(x, y, 1) + " " + pixmap.getSample(x, y, 2));
}
