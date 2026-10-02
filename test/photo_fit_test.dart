// Runs grid detection on a real board photo and draws the result, for tuning
// detection against photos that aren't checked in.
//
//   BOARD_PHOTO=/path/to/photo.png BOARD_TITLE=1844 \
//     BOARD_PHOTO_OUT=/tmp/fit.png flutter test test/photo_fit_test.dart
//
// Skipped when BOARD_PHOTO isn't set.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/processing/gray_image.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/processing/plate_reader.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
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
    // BOARD_SESSION=<session.json> reads against a saved game, as the app
    // does, and lets the fit expect its tiles' colours; BOARD_FACING=<degrees>
    // says which way the board faced in the game's last photo.
    final saved = Platform.environment['BOARD_SESSION'];
    final session = saved == null
        // Read every visible hex as if this were the start of a new game.
        ? GameSession.start(
            title: title,
            name: 'photo test',
            startedEmpty: Platform.environment['BOARD_EMPTY'] != '0')
        : GameSession.fromJson(
            jsonDecode(File(saved).readAsStringSync()) as Map<String, Object?>);
    final facing = double.tryParse(Platform.environment['BOARD_FACING'] ?? '');
    final watch = Stopwatch()..start();
    // ignore: avoid_print
    final found = GridDetector(title.map, log: print).fitBoard(photo,
        hints: BoardHints(
          colours: saved == null
              ? const {}
              : {
                  for (final e in session.content(title).entries)
                    e.key: e.value.color,
                },
          tiled: {
            for (final hex in title.map.hexes)
              if (session.tileAt(hex) != null) hex.coord,
          },
          facing: facing == null ? null : facing * math.pi / 180,
        ));
    // ignore: avoid_print
    print('fit in ${watch.elapsedMilliseconds} ms: '
        '${found == null ? 'nothing found' : 'coverage ${found.coverage.toStringAsFixed(2)}, '
            'margin ${found.placementMargin?.toStringAsFixed(2)}, '
            '${found.visible.length} hexes visible, facing '
            '${(GridFit.facingOf(found.boardToImage, title.map.boardBounds.center) * 180 / math.pi).round()} degrees'}');
    expect(found, isNotNull);
    var fit = found!;

    final reader = BoardReader(title);
    // As the app does: lined up with what the game knows is there.
    final alignWatch = Stopwatch()..start();
    final aligned = await reader.alignToKnown(
        photo: photo,
        boardToImage: fit.boardToImage,
        hexes: fit.visible,
        session: session,
        // ignore: avoid_print
        log: print);
    // ignore: avoid_print
    print('aligned in ${alignWatch.elapsedMilliseconds} ms');
    fit = GridFit(
        boardToImage: aligned,
        visible: fit.visible,
        coverage: fit.coverage,
        hexCoverage: fit.hexCoverage,
        placementMargin: fit.placementMargin);
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
    final glared = [
      for (final r in readings)
        if (r.glare > 0.3) '${r.hex.id} ${(r.glare * 100).round()}%',
    ];
    // ignore: avoid_print
    print('glare: ${glared.isEmpty ? 'none' : glared.join(', ')}');
    final tokens = [
      for (final r in readings)
        for (final t in r.tokens.values)
          if (t.present) '${r.hex.id}=$t ${t.color}',
    ];
    // ignore: avoid_print
    print('tokens seen: ${tokens.isEmpty ? 'none' : tokens.join(', ')}');
    // BOARD_DUMP=<hex ids> writes each of those hexes as read, enlarged,
    // with where its token slots were looked at marked.
    final dump = Platform.environment['BOARD_DUMP'];
    if (dump != null) {
      final rgb = RgbImage.fromImage(photo);
      for (final id in dump.split(',')) {
        final hex = title.map.byId(id)!;
        final reading = readings.where((r) => r.hex == hex).firstOrNull;
        final content = reading == null
            ? null
            : BoardReader(title).rules.contentOf(hex, reading.reading.option);
        const px = 240;
        final out = img.Image(width: px, height: px);
        final sample = List<double>.filled(3, 0);
        Offset toBoard(double x, double y) =>
            hex.coord.boardCenter + Offset(x / px * 2.4 - 1.2, y / px * 2.4 - 1.2);
        for (int y = 0; y < px; y++) {
          for (int x = 0; x < px; x++) {
            final p = fit.boardToImage.apply(toBoard(x.toDouble(), y.toDouble()));
            if (!rgb.contains(p.dx, p.dy)) continue;
            rgb.sample(p.dx, p.dy, sample);
            out.setPixelRgb(x, y, sample[0].round(), sample[1].round(), sample[2].round());
          }
        }
        if (content != null) {
          for (final station in content.stations) {
            if (station.kind != StationKind.city) continue;
            for (final slot in TileRenderer.slotPositions(
                content, station.index, hex.coord.boardCenter, 1)) {
              final at = (slot - hex.coord.boardCenter + const Offset(1.2, 1.2)) / 2.4 * px.toDouble();
              img.drawCircle(out,
                  x: at.dx.round(), y: at.dy.round(),
                  radius: (TileRenderer.slotRadiusFor(station) / 2.4 * px).round(),
                  color: img.ColorRgb8(255, 0, 255));
            }
          }
        }
        final path = (Platform.environment['BOARD_PHOTO_OUT'] ?? '/tmp/fit.png')
            .replaceFirst('.png', '_hex_$id.png');
        File(path).writeAsBytesSync(img.encodePng(out));
        // ignore: avoid_print
        print('hex $id read as ${reading?.reading.option}: $path');
      }
    }
    if (saved != null) {
      // Against the saved game's tokens, as the user left them: each city
      // read, what was seen there and what is really there.
      final read = <String>{};
      for (final r in readings) {
        r.tokens.forEach((station, t) {
          read.add(station);
          final truth = session.tokens[station];
          final seen = t.present ? t.company?.id : null;
          final verdict = seen == truth
              ? 'ok   '
              : truth == null
                  ? 'EXTRA'
                  : seen == null
                      ? 'MISSED'
                      : 'WRONG';
          // ignore: avoid_print
          print('token $verdict ${r.hex.id} $station: seen ${seen ?? '-'} '
              '(${(t.confidence * 100).round()}%, whose '
              '${(t.companyConfidence * 100).round()}%) colour ${t.color.toARGB32().toRadixString(16)}, '
              'really ${truth ?? '-'}${r.reading.isReliable ? '' : ', tile doubtful'}');
        });
      }
      for (final station in session.tokens.keys) {
        // ignore: avoid_print
        if (!read.contains(station)) print('token UNREAD $station: really ${session.tokens[station]}');
      }
    }
    final tunnels = reader.readTunnels(
        photo: photo, boardToImage: fit.boardToImage, hexes: fit.visible);
    // ignore: avoid_print
    print('tunnels: ${tunnels.isEmpty ? 'none' : tunnels.join(', ')}');
    final mountains = reader.readMountains(
        photo: photo, boardToImage: fit.boardToImage, hexes: fit.visible);
    // ignore: avoid_print
    print('mountains: ${mountains.isEmpty ? 'none' : mountains.join(', ')}');
    final stripsOut =
        Platform.environment['BOARD_PHOTO_OUT'] ?? '/tmp/fit.png';
    final rgb = RgbImage.fromImage(photo);
    for (final m in mountains) {
      // The strips plates' figures are read from, to check by eye or run
      // through a text recognizer.
      final strip = PlateReader(title).strip(rgb, fit.boardToImage, m);
      if (strip == null) continue;
      final path = stripsOut.replaceFirst('.png', '_plate_${m.hex.id}.png');
      File(path).writeAsBytesSync(img.encodePng(strip));
      File(path.replaceFirst('.png', '_ink.png'))
          .writeAsBytesSync(img.encodePng(PlateReader.inked(strip)));
      // ignore: avoid_print
      print('  plate strip: $path (and _ink)');
    }

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
