import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_rules.dart';
import 'package:eighteen_xx_calculator/processing/train_routes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sides of a pointy-topped hex: west and east, along a row.
const west = 1, east = 4;

/// A city on a row of hexes, with track out to the west and east -- or
/// only the one way, at the [westEnd] or [eastEnd] of the row.
String city(int revenue, {bool westEnd = false, bool eastEnd = false}) =>
    'city=revenue:$revenue'
    '${westEnd ? '' : ';path=a:$west,b:_0'}'
    '${eastEnd ? '' : ';path=a:$east,b:_0'}';

String town(int revenue) =>
    'town=revenue:$revenue;path=a:$west,b:_0;path=a:$east,b:_0';

const track = 'path=a:$west,b:$east';
const narrowTrack = 'path=a:$west,b:$east,track:narrow';

const trains = [
  TrainType(name: '2', base: '2', distance: 2),
  TrainType(name: '3', base: '3', distance: 3),
  TrainType(name: '2H', base: '2', distance: 2, kind: TrainKind.hexes),
  TrainType(name: '4H', base: '4', distance: 4, kind: TrainKind.hexes),
  TrainType(
      name: '2E', base: '2E', distance: 99, pays: 2, kind: TrainKind.express),
  TrainType(name: '1+', base: '1+', distance: 1, freeTowns: true),
  TrainType(name: '2+', base: '2+', distance: 2, freeTowns: true),
];

/// A title of the [hexes] given, by coordinate and printing (with its
/// colour), and the route graph of them as printed.
(GameTitle, BoardGraph) board(
  Map<HexCoord, (TileColor, String)> hexes, {
  RouteRules rules = RouteRules.none,
  Map<String, Set<String>> groups = const {},
  Map<String, int> bonus = const {},
}) {
  final mapHexes = [
    for (final e in hexes.entries)
      MapHex(
        id: 'R${e.key.row}C${e.key.col}',
        coord: e.key,
        printed: TileDefinition.parseDsl(
            'map:R${e.key.row}C${e.key.col}', e.value.$1, e.value.$2),
      ),
  ];
  final title = GameTitle(
    id: 'test',
    name: 'Test',
    description: '',
    map: MapLayout(mapHexes),
    tiles: const {},
    trains: trains,
    routeRules: rules,
    stopGroups: groups,
    groupBonus: bonus,
  );
  final graph = BoardGraph.fromContent(
      {for (final h in mapHexes) h.coord: h.printed});
  return (title, graph);
}

/// Hexes along row 0 from column 0, west to east.
Map<HexCoord, (TileColor, String)> row(List<String> codes,
        {Map<int, TileColor> colours = const {}}) =>
    {
      for (int i = 0; i < codes.length; i++)
        HexCoord(0, i): (colours[i] ?? TileColor.yellow, codes[i]),
    };

StationNode at(BoardGraph graph, int col, [int row = 0]) =>
    graph.stations.firstWhere((s) => s.hex == HexCoord(row, col));

List<int> columns(TrainRun run) => [for (final s in run.stops) s.hex.col];

void main() {
  group('trains together', () {
    test('two trains share a city but not track', () {
      final (title, graph) = board(row([
        city(20, westEnd: true),
        city(30),
        city(40),
        city(50, eastEnd: true),
      ]));
      at(graph, 1).tokens = ['A'];
      final runs = TrainRouter(title, graph, 'A').best(['2', '2']);
      expect(runs.revenue, 70 + 50);
      expect(runs.runs.map(columns), unorderedEquals([
        [1, 2],
        [1, 0],
      ]));
      expect(runs.complete, isTrue);
    });

    test('a second train gets nothing when the only track is taken', () {
      final (title, graph) = board(row([
        city(20, westEnd: true),
        city(30),
        city(40, eastEnd: true),
      ]));
      at(graph, 0).tokens = ['A'];
      final runs = TrainRouter(title, graph, 'A').best(['3', '2']);
      // The 3 runs the whole line; the 2 has no track left to run on.
      expect(runs.runs[0].revenue, 90);
      expect(runs.runs[1].runs, isFalse);
      expect(runs.revenue, 90);
    });

    test('three trains out of a hub each take their own branch', () {
      final (title, graph) = board({
        const HexCoord(2, 2): (
          TileColor.yellow,
          'city=revenue:10;path=a:$west,b:_0;path=a:$east,b:_0;path=a:3,b:_0'
        ),
        const HexCoord(2, 1): (TileColor.yellow, 'city=revenue:50;path=a:$east,b:_0'),
        const HexCoord(2, 3): (TileColor.yellow, 'city=revenue:40;path=a:$west,b:_0'),
        // North-east of the hub, joined by its south-west side.
        const HexCoord(1, 2): (TileColor.yellow, 'city=revenue:30;path=a:0,b:_0'),
      });
      at(graph, 2, 2).tokens = ['A'];
      final router = TrainRouter(title, graph, 'A');
      expect(router.best(['2', '2', '2']).revenue, 60 + 50 + 40);
      // Two 3s: one runs through the hub between two branches, the other
      // out along the third.
      final threes = router.best(['3', '3']);
      expect(threes.revenue, 140);
      final used = <String>{};
      for (final run in threes.runs) {
        for (final edge in run.track) {
          for (final s in edge.segments) {
            expect(used.add(s), isTrue, reason: '$s used twice');
          }
        }
      }
    });

    test("a company with no token on the board doesn't run", () {
      final (title, graph) = board(row([city(20, westEnd: true), city(30)]));
      final runs = TrainRouter(title, graph, 'A').best(['2']);
      expect(runs.runs.single.runs, isFalse);
    });
  });

  group('kinds of train', () {
    test('an H train counts hexes, not stops', () {
      final (title, graph) = board(row([
        city(20, westEnd: true),
        track,
        track,
        city(50),
        city(10, eastEnd: true),
      ]));
      at(graph, 0).tokens = ['A'];
      final router = TrainRouter(title, graph, 'A');
      expect(router.best(['2']).revenue, 70);
      // Four hexes from the token to the 50: out of a 2H's reach.
      expect(router.best(['2H']).runs.single.runs, isFalse);
      expect(router.best(['4H']).revenue, 70);
    });

    test("an H train can't visit a red off-board area", () {
      final (title, graph) = board(row([
        'offboard=revenue:yellow_60|green_80;path=a:$east,b:_0',
        city(20),
        city(10, eastEnd: true),
      ], colours: {0: TileColor.red}));
      at(graph, 1).tokens = ['A'];
      final router = TrainRouter(title, graph, 'A');
      expect(router.best(['2']).revenue, 80);
      expect(router.best(['2H']).revenue, 30);
    });

    test('a D train is paid the diesel figure, and only a D train', () {
      // As 1889's off-boards print it.
      final (title, graph) = board(row([
        'offboard=revenue:yellow_30|brown_60|diesel_100;path=a:$east,b:_0',
        city(20, eastEnd: true),
      ], colours: {0: TileColor.red}));
      at(graph, 1).tokens = ['A'];
      final router = TrainRouter(title, graph, 'A');
      expect(router.best(['2']).revenue, 50);
      expect(router.best(['D']).revenue, 120);
      // A figure the user set stands for every train.
      at(graph, 0)
        ..revenue = 70
        ..revenueSource = RevenueSource.manual;
      expect(TrainRouter(title, graph, 'A').best(['D']).revenue, 90);
    });

    test('an express is paid for its best stops, one with a token, and red '
        'off-boards on top', () {
      final (title, graph) = board(row([
        'offboard=revenue:yellow_10|green_20;path=a:$east,b:_0',
        city(10),
        city(50),
        city(60),
        city(70, eastEnd: true),
      ], colours: {0: TileColor.red}));
      at(graph, 1).tokens = ['A'];
      final run = TrainRouter(title, graph, 'A').best(['2E']).runs.single;
      // Runs the whole line; the best two would be 70 and 60, but one paid
      // stop has to be the token's, and the red area pays besides.
      expect(run.stops.length, 5);
      expect(run.paid.map((s) => s.revenue), unorderedEquals([70, 10, 10]));
      expect(run.revenue, 90);
    });

    test('a "+" train runs to so many cities and any number of towns', () {
      final (title, graph) = board(row([
        city(20, westEnd: true),
        town(10),
        town(10),
        city(30, eastEnd: true),
      ]));
      at(graph, 0).tokens = ['A'];
      final router = TrainRouter(title, graph, 'A');
      expect(router.best(['1+']).revenue, 40);
      expect(router.best(['2+']).revenue, 70);
      expect(router.best(['2']).revenue, 30);
    });

    test('a name the title lacks runs as many stops as it says', () {
      final (title, graph) = board(row([
        city(20, westEnd: true),
        city(30),
        city(40),
        city(50, eastEnd: true),
      ]));
      at(graph, 0).tokens = ['A'];
      expect(TrainRouter(title, graph, 'A').best(['4']).revenue, 140);
    });
  });

  group('the rules of a route', () {
    test("two of a tile's tracks meeting at a side don't join there", () {
      // A curve each way from the middle hex's west side, like 1844's 29
      // at H11: a city at the far end of each curve, and one to the west.
      final (title, graph) = board({
        const HexCoord(2, 2): (
          TileColor.green,
          'path=a:$west,b:3;path=a:$west,b:5'
        ),
        const HexCoord(2, 1): (TileColor.yellow, 'city=revenue:20;path=a:$east,b:_0'),
        // North-east of the middle, joined by its south-west side.
        const HexCoord(1, 2): (TileColor.yellow, 'city=revenue:30;path=a:0,b:_0'),
        // South-east of it, joined by its north-west side.
        const HexCoord(3, 2): (TileColor.yellow, 'city=revenue:40;path=a:2,b:_0'),
      });
      final northEast = at(graph, 2, 1), southEast = at(graph, 2, 3);
      // Each curve runs to the west city, not round to the other curve.
      expect(graph.edgesFrom(northEast).map((e) => e.to),
          [at(graph, 1, 2)]);
      expect(graph.edgesFrom(southEast).map((e) => e.to),
          [at(graph, 1, 2)]);
      northEast.tokens = ['A'];
      final runs = TrainRouter(title, graph, 'A').best(['2', '2']);
      // North-east to west pays 50; the second train can't also cross the
      // west side, so it has nowhere to go.
      expect(runs.revenue, 50);
      expect(runs.runs.where((r) => r.runs), hasLength(1));
    });

    test("a full city ends a route", () {
      final (title, graph) = board(row([
        city(20, westEnd: true),
        city(30),
        city(40, eastEnd: true),
      ]));
      at(graph, 0).tokens = ['A'];
      at(graph, 1).tokens = ['B'];
      expect(TrainRouter(title, graph, 'A').best(['3']).revenue, 50);
    });

    test('tunnel track pays extra for each stop', () {
      final (title, graph) = board(
        row([city(20, westEnd: true), narrowTrack, city(30, eastEnd: true)]),
        rules: const RouteRules(narrowBonus: 10),
      );
      at(graph, 0).tokens = ['A'];
      final run = TrainRouter(title, graph, 'A').best(['2']).runs.single;
      expect(run.bonus, 20);
      expect(run.revenue, 70);
      expect(run.bonuses.map((b) => (b.reason, b.amount)), [
        ('Tunnel track: 10 for each of the 2 stops paid for', 20),
      ]);
    });

    test('joining east and west pays both bonuses', () {
      final (title, graph) = board(
        row([
          'offboard=revenue:yellow_30;path=a:$east,b:_0',
          city(20),
          'offboard=revenue:yellow_40;path=a:$west,b:_0',
        ], colours: {0: TileColor.red, 2: TileColor.red}),
        rules: const RouteRules(bonusPairs: [('E', 'W')]),
        groups: {
          'R0C0': {'W'},
          'R0C2': {'E'},
        },
        bonus: {'R0C0': 50, 'R0C2': 30},
      );
      at(graph, 1).tokens = ['A'];
      final run = TrainRouter(title, graph, 'A').best(['3']).runs.single;
      expect(run.bonus, 80);
      expect(run.revenue, 30 + 20 + 40 + 80);
      // Spelt out, with what each area adds.
      expect(run.bonuses.single.reason, 'East to west: R0C2 30 + R0C0 50');
      expect(run.bonuses.single.amount, 80);
    });

    test('a stop that pays nothing is out of bounds where the title says',
        () {
      final hexes = row([
        city(20, westEnd: true),
        'offboard=revenue:0;path=a:$west,b:_0',
      ], colours: {1: TileColor.grey});
      final (barred, barredGraph) =
          board(hexes, rules: const RouteRules(noEmptyStops: true));
      at(barredGraph, 0).tokens = ['A'];
      expect(TrainRouter(barred, barredGraph, 'A').best(['2']).runs.single.runs,
          isFalse);
      final (open, openGraph) = board(hexes);
      at(openGraph, 0).tokens = ['A'];
      expect(TrainRouter(open, openGraph, 'A').best(['2']).revenue, 20);
    });
  });

  group('the 1844 board', () {
    test('mountain bonuses and groups come from the printing', () {
      final title = GameTitle.byId('1844')!;
      expect(title.stopGroups['C8'], containsAll(['W']));
      expect(title.groupBonus['C8'], 50);
      // Printed without an icon, it pays its named group's.
      expect(title.groupBonus['A20'], 30);
      expect(title.routeRules.noEmptyStops, isTrue);
      expect(title.trainNamed('8E')!.kind, TrainKind.express);
      expect(title.trainNamed('3H')!.kind, TrainKind.hexes);
      expect(GameTitle.byId('1854')!.trainNamed('2+')!.freeTowns, isTrue);
    });
  });

  group("on 1889's map", () {
    test('Matsuyama runs to Imabari, which pays a D train most', () {
      final g1889 = GameTitle.byId('1889')!;
      final rules = TileRules(g1889);
      final matsuyama = g1889.map.byId('E2')!;
      final imabari = g1889.map.byId('F1')!;
      final toward = [
        for (int side = 0; side < 6; side++)
          if (Board.neighborOf(matsuyama.coord, side) == imabari.coord) side,
      ].single;
      // Imabari's own track meets that side.
      expect(imabari.printed.edges, contains((toward + 3) % 6));
      final session = GameSession.start(
          title: g1889, name: 'Shikoku', startedEmpty: true);
      final tile = rules.options(matsuyama, null, maxSteps: 1).firstWhere(
          (o) =>
              !o.isPrinted &&
              rules.contentOf(matsuyama, o)!.edges.contains(toward));
      session.setManually(
          matsuyama, PlacedTile(tile.tileId!, rotation: tile.rotation));
      final circle = '${matsuyama.coord.row}_${matsuyama.coord.col}_0';
      session.tokens[GameSession.slotId(circle, 0)] = 'IR';
      int pays(String train) =>
          TrainRouter(g1889, session.graph(g1889), 'IR').best([train]).revenue;
      // A yellow city of 20, and Imabari's 30 while tiles are yellow...
      expect(pays('2'), 50);
      // ...60 once they are brown...
      session.phase = TileColor.brown;
      expect(pays('6'), 80);
      // ...and 100 to a diesel.
      expect(pays('D'), 120);
    });
  });
}
