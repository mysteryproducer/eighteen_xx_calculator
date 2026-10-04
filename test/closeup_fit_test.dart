// Runs a real close-up through the pipeline as the app would -- the capture
// guide's placement, the close-up fit, then reading the hexes -- and draws
// the result, for tuning against photos that aren't checked in.
//
//   CLOSEUP_PHOTO=/path/to/photo.png CLOSEUP_TARGET=H17 BOARD_TITLE=1844 \
//     CLOSEUP_OUT=/tmp/closeup.png flutter test test/closeup_fit_test.dart
//
// CLOSEUP_TARGET is the hex the app asked to be centred. CLOSEUP_RADIUS
// (default 1) is how far around it to read; CLOSEUP_SESSION a saved
// session.json to read against, rather than a game joined part-way;
// CLOSEUP_GLARE_FROM a photo of the whole board under the same light, whose
// glare the close-up is read with, as the app does.
//
// Skipped when CLOSEUP_PHOTO isn't set.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/processing/board_reader.dart';
import 'package:eighteen_scanner/processing/gray_image.dart';
import 'package:eighteen_scanner/processing/grid_detector.dart';
import 'package:eighteen_scanner/processing/plate_reader.dart';
import 'package:eighteen_scanner/screens/capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final photoPath = env['CLOSEUP_PHOTO'];
  test('fits and reads a close-up', () async {
    final title = GameTitle.byId(env['BOARD_TITLE'] ?? '1844')!;
    final map = title.map;
    final photo = img.decodeImage(File(photoPath!).readAsBytesSync())!;
    final target = map.byId(env['CLOSEUP_TARGET'] ?? '')!;
    final guide = CaptureGuide(
      target: target.coord,
      hexes: [for (final c in map.around([target.coord], 1)) map.at(c)!],
      instruction: '',
    );
    final guess = guide
        .homographyFor(Size(photo.width.toDouble(), photo.height.toDouble()));
    final saved = env['CLOSEUP_SESSION'];
    final session = saved == null
        ? GameSession.start(title: title, name: 'close-up test', startedEmpty: false)
        : GameSession.fromJson(
            jsonDecode(File(saved).readAsStringSync()) as Map<String, Object?>);
    // ignore: avoid_print
    final found = GridDetector(map, log: print).fitCloseUp(
        photo, guess, target.coord,
        hints: saved == null
            ? null
            : BoardHints(
                colours: {
                  for (final e in session.content(title).entries)
                    e.key: e.value.color,
                },
                tiled: {
                  for (final hex in map.hexes)
                    if (session.tileAt(hex) != null) hex.coord,
                },
              ));
    expect(found, isNotNull);
    var fit = found!;
    final at = fit.boardToImage.apply(target.coord.boardCenter);
    // ignore: avoid_print
    print('coverage ${fit.coverage.toStringAsFixed(2)}, ${target.id} at '
        '(${at.dx.round()}, ${at.dy.round()})');
    final around =
        map.around([target.coord], int.parse(env['CLOSEUP_RADIUS'] ?? '1'));
    final reader = BoardReader(title);
    // As the app does: lined up with what the game knows is there.
    final aligned = await reader.alignToKnown(
        photo: photo,
        boardToImage: fit.boardToImage,
        hexes: fit.visible,
        session: session,
        // ignore: avoid_print
        log: print);
    fit = GridFit(
        boardToImage: aligned,
        visible: fit.visible,
        coverage: fit.coverage,
        hexCoverage: fit.hexCoverage);
    final glareFrom = env['CLOSEUP_GLARE_FROM'];
    var prior = <HexCoord, double>{};
    if (glareFrom != null) {
      final board = img.decodeImage(File(glareFrom).readAsBytesSync())!;
      final boardFit = GridDetector(map).fitBoard(board)!;
      prior = reader.measureGlare(
          RgbImage.fromImage(board), boardFit.boardToImage, boardFit.visible);
    }
    final readings = await reader.read(
      glarePrior: prior,
      photo: photo,
      boardToImage: fit.boardToImage,
      hexes: around.intersection(fit.visible),
      context: fit.visible,
      session: session,
    );
    for (final r in readings) {
      final ranked = r.reading.ranked
          .take(3)
          .map((e) => '${e.$1} ${e.$2.toStringAsFixed(2)}')
          .join(', ');
      final tokens = r.tokens.values.map((t) => '$t').join(', ');
      // ignore: avoid_print
      print('${r.hex.id}: ${r.reading.option} '
          '${(r.reading.confidence * 100).round()}% ($ranked)'
          '${r.glare > 0.3 ? ' glare ${(r.glare * 100).round()}%' : ''}'
          '${tokens.isEmpty ? '' : '; $tokens'}');
    }

    for (final t in reader.readTunnels(
        photo: photo,
        boardToImage: fit.boardToImage,
        hexes: around.intersection(fit.visible))) {
      // ignore: avoid_print
      print('$t');
    }
    final plates = PlateReader(title);
    final outPath = env['CLOSEUP_OUT'] ?? '/tmp/closeup.png';
    for (final m in reader.readMountains(
        photo: photo, boardToImage: fit.boardToImage, hexes: fit.visible)) {
      // ignore: avoid_print
      print('$m');
      // The strip the plate's figures are read from, to check by eye or
      // run through a text recognizer.
      final strip = plates.strip(
          RgbImage.fromImage(photo), fit.boardToImage, m);
      if (strip != null) {
        final path = outPath.replaceFirst('.png', '_plate_${m.hex.id}.png');
        File(path).writeAsBytesSync(img.encodePng(strip));
        File(path.replaceFirst('.png', '_ink.png'))
            .writeAsBytesSync(img.encodePng(PlateReader.inked(strip)));
        // ignore: avoid_print
        print('  plate strip: $path (and _ink)');
      }
    }

    final out = img.Image.from(photo);
    for (final hex in fit.visible) {
      for (int i = 0; i < 6; i++) {
        final a = fit.boardToImage.apply(HexGeometry.vertex(hex.boardCenter, 1, i));
        final b = fit.boardToImage
            .apply(HexGeometry.vertex(hex.boardCenter, 1, (i + 1) % 6));
        img.drawLine(out,
            x1: a.dx.round(), y1: a.dy.round(), x2: b.dx.round(), y2: b.dy.round(),
            color: img.ColorRgb8(0, 220, 255), thickness: 3);
      }
      final c = fit.boardToImage.apply(hex.boardCenter);
      img.drawString(out, map.at(hex)?.id ?? '',
          font: img.arial24,
          x: c.dx.round() - 20,
          y: c.dy.round() - 12,
          color: img.ColorRgb8(255, 0, 60));
    }
    File(outPath).writeAsBytesSync(img.encodePng(out));
    // ignore: avoid_print
    print('wrote $outPath');
  }, skip: photoPath == null ? 'set CLOSEUP_PHOTO to run' : false);
}
