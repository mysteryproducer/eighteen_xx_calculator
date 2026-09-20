import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_rules.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/processing/hex_patch.dart';
import 'package:eighteen_xx_calculator/processing/tile_classifier.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/synthetic_board.dart';

final rules = TileRules(title);

/// The patch a rendered tile makes, as if photographed square-on.
Future<HexPatch> patchOf(TileDefinition def) async =>
    HexPatch.fromTileImage(await TileRenderer.rasterize(def, size: HexPatch.size));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading one hex', () {
    late TileClassifier classifier;
    late HexPatch plainPatch;

    setUpAll(() async {
      classifier = TileClassifier();
      plainPatch = await patchOf(
          TileDefinition.parseDsl('blank', TileColor.plain, ''));
    });

    /// Classifies [shown] on [hex], as if it had been photographed.
    Future<TileReading> read(
      MapHex hex,
      TileDefinition shown, {
      PlacedTile? believed,
      HexPatch? reference,
    }) async {
      final options = rules.options(hex, believed, maxSteps: 2);
      final templates = {
        for (final o in options)
          keyOf(hex, o): rules.contentOf(hex, o)!,
      };
      await classifier.prepare(templates);
      final patch = await patchOf(shown);
      return classifier.classify(
        patch: patch,
        // Colour as measured against the bare map around it.
        relativeChroma: patch.chroma - plainPatch.chroma,
        options: options,
        keyOf: (o) => keyOf(hex, o),
        colourOf: (o) => rules.contentOf(hex, o)!.color,
        colours: renderedColours,
        reference: reference,
      );
    }

    test('an untouched hex reads as nothing laid', () async {
      final hex = title.map.hexes
          .firstWhere((h) => h.takesTiles && h.printed.stations.isEmpty);
      final reading = await read(hex, hex.printed);
      expect(reading.option.isPrinted, isTrue);
      expect(reading.isReliable, isTrue);
    });

    test('a tile is recognized, the right way round', () async {
      final hex = title.map.byId('C12')!; // Basel, a printed city
      // Every way tile 57 can legally go on Basel, read back.
      final ways = rules
          .options(hex, null, maxSteps: 1)
          .where((o) => o.tileId == '57')
          .toList();
      expect(ways.length, greaterThan(1));
      for (final way in ways) {
        final reading = await read(hex, rules.contentOf(hex, way)!);
        expect(reading.option.tileId, '57');
        expect(reading.option.rotation, way.rotation);
        expect(reading.isReliable, isTrue, reason: 'turn ${way.rotation}');
      }
    });

    test('an upgrade on a hex that already has a tile is recognized', () async {
      final hex = title.map.byId('C12')!;
      final laid = rules
          .options(hex, null, maxSteps: 1)
          .firstWhere((o) => o.tileId == '57')
          .placed!;
      final upgrade = rules
          .options(hex, laid, maxSteps: 1)
          .firstWhere((o) => o.tileId == '15');
      final reading = await read(hex, rules.contentOf(hex, upgrade)!,
          believed: laid);
      expect(reading.option.tileId, '15');
      expect(reading.option.rotation, upgrade.rotation);
    });

    test('a hex that has not changed reads as unchanged', () async {
      final hex = title.map.byId('C12')!;
      final laid = rules
          .options(hex, null, maxSteps: 1)
          .firstWhere((o) => o.tileId == '57')
          .placed!;
      final reading = await read(
        hex,
        title.tiles['57']!.rotated(laid.rotation),
        believed: laid,
      );
      expect(reading.option.tileId, '57');
      expect(reading.option.steps, 0);
      expect(reading.isReliable, isTrue);
    });

    test('what the hex looked like before settles a hard call', () async {
      // Map art the renderer doesn't draw -- hill shading, a lake, a place
      // name -- makes a bare hex look a little like track. Having seen the
      // hex before, the app knows that is just how it looks.
      final hex = title.map.byId('C10')!;
      final smudged = await patchOf(hex.printed);
      for (int i = 0; i < smudged.darkness.length; i += 7) {
        smudged.darkness[i] = 0.6; // speckle, as printed texture would
      }
      final reading = await read(hex, hex.printed, reference: smudged);
      expect(reading.option.isPrinted, isTrue);
    });

    test('a later tile on the same city is recognized as the upgrade', () async {
      final hex = title.map.byId('C12')!;
      // Yellow, then the green that follows it, then the brown after that --
      // each one whatever the rules actually allow on this hex.
      final yellow = rules
          .options(hex, null, maxSteps: 1)
          .firstWhere((o) => o.tileId == '57')
          .placed!;
      final green =
          rules.options(hex, yellow, maxSteps: 1).firstWhere((o) => o.steps > 0).placed!;
      final brown =
          rules.options(hex, green, maxSteps: 1).firstWhere((o) => o.steps > 0);
      final reading =
          await read(hex, rules.contentOf(hex, brown)!, believed: green);
      expect(reading.option.tileId, brown.tileId);
      expect(reading.option.rotation, brown.rotation);
      expect(rules.contentOf(hex, brown)!.color, TileColor.brown);
    });

    test('only what the rules allow is even considered', () async {
      final hex = title.map.byId('B23')!; // Rorschach, a printed town
      final options = rules.options(hex, null, maxSteps: 1);
      for (final option in options.where((o) => !o.isPrinted)) {
        expect(rules.contentOf(hex, option)!.townCount, 1);
      }
    });
  });

  group('reading a whole board', () {
    test('tiles laid on a photographed board are found', () async {
      // Three tiles on an otherwise untouched 1844 board.
      // Whatever the rules allow on each of these, so the test can't ask for
      // a lay that would be illegal (and so never considered when reading).
      final laid = {
        for (final id in ['C12', 'C14', 'D13'])
          title.map.byId(id)!.coord: rules
              .options(title.map.byId(id)!, null, maxSteps: 1)
              .where((o) => !o.isPrinted)
              .map((o) => o.placed!)
              .first,
      };
      final board = await drawBoard(title.map, laid: laid);
      // Photographed from a slight angle, as a hand-held shot would be.
      final camera = Homography([
        0.95, 0.04, 20, //
        -0.03, 0.97, 15, //
        -0.00005, -0.00002, 1,
      ]);
      final photo = warp(board, camera, width: board.width, height: board.height);

      final fit = GridDetector(title.map).fitBoard(photo);
      expect(fit, isNotNull);

      final session = GameSession.start(
          title: title, name: 'test', startedEmpty: true);
      final readings = await BoardReader(title).read(
        photo: photo,
        boardToImage: fit!.boardToImage,
        hexes: fit.visible,
        context: fit.visible,
        session: session,
      );
      BoardReader.apply(session, readings, source: HexSource.overview);

      for (final entry in laid.entries) {
        final hex = title.map.at(entry.key)!;
        expect(session.tileAt(hex)?.tileId, entry.value.tileId,
            reason: 'tile on ${hex.id}');
        expect(session.tileAt(hex)?.rotation, entry.value.rotation,
            reason: 'turn of the tile on ${hex.id}');
      }
      // And the rest of the board is still bare.
      final wrong = readings
          .where((r) => !laid.containsKey(r.hex.coord) && r.tile != null)
          .map((r) => '${r.hex.id}=${r.reading.option}')
          .toList();
      expect(wrong, isEmpty);
    });

    test('a close-up updates only the hexes it covers', () async {
      final bern = title.map.byId('F11')!;
      final session = GameSession.start(
          title: title, name: 'test', startedEmpty: true);
      // Somewhere else on the board, already known.
      final chur = title.map.byId('G26')!;
      session.setManually(chur, const PlacedTile('57'));

      final board = await drawBoard(title.map,
          hexRadius: 120,
          laid: {bern.coord: const PlacedTile('57', rotation: 2)});
      final truth = boardToDrawn(title.map, 120);
      final centre = truth.apply(bern.coord.boardCenter);
      const size = 900;
      final crop = Homography.similarity(
          translation: Offset(size / 2 - centre.dx, size / 2 - centre.dy));
      final photo = warp(board, crop, width: size, height: size);
      final guess = Homography.similarity(
        scale: 0.14 * size,
        translation: const Offset(size / 2, size / 2) -
            bern.coord.boardCenter * (0.14 * size),
      );

      final fit = GridDetector(title.map).fitCloseUp(photo, guess, bern.coord);
      expect(fit, isNotNull);
      final around = title.map.around([bern.coord], 1);
      final readings = await BoardReader(title).read(
        photo: photo,
        boardToImage: fit!.boardToImage,
        hexes: around.intersection(fit.visible),
        context: fit.visible,
        session: session,
      );
      BoardReader.apply(session, readings, source: HexSource.closeUp);

      expect(session.tileAt(bern)?.tileId, '57');
      expect(session.tileAt(bern)?.rotation, 2);
      // The far side of the board is untouched by this photo.
      expect(session.tileAt(chur)?.tileId, '57');
      expect(session.stateOf(chur).source, HexSource.manual);
    });

    test('a photo of the bare board is remembered rather than read', () async {
      final board = await drawBoard(title.map);
      final fit = GridDetector(title.map).fitBoard(board)!;
      final session = GameSession.start(
          title: title, name: 'test', startedEmpty: true);
      final readings = await BoardReader(title).readAsPrinted(
        photo: board,
        boardToImage: fit.boardToImage,
        hexes: fit.visible,
        session: session,
      );
      expect(readings, hasLength(fit.visible.length));
      final basel = title.map.byId('C12')!;
      expect(session.stateOf(basel).reference, isNotNull);
      expect(session.stateOf(basel).tile, isNull);
      expect(session.doubtfulHexes(title.map), isEmpty);
    });
  });
}

String keyOf(MapHex hex, TileOption option) =>
    option.isPrinted ? 'map:${hex.id}' : 'tile:${option.tileId}@${option.rotation}';

/// Colours as the renderer draws them, measured the way the reader measures
/// a photo: against the bare map around the hex. Drawn tiles are far more
/// saturated than photographed ones, which is why the classifier's own
/// defaults (tuned on a photo) aren't used here.
const ColourModel renderedColours = ColourModel({
    TileColor.plain: Offset(0, 0),
    TileColor.yellow: Offset(0.027, 0.265),
    TileColor.green: Offset(-0.197, 0.089),
    TileColor.brown: Offset(0.165, 0.226),
    TileColor.grey: Offset(-0.007, -0.025),
    TileColor.red: Offset(0.26, 0.135),
    TileColor.blue: Offset(-0.22, -0.32),
    TileColor.purple: Offset(-0.03, -0.11),
}, spread: 0.08);
