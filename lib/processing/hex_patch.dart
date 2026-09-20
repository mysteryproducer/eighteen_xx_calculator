import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import 'gray_image.dart';

/// One hex cut out of a photo and squared up, reduced to what recognition
/// compares: where the dark printing is, and the colour of the background.
///
/// The hex is sampled through the board-to-photo perspective transform, so
/// however the photo was angled the patch is framed exactly as
/// `TileRenderer` draws a tile -- same size, same orientation -- and a tile
/// in the photo lines up pixel for pixel with its rendered template.
class HexPatch {
  /// Width and height in samples.
  static const int size = 48;

  /// The hex's circumradius as a share of [size], as in `TileRenderer.paint`.
  static const double radiusShare = 0.48;

  /// How dark each sample is against the hex's own background, scaled so the
  /// darkest printing is about 1. Zero outside the hex.
  final Float32List darkness;

  /// Background colour as (red - green, yellow - blue) shares of brightness.
  final Offset chroma;

  const HexPatch(this.darkness, this.chroma);

  /// Sample indices inside the hex, clear of its outline (and of small
  /// errors in where the outline was found).
  static final List<int> mask = () {
    final result = <int>[];
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final o = _boardOffset(x, y);
        if (_hexNorm(o) < 0.8) result.add(y * size + x);
      }
    }
    return result;
  }();

  /// Board offset from the hex centre of sample (x, y).
  static Offset _boardOffset(int x, int y) => Offset(
        (x + 0.5 - size / 2) / (radiusShare * size),
        (y + 0.5 - size / 2) / (radiusShare * size),
      );

  static double _hexNorm(Offset v) {
    final a = v.dx.abs();
    final b = (0.5 * v.dx + 0.8660254037844386 * v.dy).abs();
    final c = (-0.5 * v.dx + 0.8660254037844386 * v.dy).abs();
    return math.max(a, math.max(b, c));
  }

  /// Cuts [hex] out of [photo] using [boardToImage].
  factory HexPatch.fromPhoto(
    RgbImage photo,
    Homography boardToImage,
    HexCoord hex,
  ) {
    final centre = hex.boardCenter;
    final rgb = List<double>.filled(3, 0);
    return HexPatch._fromSampler((x, y, out) {
      final p = boardToImage.apply(centre + _boardOffset(x, y));
      photo.sample(p.dx, p.dy, rgb);
      out[0] = rgb[0];
      out[1] = rgb[1];
      out[2] = rgb[2];
    });
  }

  /// From an image framed like a `TileRenderer` tile (a rendered template,
  /// or a test image), at any size.
  factory HexPatch.fromTileImage(img.Image tile) {
    final scaled = tile.width == size && tile.height == size
        ? tile
        : img.copyResize(tile,
            width: size, height: size, interpolation: img.Interpolation.average);
    return HexPatch._fromSampler((x, y, out) {
      final p = scaled.getPixel(x, y);
      out[0] = p.r.toDouble();
      out[1] = p.g.toDouble();
      out[2] = p.b.toDouble();
    });
  }

  factory HexPatch._fromSampler(void Function(int x, int y, List<double> out) sample) {
    final n = size * size;
    final r = Float32List(n), g = Float32List(n), b = Float32List(n);
    final lum = Float32List(n);
    final rgb = List<double>.filled(3, 0);
    for (final i in mask) {
      sample(i % size, i ~/ size, rgb);
      r[i] = rgb[0];
      g[i] = rgb[1];
      b[i] = rgb[2];
      lum[i] = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
    }

    // Most of a tile is background; take a high-ish percentile as its
    // brightness so white city circles don't count as background either.
    final values = [for (final i in mask) lum[i]]..sort();
    final background = math.max(1.0, values[(values.length * 0.7).floor()]);

    final darkness = Float32List(n);
    double strongest = 0;
    final raw = <double>[];
    for (final i in mask) {
      var d = math.max(0.0, (background - lum[i]) / background);
      // Track, city rings and town bars are printed black. Lakes and rivers
      // are dark too, but coloured, so strongly coloured pixels count less.
      final hi = math.max(r[i], math.max(g[i], b[i]));
      final lo = math.min(r[i], math.min(g[i], b[i]));
      final saturation = hi <= 0 ? 0.0 : (hi - lo) / hi;
      d *= (1 - (saturation - 0.2) / 0.3).clamp(0.0, 1.0);
      darkness[i] = d;
      raw.add(d);
    }
    raw.sort();
    strongest = raw[(raw.length * 0.98).floor()];
    // Scale so solid printing is about 1, but don't blow up the faint
    // texture of a blank hex into something that looks like track.
    final scale = 1 / math.max(0.3, strongest);
    for (final i in mask) {
      darkness[i] = math.min(1.0, darkness[i] * scale);
    }

    double sr = 0, sg = 0, sb = 0;
    int count = 0;
    for (final i in mask) {
      final d = (background - lum[i]) / background;
      if (d > 0.1 || lum[i] > background * 1.15) continue;
      sr += r[i];
      sg += g[i];
      sb += b[i];
      count++;
    }
    final sum = sr + sg + sb;
    final chroma = count == 0 || sum <= 0
        ? Offset.zero
        : Offset((sr - sg) / sum, ((sr + sg) / 2 - sb) / sum);
    return HexPatch(darkness, chroma);
  }

  /// Mean squared difference in darkness over the hex, 0 for identical.
  double distanceTo(HexPatch other) {
    double total = 0;
    for (final i in mask) {
      final d = darkness[i] - other.darkness[i];
      total += d * d;
    }
    return total / mask.length;
  }

  /// A compact form for saving: darkness quantized to bytes, base64.
  String encodeDarkness() {
    final bytes = Uint8List(size * size);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = (darkness[i] * 255).round().clamp(0, 255);
    }
    return base64Encode(bytes);
  }

  static HexPatch decode(String darkness, Offset chroma) {
    final bytes = base64Decode(darkness);
    final values = Float32List(size * size);
    for (int i = 0; i < values.length && i < bytes.length; i++) {
      values[i] = bytes[i] / 255;
    }
    return HexPatch(values, chroma);
  }

  /// The hex as a small colour picture, for showing the user what the camera
  /// saw next to what it was read as.
  static img.Image picture(
    RgbImage photo,
    Homography boardToImage,
    HexCoord hex, {
    int pixels = 128,
  }) {
    final out = img.Image(width: pixels, height: pixels);
    final centre = hex.boardCenter;
    final rgb = List<double>.filled(3, 0);
    for (int y = 0; y < pixels; y++) {
      for (int x = 0; x < pixels; x++) {
        final o = Offset(
          (x + 0.5 - pixels / 2) / (radiusShare * pixels),
          (y + 0.5 - pixels / 2) / (radiusShare * pixels),
        );
        final p = boardToImage.apply(centre + o);
        photo.sample(p.dx, p.dy, rgb);
        out.setPixelRgb(x, y, rgb[0].round(), rgb[1].round(), rgb[2].round());
      }
    }
    return out;
  }
}
