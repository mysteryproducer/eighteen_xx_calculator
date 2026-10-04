// Builds the labelled data set of hexes from real photos, for measuring the
// recognizer and, one day, training one.
//
//   DATASET_DIR=/path/to/dataset flutter test test/build_dataset_test.dart
//
// DATASET_DIR holds manifest.json: the photos, which game is the truth for
// each (with corrections to labels known to be wrong, and hexes to leave
// out, and the title where it isn't the manifest's), hex centres picked by
// hand where the detector can't place a photo, saved games photographed
// while their board stood as a truth has it (their pictures of each hex are
// labelled by it), and the training logs the app keeps of the user's
// corrections. Writes hexes/<photo>/<hex>.png -- each hex squared up, 128
// pixels, as the app saves them -- fits/<photo>.jpg to check each placement
// by eye, and hexes.csv with a row per picture. Skipped when DATASET_DIR
// isn't set.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eighteen_scanner/geometry/homography.dart';
import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/models/board_graph.dart';
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/models/tile_definition.dart';
import 'package:eighteen_scanner/processing/board_reader.dart';
import 'package:eighteen_scanner/processing/gray_image.dart';
import 'package:eighteen_scanner/processing/grid_detector.dart';
import 'package:eighteen_scanner/processing/hex_patch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Platform.environment['DATASET_DIR'];
  test('builds the hex data set', () async {
    final manifest = jsonDecode(File('$root/manifest.json').readAsStringSync())
        as Map<String, Object?>;
    final title = GameTitle.byId(manifest['title'] as String)!;
    final detectors = <String, GridDetector>{};
    final readers = <String, BoardReader>{};

    // Each truth: the game as it stood, labels known to be wrong put right,
    // and the hexes whose label can't be trusted at all; of the manifest's
    // title unless it names another.
    final truths = <String, (GameSession, Set<String>, GameTitle)>{};
    (manifest['truths'] as Map<String, Object?>).forEach((id, value) {
      final spec = value as Map<String, Object?>;
      final title = spec['title'] == null
          ? GameTitle.byId(manifest['title'] as String)!
          : GameTitle.byId(spec['title'] as String)!;
      final path = spec['session'] as String?;
      final session = path == null
          ? GameSession.start(title: title, name: id, startedEmpty: true)
          : GameSession.fromJson(jsonDecode(File('$root/$path').readAsStringSync())
              as Map<String, Object?>);
      final corrections = spec['corrections'] as Map<String, Object?>? ?? {};
      corrections.forEach((hexId, tile) {
        final [tileId, rotation] = tile as List<Object?>;
        session.setManually(title.map.byId(hexId)!,
            tileId == null ? null : PlacedTile(tileId as String, rotation: rotation as int));
      });
      truths[id] = (
        session,
        {...(spec['exclude'] as List<Object?>? ?? []).cast<String>()},
        title,
      );
    });

    final rows = <Map<String, Object?>>[];
    // A tile turned so it looks the same -- a straight turned half round --
    // is the same label: the lowest turn that looks like it. The photos are
    // all of the manifest's title; a device's log holds whatever was played.
    String looks(String tileId, int rotation, [GameTitle? of]) {
      final def = (of ?? title).tiles[tileId];
      if (def == null) return '$tileId@$rotation';
      String shape(int r) => ([
            for (final seg in def.rotated(r).segments)
              ([seg.a, seg.b].map((e) => switch (e) {
                    EdgeEndpoint(:final edge) => 'e$edge',
                    StationEndpoint(:final stationIndex) => 's$stationIndex',
                  }).toList()
                    ..sort())
                  .join('-'),
          ]..sort())
              .join(' ');
      final wanted = shape(rotation);
      for (int r = 0; r < 6; r++) {
        if (shape(r) == wanted) return '$tileId@$r';
      }
      return '$tileId@$rotation';
    }

    String labelOf(PlacedTile? t, [GameTitle? of]) =>
        t == null ? 'printed' : looks(t.tileId, t.rotation, of);
    String colourOf(String? tileId, [GameTitle? of]) =>
        tileId == null ? 'plain' : (of ?? title).tiles[tileId]?.color.name ?? '?';

    for (final value in manifest['photos'] as List<Object?>) {
      final spec = value as Map<String, Object?>;
      final id = spec['id'] as String;
      final photo = img.decodeImage(File('$root/${spec['file']}').readAsBytesSync())!;
      final (truth, excluded, title) = truths[spec['truth']]!;
      final detector = detectors[title.id] ??= GridDetector(title.map);
      final reader = readers[title.id] ??= BoardReader(title);
      final rgb = RgbImage.fromImage(photo);

      // Where the board is: from hand-picked hex centres where given, else
      // as the app finds it; then lined up with the tiles the truth knows.
      final points = spec['points'] as String?;
      Homography h;
      String method;
      if (points != null) {
        final from = <Offset>[], to = <Offset>[];
        for (final entry in points.split(';')) {
          final [hexId, at] = entry.split(':');
          final [x, y] = at.split(',').map(double.parse).toList();
          from.add(title.map.byId(hexId)!.coord.boardCenter);
          to.add(Offset(x, y));
        }
        // Snapped to the printed lines, unless the photo says not to: on a
        // board printing none (1889), snapping can pull a close, steep view
        // off.
        final guess = Homography.fit(from, to)!;
        if (spec['snap'] == false) {
          h = guess;
          method = 'hand-picked centres';
        } else {
          h = detector.snap(photo, guess).boardToImage;
          method = 'hand-picked centres, snapped';
        }
      } else {
        final fit = detector.fitBoard(photo,
            hints: BoardHints(colours: {
              for (final e in truth.content(title).entries) e.key: e.value.color,
            }, tiled: {
              for (final hex in title.map.hexes)
                if (truth.tileAt(hex) != null) hex.coord,
            }))!;
        h = fit.boardToImage;
        method = 'found automatically';
      }
      bool inside(HexCoord c, Homography h) {
        for (int k = 0; k < 6; k++) {
          final p = h.apply(HexGeometry.vertex(c.boardCenter, 1, k));
          if (p.dx < 0 || p.dy < 0 || p.dx >= photo.width || p.dy >= photo.height) {
            return false;
          }
        }
        return true;
      }

      final inView = {for (final c in title.map.coords) if (inside(c, h)) c};
      h = await reader.alignToKnown(
          photo: photo, boardToImage: h, hexes: inView, session: truth);
      final visible = {for (final c in title.map.coords) if (inside(c, h)) c};
      final tileHexes = {
        for (final c in visible)
          if (title.map.at(c)!.takesTiles) c,
      };

      // What the app reads there with nothing to go on -- a game joined
      // part-way -- as the baseline any other recognizer has to beat.
      final readings = await reader.read(
        photo: photo,
        boardToImage: h,
        hexes: tileHexes,
        context: visible,
        session: GameSession.start(title: title, name: 'baseline', startedEmpty: false),
      );
      final facing =
          (GridFit.facingOf(h, title.map.boardBounds.center) * 180 / math.pi).round();
      await Directory('$root/hexes/$id').create(recursive: true);
      var right = 0, total = 0;
      for (final r in readings) {
        if (excluded.contains(r.hex.id)) continue;
        final really = truth.tileAt(r.hex);
        final picture = HexPatch.picture(rgb, h, r.hex.coord, pixels: 128);
        File('$root/hexes/$id/${r.hex.id}.png').writeAsBytesSync(img.encodePng(picture));
        final read = r.reading.option.placed;
        final ok = labelOf(read, title) == labelOf(really, title);
        total++;
        if (ok) right++;
        rows.add({
          'image': 'hexes/$id/${r.hex.id}.png',
          'source': 'photo',
          'photo': id,
          'device': spec['device'],
          'title': title.id,
          'truth': spec['truth'],
          'hex': r.hex.id,
          'label': labelOf(really, title),
          'tile': really?.tileId ?? 'printed',
          'rotation': int.parse(
              labelOf(really, title).split('@').last.replaceAll('printed', '0')),
          'colour': colourOf(really?.tileId, title),
          'glare': r.glare.toStringAsFixed(2),
          'hex_px': (h.localScale(r.hex.coord.boardCenter) * math.sqrt(3)).round(),
          'facing': facing,
          'read_as': labelOf(read, title),
          'read_confidence': r.reading.confidence.toStringAsFixed(2),
          'read_right': ok,
        });
      }

      // The placement, to check by eye.
      final overlay = img.copyResize(photo, width: photo.width ~/ 2);
      final half = h.then(Homography.similarity(scale: 0.5));
      for (final c in visible) {
        for (int k = 0; k < 6; k++) {
          final a = half.apply(HexGeometry.vertex(c.boardCenter, 1, k));
          final b = half.apply(HexGeometry.vertex(c.boardCenter, 1, (k + 1) % 6));
          img.drawLine(overlay, x1: a.dx.round(), y1: a.dy.round(), x2: b.dx.round(),
              y2: b.dy.round(), color: img.ColorRgb8(255, 0, 80));
        }
      }
      await Directory('$root/fits').create(recursive: true);
      File('$root/fits/$id.jpg').writeAsBytesSync(img.encodeJpg(overlay, quality: 80));
      // ignore: avoid_print
      print('$id: $method, facing $facing degrees, ${tileHexes.length} tile hexes in view, '
          '$total kept; the app reads $right of them right with nothing to go on');
    }

    // Saved games photographed while the board stood as a truth has it: the
    // app's own picture of each hex, cut where the app (and the user, lining
    // the grid up by hand where it had to) placed it, labelled by the truth.
    // A picture the device's log holds already, as a correction, is left to
    // that.
    for (final value in manifest['games'] as List<Object?>? ?? const []) {
      final spec = value as Map<String, Object?>;
      final (truth, excluded, title) = truths[spec['truth']]!;
      final gameDir = '$root/${spec['game']}';
      final saved = GameSession.fromJson(
          jsonDecode(File('$gameDir/session.json').readAsStringSync())
              as Map<String, Object?>);
      final logged = <String, Map<String, Object?>>{};
      final logPictures = <String>{};
      final log = spec['log'] as String?;
      if (log != null) {
        for (final line in File('$root/$log/labels.jsonl').readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          final entry = jsonDecode(line) as Map<String, Object?>;
          final picture = entry['picture'] as String;
          if (!picture.startsWith('${saved.id}-')) continue;
          // The last word on each hex: what the app had read before the user
          // put it right.
          logged[entry['hex'] as String] = entry;
          final file = File('$root/$log/pictures/$picture');
          if (file.existsSync()) {
            logPictures.add(base64.encode(file.readAsBytesSync()));
          }
        }
      }
      final id = spec['id'] as String;
      final folder = 'hexes/$id';
      await Directory('$root/$folder').create(recursive: true);
      var kept = 0, skipped = 0, right = 0;
      for (final hex in title.map.hexes) {
        final file = File('$gameDir/hexes/${hex.id}.png');
        if (!file.existsSync() || excluded.contains(hex.id)) continue;
        final bytes = file.readAsBytesSync();
        if (logPictures.contains(base64.encode(bytes))) {
          skipped++;
          continue;
        }
        final state = saved.hexes[hex.id];
        final really = truth.tileAt(hex);
        // What the app read there: its reading, or where the user set the
        // hex by hand, what it had read before.
        String readAs = '';
        if (state != null && state.source != HexSource.manual) {
          readAs = labelOf(state.tile, title);
        } else if (logged[hex.id] case final entry?) {
          final readTile = entry['readAs'] as String?;
          readAs = readTile == null
              ? 'printed'
              : looks(readTile, (entry['readAsRotation'] as num?)?.toInt() ?? 0,
                  title);
        }
        File('$root/$folder/${hex.id}.png').writeAsBytesSync(bytes);
        final label = labelOf(really, title);
        if (readAs == label) right++;
        rows.add({
          'image': '$folder/${hex.id}.png',
          'source': 'game',
          'photo': saved.id,
          'device': spec['device'],
          'title': title.id,
          'truth': spec['truth'],
          'hex': hex.id,
          'label': label,
          'tile': really?.tileId ?? 'printed',
          'rotation': int.parse(label.split('@').last.replaceAll('printed', '0')),
          'colour': colourOf(really?.tileId, title),
          'glare': saved.glare[hex.id]?.toStringAsFixed(2) ?? '',
          'hex_px': '',
          'facing': '',
          'read_as': readAs,
          'read_confidence': state?.confidence.toStringAsFixed(2) ?? '',
          'read_right': readAs == '' ? '' : readAs == label,
        });
        kept++;
      }
      // ignore: avoid_print
      print('$id: $kept pictures kept, $skipped left to the log; the app had '
          '$right of them right');
    }

    // The app's own log of what the user corrected, with the pictures.
    for (final value in manifest['corrections'] as List<Object?>? ?? const []) {
      final spec = value as Map<String, Object?>;
      final device = spec['device'] as String;
      final fixes = [
        for (final f in spec['fix'] as List<Object?>? ?? const [])
          f as Map<String, Object?>,
      ];
      final folder = 'hexes/corrections-${spec['id']}';
      await Directory('$root/$folder').create(recursive: true);
      var kept = 0, dropped = 0, fixed = 0;
      for (final line in File('$root/${spec['labels']}').readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final entry = jsonDecode(line) as Map<String, Object?>;
        final played = GameTitle.byId(entry['title'] as String? ?? title.id) ?? title;
        var tileId = entry['tile'] as String?;
        var rotation = (entry['rotation'] as num?)?.toInt() ?? 0;
        var drop = false;
        for (final f in fixes) {
          if (f['hex'] != entry['hex']) continue;
          if (f.containsKey('tile') && f['tile'] != tileId) continue;
          if (f.containsKey('rotation') && f['rotation'] != rotation) continue;
          if (f.containsKey('game') &&
              !(entry['picture'] as String).startsWith('${f['game']}-')) {
            continue;
          }
          if (f['drop'] == true) {
            drop = true;
          } else {
            final [t, r] = f['set'] as List<Object?>;
            tileId = t as String?;
            rotation = r as int;
            fixed++;
          }
        }
        if (drop) {
          dropped++;
          continue;
        }
        final picture = entry['picture'] as String;
        File('$root/${spec['pictures']}/$picture').copySync('$root/$folder/$picture');
        final label = tileId == null ? 'printed' : looks(tileId, rotation, played);
        final readTile = entry['readAs'] as String?;
        final readAs = readTile == null
            ? 'printed'
            : looks(readTile, (entry['readAsRotation'] as num?)?.toInt() ?? 0, played);
        rows.add({
          'image': '$folder/$picture',
          'source': 'correction',
          'photo': '',
          'device': device,
          'title': played.id,
          'truth': 'user',
          'hex': entry['hex'],
          'label': label,
          'tile': tileId ?? 'printed',
          'rotation': int.parse(label.split('@').last.replaceAll('printed', '0')),
          'colour': colourOf(tileId, played),
          'glare': '',
          'hex_px': '',
          'facing': '',
          'read_as': readAs,
          'read_confidence': ((entry['confidence'] as num?) ?? 0).toStringAsFixed(2),
          'read_right': readAs == label,
        });
        kept++;
      }
      // ignore: avoid_print
      print('corrections from $device: $kept kept ($fixed put right), $dropped dropped');
    }

    final columns = rows.first.keys.toList();
    File('$root/hexes.csv').writeAsStringSync([
      columns.join(','),
      for (final row in rows) [for (final c in columns) '${row[c]}'].join(','),
    ].join('\n'));
    // ignore: avoid_print
    print('${rows.length} labelled hex pictures written to $root/hexes.csv');
  }, skip: root == null ? 'Set DATASET_DIR' : false, timeout: const Timeout(Duration(minutes: 60)));
}
