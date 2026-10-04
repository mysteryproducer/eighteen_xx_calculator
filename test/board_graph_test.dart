import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/models/board_graph.dart';
import 'package:eighteen_scanner/models/tile_definition.dart';
import 'package:eighteen_scanner/models/tile_seed_data.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tile 57 is a city with track out of edges 0 and 3, which are the
/// south-west and north-east sides; turned four steps ([eastWest]) it runs
/// east-west instead, so a row of them is a railway with stations. Tile 9 is
/// plain straight track between the same two sides.
const int eastWest = 4;
BoardGraph graphOf(Map<HexCoord, PlacedTile> tiles) =>
    BoardGraph.build(tiles, TileSeedData.all);

/// A city tile for the hex across [edge] of a hub, turned so one end of its
/// track faces back at the hub. Tile 57's ends are at edges 0 and 3, so
/// turning it by the number of the side facing the hub puts an end there.
PlacedTile facingHub(int edge) =>
    PlacedTile('57', rotation: HexGeometry.oppositeEdge(edge));

void main() {
  group('build', () {
    test('joins two cities through intervening plain track', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57', rotation: eastWest),
        const HexCoord(0, 1): const PlacedTile('9', rotation: eastWest),
        const HexCoord(0, 2): const PlacedTile('57', rotation: eastWest),
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
        const HexCoord(0, 0): const PlacedTile('57', rotation: eastWest),
        // Gap at (0, 1).
        const HexCoord(0, 2): const PlacedTile('57', rotation: eastWest),
      });
      expect(graph.stations, hasLength(2));
      expect(graph.edgesFrom(graph.stations.first), isEmpty);
      expect(graph.edgesFrom(graph.stations.last), isEmpty);
    });

    test('a neighbour whose track faces the wrong way stays disconnected', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57', rotation: eastWest),
        // Turned one step further, the straight runs south-east to
        // south-west, so nothing meets the cities either side of it.
        const HexCoord(0, 1): const PlacedTile('9', rotation: eastWest + 1),
        const HexCoord(0, 2): const PlacedTile('57', rotation: eastWest),
      });
      expect(graph.edgesFrom(graph.stationById('0_0_0')!), isEmpty);
    });

    test('rotation is what makes a corner connect', () {
      // Unturned, tile 57's track leaves by edge 0 (south-west) and edge 3
      // (north-east), so it meets a city on the hex below-left.
      final southWest = Board.neighborOf(const HexCoord(0, 0), 0);
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57'),
        southWest: const PlacedTile('57'),
      });
      final edges = graph.edgesFrom(graph.stationById('0_0_0')!);
      expect(edges, hasLength(1));
      expect(edges.single.to.hex, southWest);
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
        const HexCoord(0, 1): const PlacedTile('57', rotation: eastWest),
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
        tiles[Board.neighborOf(const HexCoord(2, 2), edge)] = facingHub(edge);
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
      // either side 3 or side 4, so the city beyond side 0 reaches both of
      // the cities on the far ends.
      const hub = HexCoord(0, 1);
      final entry = Board.neighborOf(hub, 0);
      final firstExit = Board.neighborOf(hub, 3);
      final secondExit = Board.neighborOf(hub, 4);

      final graph = graphOf({
        hub: const PlacedTile('23'),
        entry: facingHub(0),
        firstExit: facingHub(3),
        secondExit: facingHub(4),
      });

      final entryCity = graph.stations.firstWhere((s) => s.hex == entry);
      final reached = graph.edgesFrom(entryCity).map((e) => e.to.hex).toSet();
      expect(reached, {firstExit, secondExit});
    });

    test('the two branches are treated as separate track', () {
      const hub = HexCoord(0, 1);
      final entry = Board.neighborOf(hub, 0);
      final graph = graphOf({
        hub: const PlacedTile('23'),
        entry: facingHub(0),
        Board.neighborOf(hub, 3): facingHub(3),
        Board.neighborOf(hub, 4): facingHub(4),
      });
      final entryCity = graph.stations.firstWhere((s) => s.hex == entry);
      final ids = graph.edgesFrom(entryCity).map((e) => e.id).toSet();
      expect(ids, hasLength(2));
    });
  });

  group('TrackEdge identity', () {
    test('is the same run of track read from either end', () {
      final graph = graphOf({
        const HexCoord(0, 0): const PlacedTile('57', rotation: eastWest),
        const HexCoord(0, 1): const PlacedTile('9', rotation: eastWest),
        const HexCoord(0, 2): const PlacedTile('57', rotation: eastWest),
      });
      final forward = graph.edgesFrom(graph.stationById('0_0_0')!).single;
      final backward = graph.edgesFrom(graph.stationById('0_2_0')!).single;
      expect(forward.id, backward.id);
    });
  });
}
