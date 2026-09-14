import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_seed_data.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tile 57 is a city with track out of edges 0 (east) and 3 (west), so
/// unrotated it runs straight across the hex; tile 9 is plain straight track
/// between the same two edges. A row of them is a railway with stations.
BoardGraph graphOf(Map<HexCoord, PlacedTile> tiles) =>
    BoardGraph.build(tiles, TileSeedData.all);

void main() {
  group('build', () {
    test('joins two cities through intervening plain track', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57'),
        const HexCoord(0, 1): const PlacedTile('9'),
        const HexCoord(0, 2): const PlacedTile('57'),
      });

      expect(graph.stations, hasLength(2));
      final west = graph.stationById('0_0_0')!;
      final east = graph.stationById('0_2_0')!;
      expect(west.kind, StationKind.city);
      expect(west.revenue, 20);

      final fromWest = graph.edgesFrom(west);
      expect(fromWest, hasLength(1));
      expect(fromWest.single.to.id, east.id);
      // The run crosses all three hexes, which is what the route overlay draws.
      expect(fromWest.single.hexPath, [
        const HexCoord(0, 0),
        const HexCoord(0, 1),
        const HexCoord(0, 2),
      ]);
      // And the connection is there from the other end too.
      expect(graph.edgesFrom(east).single.to.id, west.id);
    });

    test('track that stops short of a neighbour connects nothing', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57'),
        // Gap at (0, 1).
        const HexCoord(0, 2): const PlacedTile('57'),
      });
      expect(graph.stations, hasLength(2));
      expect(graph.edgesFrom(graph.stations.first), isEmpty);
      expect(graph.edgesFrom(graph.stations.last), isEmpty);
    });

    test('a neighbour whose track faces the wrong way stays disconnected', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57'),
        // Tile 9 turned one step runs edges 1-4, so nothing meets edge 3.
        const HexCoord(0, 1): const PlacedTile('9', rotation: 1),
        const HexCoord(0, 2): const PlacedTile('57'),
      });
      expect(graph.edgesFrom(graph.stationById('0_0_0')!), isEmpty);
    });

    test('rotation is what makes a corner connect', () {
      // Tile 57 at (0,0) turned so its track leaves by edge 1 (south-east),
      // meeting a city on the hex below-right.
      final southEast = Board.neighborOf(const HexCoord(0, 0), 1);
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57', rotation: 1),
        southEast: const PlacedTile('57', rotation: 1),
      });
      final edges = graph.edgesFrom(graph.stationById('0_0_0')!);
      expect(edges, hasLength(1));
      expect(edges.single.to.hex, southEast);
    });

    test('towns on a tile become separate revenue centres', () {
      // Tile 1 carries two towns on separate runs of track.
      final graph = graphOf({const HexCoord(0, 0): const PlacedTile('1')});
      expect(graph.stations, hasLength(2));
      expect(graph.stations.every((s) => s.kind == StationKind.town), isTrue);
      expect(graph.stations.map((s) => s.revenue), everyElement(10));
    });

    test('blank hexes contribute nothing', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile(TileSeedData.blankTileId),
        const HexCoord(0, 1): const PlacedTile(TileSeedData.blankTileId),
      });
      expect(graph.stations, isEmpty);
    });

    test('unknown tile ids are ignored rather than crashing', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('not-a-tile'),
        const HexCoord(0, 1): const PlacedTile('57'),
      });
      expect(graph.stations, hasLength(1));
    });

    test('a junction city links every direction its track reaches', () {
      // Tile 15 is a city with track to edges 0, 1, 2 and 3; put a city on
      // each of those neighbours and all four should connect.
      final tiles = <HexCoord, PlacedTile>{
        const HexCoord(2, 2): const PlacedTile('15'),
      };
      for (final edge in [0, 1, 2, 3]) {
        final neighbour = Board.neighborOf(const HexCoord(2, 2), edge);
        // Tile 57 runs edges 0-3; rotate it so one end faces back at us.
        tiles[neighbour] =
            PlacedTile('57', rotation: HexGeometry.oppositeEdge(edge));
      }
      final graph = graphOf(tiles);
      final hub = graph.stationById('2_2_0')!;
      expect(graph.edgesFrom(hub), hasLength(4));
      expect(hub.slots, 2);
    });
  });

  group('hexsides carrying two tracks', () {
    test('both branches of a tile like #23 connect', () {
      // Tile 23 runs 0-3 and 0-4: a train entering by side 0 can leave by
      // either side 3 or side 4, so the city beyond side 0 reaches both of the
      // cities on the far ends.
      const hub = HexCoord(0, 1);
      final west = Board.neighborOf(hub, 3);
      final northWest = Board.neighborOf(hub, 4);
      final east = Board.neighborOf(hub, 0);

      final graph = graphOf({
        hub: const PlacedTile('23'),
        // Tile 57 runs 0-3; rotate each city so one end faces the hub.
        west: const PlacedTile('57'),
        northWest: PlacedTile('57', rotation: HexGeometry.oppositeEdge(4)),
        east: const PlacedTile('57'),
      });

      final eastCity = graph.stations.firstWhere((s) => s.hex == east);
      final reached = graph.edgesFrom(eastCity).map((e) => e.to.hex).toSet();
      expect(reached, {west, northWest});
    });

    test('the two branches are treated as separate track', () {
      const hub = HexCoord(0, 1);
      final graph = graphOf({
        hub: const PlacedTile('23'),
        Board.neighborOf(hub, 3): const PlacedTile('57'),
        Board.neighborOf(hub, 4):
            PlacedTile('57', rotation: HexGeometry.oppositeEdge(4)),
        Board.neighborOf(hub, 0): const PlacedTile('57'),
      });
      final eastCity =
          graph.stations.firstWhere((s) => s.hex == Board.neighborOf(hub, 0));
      final ids = graph.edgesFrom(eastCity).map((e) => e.id).toSet();
      expect(ids, hasLength(2));
    });
  });

  group('TrackEdge identity', () {
    test('is the same run of track read from either end', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57'),
        const HexCoord(0, 1): const PlacedTile('9'),
        const HexCoord(0, 2): const PlacedTile('57'),
      });
      final forward = graph.edgesFrom(graph.stationById('0_0_0')!).single;
      final backward = graph.edgesFrom(graph.stationById('0_2_0')!).single;
      expect(forward.id, backward.id);
    });
  });
}
