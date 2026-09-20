/// Track/city layout for one 18xx tile design, independent of where or how
/// it's placed on a board.
///
/// The DSL parsed here (`parseDsl`) is a small subset of the tile grammar
/// documented in tobymao/18xx's TILES.md (https://github.com/tobymao/18xx,
/// MIT licensed) -- e.g. `'8' => 'path=a:0,b:2'`, `'5' =>
/// 'city=revenue:20;path=a:0,b:_0;path=a:1,b:_0'`. Hex edges are numbered
/// 0..5 clockwise (see [HexGeometry] in board.dart); an endpoint of `_N`
/// refers by index to the Nth city/town declared earlier in the same tile
/// string. This parser understands `city=`, `town=`, `offboard=`, `path=`
/// and `label=` (plus their `revenue`/`slots`/`a`/`b`/`track` sub-parts),
/// which is enough for both lay-able tiles and the pre-printed hexes of a
/// title's map. Junctions, borders, terrain costs, icons and multi-lane track
/// are skipped.
library;

/// A tile's colour, which is also its phase. `plain` is the bare map hex --
/// no tile laid yet -- which the classifier needs as a template so empty
/// hexes aren't forced onto a real tile. The last three only occur printed on
/// a map: red off-board areas, blue water, and purple special hexes.
enum TileColor { plain, yellow, green, brown, grey, red, blue, purple }

/// The colours a laid tile can have, in upgrade order.
const List<TileColor> tilePhases = [
  TileColor.yellow,
  TileColor.green,
  TileColor.brown,
  TileColor.grey,
];

/// Parses a tobymao/18xx colour name (`white`, `gray`, ...).
TileColor tileColorFromName(String name) => switch (name) {
      'white' => TileColor.plain,
      'yellow' => TileColor.yellow,
      'green' => TileColor.green,
      'brown' => TileColor.brown,
      'gray' || 'grey' || 'sepia' => TileColor.grey,
      'red' => TileColor.red,
      'blue' => TileColor.blue,
      'purple' => TileColor.purple,
      _ => TileColor.plain,
    };

/// Cities take station tokens; towns don't; off-board areas are revenue
/// locations at the map edge whose value depends on the game phase.
enum StationKind { city, town, offboard }

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

  /// The printed revenue, or the first phase's value when it varies by phase.
  final int revenue;
  final int slots;

  /// Revenue by phase, for locations printed like `yellow_20|green_30`.
  /// Empty when the revenue is a single figure.
  final Map<TileColor, int> phaseRevenue;

  const TileStation({
    required this.index,
    required this.kind,
    required this.revenue,
    this.slots = 1,
    this.phaseRevenue = const {},
  });

  /// What this stop pays once the game has reached [phase]: the value for the
  /// latest phase printed that isn't past [phase].
  int revenueIn(TileColor phase) {
    if (phaseRevenue.isEmpty) return revenue;
    int? value;
    for (final p in tilePhases) {
      final v = phaseRevenue[p];
      if (v != null) value = v;
      if (p == phase) break;
    }
    return value ?? revenue;
  }
}

class TileSegment {
  final TileEndpoint a;
  final TileEndpoint b;

  /// Narrow-gauge track (`track:narrow`) is kept apart from standard gauge
  /// for later train rules; it still connects for now.
  final bool narrow;

  const TileSegment(this.a, this.b, {this.narrow = false});
}

class TileDefinition {
  final String id;
  final TileColor color;
  final List<TileStation> stations;
  final List<TileSegment> segments;

  /// A letter printed on the tile (`OO`, `B`, `Z`...). Labelled map hexes only
  /// take tiles with the same label.
  final String? label;

  /// Hex sides printed as impassable (a thick black line on the map, often
  /// along a lake or mountain ridge). Track may not cross them.
  final Set<int> impassable;

  const TileDefinition({
    required this.id,
    required this.color,
    required this.stations,
    required this.segments,
    this.label,
    this.impassable = const {},
  });

  int get cityCount => stations.where((s) => s.kind == StationKind.city).length;
  int get townCount => stations.where((s) => s.kind == StationKind.town).length;

  /// The hex edges this tile's track reaches.
  Set<int> get edges => {
        for (int e = 0; e < 6; e++)
          if (touchesEdge(e)) e,
      };

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
      label: label,
      impassable: {for (final e in impassable) (e + s) % 6},
      segments: [
        for (final seg in segments)
          TileSegment(rotateEndpoint(seg.a), rotateEndpoint(seg.b),
              narrow: seg.narrow),
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
    // For the phase-based `yellow_40|green_50` form this is the first phase's
    // figure; `_parsePhaseRevenue` keeps the rest.
    final match = RegExp(r'-?\d+').firstMatch(raw);
    return match == null ? 0 : int.parse(match.group(0)!);
  }

  static Map<TileColor, int> _parsePhaseRevenue(String raw) {
    if (!raw.contains('_')) return const {};
    final result = <TileColor, int>{};
    for (final part in raw.split('|')) {
      final kv = part.split('_');
      if (kv.length != 2) continue;
      final value = int.tryParse(kv[1]);
      if (value != null) result[tileColorFromName(kv[0])] = value;
    }
    return result;
  }

  /// Parses a tile DSL string (see class doc) into a [TileDefinition].
  static TileDefinition parseDsl(String id, TileColor color, String dsl) {
    final stations = <TileStation>[];
    final segments = <TileSegment>[];
    final impassable = <int>{};
    String? label;

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
        case 'offboard':
          int revenue = 0;
          int slots = 1;
          var phaseRevenue = const <TileColor, int>{};
          for (final sp in subParts) {
            final kv = sp.split(':');
            if (kv.length != 2) continue;
            if (kv[0] == 'revenue') {
              revenue = _parseRevenue(kv[1]);
              phaseRevenue = _parsePhaseRevenue(kv[1]);
            }
            if (kv[0] == 'slots') slots = int.tryParse(kv[1]) ?? 1;
          }
          stations.add(TileStation(
            index: stations.length,
            kind: switch (key) {
              'city' => StationKind.city,
              'town' => StationKind.town,
              _ => StationKind.offboard,
            },
            revenue: revenue,
            slots: slots,
            phaseRevenue: phaseRevenue,
          ));
          break;
        case 'path':
          TileEndpoint? a;
          TileEndpoint? b;
          String? track;
          for (final sp in subParts) {
            final kv = sp.split(':');
            if (kv.length != 2) continue;
            if (kv[0] == 'a') a = _parseEndpoint(kv[1]);
            if (kv[0] == 'b') b = _parseEndpoint(kv[1]);
            if (kv[0] == 'track') track = kv[1];
          }
          // Future track (1844's Gotthard tunnel before it opens, say) is
          // printed on the map but can't be run yet.
          if (a != null && b != null && track != 'future') {
            segments.add(TileSegment(a, b, narrow: track == 'narrow'));
          }
          break;
        case 'label':
          label = body.trim();
          break;
        case 'border':
          int? edge;
          String? type;
          for (final sp in subParts) {
            final kv = sp.split(':');
            if (kv.length != 2) continue;
            if (kv[0] == 'edge') edge = int.tryParse(kv[1]);
            if (kv[0] == 'type') type = kv[1];
          }
          if (edge != null && type == 'impassable') impassable.add(edge);
          break;
        default:
          // upgrade=, icon=, frame=, junction... -- skipped.
          break;
      }
    }

    return TileDefinition(
      id: id,
      color: color,
      stations: stations,
      segments: segments,
      label: label,
      impassable: impassable,
    );
  }
}
