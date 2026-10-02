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

  RevenueSource revenueSource = RevenueSource.tile;

  /// Whose token is in each of the city's circles, in order: a company id,
  /// or null for an open circle. Set from the session (see
  /// `GameSession.tokens`).
  List<String?> tokens;

  StationNode({
    required this.hex,
    required this.stationIndex,
    required this.kind,
    required this.revenue,
    this.slots = 1,
    List<String?>? tokens,
  }) : tokens = tokens ?? List<String?>.filled(slots < 1 ? 1 : slots, null);

  String get id => '${hex.row}_${hex.col}_$stationIndex';

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
  const TrackEdge({required this.from, required this.to, required this.hexPath});

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
          slots: st.slots,
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

    final raw = <String, List<String>>{};
    void link(String a, String b) {
      raw.putIfAbsent(a, () => []).add(b);
      raw.putIfAbsent(b, () => []).add(a);
    }

    rotated.forEach((hex, def) {
      String portFor(TileEndpoint e) => switch (e) {
            EdgeEndpoint(:final edge) => edgePort(hex, edge),
            StationEndpoint(:final stationIndex) => stationPort(hex, stationIndex),
          };
      for (final seg in def.segments) {
        // Track printed for a line that hasn't opened yet carries nothing.
        if (seg.future) continue;
        link(portFor(seg.a), portFor(seg.b));
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
          link(edgePort(hex, edge), edgePort(neighbour, opposite));
        }
      }
    });

    // Contract pass-through track: walk out of each station and keep going
    // through hex-edge ports until another station is reached.
    //
    // The walk forks rather than following one way, because a hexside can
    // carry more than one track: on a tile like #23 a train entering by side 0
    // can leave by either side 3 or side 4, and both are real connections.
    final adjacency = <String, List<TrackEdge>>{};
    for (final station in stations) {
      final start = stationPort(station.hex, station.stationIndex);
      final edges = <TrackEdge>[];

      void explore(
        String previous,
        String current,
        List<HexCoord> hexPath,
        Set<String> visited,
      ) {
        if (current.startsWith('S:')) {
          final other = stationByKey[current.substring(2)];
          if (other == null) return;
          final path = List<HexCoord>.of(hexPath);
          if (path.isEmpty || path.last != other.hex) path.add(other.hex);
          edges.add(TrackEdge(from: station, to: other, hexPath: path));
          return; // stations end a run of track; they don't pass through
        }

        final hex = _hexOfPort(current);
        final added = hexPath.isEmpty || hexPath.last != hex;
        if (added) hexPath.add(hex);
        for (final next in raw[current] ?? const <String>[]) {
          if (next == previous || visited.contains(next)) continue;
          visited.add(next);
          explore(current, next, hexPath, visited);
          visited.remove(next);
        }
        if (added) hexPath.removeLast();
      }

      for (final firstHop in raw[start] ?? const <String>[]) {
        explore(start, firstHop, [station.hex], {start, firstHop});
      }
      adjacency[station.id] = edges;
    }

    return BoardGraph(stations: stations, adjacency: adjacency);
  }

  static HexCoord _hexOfPort(String port) {
    // Format: "E:<row>:<col>:<edge>"
    final parts = port.substring(2).split(':');
    return HexCoord(int.parse(parts[0]), int.parse(parts[1]));
  }
}
