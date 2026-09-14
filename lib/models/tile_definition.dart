/// Track/city layout for one 18xx tile design, independent of where or how
/// it's placed on a board.
///
/// The DSL parsed here (`parseDsl`) is a small subset of the tile grammar
/// documented in tobymao/18xx's TILES.md (https://github.com/tobymao/18xx,
/// MIT licensed) -- e.g. `'8' => 'path=a:0,b:2'`, `'5' =>
/// 'city=revenue:20;path=a:0,b:_0;path=a:1,b:_0'`. Hex edges are numbered
/// 0..5 clockwise (see [HexGeometry] in board.dart); an endpoint of `_N`
/// refers by index to the Nth city/town declared earlier in the same tile
/// string. This parser only understands `city=`, `town=`, and `path=`
/// (plus their `revenue`/`slots`/`a`/`b` sub-parts) -- offboards, junctions,
/// labels, borders, and multi-lane track are not handled and are simply
/// skipped, since the seed tile set in tile_seed_data.dart doesn't need them.
library;

/// `plain` is the bare map hex -- no tile laid yet -- which the classifier
/// needs as a template so empty hexes aren't forced onto a real tile.
enum TileColor { plain, yellow, green, brown, grey }

enum StationKind { city, town }

/// One endpoint of a track segment: either a hex edge, or a reference to a
/// station (city/town) declared elsewhere on the same tile.
sealed class TileEndpoint {
  const TileEndpoint();
}

class EdgeEndpoint extends TileEndpoint {
  final int edge; // 0..5
  const EdgeEndpoint(this.edge);

  @override
  bool operator ==(Object other) => other is EdgeEndpoint && other.edge == edge;
  @override
  int get hashCode => edge.hashCode;
  @override
  String toString() => 'Edge($edge)';
}

class StationEndpoint extends TileEndpoint {
  final int stationIndex;
  const StationEndpoint(this.stationIndex);

  @override
  bool operator ==(Object other) =>
      other is StationEndpoint && other.stationIndex == stationIndex;
  @override
  int get hashCode => stationIndex.hashCode;
  @override
  String toString() => 'Station($stationIndex)';
}

class TileStation {
  final int index;
  final StationKind kind;
  final int revenue; // default/placeholder; real revenue comes from OCR
  final int slots;
  const TileStation({
    required this.index,
    required this.kind,
    required this.revenue,
    this.slots = 1,
  });
}

class TileSegment {
  final TileEndpoint a;
  final TileEndpoint b;
  const TileSegment(this.a, this.b);
}

class TileDefinition {
  final String id;
  final TileColor color;
  final List<TileStation> stations;
  final List<TileSegment> segments;

  const TileDefinition({
    required this.id,
    required this.color,
    required this.stations,
    required this.segments,
  });

  /// True if any segment on this tile touches hex edge [edge].
  bool touchesEdge(int edge) {
    for (final seg in segments) {
      if (seg.a is EdgeEndpoint && (seg.a as EdgeEndpoint).edge == edge) return true;
      if (seg.b is EdgeEndpoint && (seg.b as EdgeEndpoint).edge == edge) return true;
    }
    return false;
  }

  /// A copy of this definition rotated clockwise by [steps] * 60 degrees.
  /// Only edge endpoints move; station references are unaffected since
  /// (for the seed tile set) stations are rendered at the hex center.
  TileDefinition rotated(int steps) {
    final s = steps % 6;
    if (s == 0) return this;
    TileEndpoint rotateEndpoint(TileEndpoint e) =>
        e is EdgeEndpoint ? EdgeEndpoint((e.edge + s) % 6) : e;
    return TileDefinition(
      id: id,
      color: color,
      stations: stations,
      segments: [
        for (final seg in segments)
          TileSegment(rotateEndpoint(seg.a), rotateEndpoint(seg.b)),
      ],
    );
  }

  static TileEndpoint _parseEndpoint(String raw) {
    final v = raw.trim();
    if (v.startsWith('_')) {
      return StationEndpoint(int.parse(v.substring(1)));
    }
    return EdgeEndpoint(int.parse(v));
  }

  static int _parseRevenue(String raw) {
    // Seed tiles only use plain integer revenue; be defensive about the
    // phase-based `yellow_40|green_50` form just in case a ported string
    // uses it, by taking the first integer found.
    final match = RegExp(r'-?\d+').firstMatch(raw);
    return match == null ? 0 : int.parse(match.group(0)!);
  }

  /// Parses a tile DSL string (see class doc) into a [TileDefinition].
  static TileDefinition parseDsl(String id, TileColor color, String dsl) {
    final stations = <TileStation>[];
    final segments = <TileSegment>[];

    for (final rawPart in dsl.split(';')) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      if (eq == -1) continue; // e.g. bare `junction` -- unsupported, skip
      final key = part.substring(0, eq);
      final body = part.substring(eq + 1);
      final subParts = body.split(',');

      switch (key) {
        case 'city':
        case 'town':
          int revenue = 0;
          int slots = 1;
          for (final sp in subParts) {
            final kv = sp.split(':');
            if (kv.length != 2) continue;
            if (kv[0] == 'revenue') revenue = _parseRevenue(kv[1]);
            if (kv[0] == 'slots') slots = int.tryParse(kv[1]) ?? 1;
          }
          stations.add(TileStation(
            index: stations.length,
            kind: key == 'city' ? StationKind.city : StationKind.town,
            revenue: revenue,
            slots: slots,
          ));
          break;
        case 'path':
          TileEndpoint? a;
          TileEndpoint? b;
          for (final sp in subParts) {
            final kv = sp.split(':');
            if (kv.length != 2) continue;
            if (kv[0] == 'a') a = _parseEndpoint(kv[1]);
            if (kv[0] == 'b') b = _parseEndpoint(kv[1]);
          }
          if (a != null && b != null) {
            segments.add(TileSegment(a, b));
          }
          break;
        default:
          // label=, upgrade=, border=, icon=, offboard=, lanes=... -- skipped.
          break;
      }
    }

    return TileDefinition(id: id, color: color, stations: stations, segments: segments);
  }
}
