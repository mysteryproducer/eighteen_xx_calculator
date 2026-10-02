import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import 'gray_image.dart';
import 'tile_renderer.dart';

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

  /// How much dark printing crosses each of the six sides, 0..1.
  ///
  /// This is what tells a tile from bare map at a glance: track runs off the
  /// edge of a tile, while the map's own art -- hill shading, place names,
  /// a river -- mostly doesn't cross a hex side, and where it does (a printed
  /// river) it does so in the same place every time, which the stored
  /// picture of the hex accounts for.
  final Float32List exits;

  /// [darkness] smoothed, which is what comparisons use: track is a thin
  /// line, and comparing thin lines pixel for pixel punishes a line that is
  /// a little out of place more than one that isn't there at all -- so a real
  /// tile can lose to bare map. A few pixels of blur forgives the difference
  /// between drawn track and printed track, and the last fraction of a hex in
  /// the grid's placement.
  final Float32List smoothed;

  HexPatch(this.darkness, this.chroma, this.exits)
      : smoothed = _blur(darkness, 2);

  /// Mean filter over a square, the same idea as `GrayImage.boxBlur` but on
  /// the fixed-size patch.
  static Float32List _blur(Float32List source, int r) {
    final out = Float32List(size * size);
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        double total = 0;
        int count = 0;
        for (int oy = -r; oy <= r; oy++) {
          final sy = y + oy;
          if (sy < 0 || sy >= size) continue;
          for (int ox = -r; ox <= r; ox++) {
            final sx = x + ox;
            if (sx < 0 || sx >= size) continue;
            total += source[sy * size + sx];
            count++;
          }
        }
        out[y * size + x] = count == 0 ? 0 : total / count;
      }
    }
    return out;
  }

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

  static final List<bool> _inMask = () {
    final result = List<bool>.filled(size * size, false);
    for (final i in mask) {
      result[i] = true;
    }
    return result;
  }();

  /// Track crossing a side is looked for in a thin band just inside it, and
  /// has to run right through the band rather than merely touch it. Tile
  /// track always meets a side square on, so close to the side it runs
  /// straight in even when the rest of it curves away; a place name or a hill
  /// doesn't run through, and the hex's own printed outline -- dark, and
  /// blurred inward in a photo of a whole board -- doesn't reach the inner
  /// edge of the band.
  ///
  /// The band is searched every half a pixel or so across the side: track
  /// printed thin, like the line on 1844's tunnel pieces, is only a couple of
  /// samples wide, and a coarser search can step straight over it.
  ///
  /// The band slides a little along the track, too: from as deep as the
  /// first window of [_exitDepths] to as far out as the last. Where a tile
  /// has a pale rim, or the grid sits a few hundredths of a hex out, track
  /// ends just short of where the band would otherwise be; and beside a
  /// city printed close to the side -- the capsule of two slots on a
  /// green tile -- the white of the city takes up the inner end.
  static const List<double> _exitDepths = [0.62, 0.68, 0.74, 0.80, 0.86, 0.92];

  /// How many neighbouring depths have to be dark together: a run of a
  /// sixth of the way to the side.
  static const int _exitRun = 3;

  /// The deepest a run may end and still count as reaching the side.
  static const double _exitReach = 0.80;
  static const List<double> _exitSpread = [
    -0.18, -0.135, -0.09, -0.045, 0, 0.045, 0.09, 0.135, 0.18, //
  ];

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

  /// Cuts [hex] out of [photo] using [boardToImage], [shift] (in board
  /// units) from where it places the hex.
  factory HexPatch.fromPhoto(
    RgbImage photo,
    Homography boardToImage,
    HexCoord hex, {
    Offset shift = Offset.zero,
  }) {
    final centre = hex.boardCenter + shift;
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
  ///
  /// A photo is scaled so its darkest printing is about 1, since the camera
  /// decides how dark black comes out. A drawing knows what black is, so it
  /// is scaled against the track colour instead: otherwise a hex whose only
  /// printing is faint -- the dotted line of a railway not yet opened -- is
  /// scaled up until it looks like solid track, and the tile that opens the
  /// line can't be told from the map underneath.
  factory HexPatch.fromTileImage(img.Image tile) {
    final scaled = tile.width == size && tile.height == size
        ? tile
        : img.copyResize(tile,
            width: size, height: size, interpolation: img.Interpolation.average);
    const ink = TileRenderer.trackColor;
    return HexPatch._fromSampler((x, y, out) {
      final p = scaled.getPixel(x, y);
      out[0] = p.r.toDouble();
      out[1] = p.g.toDouble();
      out[2] = p.b.toDouble();
    },
        inkLuminance: 255 *
            (0.299 * ink.r + 0.587 * ink.g + 0.114 * ink.b));
  }

  factory HexPatch._fromSampler(
    void Function(int x, int y, List<double> out) sample, {
    double? inkLuminance,
  }) {
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
      // Lakes and rivers are dark but blue, so they shouldn't read as track.
      // Track itself is printed black, which photographs warm-brown under
      // warm light and saturated enough to be thrown out by any test for
      // "coloured", so the test has to be for blue in particular.
      final sum = r[i] + g[i] + b[i];
      final blueness = sum <= 0 ? 0.0 : (b[i] - (r[i] + g[i]) / 2) / sum;
      d *= (1 - (blueness - 0.02) / 0.10).clamp(0.0, 1.0);
      darkness[i] = d;
      raw.add(d);
    }
    raw.sort();
    strongest = inkLuminance == null
        ? raw[(raw.length * 0.98).floor()]
        : (background - inkLuminance) / background;
    // Scale so solid printing is about 1, but don't blow up the faint
    // texture of a blank hex into something that looks like track.
    final scale = 1 / math.max(0.3, strongest);
    for (final i in mask) {
      darkness[i] = math.min(1.0, darkness[i] * scale);
    }

    // The tile's own colour, from the pixels about as bright as its
    // background. White city circles are the brightest, least coloured
    // thing on a tile, and where they cover much of it -- three big circles
    // on a brown tile -- they would set the background, the brown would
    // count as too dark to be background, and the tile's colour would come
    // out grey. So they are left out, unless that leaves too little to go on
    // (bare map and grey tiles are pale and colourless all over).
    final brightest = values[(values.length * 0.95).floor()];
    bool whiteish(int i) {
      final hi = math.max(r[i], math.max(g[i], b[i]));
      final lo = math.min(r[i], math.min(g[i], b[i]));
      return lum[i] > brightest * 0.85 && hi > 0 && (hi - lo) / hi < 0.12;
    }

    final coloured = [
      for (final i in mask)
        if (!whiteish(i)) lum[i],
    ]..sort();
    final skipWhite = coloured.length >= mask.length * 0.3;
    final paper = skipWhite
        ? math.max(1.0, coloured[(coloured.length * 0.7).floor()])
        : background;
    double sr = 0, sg = 0, sb = 0;
    int count = 0;
    for (final i in mask) {
      if (skipWhite && whiteish(i)) continue;
      final d = (paper - lum[i]) / paper;
      if (d > 0.1 || lum[i] > paper * 1.15) continue;
      sr += r[i];
      sg += g[i];
      sb += b[i];
      count++;
    }
    final sum = sr + sg + sb;
    final chroma = count == 0 || sum <= 0
        ? Offset.zero
        : Offset((sr - sg) / sum, ((sr + sg) / 2 - sb) / sum);

    // How much dark printing crosses each side.
    return HexPatch(darkness, chroma, _exitsOf(darkness));
  }

  /// How strongly track runs across each side of [hex] and on into the
  /// hex next door, read straight from [photo]: along lines square to the
  /// side, the weakest darkness from a little inside the side to a little
  /// beyond it, and the strongest such line.
  ///
  /// Track that leaves a tile carries on into its neighbour's wherever the
  /// two connect, so this sees an exit even where the tile's own end of it
  /// is a short stub beside a city -- blurred over by the white of the city
  /// in a photo of the whole board -- and isn't fooled by the printed
  /// outline, which runs along the side rather than across it. A side with
  /// no crossing says nothing: track may end at a bare hex.
  static Float32List crossingsOf(
      RgbImage photo, Homography boardToImage, HexCoord hex) {
    final centre = hex.boardCenter;
    final rgb = List<double>.filled(3, 0);
    // Darkness against the paper around the hex, scaled so that solid
    // printing is about 1, as for a patch.
    double luminanceAt(Offset board) {
      final p = boardToImage.apply(board);
      photo.sample(p.dx, p.dy, rgb);
      final sum = rgb[0] + rgb[1] + rgb[2];
      final blueness = sum <= 0 ? 0.0 : (rgb[2] - (rgb[0] + rgb[1]) / 2) / sum;
      final l = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
      // Blue water is dark but isn't track: count it as paper.
      return blueness > 0.06 ? double.infinity : l;
    }

    final around = <double>[];
    for (int y = -12; y <= 12; y++) {
      for (int x = -12; x <= 12; x++) {
        final l = luminanceAt(centre + Offset(x / 12, y / 12) * 1.3);
        if (l.isFinite) around.add(l);
      }
    }
    final crossings = Float32List(6);
    if (around.length < 50) return crossings;
    around.sort();
    final paper = math.max(1.0, around[(around.length * 0.7).floor()]);
    final ink = around[(around.length * 0.02).floor()];
    final full = math.max(0.3, (paper - ink) / paper);
    double darkness(Offset board) {
      final l = luminanceAt(board);
      if (!l.isFinite) return 0;
      return (math.max(0.0, (paper - l) / paper) / full).clamp(0.0, 1.0);
    }

    for (int k = 0; k < 6; k++) {
      final normal = HexGeometry.edgeNormal(k);
      final along = Offset(-normal.dy, normal.dx);
      double line(double t) {
        double weakest = 1;
        for (final depth in _crossingDepths) {
          final d = darkness(centre + normal * (depth * _apothem) + along * t);
          if (d < weakest) weakest = d;
        }
        return weakest;
      }

      double strongest = 0;
      for (final t in _exitSpread) {
        // Track crosses at one place; a border printed along the side, or a
        // shadow, is as dark a little way along it either side.
        final beside = (line(t - _besideCrossing) + line(t + _besideCrossing)) / 2;
        final crossing = line(t) - beside;
        if (crossing > strongest) strongest = crossing;
      }
      crossings[k] = strongest;
    }
    return crossings;
  }

  /// From inside a side to beyond it, as shares of the hex's apothem: clear
  /// of the side itself, where the printed outline runs, and where laid
  /// tiles meet in a thin pale rim that breaks the track.
  static const List<double> _crossingDepths = [0.82, 0.89, 1.11, 1.18];

  /// How far along the side, either way, the paper beside a crossing is.
  static const double _besideCrossing = 0.3;

  /// Where the side exits of the hex centred at [centre] (in board units)
  /// are sampled, for tools to show.
  static Iterable<Offset> exitSamples(Offset centre) sync* {
    for (int k = 0; k < 6; k++) {
      final normal = HexGeometry.edgeNormal(k);
      final along = Offset(-normal.dy, normal.dx);
      for (final t in _exitSpread) {
        for (final depth in _exitDepths) {
          yield centre + normal * (depth * _apothem) + along * t;
        }
      }
    }
  }

  /// How much dark printing crosses each side: along each line running
  /// through the band towards the side, the weakest of its samples (the line
  /// has to be dark all the way through, not just touch the band), and the
  /// strongest such line.
  static Float32List _exitsOf(Float32List darkness) {
    // Between samples, from the ones inside the hex: the outermost depth is
    // within a sample of the edge of [mask], and outside it there is no
    // picture, not blank map.
    double at(double fx, double fy) {
      final x0 = fx.floor(), y0 = fy.floor();
      final ax = fx - x0, ay = fy - y0;
      double total = 0, weight = 0;
      void add(int x, int y, double w) {
        if (x < 0 || y < 0 || x >= size || y >= size) return;
        if (!_inMask[y * size + x] || w <= 0) return;
        total += darkness[y * size + x] * w;
        weight += w;
      }

      add(x0, y0, (1 - ax) * (1 - ay));
      add(x0 + 1, y0, ax * (1 - ay));
      add(x0, y0 + 1, (1 - ax) * ay);
      add(x0 + 1, y0 + 1, ax * ay);
      return weight <= 0 ? 0.0 : total / weight;
    }

    final exits = Float32List(6);
    final along = Float64List(_exitDepths.length);
    for (int k = 0; k < 6; k++) {
      final normal = HexGeometry.edgeNormal(k);
      final across = Offset(-normal.dy, normal.dx);
      double strongest = 0;
      for (final t in _exitSpread) {
        for (int i = 0; i < _exitDepths.length; i++) {
          final p = normal * (_exitDepths[i] * _apothem) + across * t;
          along[i] = at(p.dx * radiusShare * size + size / 2 - 0.5,
              p.dy * radiusShare * size + size / 2 - 0.5);
        }
        // The best run of neighbouring depths that reaches far enough out.
        for (int end = _exitRun - 1; end < _exitDepths.length; end++) {
          if (_exitDepths[end] < _exitReach) continue;
          double weakest = 1;
          for (int i = end - _exitRun + 1; i <= end; i++) {
            if (along[i] < weakest) weakest = along[i];
          }
          if (weakest > strongest) strongest = weakest;
        }
      }
      exits[k] = strongest;
    }
    return exits;
  }

  static const double _apothem = 0.8660254037844386;

  /// Mean squared difference in darkness over the hex, 0 for identical.
  double distanceTo(HexPatch other) {
    double total = 0;
    for (final i in mask) {
      final d = smoothed[i] - other.smoothed[i];
      total += d * d;
    }
    return total / mask.length;
  }

  // --- Lining up ----------------------------------------------------------
  //
  // Lining a drawing up with a photo compares a hex at many small shifts, so
  // it uses a plainer, coarser picture of it: darkness against the hex's
  // background, at half the samples each way, only where [mask] looks.

  /// Width and height of the coarse picture, in samples.
  static const int coarseSize = size ~/ 2;

  /// Coarse sample indices inside the hex, as [mask].
  static final List<int> coarseMask = () {
    final result = <int>[];
    for (int y = 0; y < coarseSize; y++) {
      for (int x = 0; x < coarseSize; x++) {
        if (_hexNorm(_coarseOffset(x, y)) < 0.8) result.add(y * coarseSize + x);
      }
    }
    return result;
  }();

  static Offset _coarseOffset(int x, int y) => Offset(
        (x + 0.5 - coarseSize / 2) / (radiusShare * coarseSize),
        (y + 0.5 - coarseSize / 2) / (radiusShare * coarseSize),
      );

  /// [hex]'s printing in [photo] as a coarse picture, [shift] (in board
  /// units) from where [boardToImage] places it. A value per [coarseMask]
  /// sample.
  static Float32List coarseFromPhoto(
    RgbImage photo,
    Homography boardToImage,
    HexCoord hex, {
    Offset shift = Offset.zero,
  }) {
    final centre = hex.boardCenter + shift;
    final lum = Float32List(coarseSize * coarseSize);
    final histogram = List<int>.filled(64, 0);
    final rgb = List<double>.filled(3, 0);
    for (final i in coarseMask) {
      final p = boardToImage
          .apply(centre + _coarseOffset(i % coarseSize, i ~/ coarseSize));
      photo.sample(p.dx, p.dy, rgb);
      final l = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
      lum[i] = l;
      histogram[(l / 4).floor().clamp(0, 63)]++;
    }
    // The background as the classifier takes it: a high-ish percentile, so
    // white city circles don't count as background either.
    final wanted = (coarseMask.length * 0.7).floor();
    var bin = 0, seen = 0;
    while (bin < 63 && seen + histogram[bin] <= wanted) {
      seen += histogram[bin];
      bin++;
    }
    final background = math.max(1.0, bin * 4.0 + 2);
    final dark = Float32List(coarseSize * coarseSize);
    for (final i in coarseMask) {
      dark[i] = math.max(0.0, (background - lum[i]) / background);
    }
    // Blurred a little, as [smoothed] is.
    final out = Float32List(coarseMask.length);
    for (int k = 0; k < coarseMask.length; k++) {
      final i = coarseMask[k];
      final x = i % coarseSize, y = i ~/ coarseSize;
      double total = 0;
      int count = 0;
      for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
          final sx = x + ox, sy = y + oy;
          if (sx < 0 || sy < 0 || sx >= coarseSize || sy >= coarseSize) continue;
          total += dark[sy * coarseSize + sx];
          count++;
        }
      }
      out[k] = total / count;
    }
    return out;
  }

  /// This patch's [smoothed] darkness as a coarse picture (see
  /// [coarseFromPhoto]).
  late final Float32List coarse = () {
    final out = Float32List(coarseMask.length);
    for (int k = 0; k < coarseMask.length; k++) {
      final i = coarseMask[k];
      final x = (i % coarseSize) * 2, y = (i ~/ coarseSize) * 2;
      out[k] = (smoothed[y * size + x] +
              smoothed[y * size + x + 1] +
              smoothed[(y + 1) * size + x] +
              smoothed[(y + 1) * size + x + 1]) /
          4;
    }
    return out;
  }();

  /// How alike two coarse pictures of a hex's printing are, -1..1: the
  /// correlation of their darkness. Unlike [distanceTo], a blank hex is not
  /// a near miss for track a little out of place -- both score nothing --
  /// which is what lining a drawing up with a photo needs.
  static double alike(Float32List a, Float32List b) {
    final n = a.length;
    double ma = 0, mb = 0;
    for (int i = 0; i < n; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= n;
    mb /= n;
    double ab = 0, aa = 0, bb = 0;
    for (int i = 0; i < n; i++) {
      final x = a[i] - ma, y = b[i] - mb;
      ab += x * y;
      aa += x * x;
      bb += y * y;
    }
    return aa <= 0 || bb <= 0 ? 0 : ab / math.sqrt(aa * bb);
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
    return HexPatch(values, chroma, _exitsOf(values));
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
