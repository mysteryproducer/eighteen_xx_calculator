import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/synthetic_board.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late img.Image flat;
  late Homography flatTruth;

  setUpAll(() async {
    flat = await drawBoard(title.map);
    flatTruth = boardToDrawn(title.map, 26);
  });

  group('finding the map in a photo', () {
    test('a square-on photo is found, and every hex lands on its own hex',
        () async {
      final fit = GridDetector(title.map).fitBoard(flat);
      expect(fit, isNotNull);
      expect(fit!.coverage, greaterThan(0.8));
      // Well under half a hex out, so every hex is cut from the right place.
      expect(worstError(fit, flatTruth, fit.visible), lessThan(0.2));
      expect(fit.visible.length, title.map.hexes.length);
      expect(fit.isConvincing, isTrue);
    });

    test('a photo taken from an angle is deskewed', () async {
      // A camera held off to one side and tilted: the far side of the board
      // is smaller, which no amount of moving or scaling a flat grid fixes.
      final camera = Homography([
        0.86, 0.1, 40, //
        -0.06, 0.82, 60, //
        -0.00012, -0.00004, 1,
      ]);
      final photo = warp(flat, camera,
          width: (flat.width * 0.9).round(),
          height: (flat.height * 0.9).round());
      final fit = GridDetector(title.map).fitBoard(photo);
      expect(fit, isNotNull);
      final truth = flatTruth.then(camera);
      expect(worstError(fit!, truth, fit.visible), lessThan(0.25));
      expect(fit.isConvincing, isTrue);
    });

    test('a turned photo finds the map the right way round', () async {
      final turned = img.copyRotate(flat, angle: 90);
      final fit = GridDetector(title.map).fitBoard(turned);
      expect(fit, isNotNull);
      // Zurich should land on Zurich, not on some other hex 90 degrees away.
      final zurich = title.map.byId('D19')!.coord;
      final basel = title.map.byId('C12')!.coord;
      final zurichAt = fit!.boardToImage.apply(zurich.boardCenter);
      final baselAt = fit.boardToImage.apply(basel.boardCenter);
      // In a picture turned clockwise, Basel (north-west of Zurich) ends up
      // above and to the right.
      expect(baselAt.dx, greaterThan(zurichAt.dx));
      expect(
          worstError(fit, boardToDrawn(title.map, 26).then(rotate90(flat)),
              fit.visible),
          lessThan(0.25));
    });

    test('uneven lighting does not move the grid', () async {
      final photo = warp(flat, Homography.identity,
          width: flat.width, height: flat.height, shading: 0.55);
      final fit = GridDetector(title.map).fitBoard(photo);
      expect(fit, isNotNull);
      expect(worstError(fit!, flatTruth, fit.visible), lessThan(0.25));
    });

    test('a photo with no hexes in it finds nothing', () async {
      final blank = img.Image(width: 400, height: 300);
      img.fill(blank, color: img.ColorRgb8(180, 170, 150));
      expect(GridDetector(title.map).fitBoard(blank), isNull);
    });
  });

  group('close-ups', () {
    test('a close-up is placed from the capture guide', () async {
      final target = title.map.byId('F11')!.coord; // Bern
      // A close-up: eight times the size, roughly centred on Bern, and a bit
      // off in framing and angle, as a hand-held shot would be.
      final closeRadius = 120.0;
      final close = await drawBoard(title.map, hexRadius: closeRadius);
      final truth = boardToDrawn(title.map, closeRadius);
      final centre = truth.apply(target.boardCenter);
      const size = 900;
      final crop = Homography.similarity(
        radians: 0.05,
        translation: Offset(size / 2 - centre.dx + 18, size / 2 - centre.dy - 12),
      );
      final photo = warp(close, crop, width: size, height: size);

      // What the guide would have implied: the target in the middle of the
      // frame at the standard size.
      final guess = Homography.similarity(
        scale: 0.14 * size,
        translation: const Offset(size / 2, size / 2) -
            target.boardCenter * (0.14 * size),
      );
      final fit = GridDetector(title.map).fitCloseUp(photo, guess, target);
      expect(fit, isNotNull);
      expect(fit!.visible, contains(target));
      expect(worstError(fit, truth.then(crop), fit.visible), lessThan(0.25));
    });

    test('a close-up framed a hex off is put right by what is printed where',
        () async {
      // Asked for Andermatt (H17), the user lined the outline up on the hex
      // next door (H15): the grid looks the same either way, but the grey
      // mountain railways and purple tunnels around Andermatt don't.
      final target = title.map.byId('H17')!.coord;
      final framed = title.map.byId('H15')!.coord;
      const closeRadius = 120.0;
      final close = await drawBoard(title.map, hexRadius: closeRadius);
      final truth = boardToDrawn(title.map, closeRadius);
      final centre = truth.apply(framed.boardCenter);
      const size = 900;
      final crop = Homography.similarity(
        translation: Offset(size / 2 - centre.dx, size / 2 - centre.dy),
      );
      final photo = warp(close, crop, width: size, height: size);
      final guess = Homography.similarity(
        scale: 0.14 * size,
        translation: const Offset(size / 2, size / 2) -
            target.boardCenter * (0.14 * size),
      );
      final fit = GridDetector(title.map).fitCloseUp(photo, guess, target);
      expect(fit, isNotNull);
      expect(worstError(fit!, truth.then(crop), fit.visible), lessThan(0.25));
    });
  });

  group('snapping a hand-made alignment', () {
    test('a rough placement is pulled onto the printed lines', () async {
      // As if the user had dragged the corners close but not exactly.
      final rough = flatTruth.then(Homography.similarity(
        scale: 1.02,
        radians: 0.012,
        translation: const Offset(7, -5),
      ));
      final fit = GridDetector(title.map).snap(flat, rough);
      expect(worstError(fit, flatTruth, fit.visible), lessThan(0.15));
      expect(fit.coverage, greaterThan(0.8));
    });
  });
}
