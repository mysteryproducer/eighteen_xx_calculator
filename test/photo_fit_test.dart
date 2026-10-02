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

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/board_reader.dart';
import 'package:eighteen_xx_calculator/processing/gray_image.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/processing/hex_patch.dart';
import 'package:eighteen_xx_calculator/processing/plate_reader.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_rules.dart';
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
    // BOARD_POINTS="D15:995,295;K10:658,788;..." places the map by hand, from
    // where hexes' centres are in the photo, and snaps it to the printed
    // lines as the align screen's "Fit to the photo" does: for a photo the
    // detector can't place by itself.
    final points = Platform.environment['BOARD_POINTS'];
    final byHand = points == null
        ? null
        : () {
            final from = <Offset>[], to = <Offset>[];
            for (final entry in points.split(';')) {
              final [id, at] = entry.split(':');
              final [x, y] = at.split(',').map(double.parse).toList();
              from.add(title.map.byId(id)!.coord.boardCenter);
              to.add(Offset(x, y));
            }
            final guess = Homography.fit(from, to)!;
            if (Platform.environment['BOARD_NOSNAP'] != null) {
              return GridFit(
                boardToImage: guess,
                visible: {
                  for (final hex in title.map.coords)
                    if (() {
                      final p = guess.apply(hex.boardCenter);
                      return p.dx > 0 && p.dy > 0 && p.dx < photo.width && p.dy < photo.height;
                    }())
                      hex,
                },
                coverage: 0,
                hexCoverage: const {},
              );
            }
            final snapped = Platform.environment['BOARD_REFINE'] != null
                ? GridDetector(title.map).refine(photo, guess)
                : GridDetector(title.map).snap(photo, guess);
            // ignore: avoid_print
            print('by hand: snapped, coverage ${snapped.coverage.toStringAsFixed(2)}');
            return snapped;
          }();
    // BOARD_HINTS=<session.json>: place the map with what that game knows
    // -- its tiles' colours, which way the board faced -- while still
    // reading as BOARD_SESSION, to look at reading apart from placing.
    final hintsPath = Platform.environment['BOARD_HINTS'];
    final hinting = hintsPath == null
        ? (saved == null ? null : session)
        : GameSession.fromJson(jsonDecode(File(hintsPath).readAsStringSync())
            as Map<String, Object?>);
    // ignore: avoid_print
    final found = byHand ?? GridDetector(title.map, log: print).fitBoard(photo,
        hints: BoardHints(
          colours: hinting == null
              ? const {}
              : {
                  for (final e in hinting.content(title).entries)
                    e.key: e.value.color,
                },
          tiled: {
            for (final hex in title.map.hexes)
              if (hinting?.tileAt(hex) != null) hex.coord,
          },
          facing: facing == null
              ? hinting?.facing
              : facing * math.pi / 180,
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
    // BOARD_ALIGN_WITH=<session.json>: line the grid up with another game's
    // tiles (the truth, say) while reading as BOARD_SESSION, to tell a misread
    // from a misplaced grid.
    final alignWith = Platform.environment['BOARD_ALIGN_WITH'];
    final aligned = await reader.alignToKnown(
        photo: photo,
        boardToImage: fit.boardToImage,
        hexes: fit.visible,
        session: alignWith == null
            ? session
            : GameSession.fromJson(jsonDecode(File(alignWith).readAsStringSync())
                as Map<String, Object?>),
        // ignore: avoid_print
        log: print);
    // ignore: avoid_print
    print('aligned in ${alignWatch.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('homography ${jsonEncode(aligned.toJson())}');
    fit = GridFit(
        boardToImage: aligned,
        visible: fit.visible,
        coverage: fit.coverage,
        hexCoverage: fit.hexCoverage,
        placementMargin: fit.placementMargin);
    // BOARD_TRUTH=<session.json>: a game whose tiles are right, to say which
    // hexes were read wrong and why.
    final truthPath = Platform.environment['BOARD_TRUTH'];
    final truth = truthPath == null
        ? null
        : GameSession.fromJson(jsonDecode(File(truthPath).readAsStringSync())
            as Map<String, Object?>);
    final parts = <HexCoord, Map<TileOption, Map<String, double>>>{};
    if (truth != null) {
      reader.explain = (hex, option, p) =>
          (parts[hex] ??= {})[option] = p;
    }
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
    if (truth != null) {
      String described(HexCoord c, TileOption o, double score) {
        final p = parts[c]?[o];
        return '$o ${score.toStringAsFixed(1)}'
            '${p == null ? '' : ' (${p.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)}').join(', ')})'}';
      }

      var right = 0;
      // BOARD_CROSSINGS=1 prints how track crossing each side into the
      // neighbour is measured, against whether the two really connect.
      if (Platform.environment['BOARD_CROSSINGS'] != null) {
        final content = truth.content(title);
        final rgbPhoto = RgbImage.fromImage(photo);
        final linked = <double>[], unlinked = <double>[], none = <double>[];
        for (final r in readings) {
          final def = content[r.hex.coord];
          if (def == null) continue;
          final crossings = HexPatch.crossingsOf(rgbPhoto, fit.boardToImage, r.hex.coord);
          for (int k = 0; k < 6; k++) {
            final mine = def.routableEdges.contains(k);
            final neighbour = content[Board.neighborOf(r.hex.coord, k)];
            final theirs = neighbour?.routableEdges
                    .contains(HexGeometry.oppositeEdge(k)) ??
                false;
            (mine && theirs ? linked : mine ? unlinked : none).add(crossings[k]);
            if ((mine && theirs && crossings[k] < 0.4) || (!mine && crossings[k] > 0.4)) {
              // ignore: avoid_print
              print('crossing ${r.hex.id} side $k: ${crossings[k].toStringAsFixed(2)} '
                  '${mine ? theirs ? 'linked' : 'exit, not linked' : 'no exit'}');
            }
          }
        }
        String spread(List<double> v) {
          v.sort();
          if (v.isEmpty) return 'none';
          return '${v.length} sides: 10% ${v[(v.length * 0.1).floor()].toStringAsFixed(2)}, '
              'median ${v[v.length ~/ 2].toStringAsFixed(2)}, 90% ${v[(v.length * 0.9).floor()].toStringAsFixed(2)}';
        }

        // ignore: avoid_print
        print('crossings where track links: ${spread(linked)}\n'
            '  where an exit meets nothing: ${spread(unlinked)}\n'
            '  where there is no exit: ${spread(none)}');
      }
      // BOARD_EXITS=1 prints every hex's measured side exits beside what
      // its real tile has.
      if (Platform.environment['BOARD_EXITS'] != null) {
        for (final r in readings) {
          final really = truth.tileAt(r.hex);
          final def = really == null
              ? r.hex.printed
              : title.tiles[really.tileId]?.rotated(really.rotation);
          final expected = def?.exitStrengths ?? const <int, double>{};
          // The drawing nearest the photo, as the classifier picks it.
          HexPatch? drawn;
          var nearest = double.infinity;
          if (def != null) {
            for (int turn = 0; turn < (TileRenderer.hasSlotRow(def) ? 3 : 1); turn++) {
              final d = HexPatch.fromTileImage(
                  await TileRenderer.rasterize(def, size: HexPatch.size, slotTurn: turn));
              final distance = r.patch.distanceTo(d);
              if (distance < nearest) {
                nearest = distance;
                drawn = d;
              }
            }
          }
          // ignore: avoid_print
          print('exits ${r.hex.id.padRight(4)} ${(really == null ? 'bare' : '${really.tileId}@${really.rotation}').padRight(7)} '
              '${[for (int e = 0; e < 6; e++) '${(expected[e] ?? 0) > 0 ? '*' : ' '}${r.patch.exits[e].toStringAsFixed(2)}'].join(' ')}'
              '${drawn == null ? '' : '   drawn ${[for (int e = 0; e < 6; e++) drawn.exits[e].toStringAsFixed(2)].join(' ')}'}');
        }
      }
      for (final r in readings) {
        final really = truth.tileAt(r.hex);
        final option = r.reading.option;
        final ok = really == null
            ? option.isPrinted
            : option.tileId == really.tileId &&
                option.rotation == really.rotation;
        if (ok) {
          right++;
          continue;
        }
        final ranked = r.reading.ranked;
        final at = ranked.indexWhere((e) => really == null
            ? e.$1.isPrinted
            : e.$1.tileId == really.tileId && e.$1.rotation == really.rotation);
        // ignore: avoid_print
        print('WRONG ${r.hex.id}: read ${described(r.hex.coord, option, ranked.first.$2)} '
            '${(r.reading.confidence * 100).round()}%, glare ${(r.glare * 100).round()}%\n'
            '      really ${really == null ? 'bare' : '${really.tileId}@${really.rotation}'}: '
            '${at < 0 ? 'not on offer' : 'ranked ${at + 1}: ${described(r.hex.coord, ranked[at].$1, ranked[at].$2)}'}');
      }
      // ignore: avoid_print
      print('against the truth: $right of ${readings.length} right');
      // BOARD_PROFILE=<hex>:<side>: darkness from the middle of the hex out
      // across that side, in the photo and in the drawing of its real tile.
      final profile = Platform.environment['BOARD_PROFILE'];
      if (profile != null) {
        final [id, sideText] = profile.split(':');
        final side = int.parse(sideText);
        final r = readings.firstWhere((r) => r.hex.id == id);
        final really = truth.tileAt(r.hex)!;
        final def = title.tiles[really.tileId]!.rotated(really.rotation);
        final drawn = HexPatch.fromTileImage(
            await TileRenderer.rasterize(def, size: HexPatch.size));
        final normal = HexGeometry.edgeNormal(side);
        final along = Offset(-normal.dy, normal.dx);
        double at(HexPatch patch, Offset p) {
          final x = (p.dx * HexPatch.radiusShare * HexPatch.size + HexPatch.size / 2 - 0.5).round();
          final y = (p.dy * HexPatch.radiusShare * HexPatch.size + HexPatch.size / 2 - 0.5).round();
          if (x < 0 || y < 0 || x >= HexPatch.size || y >= HexPatch.size) return -1;
          return patch.darkness[y * HexPatch.size + x];
        }

        for (final t in [-0.09, 0.0, 0.09]) {
          final photoLine = <String>[], drawnLine = <String>[];
          for (double depth = 0.4; depth <= 1.001; depth += 0.06) {
            final p = normal * (depth * 0.8660254) + along * t;
            photoLine.add(at(r.patch, p).toStringAsFixed(2));
            drawnLine.add(at(drawn, p).toStringAsFixed(2));
          }
          // ignore: avoid_print
          print('profile $id side $side t $t (depth 0.40..1.00 step 0.06)\n'
              '  photo   ${photoLine.join(' ')}\n  drawing ${drawnLine.join(' ')}');
        }
      }
      // BOARD_COMPARE=<hex ids>: each hex as photographed, beside drawings
      // of what it really holds and what it was read as.
      final compare = Platform.environment['BOARD_COMPARE'];
      if (compare != null) {
        final rgb = RgbImage.fromImage(photo);
        for (final id in compare.split(',')) {
          final r = readings.firstWhere((r) => r.hex.id == id);
          final really = truth.tileAt(r.hex);
          final shot = HexPatch.picture(rgb, fit.boardToImage, r.hex.coord, pixels: 200);
          // The hex as the grid places it, and its sides' middles.
          for (int i = 0; i < 6; i++) {
            Offset px(Offset board) => board * (HexPatch.radiusShare * 200) + const Offset(100, 100);
            final a = px(HexGeometry.vertex(Offset.zero, 1, i));
            final b = px(HexGeometry.vertex(Offset.zero, 1, (i + 1) % 6));
            img.drawLine(shot, x1: a.dx.round(), y1: a.dy.round(), x2: b.dx.round(), y2: b.dy.round(),
                color: img.ColorRgb8(255, 0, 255));
          }
          final realDef = really == null
              ? r.hex.printed
              : title.tiles[really.tileId]!.rotated(really.rotation);
          final panels = <img.Image>[
            shot,
            for (int turn = 0; turn < (TileRenderer.hasSlotRow(realDef) ? 3 : 1); turn++)
              await TileRenderer.rasterize(realDef, size: 200, slotTurn: turn),
            await TileRenderer.rasterize(
                reader.rules.contentOf(r.hex, r.reading.option) ?? r.hex.printed,
                size: 200),
          ];
          final sheet = img.Image(width: 200 * panels.length, height: 200);
          for (int i = 0; i < panels.length; i++) {
            img.compositeImage(sheet, panels[i], dstX: 200 * i);
          }
          final path = (Platform.environment['BOARD_PHOTO_OUT'] ?? '/tmp/fit.png')
              .replaceFirst('.png', '_cmp_$id.png');
          File(path).writeAsBytesSync(img.encodePng(sheet));
        }
      }
    }
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
        final px = int.tryParse(Platform.environment["BOARD_DUMP_PX"] ?? "") ?? 240;
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
        // Where each side's exit is sampled, in green.
        for (final at in HexPatch.exitSamples(hex.coord.boardCenter)) {
          final q = (at - hex.coord.boardCenter + const Offset(1.2, 1.2)) / 2.4 * px.toDouble();
          img.fillCircle(out, x: q.dx.round(), y: q.dy.round(), radius: 1,
              color: img.ColorRgb8(0, 255, 0));
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
      // Against the saved game's tokens, as the user left them, city by city
      // (which circle of a city a token is in doesn't matter, and a photo
      // can't tell): what was seen there and what is really there.
      final seenBy = <String, List<String>>{};
      final read = <String>{};
      for (final r in readings) {
        r.tokens.forEach((circle, t) {
          final (city, _) = GameSession.circleOf(circle);
          read.add(city);
          (seenBy[city] ??= []);
          if (t.present && t.company != null) seenBy[city]!.add(t.company!.id);
        });
      }
      final really = <String, List<String>>{};
      session.tokens.forEach((circle, company) {
        final (city, _) = GameSession.circleOf(circle);
        (really[city] ??= []).add(company);
      });
      final counts = <String, int>{};
      for (final city in {...read, ...really.keys}) {
        final seen = [...?seenBy[city]]..sort();
        final truth = [...?really[city]]..sort();
        final verdict = !read.contains(city)
            ? 'UNREAD'
            : seen.join(',') == truth.join(',')
                ? 'ok'
                : seen.length > truth.length
                    ? 'EXTRA'
                    : seen.length < truth.length
                        ? 'MISSED'
                        : 'WRONG';
        counts[verdict] = (counts[verdict] ?? 0) + 1;
        if (verdict != 'ok') {
          // ignore: avoid_print
          print('token $verdict $city: seen ${seen.isEmpty ? '-' : seen.join(',')}, '
              'really ${truth.isEmpty ? '-' : truth.join(',')}');
        }
      }
      // ignore: avoid_print
      print('tokens by city: $counts');
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
