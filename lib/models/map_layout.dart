import 'dart:math' as math;
import 'dart:ui';

import 'board.dart';
import 'tile_definition.dart';

/// One hex of a title's printed map.
class MapHex {
  /// The coordinate printed on the board: row letter, column number (`D19`).
  final String id;
  final HexCoord coord;

  /// What's printed on the hex: its colour, any cities, towns, off-board
  /// revenue and pre-printed track.
  final TileDefinition printed;

  /// Place name, if the map names one.
  final String? name;

  /// A label that green and later tiles on this hex must carry, when the
  /// printed hex itself has none yet (1844's Zürich becomes a `Z` city in
  /// green).
  final String? futureLabel;

  const MapHex({
    required this.id,
    required this.coord,
    required this.printed,
    this.name,
    this.futureLabel,
  });

  /// Whether players can lay tiles here. Red off-board areas, grey
  /// pre-printed hexes, water, and the purple hexes a game converts by itself
  /// (1844's Gotthard tunnel and the other mountain lines) keep their
  /// printing, so they are never scanned for tiles.
  bool get takesTiles =>
      switch (printed.color) {
        TileColor.plain ||
        TileColor.yellow ||
        TileColor.green ||
        TileColor.brown =>
          true,
        _ => false,
      } ||
      // A line printed for later opening does get a tile: the game lays it
      // when the line opens, and the board changes.
      opensLater;

  /// Whether the hex carries track printed for a line that hasn't opened.
  bool get opensLater => printed.segments.any((s) => s.future);

  String get displayName => name == null ? id : '$id $name';

  @override
  String toString() => 'MapHex($id)';
}

/// A title's map: which hexes exist, where they sit, and what's printed on
/// each.
///
/// Real maps aren't rectangles -- hexes are missing all round the edges and
/// some titles have separate insets -- so the map is the list of hexes that
/// exist rather than a row and column count. Positions use [HexCoord]'s
/// odd-r offset layout, whose board-space geometry ([HexCoord.boardCenter]) is
/// what the photo is registered against.
class MapLayout {
  final List<MapHex> hexes;
  final Map<HexCoord, MapHex> _byCoord;
  final Map<String, MapHex> _byId;

  MapLayout(this.hexes)
      : _byCoord = {for (final h in hexes) h.coord: h},
        _byId = {for (final h in hexes) h.id: h};

  MapHex? at(HexCoord coord) => _byCoord[coord];
  MapHex? byId(String id) => _byId[id];
  bool contains(HexCoord coord) => _byCoord.containsKey(coord);
  Iterable<HexCoord> get coords => _byCoord.keys;

  /// A rectangular block of plain hexes, for boards without title data.
  factory MapLayout.rectangle(int rows, int cols) {
    final blank = TileDefinition.parseDsl('blank', TileColor.plain, '');
    return MapLayout([
      for (int r = 0; r < rows; r++)
        for (int c = 0; c < cols; c++)
          MapHex(
            id: '${_rowLetters(r)}${c + 1}',
            coord: HexCoord(r, c),
            printed: blank,
          ),
    ]);
  }

  /// Converts a printed coordinate (`D19`: row D, column 19) to a [HexCoord].
  ///
  /// tobymao/18xx numbers pointy-top maps in "doubled" coordinates: the
  /// column number goes up by two between neighbours in a row, and odd and
  /// even numbers alternate between rows. Which rows get the odd numbers
  /// varies by title, so [rowShift] moves every row down one when needed to
  /// line the numbering up with [HexCoord]'s odd-r layout, where odd rows are
  /// the ones pushed right.
  static HexCoord coordFromId(String id, {required int rowShift}) {
    final match = RegExp(r'^([A-Z]+)(-?\d+)$').firstMatch(id);
    if (match == null) throw FormatException('Not a hex coordinate: $id');
    final row = _rowIndex(match.group(1)!) + rowShift;
    final doubled = int.parse(match.group(2)!);
    return HexCoord(row, (doubled - (row & 1)) ~/ 2);
  }

  /// Converts a printed coordinate on a flat-topped map (`B3`: column B,
  /// row 3) to a [HexCoord].
  ///
  /// The app keeps every map pointy-topped: a flat-topped map turned a
  /// twelfth of a turn clockwise is exactly a pointy-topped one, and each
  /// side keeps its number -- side 0, the bottom of a flat hex, becomes the
  /// lower left of a pointy one -- so the title's tiles carry over as they
  /// are, and only drawing turns the map back (see `GameTitle.displayTurn`).
  /// tobymao numbers flat maps in doubled coordinates too, the row number
  /// going up by two between neighbours in a column; stepping across side k
  /// is the same step on both maps, which makes the pointy doubled
  /// coordinates (3x - y) / 2 and (x + y) / 2. [rowShift] lines the row
  /// numbering up so those are whole.
  static HexCoord coordFromFlatId(String id, {required int rowShift}) {
    final match = RegExp(r'^([A-Z]+)(-?\d+)$').firstMatch(id);
    if (match == null) throw FormatException('Not a hex coordinate: $id');
    final x = _rowIndex(match.group(1)!);
    final y = int.parse(match.group(2)!) + rowShift;
    final row = (x + y) ~/ 2;
    final doubled = (3 * x - y) ~/ 2;
    return HexCoord(row, (doubled - (row & 1)) ~/ 2);
  }

  /// The shift [coordFromFlatId] needs for a map containing [sampleId].
  static int flatRowShiftFor(String sampleId) {
    final match = RegExp(r'^([A-Z]+)(-?\d+)$').firstMatch(sampleId)!;
    return (_rowIndex(match.group(1)!) + int.parse(match.group(2)!)) & 1;
  }

  /// The shift [coordFromId] needs for a map containing [sampleId].
  static int rowShiftFor(String sampleId) {
    final match = RegExp(r'^([A-Z]+)(-?\d+)$').firstMatch(sampleId)!;
    final row = _rowIndex(match.group(1)!);
    final doubled = int.parse(match.group(2)!);
    return (doubled - row) & 1;
  }

  static int _rowIndex(String letters) {
    var index = 0;
    for (final unit in letters.codeUnits) {
      index = index * 26 + (unit - 64);
    }
    return index - 1;
  }

  static String _rowLetters(int index) {
    var n = index + 1;
    var s = '';
    while (n > 0) {
      final rem = (n - 1) % 26;
      s = String.fromCharCode(65 + rem) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  /// The area the map covers on the flat board, in [HexCoord.boardCenter]
  /// units, including the hexes' own extent.
  Rect get boardBounds {
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    for (final h in hexes) {
      final c = h.coord.boardCenter;
      minX = math.min(minX, c.dx - math.sqrt(3) / 2);
      maxX = math.max(maxX, c.dx + math.sqrt(3) / 2);
      minY = math.min(minY, c.dy - 1);
      maxY = math.max(maxY, c.dy + 1);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Four hexes near the corners of the map, spread as far apart as the map
  /// allows. Dragging these onto their places in a photo fixes the whole
  /// map's perspective when automatic alignment needs help.
  ///
  /// Where the hex nearest a corner has no name, a named place a step or two
  /// from it is taken instead -- the one furthest out, so the four stay
  /// spread: a board like 1889's prints no grid references, only its towns'
  /// names, and a bare hex among bare hexes is hard to find. Never one
  /// beside another.
  List<MapHex> get anchors {
    final bounds = boardBounds;
    final corners = [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomRight,
      bounds.bottomLeft,
    ];
    final chosen = <MapHex>[];
    for (final corner in corners) {
      MapHex? best;
      double bestDistance = double.infinity;
      for (final h in hexes) {
        if (chosen.contains(h)) continue;
        final d = (h.coord.boardCenter - corner).distance;
        if (d < bestDistance) {
          bestDistance = d;
          best = h;
        }
      }
      if (best == null) continue;
      if (best.name == null) {
        MapHex? named;
        double furthest = -1;
        for (final h in hexes) {
          if (chosen.contains(h) || h.name == null) continue;
          if (h.coord.distanceTo(best.coord) > 2) continue;
          // Never beside one already chosen.
          if (chosen.any((c) => c.coord.distanceTo(h.coord) <= 1)) continue;
          final out = (h.coord.boardCenter - bounds.center).distance;
          if (out > furthest) {
            furthest = out;
            named = h;
          }
        }
        if (named != null) best = named;
      }
      chosen.add(best);
    }
    return chosen;
  }

  /// Four of a close-up's few hexes to drag: as far apart as they go -- none
  /// side by side where four can be found so, otherwise as few pairs as can
  /// be -- then spread over as much of the frame as possible. Two handles
  /// side by side hold nothing of the map's size or turn, and were very hard
  /// to line up (a close-up in 1889's west, 4 October); a named place helps
  /// find a hex, but in a close-up its neighbours do too, so a name counts
  /// for only a little.
  List<MapHex> get closeUpAnchors {
    if (hexes.length <= 4) return List.of(hexes);
    List<MapHex> best = hexes.take(4).toList();
    (int, int, double)? bestScore;
    bool better((int, int, double) a, (int, int, double) b) =>
        a.$1 != b.$1 ? a.$1 > b.$1 : a.$2 != b.$2 ? a.$2 > b.$2 : a.$3 > b.$3;
    final n = hexes.length;
    for (var a = 0; a < n; a++) {
      for (var b = a + 1; b < n; b++) {
        for (var c = b + 1; c < n; c++) {
          for (var d = c + 1; d < n; d++) {
            final four = [hexes[a], hexes[b], hexes[c], hexes[d]];
            var nearest = 1 << 30, touching = 0;
            for (var i = 0; i < 4; i++) {
              for (var j = i + 1; j < 4; j++) {
                final apart = four[i].coord.distanceTo(four[j].coord);
                if (apart < nearest) nearest = apart;
                if (apart <= 1) touching++;
              }
            }
            final named = four.where((h) => h.name != null).length;
            final score = (
              nearest,
              -touching,
              _hullArea([for (final h in four) h.coord.boardCenter]) *
                  (1 + 0.1 * named),
            );
            if (bestScore == null || better(score, bestScore)) {
              bestScore = score;
              best = four;
            }
          }
        }
      }
    }
    return best;
  }

  /// The area of the smallest convex shape round [points].
  static double _hullArea(List<Offset> points) {
    final sorted = [...points]
      ..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    double cross(Offset o, Offset a, Offset b) =>
        (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final hull = <Offset>[];
    for (final pass in [sorted, sorted.reversed.toList()]) {
      final start = hull.length;
      for (final p in pass) {
        while (hull.length >= start + 2 &&
            cross(hull[hull.length - 2], hull.last, p) <= 0) {
          hull.removeLast();
        }
        hull.add(p);
      }
      hull.removeLast();
    }
    var twice = 0.0;
    for (var i = 0; i < hull.length; i++) {
      final p = hull[i], q = hull[(i + 1) % hull.length];
      twice += p.dx * q.dy - q.dx * p.dy;
    }
    return twice.abs() / 2;
  }

  /// The hexes of [coords] and everything within [radius] steps of them that
  /// exists on the map.
  Set<HexCoord> around(Iterable<HexCoord> coords, int radius) {
    final result = <HexCoord>{};
    for (final centre in coords) {
      for (int dz = -radius; dz <= radius; dz++) {
        for (int dx = -radius; dx <= radius; dx++) {
          final dy = -dx - dz;
          if (dy.abs() > radius) continue;
          final h = HexCoord.fromCube(centre.cubeX + dx, centre.cubeZ + dz);
          if (contains(h)) result.add(h);
        }
      }
    }
    return result;
  }
}
