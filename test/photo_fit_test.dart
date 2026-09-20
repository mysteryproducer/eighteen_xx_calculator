// Runs grid detection on a real board photo and draws the result, for tuning
// detection against photos that aren't checked in.
//
//   BOARD_PHOTO=/path/to/photo.png BOARD_TITLE=1844 \
//     BOARD_PHOTO_OUT=/tmp/fit.png flutter test test/photo_fit_test.dart
//
// Skipped when BOARD_PHOTO isn't set.
import 'dart:io';
import 'dart:math' as math;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final photoPath = Platform.environment['BOARD_PHOTO'];
  test('fits the map to a board photo', () async {
    final title = GameTitle.byId(Platform.environment['BOARD_TITLE'] ?? '1844')!;
    var photo = img.decodeImage(File(photoPath!).readAsBytesSync())!;
    // BOARD_ROTATE=90|180|270 and BOARD_CROP=<fraction> try the same photo
    // turned or trimmed, to check detection doesn't depend on framing.
    final turn = int.tryParse(Platform.environment['BOARD_ROTATE'] ?? '');
    if (turn != null) photo = img.copyRotate(photo, angle: turn);
    final crop = double.tryParse(Platform.environment['BOARD_CROP'] ?? '');
    if (crop != null) {
      final dx = (photo.width * crop).round(), dy = (photo.height * crop).round();
      photo = img.copyCrop(photo,
          x: dx, y: dy, width: photo.width - 2 * dx, height: photo.height - 2 * dy);
    }
    final watch = Stopwatch()..start();
    // ignore: avoid_print
    final fit = GridDetector(title.map, log: print).fitBoard(photo);
    // ignore: avoid_print
    print('fit in ${watch.elapsedMilliseconds} ms: '
        '${fit == null ? 'nothing found' : 'coverage ${fit.coverage.toStringAsFixed(2)}, '
            'margin ${fit.placementMargin?.toStringAsFixed(2)}, '
            '${fit.visible.length} hexes visible'}');
    expect(fit, isNotNull);
    fit!;

    // Read every visible hex as if this were the start of a new game.
    final session = GameSession.start(
        title: title,
        name: 'photo test',
        startedEmpty: Platform.environment['BOARD_EMPTY'] != '0');
    final reader = BoardReader(title);
    final readWatch = Stopwatch()..start();
    final readings = await reader.read(
      photo: photo,
      boardToImage: fit.boardToImage,
      hexes: fit.visible,
      context: fit.visible,
      session: session,
    );
    final tiles = readings.where((r) => !r.reading.option.isPrinted).toList();
    final doubtful = readings.where((r) => !r.reading.isReliable).toList();
    // ignore: avoid_print
    print('read ${readings.length} hexes in ${readWatch.elapsedMilliseconds} ms: '
        '${tiles.length} read as tiles (${tiles.map((r) => '${r.hex.id}=${r.reading.option}').join(' ')}), '
        '${doubtful.length} doubtful (${doubtful.map((r) => '${r.hex.id} ${(r.reading.confidence * 100).round()}%').join(', ')})');

    final out = img.Image.from(photo);
    for (final hex in fit.visible) {
      final c = hex.boardCenter;
      final cover = fit.hexCoverage[hex] ?? 0;
      final color = cover > 0.6
          ? img.ColorRgb8(0, 220, 255)
          : cover > 0.3
              ? img.ColorRgb8(255, 200, 0)
              : img.ColorRgb8(255, 0, 60);
      for (int i = 0; i < 6; i++) {
        final a = fit.boardToImage.apply(HexGeometry.vertex(c, 1, i));
        final b = fit.boardToImage.apply(HexGeometry.vertex(c, 1, (i + 1) % 6));
        img.drawLine(out,
            x1: a.dx.round(), y1: a.dy.round(), x2: b.dx.round(), y2: b.dy.round(),
            color: color, thickness: 2);
      }
      final centre = fit.boardToImage.apply(c);
      final label = title.map.at(hex)?.id ?? '';
      img.drawString(out, label,
          font: img.arial14,
          x: centre.dx.round() - 12,
          y: centre.dy.round() - 7,
          color: color);
    }
    final outPath = Platform.environment['BOARD_PHOTO_OUT'] ?? '/tmp/fit.png';

    File(outPath).writeAsBytesSync(img.encodePng(out));
    // ignore: avoid_print
    print('wrote $outPath (${math.min(out.width, out.height)} px short side)');
  }, skip: photoPath == null ? 'set BOARD_PHOTO to run' : false);
}
