import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../geometry/homography.dart';
import '../models/map_layout.dart';
import 'gray_image.dart';
import 'tile_renderer.dart';

/// What a photo showed of a tunnel on one hex.
class TunnelReading {
  final MapHex hex;

  /// The two sides the tunnel joins, or null for none.
  final (int, int)? path;

  /// How sure the photo is of [path] (or of there being no tunnel), 0..1.
  final double confidence;

  const TunnelReading(this.hex, this.path, this.confidence);

  @override
  String toString() => path == null
      ? '${hex.id}: no tunnel (${(confidence * 100).round()}%)'
      : '${hex.id}: tunnel ${path!.$1}-${path!.$2} (${(confidence * 100).round()}%)';
}

/// Looks for 1844's tunnel pieces: a strip laid over a mountain hex with a
/// line of black and white dashes down its middle.
///
/// The dashes are what give it away. Along the run a tunnel takes, the
/// photo goes dark, light, dark, light at the dash spacing; along any other
/// run through the hex it doesn't -- place names and tunnel portals are
/// dark and light too, but not evenly, and the Furka-Oberalp line is solid.
/// Each run a tunnel could take is scored on how well the light along it
/// follows an even on-off pattern, and a tunnel is read only where one run
/// clearly beats all the others and stands out against the hex's own
/// contrast.
class TunnelDetector {
  const TunnelDetector();

  /// Reads [hex] in [photo], where a tunnel could run any of [paths].
  TunnelReading detect(
    RgbImage photo,
    Homography boardToImage,
    MapHex hex,
    List<(int, int)> paths,
  ) {
    if (paths.isEmpty) return TunnelReading(hex, null, 0);
    final centre = hex.coord.boardCenter;
    final rgb = List<double>.filled(3, 0);
    double? lum(Offset board) {
      final p = boardToImage.apply(board);
      if (!photo.contains(p.dx, p.dy)) return null;
      photo.sample(p.dx, p.dy, rgb);
      return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
    }

    // The hex's own contrast, from its darkest printing to its background.
    final all = <double>[];
    for (double y = -0.8; y <= 0.8; y += 0.08) {
      for (double x = -0.8; x <= 0.8; x += 0.08) {
        final v = lum(centre + Offset(x, y));
        if (v != null) all.add(v);
      }
    }
    if (all.length < 100) return TunnelReading(hex, null, 0);
    all.sort();
    final contrast = math.max(
        20.0, all[(all.length * 0.6).floor()] - all[(all.length * 0.03).floor()]);

    final scored = <((int, int), double)>[];
    for (final path in paths) {
      final points =
          TileRenderer.runPoints(centre, 1, path.$1, path.$2, _samples);
      double best = 0;
      // A piece laid by hand is rarely dead on the line: look a little to
      // either side as well.
      for (final shift in _sideways) {
        final profile = <double>[];
        for (int i = _samples ~/ 10; i <= _samples - _samples ~/ 10; i++) {
          final along = points[math.min(i + 1, _samples)] - points[math.max(i - 1, 0)];
          final normal = Offset(-along.dy, along.dx) / along.distance;
          final v = lum(points[i] + normal * shift);
          if (v == null) break;
          profile.add(v);
        }
        if (profile.length < _samples * 0.8) continue;
        final spacing = (points[1] - points[0]).distance;
        best = math.max(best, _dashes(profile, spacing));
      }
      scored.add((path, best));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final strongest = scored.first;
    final next = scored.length > 1 ? scored[1].$2 : 0.0;
    final lead = strongest.$2 / math.max(1.0, next);
    final strength = strongest.$2 / contrast;
    // From the photos so far: a tunnel piece scores 2.2 times the next run
    // and half the hex's contrast; printed hexes without one, at most 1.4
    // times and a fifth.
    final present = lead >= 1.8 && strength >= 0.3;
    if (present) {
      final sure = math.min(((lead - 1.6) / 0.6).clamp(0.0, 1.0),
          ((strength - 0.2) / 0.2).clamp(0.0, 1.0));
      return TunnelReading(hex, strongest.$1, sure);
    }
    final sureNone = math.max(((1.6 - lead) / 0.3).clamp(0.0, 1.0),
        ((0.25 - strength) / 0.1).clamp(0.0, 1.0));
    return TunnelReading(hex, null, sureNone);
  }

  /// How well [profile] (light along a run, sampled every [spacing] board
  /// units) follows an even on-off pattern at the dash spacing of a tunnel
  /// piece, at whatever phase fits best: the mean light difference between
  /// its "on" and "off" halves.
  static double _dashes(List<double> profile, double spacing) {
    final mean = profile.reduce((a, b) => a + b) / profile.length;
    double best = 0;
    final shortest = (_shortestPeriod / spacing).round();
    final longest = (_longestPeriod / spacing).round();
    for (int period = shortest; period <= longest; period++) {
      for (int phase = 0; phase < period; phase++) {
        double sum = 0;
        for (int i = 0; i < profile.length; i++) {
          sum += ((i + phase) % period < period / 2 ? 1 : -1) *
              (profile[i] - mean);
        }
        best = math.max(best, sum / profile.length);
      }
    }
    return best;
  }

  static const int _samples = 100;
  static const List<double> _sideways = [-0.05, -0.025, 0, 0.025, 0.05];

  /// The dash spacing looked for, in board units (a hex's radius is 1). The
  /// 1844 pieces measure about 0.28.
  static const double _shortestPeriod = 0.18;
  static const double _longestPeriod = 0.40;
}
