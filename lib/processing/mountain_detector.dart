import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../geometry/homography.dart';
import '../models/map_layout.dart';
import 'gray_image.dart';

/// What a photo showed of a mountain railway on one mountain.
class MountainReading {
  final MapHex hex;

  /// Whether a revenue plate seems to be on the mountain.
  final bool present;

  /// How sure the photo is either way, 0..1.
  final double confidence;

  /// How washed out by glare the mountain was, 0..1: enough to fade a
  /// plate out of sight towards 1.
  final double washout;

  const MountainReading(this.hex, this.present, this.confidence,
      {this.washout = 0});

  @override
  String toString() =>
      '${hex.id}: ${present ? 'plate' : 'no plate'} (${(confidence * 100).round()}%)'
      '${washout > 0.5 ? ', washed out' : ''}';
}

/// Looks for 1844's mountain railway plates: a pale plate laid on a grey
/// mountain hex with a row of four boxes, coloured yellow, green, salmon and
/// grey for the phases, each with that phase's revenue in it.
///
/// The coloured boxes are what give it away. A mountain hex is printed grey
/// and black, so wherever a patch of yellow, one of green and one of salmon
/// sit side by side on it, in that order from left to right, a plate is
/// there. Which plate it is lies in the figures, which a photo of the whole
/// board is too small to read; that is left to the user.
///
/// Glare fades the boxes towards white, so on a washed-out mountain they are
/// looked for more faintly, and not finding them is taken as not knowing.
class MountainDetector {
  const MountainDetector();

  MountainReading detect(RgbImage photo, Homography boardToImage, MapHex hex) {
    final colours = <List<double>>[];
    final places = <Offset>[];
    final rgb = List<double>.filled(3, 0);
    var inHex = 0;
    for (double y = -0.95; y <= 0.95; y += _step) {
      for (double x = -0.95; x <= 0.95; x += _step) {
        final o = Offset(x, y);
        if (_hexNorm(o) > 0.86) continue;
        inHex++;
        final p = boardToImage.apply(hex.coord.boardCenter + o);
        if (!photo.contains(p.dx, p.dy)) continue;
        photo.sample(p.dx, p.dy, rgb);
        colours.add(List.of(rgb));
        places.add(o);
      }
    }
    // Part of the mountain out of the photo could have the plate on it.
    if (colours.length < inHex * 0.9) return MountainReading(hex, false, 0);

    // How far glare has lifted the hex. It is printed grey and black, so
    // its middle tone is nowhere near white unless glare put it there; and
    // the colours of a plate fade with it, so they are looked for more
    // faintly, and not finding them says less.
    final weakest = [
      for (final c in colours) math.min(c[0], math.min(c[1], c[2])),
    ]..sort();
    final washout = ((weakest[weakest.length ~/ 2] - _washedFrom) /
            _washedSpan)
        .clamp(0.0, 1.0);
    final faint = 1 - _fading * washout;

    // Against the hex's own middle colour, so the light's colour drops out.
    final middle = [
      for (int k = 0; k < 3; k++)
        (colours.map((c) => c[k]).toList()..sort())[colours.length ~/ 2],
    ];
    final (my, mg, mr) = _hues(middle);
    final yellow = <Offset>[], green = <Offset>[], salmon = <Offset>[];
    for (int i = 0; i < colours.length; i++) {
      final (y, g, r) = _hues(colours[i]);
      final dy = (y - my) / faint, dg = (g - mg) / faint, dr = (r - mr) / faint;
      if (dy > 0.10 && dg > -0.03) yellow.add(places[i]);
      if (dg > 0.05 && dy < 0.12) green.add(places[i]);
      // Salmon goes mauve under a warm lamp, so it is the faintest.
      if (dr > 0.05 && dy < 0.12) salmon.add(places[i]);
    }
    // Each colour where it gathers into a box. Colour scattered elsewhere --
    // a neighbouring tile's edge, the printed map -- is not a plate.
    final boxes = [for (final found in [yellow, green, salmon]) _densest(found)];
    final n = colours.length;
    // On the photos so far a plate's yellow and green boxes each cover over
    // 1.3% of its mountain, and its salmon one less where it fades;
    // scattered colour on a bare mountain never makes the three in a row.
    final evidence = [
      boxes[0].$2 / n / _yellowShare,
      boxes[1].$2 / n / _greenShare,
      boxes[2].$2 / n / _salmonShare,
    ].reduce(math.min);
    var inRow = true;
    for (int k = 0; k < 2; k++) {
      final step = boxes[k + 1].$1 - boxes[k].$1;
      if (step.dx < 0.15 || step.dx > 0.5 || step.dy.abs() > 0.15) {
        inRow = false;
      }
    }
    if (inRow && evidence >= 1) {
      return MountainReading(
          hex, true, ((evidence - 0.5) / 1.5).clamp(0.0, 1.0),
          washout: washout);
    }
    return MountainReading(
        hex, false, ((1 - evidence) * 1.2 * (1 - washout)).clamp(0.0, 1.0),
        washout: washout);
  }

  /// The centre of the box-sized patch holding the most of [points], and
  /// how many it holds.
  static (Offset, int) _densest(List<Offset> points) {
    var best = (Offset.zero, 0);
    for (double y = -0.8; y <= 0.8; y += 0.05) {
      for (double x = -0.8; x <= 0.8; x += 0.05) {
        var count = 0;
        for (final p in points) {
          if ((p.dx - x).abs() <= _boxWidth / 2 &&
              (p.dy - y).abs() <= _boxHeight / 2) {
            count++;
          }
        }
        if (count > best.$2) best = (Offset(x, y), count);
      }
    }
    return best;
  }

  /// A plate's boxes, as a share of a hex's circumradius.
  static const double _boxWidth = 0.3;
  static const double _boxHeight = 0.2;

  /// How much of a mountain each box's colour has to cover, at the least,
  /// to be taken for a plate.
  static const double _yellowShare = 0.007;
  static const double _greenShare = 0.012;
  static const double _salmonShare = 0.002;

  /// Where the middle of a mountain's weakest colour channel starts to show
  /// glare, and how much brighter it is when the glare is total. Measured
  /// on the photos so far: a mountain under the lamp's light alone sits at
  /// 120 to 165; where glare faded a plate, 177 and up.
  static const double _washedFrom = 150;
  static const double _washedSpan = 30;

  /// How much fainter the colours are looked for under total glare.
  static const double _fading = 0.6;

  /// Yellowness, greenness and redness of [c], as shares of its brightness.
  static (double, double, double) _hues(List<double> c) {
    final sum = c[0] + c[1] + c[2] + 1;
    return (
      ((c[0] + c[1]) / 2 - c[2]) / sum,
      (c[1] - (c[0] + c[2]) / 2) / sum,
      (c[0] - c[1]) / sum,
    );
  }

  static const double _step = 0.025;

  static double _hexNorm(Offset v) {
    final a = v.dx.abs();
    final b = (0.5 * v.dx + 0.8660254037844386 * v.dy).abs();
    final c = (-0.5 * v.dx + 0.8660254037844386 * v.dy).abs();
    return math.max(a, math.max(b, c));
  }
}
