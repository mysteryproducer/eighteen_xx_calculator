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
  /// pre-printed hexes, water and special hexes keep their printing all game,
  /// so they are never scanned for tiles.
  bool get takesTiles => switch (printed.color) {
        TileColor.plain ||
        TileColor.yellow ||
        TileColor.green ||
        TileColor.brown =>
          true,
        TileColor.purple => true,
        _ => false,
      };

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
      if (best != null) chosen.add(best);
    }
    return chosen;
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
