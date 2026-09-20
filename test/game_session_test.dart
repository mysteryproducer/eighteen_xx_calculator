import 'dart:io';
import 'dart:typed_data';

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

final title = GameTitle.byId('1844')!;

GameSession newGame({bool startedEmpty = true}) => GameSession.start(
      title: title,
      name: 'Test game',
      startedEmpty: startedEmpty,
    );

void main() {
  group('what the session believes', () {
    test('a new game starts with the board as printed, and knows it', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      expect(session.tileAt(basel), isNull);
      expect(session.stateOf(basel).basisKnown, isTrue);
      expect(session.doubtfulHexes(title.map), isEmpty);
    });

    test('a game joined part-way knows nothing until it is photographed', () {
      final session = newGame(startedEmpty: false);
      final basel = title.map.byId('C12')!;
      expect(session.stateOf(basel).basisKnown, isFalse);
      expect(session.stateOf(basel).isDoubtful, isTrue);
      // Hexes that never change are known either way.
      expect(session.stateOf(title.map.byId('M18')!).isDoubtful, isFalse);
    });

    test('a confident reading becomes what later photos are matched against', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.recordReading(
        basel,
        tile: const PlacedTile('57', rotation: 2),
        confidence: 0.9,
        source: HexSource.overview,
        reference: 'abc',
      );
      final state = session.stateOf(basel);
      expect(state.tile?.tileId, '57');
      expect(state.basis?.rotation, 2);
      expect(state.reference, 'abc');
      expect(state.isDoubtful, isFalse);
    });

    test('a doubtful reading is shown but does not narrow the next one', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.recordReading(basel,
          tile: const PlacedTile('57'),
          confidence: 0.2,
          source: HexSource.overview,
          reference: 'x');
      final state = session.stateOf(basel);
      expect(state.tile?.tileId, '57', reason: 'best guess is still shown');
      expect(state.isDoubtful, isTrue);
      expect(state.basis, isNull, reason: 'still matched against bare map');
      expect(state.reference, isNull);
    });

    test("a doubtful reading doesn't overwrite what the user set", () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.setManually(basel, const PlacedTile('5', rotation: 1));
      session.recordReading(basel,
          tile: const PlacedTile('9'),
          confidence: 0.1,
          source: HexSource.closeUp);
      final state = session.stateOf(basel);
      expect(state.tile?.tileId, '5');
      // But it is flagged, so someone looks again.
      expect(state.isDoubtful, isTrue);
    });

    test('a confident reading does pick up a tile laid since', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.setManually(basel, const PlacedTile('57'));
      session.recordReading(basel,
          tile: const PlacedTile('14'),
          confidence: 0.95,
          source: HexSource.closeUp);
      expect(session.stateOf(basel).tile?.tileId, '14');
    });
  });

  group('the board it describes', () {
    test('printed track and laid tiles make one graph', () {
      final session = newGame();
      final graph = session.graph(title);
      // Every printed city, town and off-board area is a stop.
      expect(graph.stations.length, greaterThan(40));
      final milano = graph.stations
          .firstWhere((s) => s.hex == title.map.byId('M18')!.coord);
      expect(milano.kind, StationKind.offboard);
      expect(milano.revenue, 40); // yellow phase
      session.phase = TileColor.brown;
      expect(session.graph(title).stations
          .firstWhere((s) => s.hex == milano.hex).revenue, 70);
    });

    test('laying tiles joins places up', () {
      final session = newGame();
      // Bern and Langnau are neighbours along a row.
      final bern = title.map.byId('F11')!;
      final langnau = title.map.byId('F13')!;
      expect(session.graph(title).edgesFrom(
          session.graph(title).stations.firstWhere((s) => s.hex == bern.coord)),
          isEmpty);
      // Tiles 57 and 4 run between edges 0 and 3 (south-west to north-east);
      // turned four steps their track runs east-west, along the row.
      session.setManually(bern, const PlacedTile('57', rotation: 4));
      session.setManually(langnau, const PlacedTile('4', rotation: 4));
      final graph = session.graph(title);
      final bernStation = graph.stations.firstWhere((s) => s.hex == bern.coord);
      expect(graph.edgesFrom(bernStation).map((e) => e.to.hex),
          contains(langnau.coord));
    });

    test('tokens are remembered per station', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      final id = '${basel.coord.row}_${basel.coord.col}_0';
      session.tokens[id] = 'red';
      expect(session.graph(title).stations
          .firstWhere((s) => s.id == id).companyId, 'red');
    });
  });

  group('saving', () {
    late Directory dir;
    late SessionStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('session_test');
      store = SessionStore(root: () async => dir);
    });
    tearDown(() async => dir.delete(recursive: true));

    test('a session survives being saved and read back', () async {
      final session = newGame();
      session.phase = TileColor.green;
      session.setManually(title.map.byId('C12')!, const PlacedTile('57', rotation: 4));
      session.tokens['x'] = 'blue';
      session.revenueOverrides['x'] = 90;
      await store.save(session);

      final loaded = (await store.list(titleId: '1844')).single;
      expect(loaded.id, session.id);
      expect(loaded.name, 'Test game');
      expect(loaded.phase, TileColor.green);
      expect(loaded.tileAt(title.map.byId('C12')!)?.rotation, 4);
      expect(loaded.tokens['x'], 'blue');
      expect(loaded.revenueOverrides['x'], 90);
    });

    test('sessions are listed per title, newest first', () async {
      final first = newGame();
      await store.save(first);
      final second = GameSession.start(
          title: GameTitle.byId('1854')!, name: 'Austria', startedEmpty: true);
      await store.save(second);
      final third = newGame()..name = 'Later';
      third.updated = DateTime.now().add(const Duration(minutes: 5));
      await store.save(third);

      expect((await store.list(titleId: '1844')).map((s) => s.name),
          ['Later', 'Test game']);
      expect((await store.list(titleId: '1854')).single.name, 'Austria');
      expect(await store.list(), hasLength(3));
    });

    test('hex pictures are kept with the session', () async {
      final session = newGame();
      await store.saveHexPicture(session.id, 'C12', Uint8List.fromList([1, 2, 3]));
      expect(await store.hexPicture(session.id, 'C12'), [1, 2, 3]);
      expect(await store.hexPicture(session.id, 'D19'), isNull);
    });

    test('deleting a session takes its pictures with it', () async {
      final session = newGame();
      await store.save(session);
      await store.saveHexPicture(session.id, 'C12', Uint8List.fromList([1]));
      await store.delete(session.id);
      expect(await store.list(), isEmpty);
      expect(await store.hexPicture(session.id, 'C12'), isNull);
    });

    test('a game saved before the sides were renumbered is flagged for '
        'checking', () async {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.setManually(basel, const PlacedTile('57', rotation: 2));
      final old = session.toJson()..['version'] = 1;
      final loaded = GameSession.fromJson(old);
      // The tile is still there to look at, but nothing is taken on trust.
      expect(loaded.tileAt(basel)?.tileId, '57');
      expect(loaded.stateOf(basel).isDoubtful, isTrue);
      expect(loaded.stateOf(basel).basisKnown, isFalse);
      // Hexes with no tile on them are unaffected.
      expect(loaded.stateOf(title.map.byId('D13')!).isDoubtful, isFalse);
    });

    test('a junk file in the folder is skipped, not fatal', () async {
      final session = newGame();
      await store.save(session);
      final bad = Directory('${dir.path}/not-a-session');
      await bad.create(recursive: true);
      await File('${bad.path}/session.json').writeAsString('{oh dear');
      expect(await store.list(), hasLength(1));
    });
  });

  group('planning close-ups', () {
    test('one close-up covers a hex and its neighbours', () {
      final bern = title.map.byId('F11')!.coord;
      final requests = planCloseUps(title.map, {bern});
      expect(requests, hasLength(1));
      expect(requests.single.covers, {bern});
    });

    test('nearby doubtful hexes are grouped into one photo', () {
      final bern = title.map.byId('F11')!.coord;
      final neighbours = title.map.around([bern], 1);
      final requests = planCloseUps(title.map, neighbours);
      expect(requests, hasLength(1));
      expect(requests.single.target, bern);
      expect(requests.single.covers, neighbours);
    });

    test('hexes far apart need a photo each', () {
      final requests = planCloseUps(title.map, {
        title.map.byId('F11')!.coord,
        title.map.byId('G26')!.coord,
      });
      expect(requests, hasLength(2));
    });

    test('every doubtful hex ends up covered exactly once', () {
      final doubtful = {
        for (final id in ['C12', 'C14', 'D13', 'D15', 'G26', 'K22', 'F11'])
          title.map.byId(id)!.coord,
      };
      final requests = planCloseUps(title.map, doubtful);
      final covered = <HexCoord>[];
      for (final r in requests) {
        covered.addAll(r.covers);
      }
      expect(covered.toSet(), doubtful);
      expect(covered.length, doubtful.length, reason: 'no hex covered twice');
    });

    test('nothing doubtful means no photos', () {
      expect(planCloseUps(title.map, {}), isEmpty);
    });
  });
}
