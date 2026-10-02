import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_seed_data.dart';
import 'package:eighteen_xx_calculator/processing/route_finder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tiles 57 and 9 run between edges 0 and 3 -- the south-west and north-east
/// sides -- so turning them four steps lays their track east-west, along a
/// row of hexes.
const int eastWest = 4;

/// A line of cities joined by plain track:
///   (0,0) city - (0,1) track - (0,2) city - (0,3) track - (0,4) city
/// Each city pays 20, so a train that can reach all three pays 60.
BoardGraph lineOfThreeCities() => BoardGraph.build(
      {
        const HexCoord(0, 0): const PlacedTile('57', rotation: eastWest),
        const HexCoord(0, 1): const PlacedTile('9', rotation: eastWest),
        const HexCoord(0, 2): const PlacedTile('57', rotation: eastWest),
        const HexCoord(0, 3): const PlacedTile('9', rotation: eastWest),
        const HexCoord(0, 4): const PlacedTile('57', rotation: eastWest),
      },
      TileSeedData.all,
    );

void main() {
  group('cities full of tokens', () {
    // The line of three cities, each with one circle: A's token at the west
    // end, and the middle city full with B's.
    BoardGraph blockedLine() {
      final graph = lineOfThreeCities();
      graph.stationById('0_0_0')!.tokens = ['A'];
      graph.stationById('0_2_0')!.tokens = ['B'];
      return graph;
    }

    test("a company can't run through a city full of others' tokens", () {
      final graph = blockedLine();
      final route = RouteFinder.bestRouteThrough(
          graph, graph.stationById('0_0_0')!, 3,
          company: 'A');
      // As far as the full city, and no further.
      expect(route.stops.map((s) => s.id), ['0_0_0', '0_2_0']);
      expect(route.revenue, 40);
    });

    test('but can through one with its own token or an open circle', () {
      final graph = blockedLine();
      graph.stationById('0_2_0')!.tokens = ['A'];
      expect(
          RouteFinder.bestRouteThrough(graph, graph.stationById('0_0_0')!, 3,
                  company: 'A')
              .revenue,
          60);
      graph.stationById('0_2_0')!.tokens = [null];
      expect(
          RouteFinder.bestRouteThrough(graph, graph.stationById('0_0_0')!, 3,
                  company: 'A')
              .revenue,
          60);
    });

    test('a city keeps an open circle until every circle is taken', () {
      final city = StationNode(
          hex: const HexCoord(0, 0),
          stationIndex: 0,
          kind: StationKind.city,
          revenue: 30,
          slots: 2);
      city.tokens = ['B', null];
      expect(city.blocks('A'), isFalse);
      city.tokens = ['B', 'C'];
      expect(city.blocks('A'), isTrue);
      expect(city.blocks('B'), isFalse);
    });
  });

  group('bestRouteThrough', () {
    test('a one-stop train earns only its own station', () {
      final graph = lineOfThreeCities();
      final home = graph.stationById('0_0_0')!;
      final route = RouteFinder.bestRouteThrough(graph, home, 1);
      expect(route.revenue, 20);
      expect(route.stops, hasLength(1));
      expect(route.track, isEmpty);
    });

    test('a two-stop train runs to the neighbouring city', () {
      final graph = lineOfThreeCities();
      final home = graph.stationById('0_0_0')!;
      final route = RouteFinder.bestRouteThrough(graph, home, 2);
      expect(route.revenue, 40);
      expect(route.stops.map((s) => s.id), ['0_0_0', '0_2_0']);
    });

    test('a longer train keeps going down the line', () {
      final graph = lineOfThreeCities();
      final home = graph.stationById('0_0_0')!;
      final route = RouteFinder.bestRouteThrough(graph, home, 3);
      expect(route.revenue, 60);
      expect(route.stops.map((s) => s.id), ['0_0_0', '0_2_0', '0_4_0']);
    });

    test('a route runs both ways out of a middle station', () {
      final graph = lineOfThreeCities();
      final home = graph.stationById('0_2_0')!;
      final route = RouteFinder.bestRouteThrough(graph, home, 3);
      expect(route.revenue, 60);
      expect(route.stops, hasLength(3));
      // The home station is in the middle of the run, not at one end.
      expect(route.stops[1].id, '0_2_0');
      expect(route.stops.map((s) => s.id).toSet(),
          {'0_0_0', '0_2_0', '0_4_0'});
    });

    test('the route always includes the home station', () {
      final graph = lineOfThreeCities();
      for (final station in graph.stations) {
        final route = RouteFinder.bestRouteThrough(graph, station, 3);
        expect(route.stops.map((s) => s.id), contains(station.id));
      }
    });

    test('an isolated station earns only itself', () {
      final graph = BoardGraph.build(
        {const HexCoord(0, 0): const PlacedTile('57', rotation: eastWest)},
        TileSeedData.all,
      );
      final route =
          RouteFinder.bestRouteThrough(graph, graph.stations.single, 5);
      expect(route.revenue, 20);
      expect(route.track, isEmpty);
    });

    test('the better-paying branch wins', () {
      // A town (10) one way, a city (20) the other; a two-stop train from the
      // junction should take the city.
      final graph = BoardGraph.build(
        {
          const HexCoord(0, 0): const PlacedTile('58'), // town, edges 0 and 2
          const HexCoord(0, 1): const PlacedTile('57', rotation: eastWest), // city, edges 0 and 3
          const HexCoord(0, 2): const PlacedTile('57', rotation: eastWest), // city, edges 0 and 3
        },
        TileSeedData.all,
      );
      final home = graph.stationById('0_1_0')!;
      final route = RouteFinder.bestRouteThrough(graph, home, 2);
      expect(route.revenue, 40);
      expect(route.stops.map((s) => s.id), containsAll(['0_1_0', '0_2_0']));
    });

    test('no stops means no route', () {
      final graph = lineOfThreeCities();
      final route =
          RouteFinder.bestRouteThrough(graph, graph.stations.first, 0);
      expect(route.isEmpty, isTrue);
      expect(route.revenue, 0);
    });
  });

  group('branching boards', () {
    /// Tile 15 is a city with track to edges 0, 1, 2 and 3; putting a city on
    /// each of those neighbours makes a hub with four branches.
    BoardGraph hubWithFourBranches() {
      final tiles = <HexCoord, PlacedTile>{
        const HexCoord(2, 2): const PlacedTile('15'),
      };
      for (final edge in [0, 1, 2, 3]) {
        tiles[Board.neighborOf(const HexCoord(2, 2), edge)] =
            PlacedTile('57', rotation: HexGeometry.oppositeEdge(edge));
      }
      return BoardGraph.build(tiles, TileSeedData.all);
    }

    test('picks the two best branches out of a hub', () {
      final graph = hubWithFourBranches();
      final hub = graph.stationById('2_2_0')!;
      expect(graph.edgesFrom(hub), hasLength(4));

      // Make the branches worth different amounts.
      final branches = graph.stations.where((s) => s.id != hub.id).toList();
      final values = [10, 20, 30, 40];
      for (var i = 0; i < branches.length; i++) {
        branches[i].revenue = values[i];
      }

      // Three stops: the hub plus the two best branches, 30 + 40 + 30.
      final route = RouteFinder.bestRouteThrough(graph, hub, 3);
      expect(route.revenue, 100);
      expect(route.stops.map((s) => s.revenue), containsAll([40, 30]));
      expect(route.stops.map((s) => s.revenue), isNot(contains(10)));
    });

    test('a two-stop train takes only the single best branch', () {
      final graph = hubWithFourBranches();
      final hub = graph.stationById('2_2_0')!;
      final branches = graph.stations.where((s) => s.id != hub.id).toList();
      for (var i = 0; i < branches.length; i++) {
        branches[i].revenue = [10, 20, 30, 40][i];
      }
      final route = RouteFinder.bestRouteThrough(graph, hub, 2);
      expect(route.revenue, 70); // hub 30 + best branch 40
      expect(route.stops, hasLength(2));
    });

    test('a branch is never used twice in one route', () {
      final graph = hubWithFourBranches();
      final hub = graph.stationById('2_2_0')!;
      final route = RouteFinder.bestRouteThrough(graph, hub, 5);
      final ids = route.stops.map((s) => s.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      final trackIds = route.track.map((t) => t.id).toList();
      expect(trackIds.toSet(), hasLength(trackIds.length));
    });
  });

  group('bestRouteAnywhere', () {
    test('finds the best-paying run without being told where to start', () {
      final graph = lineOfThreeCities();
      final route = RouteFinder.bestRouteAnywhere(graph, 3);
      expect(route.revenue, 60);
      expect(route.stops, hasLength(3));
    });

    test('an empty board has no route', () {
      final graph = BoardGraph.build(const {}, TileSeedData.all);
      expect(RouteFinder.bestRouteAnywhere(graph, 4).isEmpty, isTrue);
    });
  });
}
