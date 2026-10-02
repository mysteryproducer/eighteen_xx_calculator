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

  /// Where on the hex this stop is printed, as tobymao/18xx's `loc:`: a side
  /// number, or a half number for the corner between two sides. Null means
  /// the middle of the hex.
  final double? loc;

  /// `style:` from the tile string, when it overrides how the stop is drawn
  /// (`dot`, `rect`, `hidden`).
  final String? style;

  /// How many sixths of a turn the tile this stop is on has been turned. A
  /// city with several slots in the middle of a tile has them printed in a
  /// row that turns with the tile.
  final int turn;

  const TileStation({
    required this.index,
    required this.kind,
    required this.revenue,
    this.slots = 1,
    this.phaseRevenue = const {},
    this.loc,
    this.style,
    this.turn = 0,
  });

  /// This stop turned [steps] sixths of a turn clockwise, since [loc] is
  /// measured against the hex's sides.
  TileStation rotated(int steps) => TileStation(
        index: index,
        kind: kind,
        revenue: revenue,
        slots: slots,
        phaseRevenue: phaseRevenue,
        loc: loc == null ? null : (loc! + steps) % 6,
        style: style,
        turn: (turn + steps) % 6,
      );

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

  /// Track printed on the map for a line that hasn't opened yet (1844's
  /// Gotthard tunnel). It is there to be seen -- so recognition should expect
  /// it -- but nothing can run over it.
  final bool future;

  const TileSegment(this.a, this.b, {this.narrow = false, this.future = false});
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

  /// The hex edges this tile's printing reaches, including track that can't
  /// be run over yet -- this is what a photo of the hex shows.
  Set<int> get edges => {
        for (int e = 0; e < 6; e++)
          if (touchesEdge(e)) e,
      };

  /// How strongly the printing should run off each edge it reaches, for
  /// recognition: 1 for track, and [futureExit] where the only track is a
  /// line that hasn't opened, which the map prints as a thin dotted line.
  /// That difference is what tells an opened line -- solid track on a tile
  /// laid over it -- from the printing underneath.
  Map<int, double> get exitStrengths => {
        for (final e in edges)
          e: segments.any((seg) => !seg.future && _touches(seg, e))
              ? 1.0
              : futureExit,
      };

  static const double futureExit = 0.35;

  static bool _touches(TileSegment seg, int edge) =>
      (seg.a is EdgeEndpoint && (seg.a as EdgeEndpoint).edge == edge) ||
      (seg.b is EdgeEndpoint && (seg.b as EdgeEndpoint).edge == edge);

  /// The edges a train could actually leave by.
  Set<int> get routableEdges => {
        for (final seg in segments)
          if (!seg.future) ...[
            if (seg.a case EdgeEndpoint(:final edge)) edge,
            if (seg.b case EdgeEndpoint(:final edge)) edge,
          ],
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
      stations: [for (final station in stations) station.rotated(s)],
      label: label,
      impassable: {for (final e in impassable) (e + s) % 6},
      segments: [
        for (final seg in segments)
          TileSegment(rotateEndpoint(seg.a), rotateEndpoint(seg.b),
              narrow: seg.narrow, future: seg.future),
      ],
    );
  }

  /// A copy that pays what [plate] pays: 1844's mountain railways put a
  /// revenue plate on a mountain printed as paying nothing.
  TileDefinition withRevenueFrom(TileDefinition plate) {
    final source = plate.stations.where((s) => s.kind == StationKind.offboard);
    if (source.isEmpty) return this;
    return TileDefinition(
      id: id,
      color: color,
      label: label,
      impassable: impassable,
      segments: segments,
      stations: [
        for (final s in stations)
          s.kind == StationKind.offboard
              ? TileStation(
                  index: s.index,
                  kind: s.kind,
                  revenue: source.first.revenue,
                  slots: s.slots,
                  phaseRevenue: source.first.phaseRevenue,
                  loc: s.loc,
                  style: s.style,
                  turn: s.turn,
                )
              : s,
      ],
    );
  }

  /// A copy with [extra] track added: 1844's tunnels are narrow track laid
  /// through whatever is already on the hex.
  TileDefinition withSegments(List<TileSegment> extra) => TileDefinition(
        id: id,
        color: color,
        stations: stations,
        label: label,
        impassable: impassable,
        segments: [...segments, ...extra],
      );

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
      // Phases are named by tile colour, except the last in some titles:
      // 1889's off-boards pay by "diesel", which comes after brown.
      final phase =
          kv[0] == 'diesel' ? TileColor.grey : tileColorFromName(kv[0]);
      if (value != null) result[phase] = value;
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
          double? loc;
          String? style;
          var phaseRevenue = const <TileColor, int>{};
          for (final sp in subParts) {
            final kv = sp.split(':');
            if (kv.length != 2) continue;
            if (kv[0] == 'revenue') {
              revenue = _parseRevenue(kv[1]);
              phaseRevenue = _parsePhaseRevenue(kv[1]);
            }
            if (kv[0] == 'slots') slots = int.tryParse(kv[1]) ?? 1;
            if (kv[0] == 'loc') loc = double.tryParse(kv[1]);
            if (kv[0] == 'style') style = kv[1];
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
            loc: loc,
            style: style,
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
          if (a != null && b != null) {
            segments.add(TileSegment(a, b,
                narrow: track == 'narrow', future: track == 'future'));
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
