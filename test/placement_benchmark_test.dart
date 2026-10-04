// Measures grid matching against the labelled photos of the data set: how
// far the detector puts each hex from where it really is, for a game joined
// part-way (nothing known) and with the tiles' colours known, as the app has
// them mid-game.
//
//   DATASET_DIR=/path/to/dataset flutter test test/placement_benchmark_test.dart
//
// Where each photo's hexes really are comes from manifest.json, as
// test/build_dataset_test.dart places them: hand-picked centres (snapped to
// the printed lines unless the photo says not to), or for a photo without
// them the detector's own placement with the truth's colours, which was
// checked by eye in fits/. So the second column flatters those; the first
// is the honest one. Prints a table; asserts nothing. Skipped when
// DATASET_DIR isn't set.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eighteen_scanner/geometry/homography.dart';
import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/processing/grid_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Platform.environment['DATASET_DIR'];
  test('places the labelled photos', () async {
    final manifest = jsonDecode(File('$root/manifest.json').readAsStringSync())
        as Map<String, Object?>;
    final truths = <String, (GameSession, GameTitle)>{};
    (manifest['truths'] as Map<String, Object?>).forEach((id, value) {
      final spec = value as Map<String, Object?>;
      final title =
          GameTitle.byId((spec['title'] ?? manifest['title']) as String)!;
      final path = spec['session'] as String?;
      truths[id] = (
        path == null
            ? GameSession.start(title: title, name: id, startedEmpty: true)
            : GameSession.fromJson(jsonDecode(File('$root/$path').readAsStringSync())
                as Map<String, Object?>),
        title,
      );
    });

    // How far [found] puts the hexes in view from where [truth] has them,
    // on average, in hex widths at each hex.
    double error(Homography truth, Homography? found, Iterable<HexCoord> hexes) {
      if (found == null) return double.infinity;
      var total = 0.0, n = 0;
      for (final c in hexes) {
        final width = truth.localScale(c.boardCenter) * math.sqrt(3);
        total += (truth.apply(c.boardCenter) - found.apply(c.boardCenter)).distance / width;
        n++;
      }
      return n == 0 ? double.infinity : total / n;
    }

    String shown(double e) => e.isInfinite ? 'none' : e.toStringAsFixed(2);
    final lines = <String>[];
    var coldRight = 0, hintedRight = 0, photos = 0;
    for (final value in manifest['photos'] as List<Object?>) {
      final spec = value as Map<String, Object?>;
      final (truth, title) = truths[spec['truth']]!;
      final detector = GridDetector(title.map);
      final photo = img.decodeImage(File('$root/${spec['file']}').readAsBytesSync())!;
      final hints = BoardHints(colours: {
        for (final e in truth.content(title).entries) e.key: e.value.color,
      }, tiled: {
        for (final hex in title.map.hexes)
          if (truth.tileAt(hex) != null) hex.coord,
      });
      final hinted = detector.fitBoard(photo, hints: hints);
      final points = spec['points'] as String?;
      Homography reference;
      if (points != null) {
        final from = <Offset>[], to = <Offset>[];
        for (final entry in points.split(';')) {
          final [hexId, at] = entry.split(':');
          final [x, y] = at.split(',').map(double.parse).toList();
          from.add(title.map.byId(hexId)!.coord.boardCenter);
          to.add(Offset(x, y));
        }
        final guess = Homography.fit(from, to)!;
        reference = spec['snap'] == false
            ? guess
            : detector.snap(photo, guess).boardToImage;
      } else if (hinted != null) {
        reference = hinted.boardToImage;
      } else {
        continue;
      }
      // The tile hexes wholly in the photo.
      final inView = [
        for (final hex in title.map.hexes)
          if (hex.takesTiles &&
              List.generate(6, (k) => reference.apply(HexGeometry.vertex(hex.coord.boardCenter, 1, k)))
                  .every((p) => p.dx >= 0 && p.dy >= 0 && p.dx < photo.width && p.dy < photo.height))
            hex.coord,
      ];
      final cold = detector.fitBoard(photo);
      final coldError = error(reference, cold?.boardToImage, inView);
      final hintedError = error(reference, hinted?.boardToImage, inView);
      photos++;
      if (coldError < 0.25) coldRight++;
      if (hintedError < 0.25) hintedRight++;
      lines.add('${(spec['id'] as String).padRight(36)} ${title.id}  '
          '${inView.length.toString().padLeft(3)} hexes  '
          'cold ${shown(coldError).padLeft(6)}  hinted ${shown(hintedError).padLeft(6)}'
          '${points == null ? '  (reference: hinted)' : ''}');
    }
    // ignore: avoid_print
    print([
      'mean error in hex widths (under 0.25 counts as placed):',
      ...lines,
      'placed: $coldRight of $photos cold, $hintedRight of $photos with colours known',
    ].join('\n'));
  }, skip: root == null ? 'Set DATASET_DIR' : false, timeout: const Timeout(Duration(minutes: 30)));
}
