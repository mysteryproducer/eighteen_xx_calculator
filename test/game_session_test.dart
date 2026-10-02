import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/tile_rules.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/processing/hex_patch.dart';
import 'package:eighteen_xx_calculator/processing/mountain_detector.dart';
import 'package:eighteen_xx_calculator/processing/tile_classifier.dart';
import 'package:eighteen_xx_calculator/processing/token_detector.dart';
import 'package:eighteen_xx_calculator/processing/tunnel_detector.dart';
import 'package:eighteen_xx_calculator/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

final title = GameTitle.byId('1844')!;

GameSession newGame({bool startedEmpty = true}) => GameSession.start(
      title: title,
      name: 'Test game',
      startedEmpty: startedEmpty,
    );

/// Bern, BLS's home city, and the id its token is kept under: its city's
/// first circle.
final bern = title.map.byId('F11')!;
final bernStation =
    GameSession.slotId('${bern.coord.row}_${bern.coord.col}_0', 0);

/// A reading of [hex] as unchanged, [sure] of that, whose one city showed
/// [token].
HexReading readingWith(MapHex hex, TokenDetection token, {double sure = 0.9}) =>
    HexReading(
      hex: hex,
      reading: TileReading(
        option: TileOption.printed,
        confidence: sure,
        ranked: const [(TileOption.printed, 0.0)],
      ),
      patch: HexPatch(Float32List(HexPatch.size * HexPatch.size), Offset.zero,
          Float32List(6)),
      picture: Uint8List(0),
      tokens: {
        GameSession.slotId('${hex.coord.row}_${hex.coord.col}_0', 0): token,
      },
    );

TokenDetection tokenOf(String companyId, {double whose = 0.9}) => TokenDetection(
      present: true,
      confidence: 0.9,
      color: const Color(0xFFC1B22B),
      company: title.companyById(companyId),
      companyConfidence: whose,
    );

const emptySlot =
    TokenDetection(present: false, confidence: 0.9, color: Color(0xFFFFFFFF));

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
      // Nor does it unsettle it: a hex the user set stays theirs, so a
      // confident photo later can't quietly put it back.
      expect(state.source, HexSource.manual);
      expect(state.isDoubtful, isFalse);
      expect(state.suggestion, isNull);
    });

    test('a confident reading does pick up an upgrade laid since', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.setManually(basel, const PlacedTile('57'));
      session.recordReading(basel,
          tile: const PlacedTile('14'),
          confidence: 0.95,
          source: HexSource.closeUp,
          upgrade: true);
      expect(session.stateOf(basel).tile?.tileId, '14');
      expect(session.stateOf(basel).suggestion, isNull);
    });

    test('a confident reading that is no upgrade is kept for review, not taken',
        () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      session.setManually(basel, const PlacedTile('57', rotation: 1));
      session.recordReading(basel,
          tile: const PlacedTile('57', rotation: 3),
          confidence: 0.9,
          source: HexSource.closeUp);
      final state = session.stateOf(basel);
      expect(state.tile?.rotation, 1);
      expect(state.source, HexSource.manual);
      expect(state.suggestion?.tile?.rotation, 3);
      expect(session.suggestedHexes(title.map), {basel.coord});

      // A photo that agrees with the user settles it again...
      session.recordReading(basel,
          tile: const PlacedTile('57', rotation: 1),
          confidence: 0.9,
          source: HexSource.closeUp);
      expect(session.stateOf(basel).suggestion, isNull);

      // ...and so does the user, whatever they choose.
      session.recordReading(basel,
          tile: null, confidence: 0.9, source: HexSource.overview);
      expect(session.stateOf(basel).suggestion?.tile, isNull);
      expect(session.suggestedHexes(title.map), {basel.coord});
      session.setManually(basel, const PlacedTile('57', rotation: 1));
      expect(session.suggestedHexes(title.map), isEmpty);
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

    test('a tunnel carries nothing until the game opens it', () {
      final session = newGame();
      final tunnel = title.map.byId('H19')!; // Gotthard, printed for later
      final andermatt = title.map.byId('H17')!; // its town

      // Printed, the line is only a promise: the track shows on the map but
      // carries nothing, so the town on it reaches nowhere.
      expect(session.content(title)[tunnel.coord]!.edges, isNotEmpty);
      expect(session.content(title)[tunnel.coord]!.routableEdges, isEmpty);
      final before = session.graph(title);
      expect(
          before.edgesFrom(
              before.stations.firstWhere((s) => s.hex == andermatt.coord)),
          isEmpty);

      // The game opens the line by laying its own tiles, and the same track
      // starts carrying trains.
      final rules = TileRules(title);
      for (final hex in [andermatt, tunnel]) {
        session.setManually(hex, rules.options(hex, null, maxSteps: 1).last.placed);
      }
      final after = session.content(title);
      expect(after[tunnel.coord]!.routableEdges,
          session.content(title)[tunnel.coord]!.edges);
      // Andermatt's town now has track reaching the tunnel beside it.
      expect(after[andermatt.coord]!.routableEdges,
          contains(andermatt.printed.edges.first));
    });

    test('tokens are remembered per circle', () {
      final session = newGame();
      final basel = title.map.byId('C12')!;
      final id = '${basel.coord.row}_${basel.coord.col}_0';
      session.tokens[GameSession.slotId(id, 0)] = 'red';
      expect(session.graph(title).stations
          .firstWhere((s) => s.id == id).tokens, ['red']);
    });

    test('a city of two circles holds two tokens', () {
      final session = newGame();
      final zurich = title.map.byId('D19')!;
      session.setManually(zurich, const PlacedTile('907'));
      final id = '${zurich.coord.row}_${zurich.coord.col}_0';
      session.tokens[GameSession.slotId(id, 0)] = 'NOB';
      session.tokens[GameSession.slotId(id, 1)] = 'SCB';
      final station =
          session.graph(title).stations.firstWhere((s) => s.id == id);
      expect(station.tokens, ['NOB', 'SCB']);
      expect(station.holds('SCB'), isTrue);
    });

    test("a token can't fill the circle a company's home token needs", () {
      // Altdorf (G18) is the Gotthardbahn's home. With one circle, nobody
      // else may take it before the Gotthardbahn has its token there.
      final session = newGame();
      final altdorf = title.map.byId('G18')!;
      session.setManually(altdorf, const PlacedTile('5', rotation: 4));
      final id = '${altdorf.coord.row}_${altdorf.coord.col}_0';
      session.tokens[GameSession.slotId(id, 0)] = 'FNM';
      expect(session.tokenProblems(title).keys, [GameSession.slotId(id, 0)]);
      expect(session.tokenProblems(title).values.single, contains('GB'));
      // The Gotthardbahn's own token there is fine...
      session.tokens[GameSession.slotId(id, 0)] = 'GB';
      expect(session.tokenProblems(title), isEmpty);
      // ...and once a green tile gives the city a second circle, the other
      // can be taken while one stays free.
      session.setManually(altdorf, const PlacedTile('15'));
      session.tokens
        ..clear()
        ..[GameSession.slotId(id, 1)] = 'FNM';
      expect(session.tokenProblems(title), isEmpty);
    });

    test('tokens saved one per city go in the first circle', () {
      final old = newGame().toJson()
        ..['version'] = 2
        ..['tokens'] = {'2_6_0': 'SCB'}
        ..['tokenDoubts'] = ['2_6_0'];
      final loaded = GameSession.fromJson(old);
      expect(loaded.tokens, {'2_6_0_0': 'SCB'});
      expect(loaded.tokenDoubts, {'2_6_0_0'});
    });
  });

  group('tunnels', () {
    test('a tunnel adds narrow track through whatever is on the hex', () {
      final session = newGame();
      final gotthard = title.map.byId('H19')!;
      session.tunnels['H19'] = (2, 5);
      final content = session.content(title)[gotthard.coord]!;
      expect(content.segments.where((s) => s.narrow), hasLength(1));
      expect(content.routableEdges, containsAll(<int>{2, 5}));
    });

    TunnelReading tunnel((int, int)? path, double sure) =>
        TunnelReading(title.map.byId('H19')!, path, sure);

    test('a tunnel the user set is never changed by a photo', () {
      final session = newGame();
      session.tunnels['H19'] = (1, 4);
      BoardReader.applyTunnels(session, [tunnel((2, 5), 1)]);
      BoardReader.applyTunnels(session, [tunnel(null, 1)]);
      expect(session.tunnels['H19'], (1, 4));
    });

    test('an uncertain tunnel is flagged, and later photos settle it', () {
      final session = newGame();
      BoardReader.applyTunnels(session, [tunnel((2, 5), 0.6)]);
      expect(session.tunnels['H19'], (2, 5));
      expect(session.tunnelDoubts, {'H19'});
      BoardReader.applyTunnels(session, [tunnel(null, 0.9)]);
      expect(session.tunnels, isEmpty);
      expect(session.tunnelDoubts, isEmpty);
      BoardReader.applyTunnels(session, [tunnel((2, 5), 0.95)]);
      expect(session.tunnels['H19'], (2, 5));
      expect(session.tunnelDoubts, isEmpty);
    });
  });

  group('mountain railways', () {
    final pilatus = title.map.byId('G14')!;

    int pays(GameSession session) => session
        .content(title)[pilatus.coord]!
        .stations
        .single
        .revenueIn(session.phase);

    test('a mountain pays nothing until a plate is put on it, then what the '
        'plate pays in each phase', () {
      final session = newGame();
      expect(pays(session), 0);
      session.mountains['G14'] = 'XM2'; // 10, 40, 50, 60
      expect(pays(session), 10);
      session.phase = TileColor.green;
      expect(pays(session), 40);
      session.phase = TileColor.grey;
      expect(pays(session), 60);
    });

    test('a plate seen but not yet named pays nothing', () {
      final session = newGame();
      session.mountains['G14'] = GameSession.unknownPlate;
      expect(pays(session), 0);
    });

    MountainReading plate(bool present, double sure) =>
        MountainReading(pilatus, present, sure);

    test('a plate seen in a photo is recorded, for the user to name', () {
      final session = newGame();
      BoardReader.applyMountains(session, [plate(true, 0.9)]);
      expect(session.mountains['G14'], GameSession.unknownPlate);
      expect(session.mountainDoubts, {'G14'});
      // Seeing it again says no more about which plate it is.
      BoardReader.applyMountains(session, [plate(true, 1)]);
      expect(session.mountainDoubts, {'G14'});
    });

    test('a plate the user named is never changed by a photo', () {
      final session = newGame();
      session.mountains['G14'] = 'XM1';
      BoardReader.applyMountains(session, [plate(false, 1)]);
      BoardReader.applyMountains(session, [plate(true, 1)]);
      expect(session.mountains['G14'], 'XM1');
      expect(session.mountainDoubts, isEmpty);
    });

    test('only a clear photo of a bare mountain takes away a plate a photo '
        'found', () {
      final session = newGame();
      BoardReader.applyMountains(session, [plate(true, 0.9)]);
      BoardReader.applyMountains(session, [plate(false, 0.3)]);
      expect(session.mountains['G14'], GameSession.unknownPlate);
      BoardReader.applyMountains(session, [plate(false, 0.9)]);
      expect(session.mountains, isEmpty);
      expect(session.mountainDoubts, isEmpty);
    });
  });

  group('station tokens from photos', () {
    void read(GameSession session, TokenDetection token, {double sure = 0.9}) =>
        BoardReader.apply(session, [readingWith(bern, token, sure: sure)],
            source: HexSource.closeUp);

    test('a token seen in a photo is recorded as that company\'s', () {
      final session = newGame();
      read(session, tokenOf('BLS'));
      expect(session.tokens[bernStation], 'BLS');
      expect(session.tokenDoubts, isEmpty);
    });

    test('a token whose company was a guess is marked for checking', () {
      final session = newGame();
      read(session, tokenOf('BLS', whose: 0.2));
      expect(session.tokens[bernStation], 'BLS');
      expect(session.tokenDoubts, contains(bernStation));
    });

    test('a later photo can settle a guess', () {
      final session = newGame();
      read(session, tokenOf('BLS', whose: 0.2));
      read(session, tokenOf('GB'));
      expect(session.tokens[bernStation], 'GB');
      expect(session.tokenDoubts, isEmpty);
    });

    test('a guess a later photo shows was never there is taken away', () {
      final session = newGame();
      read(session, tokenOf('BLS', whose: 0.2));
      read(session, emptySlot);
      expect(session.tokens, isEmpty);
      expect(session.tokenDoubts, isEmpty);
    });

    test('a token the user set stays as they set it', () {
      final session = newGame();
      session.tokens[bernStation] = 'GB';
      read(session, tokenOf('BLS'));
      read(session, emptySlot);
      expect(session.tokens[bernStation], 'GB');
    });

    test('no tokens are read off a hex whose tile was in doubt', () {
      // Where the tile is unsure, so is where its cities are.
      final session = newGame();
      read(session, tokenOf('BLS'), sure: 0.3);
      expect(session.tokens, isEmpty);
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
      session.tokenDoubts.add('x');
      session.tunnels['H19'] = (2, 5);
      session.tunnelDoubts.add('H19');
      session.mountains['G14'] = 'XM3';
      session.mountains['L23'] = GameSession.unknownPlate;
      session.mountainDoubts.add('L23');
      session.facing = 1.2345;
      session.colourProfile = ColourProfile(
          colours: {TileColor.yellow: const Offset(0.02, 0.15)},
          measured: DateTime(2026, 10, 1, 11, 40));
      final f13 = title.map.byId('F13')!;
      session.setManually(f13, const PlacedTile('58', rotation: 4));
      session.recordReading(f13,
          tile: const PlacedTile('3', rotation: 2),
          confidence: 0.8,
          source: HexSource.closeUp);
      session.revenueOverrides['x'] = 90;
      await store.save(session);

      final loaded = (await store.list(titleId: '1844')).single;
      expect(loaded.id, session.id);
      expect(loaded.name, 'Test game');
      expect(loaded.phase, TileColor.green);
      expect(loaded.tileAt(title.map.byId('C12')!)?.rotation, 4);
      expect(loaded.tokens['x'], 'blue');
      expect(loaded.tokenDoubts, {'x'});
      expect(loaded.tunnels['H19'], (2, 5));
      expect(loaded.colourProfile?.colours[TileColor.yellow],
          const Offset(0.02, 0.15));
      expect(loaded.colourProfile?.measured, DateTime(2026, 10, 1, 11, 40));
      expect(loaded.tunnelDoubts, {'H19'});
      expect(loaded.mountains,
          {'G14': 'XM3', 'L23': GameSession.unknownPlate});
      expect(loaded.mountainDoubts, {'L23'});
      expect(loaded.facing, closeTo(1.2345, 1e-4));
      final suggestion = loaded.stateOf(title.map.byId('F13')!).suggestion;
      expect(suggestion?.tile?.tileId, '3');
      expect(suggestion?.tile?.rotation, 2);
      expect(suggestion?.confidence, 0.8);
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
