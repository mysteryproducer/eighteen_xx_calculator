import 'board.dart';
import 'tile_definition.dart';

/// A tile as it sits on the board: which design, turned which way.
class PlacedTile {
  final String tileId;
  final int rotation; // 0..5, clockwise 60-degree steps
  const PlacedTile(this.tileId, {this.rotation = 0});
}

/// Where a station's revenue figure came from, in the order they're trusted
/// (see `RevenueResolver`).
enum RevenueSource {
  /// Typed in by the user. Beats everything else.
  manual,

  /// Printed on a tile the classifier recognized confidently, or that the user
  /// confirmed.
  tile,

  /// Read off the photo, because the tile match was too doubtful to trust.
  photo,

  /// The tile match was doubtful and the photo couldn't be read, so this is
  /// the doubtful tile's value. Worth checking by hand.
  unverified,
}

/// A revenue centre (city or town) on the board.
class StationNode {
  final HexCoord hex;
  final int stationIndex; // index of the station within its tile
  final StationKind kind;
  final int slots;

  /// Revenue for this stop. Seeded from the tile definition; [revenueSource]
  /// records whether that stood or was replaced.
  int revenue;

  /// What a D train is paid here instead, where the printing says so (see
  /// `TileStation.dieselRevenue`).
  final int? dieselRevenue;

  RevenueSource revenueSource = RevenueSource.tile;

  /// Whose token is in each of the city's circles, in order: a company id,
  /// or null for an open circle. Set from the session (see
  /// `GameSession.tokens`).
  List<String?> tokens;

  /// The colour of what it's printed on, where known: some trains can't
  /// visit red off-board areas.
  final TileColor? color;

  StationNode({
    required this.hex,
    required this.stationIndex,
    required this.kind,
    required this.revenue,
    this.dieselRevenue,
    this.slots = 1,
    List<String?>? tokens,
    this.color,
  }) : tokens = tokens ?? List<String?>.filled(slots < 1 ? 1 : slots, null);

  String get id => '${hex.row}_${hex.col}_$stationIndex';

  /// What a train called [train] is paid here: a D train its diesel figure,
  /// unless the revenue has been set some other way than by the tile.
  int revenueFor(String train) =>
      dieselRevenue != null &&
              revenueSource == RevenueSource.tile &&
              train.toUpperCase() == 'D'
          ? dieselRevenue!
          : revenue;

  /// The first company with a token here, if any.
  String? get companyId => tokens.whereType<String>().firstOrNull;

  /// Whether [company] has a token here.
  bool holds(String company) => tokens.contains(company);

  /// Whether [company]'s trains are stopped here: a city whose every circle
  /// holds another company's token can begin or end a route, but not be run
  /// through.
  bool blocks(String company) =>
      kind == StationKind.city &&
      tokens.isNotEmpty &&
      tokens.every((t) => t != null && t != company);

  @override
  String toString() => 'Station($id ${kind.name} $revenue)';
}

/// A run of track connecting two stations, with every intervening hex it
/// passes through (used to draw a computed route back onto the photo).
class TrackEdge {
  final StationNode from;
  final StationNode to;
  final List<HexCoord> hexPath;

  /// The pieces of printed track it runs over, one id per tile segment, and
  /// the hex sides it crosses: no route uses one twice, and two trains of a
  /// company can't share any.
  final List<String> segments;

  /// Whether any of it is narrow gauge (1844's tunnels).
  final bool narrow;

  const TrackEdge({
    required this.from,
    required this.to,
    required this.hexPath,
    this.segments = const [],
    this.narrow = false,
  });

  /// How many hexes it crosses into after leaving [from]'s.
  int get hexSteps => hexPath.length - 1;

  /// Stable identity for a physical stretch of track, direction-independent,
  /// so a route can't traverse the same track twice.
  String get id {
    final ends = [from.id, to.id]..sort();
    final hexes = hexPath.map((h) => '${h.row},${h.col}').join('>');
    final reversedHexes = hexPath.reversed.map((h) => '${h.row},${h.col}').join('>');
    final path = hexes.compareTo(reversedHexes) <= 0 ? hexes : reversedHexes;
    return '${ends[0]}|${ends[1]}|$path';
  }
}

/// The board reduced to what route-finding actually needs: stations, and the
/// stretches of track between them. Plain pass-through track (a #9 straight,
/// say) isn't a node -- it's contracted into the edge that crosses it.
class BoardGraph {
  final List<StationNode> stations;
  final Map<String, List<TrackEdge>> adjacency; // station id -> outgoing edges

  const BoardGraph({required this.stations, required this.adjacency});

  StationNode? stationById(String id) {
    for (final s in stations) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<TrackEdge> edgesFrom(StationNode node) => adjacency[node.id] ?? const [];

  /// Builds the graph from recognized tiles.
  ///
  /// [placedTiles] maps each occupied hex to its recognized tile + rotation;
  /// [definitions] supplies the track layout per tile id (normally
  /// `TileSeedData.all`). Tiles whose id isn't in [definitions] are ignored.
  static BoardGraph build(
    Map<HexCoord, PlacedTile> placedTiles,
    Map<String, TileDefinition> definitions,
  ) {
    // Rotated definition per occupied hex.
    final rotated = <HexCoord, TileDefinition>{};
    placedTiles.forEach((hex, placed) {
      final def = definitions[placed.tileId];
      if (def != null) rotated[hex] = def.rotated(placed.rotation);
    });
    return fromContent(rotated);
  }

  /// Builds the graph from what is on each hex, already turned the right way:
  /// a laid tile, or the map's own printing where there is none. Stations
  /// whose revenue changes with the game's phase pay their [phase] value.
  static BoardGraph fromContent(
    Map<HexCoord, TileDefinition> rotated, {
    TileColor phase = TileColor.yellow,
  }) {
    // One node per station instance.
    final stations = <StationNode>[];
    final stationByKey = <String, StationNode>{};
    rotated.forEach((hex, def) {
      for (final st in def.stations) {
        final node = StationNode(
          hex: hex,
          stationIndex: st.index,
          kind: st.kind,
          revenue: st.revenueIn(phase),
          dieselRevenue: st.dieselRevenue,
          slots: st.slots,
          color: def.color,
        );
        stations.add(node);
        stationByKey[node.id] = node;
      }
    });

    // Low-level "port" graph. A port is either a station, or the point where
    // track crosses a hex edge. Track segments inside a tile connect ports
    // within a hex; matching edges of neighbouring tiles connect ports across
    // the hex boundary.
    String stationPort(HexCoord h, int index) => 'S:${h.row}_${h.col}_$index';
    String edgePort(HexCoord h, int edge) => 'E:${h.row}:${h.col}:$edge';

    // Each link is a piece of a tile's track, or a crossing of a hex side
    // from one tile's track to the next; each has an id, so a route can use
    // it only once.
    final raw = <String, List<(String, String, bool)>>{}; // to, id, crossing
    final narrow = <String>{};
    void link(String a, String b, String id, {bool crossing = false}) {
      raw.putIfAbsent(a, () => []).add((b, id, crossing));
      raw.putIfAbsent(b, () => []).add((a, id, crossing));
    }

    rotated.forEach((hex, def) {
      String portFor(TileEndpoint e) => switch (e) {
            EdgeEndpoint(:final edge) => edgePort(hex, edge),
            StationEndpoint(:final stationIndex) => stationPort(hex, stationIndex),
          };
      for (int i = 0; i < def.segments.length; i++) {
        final seg = def.segments[i];
        // Track printed for a line that hasn't opened yet carries nothing.
        if (seg.future) continue;
        final id = _segmentId(hex, i);
        if (seg.narrow) narrow.add(id);
        link(portFor(seg.a), portFor(seg.b), id);
      }
      // Join this tile's track to the neighbouring tile's track where both
      // sides of a hex boundary carry track.
      final reachable = def.routableEdges;
      for (int edge = 0; edge < 6; edge++) {
        if (!reachable.contains(edge)) continue;
        final neighbour = Board.neighborOf(hex, edge);
        final neighbourDef = rotated[neighbour];
        if (neighbourDef == null) continue;
        final opposite = HexGeometry.oppositeEdge(edge);
        if (!neighbourDef.routableEdges.contains(opposite)) continue;
        if (def.impassable.contains(edge) ||
            neighbourDef.impassable.contains(opposite)) {
          continue;
        }
        // Link once per boundary, not twice (each hex would otherwise add it).
        if (hex.row < neighbour.row ||
            (hex.row == neighbour.row && hex.col < neighbour.col)) {
          link(edgePort(hex, edge), edgePort(neighbour, opposite),
              '${hex.row},${hex.col}|$edge',
              crossing: true);
        }
      }
    });

    // Contract pass-through track: walk out of each station and keep going
    // through hex-edge ports until another station is reached.
    //
    // The walk forks rather than following one way, because a hexside can
    // carry more than one track: on a tile like #23 a train entering by side 0
    // can leave by either side 3 or side 4, and both are real connections.
    // But track only meets at a side to run on into the next hex: a train
    // that comes to a side along one of a tile's tracks crosses it, and one
    // that crosses it takes one of the next tile's tracks. Two tracks of
    // the same tile that meet at a side -- 1844's 29 at H11, a curve each
    // way from the side facing H13 -- are no junction; only a city or a
    // town joins tracks.
    final adjacency = <String, List<TrackEdge>>{};
    for (final station in stations) {
      final start = stationPort(station.hex, station.stationIndex);
      final edges = <TrackEdge>[];

      void explore(
        String previous,
        String current,
        List<HexCoord> hexPath,
        Set<String> visited,
        List<String> segments,
        bool crossedIn,
      ) {
        if (current.startsWith('S:')) {
          final other = stationByKey[current.substring(2)];
          if (other == null) return;
          final path = List<HexCoord>.of(hexPath);
          if (path.isEmpty || path.last != other.hex) path.add(other.hex);
          edges.add(TrackEdge(
            from: station,
            to: other,
            hexPath: path,
            segments: List.of(segments),
            narrow: segments.any(narrow.contains),
          ));
          return; // stations end a run of track; they don't pass through
        }

        final hex = _hexOfPort(current);
        final added = hexPath.isEmpty || hexPath.last != hex;
        if (added) hexPath.add(hex);
        for (final (next, id, crossing)
            in raw[current] ?? const <(String, String, bool)>[]) {
          if (next == previous || visited.contains(next)) continue;
          // Along a tile's track to a side, then across it; across, then
          // along the next tile's track.
          if (crossing == crossedIn) continue;
          visited.add(next);
          segments.add(id);
          explore(current, next, hexPath, visited, segments, crossing);
          segments.removeLast();
          visited.remove(next);
        }
        if (added) hexPath.removeLast();
      }

      for (final (firstHop, id, crossing)
          in raw[start] ?? const <(String, String, bool)>[]) {
        explore(start, firstHop, [station.hex], {start, firstHop}, [id],
            crossing);
      }
      adjacency[station.id] = edges;
    }

    return BoardGraph(stations: stations, adjacency: adjacency);
  }

  /// The id in [TrackEdge.segments] of segment [index] of the tile on
  /// [hex].
  static String _segmentId(HexCoord hex, int index) =>
      '${hex.row},${hex.col}#$index';

  /// The hex and the tile's segment, by its index among the tile's
  /// segments, that an id in [TrackEdge.segments] names; null for a hex side
  /// crossed.
  static (HexCoord, int)? tileSegmentOf(String id) {
    final hash = id.indexOf('#');
    if (hash < 0) return null;
    final [row, col] = id.substring(0, hash).split(',');
    return (
      HexCoord(int.parse(row), int.parse(col)),
      int.parse(id.substring(hash + 1)),
    );
  }

  static HexCoord _hexOfPort(String port) {
    // Format: "E:<row>:<col>:<edge>"
    final parts = port.substring(2).split(':');
    return HexCoord(int.parse(parts[0]), int.parse(parts[1]));
  }
}
