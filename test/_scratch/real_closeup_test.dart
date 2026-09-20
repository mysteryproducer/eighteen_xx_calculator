import 'dart:io';
import 'dart:ui' show Size;
import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/screens/capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real close-up', () {
    final s = Platform.environment['S']!;
    final title = GameTitle.byId('1844')!;
    final targetId = Platform.environment['TARGET'] ?? 'F13';
    final target = title.map.byId(targetId)!;
    for (final name in (Platform.environment['PHOTOS'] ?? '').split(',')) {
      final photo = img.decodeImage(File('$s/$name.png').readAsBytesSync())!;
      final guide = CaptureGuide(
        target: target.coord,
        hexes: [for (final c in title.map.around([target.coord], 1)) title.map.at(c)!],
        instruction: '',
      );
      final guess = guide.homographyFor(
          Size(photo.width.toDouble(), photo.height.toDouble()));
      // ignore: avoid_print
      final fit = GridDetector(title.map, log: print).fitCloseUp(photo, guess, target.coord);
      // ignore: avoid_print
      print('$name: ${fit == null ? 'NOT FOUND' : 'coverage ${fit.coverage.toStringAsFixed(2)}, '
          '${fit.visible.length} visible: ${fit.visible.map((c) => title.map.at(c)?.id).take(12).join(" ")}'}');
      if (fit == null) continue;
      final out = img.Image.from(photo);
      for (final hex in fit.visible) {
        final c = hex.boardCenter;
        for (int i = 0; i < 6; i++) {
          final a = fit.boardToImage.apply(HexGeometry.vertex(c, 1, i));
          final b = fit.boardToImage.apply(HexGeometry.vertex(c, 1, (i + 1) % 6));
          img.drawLine(out, x1: a.dx.round(), y1: a.dy.round(),
              x2: b.dx.round(), y2: b.dy.round(),
              color: img.ColorRgb8(0, 230, 255), thickness: 3);
        }
        final centre = fit.boardToImage.apply(c);
        img.drawString(out, title.map.at(hex)!.id, font: img.arial24,
            x: centre.dx.round() - 16, y: centre.dy.round() - 12,
            color: img.ColorRgb8(255, 0, 255));
      }
      File('$s/${name}_fit.png').writeAsBytesSync(img.encodePng(out));
    }
  });
}
