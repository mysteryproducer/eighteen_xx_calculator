import 'dart:math' as math;

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_rules.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/processing/hex_patch.dart';
import 'package:eighteen_xx_calculator/processing/mountain_detector.dart';
import 'package:eighteen_xx_calculator/processing/tile_classifier.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:eighteen_xx_calculator/processing/gray_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
        exitsOf: (o) => rules.contentOf(hex, o)!.exitStrengths,
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
      // Three tiles on an otherwise untouched 1844 board, well inside the
      // map so a photo taken at an angle still has them in frame. Each is
      // whatever the rules allow there, so the test can't ask for a lay that
      // would be illegal (and so never considered when reading).
      final middle = title.map.boardBounds.center;
      final inland = title.map.hexes
          .where((h) =>
              h.takesTiles && h.coord.neighbors.every(title.map.contains))
          .toList()
        ..sort((a, b) => (a.coord.boardCenter - middle)
            .distance
            .compareTo((b.coord.boardCenter - middle).distance));
      final laid = {
        for (final hex in inland.take(3))
          hex.coord: rules
              .options(hex, null, maxSteps: 1)
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

    test('a tile the app misread is taken back by a clear photo, but not one '
        'the user set', () async {
      // A close-up framed a hex off once read a straight on bare map, and was
      // sure of it. Tiles are never taken up in play, so without a way back
      // that mistake would stay for good.
      final misread = title.map.byId('H15')!;
      final set = title.map.byId('H11')!;
      final session = GameSession.start(
          title: title, name: 'test', startedEmpty: true);
      session.recordReading(misread,
          tile: const PlacedTile('9', rotation: 2),
          confidence: 0.83,
          source: HexSource.closeUp);
      session.setManually(set, const PlacedTile('9', rotation: 2));

      const radius = 120.0;
      final board = await drawBoard(title.map, hexRadius: radius);
      final truth = boardToDrawn(title.map, radius);
      final centre = truth.apply(title.map.byId('H13')!.coord.boardCenter);
      const size = 900;
      final crop = Homography.similarity(
          translation: Offset(size / 2 - centre.dx, size / 2 - centre.dy));
      final photo = warp(board, crop, width: size, height: size);
      final readings = await BoardReader(title).read(
        photo: photo,
        boardToImage: truth.then(crop),
        hexes: [misread.coord, set.coord],
        context: title.map.around([misread.coord, set.coord], 1),
        session: session,
      );
      BoardReader.apply(session, readings, source: HexSource.closeUp);

      expect(session.tileAt(misread), isNull);
      expect(session.tileAt(set)?.tileId, '9');
    });

    test('a tunnel piece is found, and no tunnel where there is none',
        () async {
      // Gotthard with a tunnel from Stans to I20 across it, drawn as the
      // pieces are printed, and every other tunnel hex bare.
      final gotthard = title.map.byId('H19')!;
      final withTunnel = gotthard.printed.withSegments([
        TileSegment(EdgeEndpoint(2), EdgeEndpoint(5), narrow: true),
      ]);
      const radius = 60.0;
      final board = await drawBoard(title.map,
          hexRadius: radius, drawn: {gotthard.coord: withTunnel});
      final readings = BoardReader(title).readTunnels(
        photo: board,
        boardToImage: boardToDrawn(title.map, radius),
        hexes: title.map.coords,
      );
      final found = {
        for (final r in readings)
          if (r.path != null) r.hex.id: r.path,
      };
      expect(found, {'H19': (2, 5)});
      expect(readings.firstWhere((r) => r.hex.id == 'H19').confidence,
          greaterThan(0.5));
    });

    group('lining the grid up with what the game knows', () {
      const radius = 40.0;
      final truth = boardToDrawn(title.map, radius);
      // A few tiles, spread over the middle of the board, as a game would
      // have them.
      final laid = {
        for (final (id, tile, turn) in const [
          ('C12', '6', 2), ('F13', '58', 4), ('G12', '27', 2),
          ('F15', '9', 1), ('E18', '57', 0), ('I8', '9', 1),
        ])
          title.map.byId(id)!.coord: PlacedTile(tile, rotation: turn),
      };
      GameSession knowing() {
        final session = GameSession.start(
            title: title, name: 'test', startedEmpty: false);
        laid.forEach((c, tile) => session.setManually(title.map.at(c)!, tile));
        return session;
      }

      double worstOff(Homography fit) => [
            for (final c in laid.keys)
              (fit.apply(c.boardCenter) - truth.apply(c.boardCenter)).distance /
                  radius,
          ].reduce(math.max);

      test('a grid a fraction of a hex off is put right', () async {
        final board =
            await drawBoard(title.map, hexRadius: radius, laid: laid);
        final off = Homography.similarity(translation: const Offset(0.3, -0.35))
            .then(truth);
        expect(worstOff(off), greaterThan(0.4));
        final aligned = await BoardReader(title).alignToKnown(
          photo: board,
          boardToImage: off,
          hexes: title.map.coords,
          session: knowing(),
        );
        expect(worstOff(aligned), lessThan(0.1));
      });

      test('a grid already right is left there', () async {
        final board =
            await drawBoard(title.map, hexRadius: radius, laid: laid);
        final aligned = await BoardReader(title).alignToKnown(
          photo: board,
          boardToImage: truth,
          hexes: title.map.coords,
          session: knowing(),
        );
        expect(worstOff(aligned), lessThan(0.05));
      });
    });

    group('mountain railways', () {
      const radius = 60.0;
      final toImage = boardToDrawn(title.map, radius);
      final pilatus = title.map.byId('G14')!;

      /// The board with a plate on Pilatus, as a camera under a lamp sees
      /// it, with a veil of glare of [glare] over Pilatus.
      Future<img.Image> photographed({double glare = 0}) async {
        final board = await drawBoard(title.map, hexRadius: radius);
        drawPlate(board, toImage, pilatus);
        underLamp(board,
            glare: glare,
            at: toImage.apply(pilatus.coord.boardCenter),
            reach: radius * 2.5);
        return board;
      }

      List<MountainReading> read(img.Image photo) =>
          BoardReader(title).readMountains(
            photo: photo,
            boardToImage: toImage,
            hexes: title.map.coords,
          );

      test('a plate is found, and none on a bare mountain', () async {
        final readings = read(await photographed());
        expect({for (final r in readings) r.hex.id}, title.mountainHexes);
        expect({for (final r in readings) if (r.present) r.hex.id}, {'G14'});
        for (final r in readings) {
          expect(r.confidence, greaterThan(0.5), reason: '$r');
        }
      });

      test('a plate faded by glare is still found', () async {
        final readings = read(await photographed(glare: 0.6));
        final reading = readings.firstWhere((r) => r.hex == pilatus);
        expect(reading.present, isTrue, reason: '$reading');
      });

      test('under glare, a bare mountain is not sure it is bare', () async {
        // The same glare over Pilatus with no plate on it: the colours of a
        // plate could have faded out of sight, so this says little.
        final board = await drawBoard(title.map, hexRadius: radius);
        underLamp(board,
            glare: 0.9,
            at: toImage.apply(pilatus.coord.boardCenter),
            reach: radius * 2.5);
        final reading = read(board).firstWhere((r) => r.hex == pilatus);
        expect(reading.present, isFalse);
        expect(reading.confidence, lessThan(0.5));
        // And says why, for the user.
        expect(reading.washout, greaterThan(0.5));
      });
    });

    group('glare', () {
      const radius = 40.0;
      final truth = boardToDrawn(title.map, radius);
      final langnau = title.map.byId('F13')!;

      /// [board] as a camera under a lamp sees it: exposed darker than the
      /// drawing's near-white paper, with glare over Langnau -- white light
      /// added, most in the middle, fading out over a few hexes.
      img.Image glared(img.Image board) {
        final out = img.Image.from(board);
        final centre = truth.apply(langnau.coord.boardCenter);
        for (final p in out) {
          final d = (Offset(p.x.toDouble(), p.y.toDouble()) - centre).distance /
              (radius * 3.5);
          final veil = 0.8 * (1 - d * d).clamp(0.0, 1.0);
          num lit(num c) => c * 0.75 + (255 - c * 0.75) * veil;
          p
            ..r = lit(p.r)
            ..g = lit(p.g)
            ..b = lit(p.b);
        }
        return out;
      }

      test('glare is found where it is, and only there', () async {
        final photo = glared(await drawBoard(title.map, hexRadius: radius));
        final glare = BoardReader(title).measureGlare(
            RgbImage.fromImage(photo), truth, title.map.coords.toSet());
        expect(glare[langnau.coord], greaterThan(0.6));
        expect(glare[title.map.byId('K22')!.coord], lessThan(0.1));
      });

      test('under glare, bare map is not taken as read', () async {
        // A game joined part-way: the app can't know Langnau's neighbour is
        // bare, and glare could be hiding a tile there.
        final photo = glared(await drawBoard(title.map, hexRadius: radius));
        final session = GameSession.start(
            title: title, name: 'test', startedEmpty: false);
        final underGlare = title.map.byId('E12')!; // beside Langnau
        final clear = title.map.byId('J21')!;
        final readings = await BoardReader(title).read(
          photo: photo,
          boardToImage: truth,
          hexes: [underGlare.coord, clear.coord],
          context: title.map.coords,
          session: session,
        );
        final read = {for (final r in readings) r.hex.id: r};
        expect(read['E12']!.glare, greaterThan(0.3));
        expect(read['E12']!.reading.isReliable, isFalse);
        expect(read['J21']!.tile, isNull);
        expect(read['J21']!.reading.isReliable, isTrue);
      });

      test('calibration measures each colour from what the game knows, and '
          'leaves glare out', () async {
        final yellowHexes = ['C10', 'E14', 'G10', 'I8', 'K12'];
        final laid = {
          for (final id in yellowHexes)
            title.map.byId(id)!.coord: const PlacedTile('9'),
        };
        final photo =
            glared(await drawBoard(title.map, hexRadius: radius, laid: laid));
        final session = GameSession.start(
            title: title, name: 'test', startedEmpty: true);
        for (final id in yellowHexes) {
          session.setManually(title.map.byId(id)!, const PlacedTile('9'));
        }
        final result = BoardReader(title).calibrate(
            photo: photo,
            boardToImage: truth,
            hexes: title.map.coords,
            session: session);
        final yellow = result.profile.colours[TileColor.yellow]!;
        expect((yellow - renderedColours.expected(TileColor.yellow)).distance,
            lessThan(0.06));
        expect(result.samples[TileColor.plain], greaterThan(30));
        expect(result.glare, contains(langnau.coord));
      });
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
