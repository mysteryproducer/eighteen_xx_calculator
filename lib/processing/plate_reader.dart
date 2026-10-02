import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/game_title.dart';
import '../models/tile_definition.dart';
import 'gray_image.dart';
import 'mountain_detector.dart';
import 'revenue_ocr.dart';

/// Which plate the figures on a mountain railway plate say it is.
class PlateIdentity {
  /// The plate, or null if the figures didn't say.
  final String? plate;

  /// Whether every figure was read, and only that plate prints them.
  final bool sure;

  /// The figures read, left to right.
  final List<int> figures;

  const PlateIdentity(this.plate, {required this.sure, required this.figures});

  @override
  String toString() =>
      '${plate == null ? 'unread' : '$plate${sure ? '' : '?'}'} $figures';
}

/// Reads which of 1844's mountain railway plates is on a mountain, from the
/// figures in its boxes.
///
/// The plates differ only in what they pay -- XM1 10, 20, 50 and 80 in the
/// four phases, XM2 10, 40, 50 and 60 -- so the row of boxes the
/// `MountainDetector` found is cut out of the photo, straightened, and handed
/// to the platform's text recognizer. Only a close-up shows the figures large
/// enough to read.
///
/// Which box a figure was read in matters as much as the figure: the green
/// box's figure is often lost against its colour, and 10, 50 and 80 in a
/// row could be XM1 or XM3 -- but 50 in the third box and 80 in the fourth
/// can only be XM1.
class PlateReader {
  final GameTitle title;

  /// Reads the words in an image and where each lies: the platform's
  /// recognizer, unless a test says otherwise.
  final Future<List<RecognizedWord>> Function(img.Image) recognizeWords;

  /// Reads the text in an image, for platforms that can't say where words
  /// lie.
  final Future<String> Function(img.Image) recognize;

  const PlateReader(
    this.title, {
    this.recognizeWords = RevenueOcr.recognizeWords,
    this.recognize = RevenueOcr.recognize,
  });

  /// What each of the title's plates prints, left to right.
  Map<String, List<int>> get plates => {
        for (final id in title.mountainPlates)
          if (title.tiles[id] case final plate?) id: figuresOf(plate),
      };

  /// What [plate] pays in each phase, in the order its boxes are printed.
  static List<int> figuresOf(TileDefinition plate) {
    final station = plate.stations.firstWhere(
        (s) => s.kind == StationKind.offboard,
        orElse: () => plate.stations.first);
    return [for (final phase in tilePhases) ?station.phaseRevenue[phase]];
  }

  /// Reads each plate among [readings] that shows large enough in [photo],
  /// by hex id. Plates too small to read, and every plate where the platform
  /// has no text recognizer, are left out.
  Future<Map<String, PlateIdentity>> readAll(
    img.Image photo,
    Homography boardToImage,
    Iterable<MountainReading> readings,
  ) async {
    final found = [
      for (final r in readings)
        if (r.present && r.plateAt != null) r,
    ];
    if (found.isEmpty) return const {};
    final rgb = RgbImage.fromImage(photo);
    final result = <String, PlateIdentity>{};
    var placing = true;
    for (final reading in found) {
      final row = strip(rgb, boardToImage, reading);
      if (row == null) continue;
      // Read as photographed and as ink on white: each catches figures the
      // other misses, and where both read a box they have to agree.
      final versions = [inked(row), row];
      try {
        if (placing) {
          try {
            result[reading.hex.id] = identifyAt(
                agreed([
                  for (final version in versions)
                    figuresAt(await recognizeWords(version)),
                ]),
                plates);
            continue;
          } on TextRecognitionUnavailable {
            placing = false;
          }
        }
        result[reading.hex.id] =
            identify(figuresIn(await recognize(versions.first)), plates);
      } on TextRecognitionUnavailable {
        break;
      }
    }
    return result;
  }

  /// The row of boxes of the plate [reading] found, cut out of [photo] and
  /// straightened through [boardToImage]: [height] pixels tall, the boxes
  /// left to right whichever way the camera was held. Null if the boxes are
  /// too small in the photo for their figures to be read.
  img.Image? strip(
    RgbImage photo,
    Homography boardToImage,
    MountainReading reading, {
    int height = 96,
  }) {
    final at = reading.plateAt, step = reading.plateStep;
    if (!reading.present || at == null || step == null) return null;
    final centre = reading.hex.coord.boardCenter + at;
    // Down the plate, as its figures are printed: a quarter turn on from
    // the way the boxes run.
    final down = Offset(-step.dy, step.dx);
    final top = boardToImage.apply(centre - down * _boxHalfHeight);
    final bottom = boardToImage.apply(centre + down * _boxHalfHeight);
    if ((bottom - top).distance < _smallestBox) return null;

    final width = (height * _along / _across).round();
    final out = img.Image(width: width, height: height);
    final rgb = List<double>.filled(3, 0);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final p = boardToImage.apply(centre +
            step * (((x + 0.5) / width - 0.5) * _along) +
            down * (((y + 0.5) / height - 0.5) * _across));
        if (photo.contains(p.dx, p.dy)) {
          photo.sample(p.dx, p.dy, rgb);
          out.setPixelRgb(
              x, y, rgb[0].round(), rgb[1].round(), rgb[2].round());
        } else {
          out.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }
    return out;
  }

  /// How much of the plate the strip takes in, in steps from box to box:
  /// the four boxes and a little either side, and their height and a
  /// little more.
  static const double _along = 4.6;
  static const double _across = 1.2;

  /// Half a box's height, in steps from box to box.
  static const double _boxHalfHeight = 0.33;

  /// The smallest a box can be in a photo, in pixels, and its figures still
  /// be read. A whole-board photo from a 1920-pixel webcam shows the boxes
  /// about 11 pixels tall, and clear plates read at that.
  static const double _smallestBox = 8;

  /// [strip] as dark ink on white, for the text recognizer: each pixel's
  /// brightest channel, stretched between the ink and the paper around it.
  /// The figures are black on boxes of four colours; the green one, darkest,
  /// otherwise loses its figure.
  static img.Image inked(img.Image strip) {
    final w = strip.width, h = strip.height;
    final bright = List<double>.filled(w * h, 0);
    for (final p in strip) {
      bright[p.y * w + p.x] = math.max(p.r, math.max(p.g, p.b)).toDouble();
    }
    // Paper and ink in each column, then around it -- about a box's width.
    final paper = List<double>.filled(w, 0), ink = List<double>.filled(w, 0);
    for (int x = 0; x < w; x++) {
      final column = [for (int y = 0; y < h; y++) bright[y * w + x]]..sort();
      paper[x] = column[(h * 0.9).floor()];
      ink[x] = column[(h * 0.05).floor()];
    }
    final reach = math.max(1, (h * 0.2).round());
    final out = img.Image(width: w, height: h);
    for (int x = 0; x < w; x++) {
      final from = math.max(0, x - reach), to = math.min(w, x + reach);
      final papers = paper.sublist(from, to)..sort();
      final inks = ink.sublist(from, to)..sort();
      final light = papers[papers.length ~/ 2];
      final dark = inks[inks.length ~/ 5];
      for (int y = 0; y < h; y++) {
        final t = ((bright[y * w + x] - dark) / math.max(1, light - dark))
            .clamp(0.0, 1.0);
        final grey = (255 * t).round();
        out.setPixelRgb(x, y, grey, grey, grey);
      }
    }
    return out;
  }

  /// The figures in [text], left to right. Every figure on a plate is a
  /// multiple of ten under a hundred, and that is what is looked for: a
  /// box's border can come back as a stray 1 ("110" for "|10"), and figures
  /// can run together ("1050").
  static List<int> figuresIn(String text) =>
      [for (final (_, _, figure) in _figures(text)) figure];

  /// The figures in [words] (from a [strip]), by the box they were read in:
  /// 0 for the yellow box to 3 for the grey one. Vision places whole words,
  /// not characters, so where a figure lies is judged from where it falls
  /// within its word. A box read as two different figures is left out.
  static Map<int, int> figuresAt(List<RecognizedWord> words) {
    final found = <int, int>{};
    final clashes = <int>{};
    for (final word in words) {
      final length = word.text.length;
      for (final (start, end, figure) in _figures(word.text)) {
        final x = word.left +
            (word.right - word.left) * ((start + end) / 2) / length;
        // A strip spans [_along] boxes' steps, centred between the second
        // and third boxes.
        final box = ((x - 0.5) * _along + 1.5).round();
        if (box < 0 || box >= _boxes) continue;
        if (found[box] case final other? when other != figure) {
          clashes.add(box);
        }
        found[box] = figure;
      }
    }
    for (final box in clashes) {
      found.remove(box);
    }
    return found;
  }

  /// What several readings of one plate (see [figuresAt]) agree on: every
  /// box any of them read, except where they read it differently.
  static Map<int, int> agreed(Iterable<Map<int, int>> readings) {
    final result = <int, int>{};
    final clashes = <int>{};
    for (final reading in readings) {
      for (final e in reading.entries) {
        if (result[e.key] case final other? when other != e.value) {
          clashes.add(e.key);
        }
        result[e.key] = e.value;
      }
    }
    for (final box in clashes) {
      result.remove(box);
    }
    return result;
  }

  /// Which of [plates] (what each prints, left to right) has the figures
  /// [placed] in those boxes. Settled when every box was read; a guess,
  /// still to be checked, when at least two were and only one plate fits.
  static PlateIdentity identifyAt(
      Map<int, int> placed, Map<String, List<int>> plates) {
    final figures = [
      for (final box in placed.keys.toList()..sort()) placed[box]!,
    ];
    final fits = [
      for (final e in plates.entries)
        if (placed.entries.every(
            (p) => p.key < e.value.length && e.value[p.key] == p.value))
          e.key,
    ];
    if (placed.length < 2 || fits.length != 1) {
      return PlateIdentity(null, sure: false, figures: figures);
    }
    final plate = fits.single;
    return PlateIdentity(plate,
        sure: placed.length == plates[plate]!.length, figures: figures);
  }

  /// Each figure in [text] -- where it starts and ends, and what it is.
  static Iterable<(int, int, int)> _figures(String text) sync* {
    for (final run in RegExp(r'\d+').allMatches(text)) {
      final digits = run.group(0)!;
      var i = 0;
      while (i + 1 < digits.length) {
        if (digits[i] != '0' && digits[i + 1] == '0') {
          yield (
            run.start + i,
            run.start + i + 2,
            int.parse(digits.substring(i, i + 2)),
          );
          i += 2;
        } else {
          i++;
        }
      }
    }
  }

  /// How many boxes a plate has: one per phase.
  static const int _boxes = 4;

  /// Which of [plates] (what each prints, left to right) the [figures] read
  /// off one say it is. Figures that could belong to more than one plate,
  /// or a lone figure, which one misread would make another plate's, say
  /// nothing.
  static PlateIdentity identify(
      List<int> figures, Map<String, List<int>> plates) {
    final fits = [
      for (final e in plates.entries)
        if (_inOrder(figures, e.value)) e.key,
    ];
    if (figures.length < 2 || fits.length != 1) {
      return PlateIdentity(null, sure: false, figures: figures);
    }
    final plate = fits.single;
    return PlateIdentity(plate,
        sure: listEquals(figures, plates[plate]), figures: figures);
  }

  /// Whether [part] appears in [whole] in the same order, not necessarily
  /// side by side.
  static bool _inOrder(List<int> part, List<int> whole) {
    var matched = 0;
    for (final figure in whole) {
      if (matched < part.length && part[matched] == figure) matched++;
    }
    return matched == part.length;
  }
}
