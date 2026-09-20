import 'dart:math' as math;
import 'dart:ui' show Offset;

/// A plane-to-plane perspective transform: the mapping between the flat board
/// and a photo of it taken from an angle.
///
/// Stored as a 3x3 matrix in row-major order. A point (x, y) maps to
/// ((h0 x + h1 y + h2) / w, (h3 x + h4 y + h5) / w) with w = h6 x + h7 y + h8.
/// A similarity transform (move, scale, turn) is the special case with
/// h6 = h7 = 0, which is what the old slider-based grid alignment could
/// express; a photo taken off-square needs the full eight degrees of freedom.
class Homography {
  final List<double> m;

  const Homography(this.m);

  static const Homography identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  /// Scale by [scale], turn by [radians] about the origin, then move by
  /// [translation].
  factory Homography.similarity({
    double scale = 1,
    double radians = 0,
    Offset translation = Offset.zero,
  }) {
    final c = math.cos(radians) * scale;
    final s = math.sin(radians) * scale;
    return Homography([c, -s, translation.dx, s, c, translation.dy, 0, 0, 1]);
  }

  /// The affine map taking the origin to [origin] and the unit x and y
  /// vectors to [xAxis] and [yAxis].
  factory Homography.affine({
    required Offset origin,
    required Offset xAxis,
    required Offset yAxis,
  }) =>
      Homography([
        xAxis.dx, yAxis.dx, origin.dx, //
        xAxis.dy, yAxis.dy, origin.dy, //
        0, 0, 1,
      ]);

  Offset apply(Offset p) {
    final w = m[6] * p.dx + m[7] * p.dy + m[8];
    return Offset(
      (m[0] * p.dx + m[1] * p.dy + m[2]) / w,
      (m[3] * p.dx + m[4] * p.dy + m[5]) / w,
    );
  }

  /// This transform followed by [other]: `a.then(b).apply(p) == b.apply(a.apply(p))`.
  Homography then(Homography other) => other._times(this);

  Homography _times(Homography o) {
    final a = m;
    final b = o.m;
    return Homography([
      for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
          a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c],
    ])._normalized();
  }

  Homography get inverse {
    final a = m;
    final c00 = a[4] * a[8] - a[5] * a[7];
    final c01 = a[5] * a[6] - a[3] * a[8];
    final c02 = a[3] * a[7] - a[4] * a[6];
    final det = a[0] * c00 + a[1] * c01 + a[2] * c02;
    if (det.abs() < 1e-18) {
      throw StateError('Homography is not invertible');
    }
    final inv = 1 / det;
    return Homography([
      c00 * inv,
      (a[2] * a[7] - a[1] * a[8]) * inv,
      (a[1] * a[5] - a[2] * a[4]) * inv,
      c01 * inv,
      (a[0] * a[8] - a[2] * a[6]) * inv,
      (a[2] * a[3] - a[0] * a[5]) * inv,
      c02 * inv,
      (a[1] * a[6] - a[0] * a[7]) * inv,
      (a[0] * a[4] - a[1] * a[3]) * inv,
    ])._normalized();
  }

  Homography _normalized() {
    final s = m[8];
    if (s.abs() < 1e-12) return this;
    return Homography([for (final v in m) v / s]);
  }

  /// How much a small step at [p] is stretched: the square root of the local
  /// area scale. Used to turn board distances into pixels at a given spot,
  /// which varies across a photo taken at an angle.
  double localScale(Offset p) {
    const e = 1e-3;
    final o = apply(p);
    final dx = apply(p + const Offset(e, 0)) - o;
    final dy = apply(p + const Offset(0, e)) - o;
    final area = (dx.dx * dy.dy - dx.dy * dy.dx).abs();
    return math.sqrt(area) / e;
  }

  /// The transform taking each of four [from] points exactly onto the
  /// matching [to] point, or null if three of them are in a line.
  static Homography? fromFourPoints(List<Offset> from, List<Offset> to) {
    assert(from.length == 4 && to.length == 4);
    return fit(from, to);
  }

  /// Least-squares transform taking [from] points onto [to] points, weighted
  /// by [weights] if given. Needs at least four points not all in a line;
  /// returns null otherwise.
  ///
  /// Uses the normalized direct linear transform (Hartley & Zisserman,
  /// Multiple View Geometry, 4.4): both point sets are shifted and scaled to
  /// be centred on the origin with unit spread before solving, which keeps the
  /// linear system well conditioned whether coordinates are board units or
  /// thousands of pixels.
  static Homography? fit(
    List<Offset> from,
    List<Offset> to, {
    List<double>? weights,
  }) {
    final n = from.length;
    if (n < 4 || to.length != n) return null;
    final w = weights ?? List<double>.filled(n, 1);

    final tFrom = _normalizing(from, w);
    final tTo = _normalizing(to, w);
    if (tFrom == null || tTo == null) return null;

    // Unknowns h0..h7 with h8 fixed at 1. Each correspondence gives two rows:
    //   x' (h6 x + h7 y + 1) = h0 x + h1 y + h2
    //   y' (h6 x + h7 y + 1) = h3 x + h4 y + h5
    final ata = List.generate(8, (_) => List<double>.filled(8, 0));
    final atb = List<double>.filled(8, 0);
    void addRow(List<double> row, double rhs, double weight) {
      for (int i = 0; i < 8; i++) {
        if (row[i] == 0) continue;
        final wi = row[i] * weight;
        for (int j = 0; j < 8; j++) {
          ata[i][j] += wi * row[j];
        }
        atb[i] += wi * rhs;
      }
    }

    for (int i = 0; i < n; i++) {
      if (w[i] <= 0) continue;
      final p = tFrom.apply(from[i]);
      final q = tTo.apply(to[i]);
      final x = p.dx, y = p.dy, u = q.dx, v = q.dy;
      addRow([x, y, 1, 0, 0, 0, -u * x, -u * y], u, w[i]);
      addRow([0, 0, 0, x, y, 1, -v * x, -v * y], v, w[i]);
    }

    final h = _solve(ata, atb);
    if (h == null) return null;
    final normalized = Homography([...h, 1]);
    // Undo the normalization: from -> tFrom -> H -> tTo^-1 -> to.
    try {
      return tFrom.then(normalized).then(tTo.inverse);
    } on StateError {
      return null;
    }
  }

  static Homography? _normalizing(List<Offset> points, List<double> weights) {
    double sx = 0, sy = 0, sw = 0;
    for (int i = 0; i < points.length; i++) {
      if (weights[i] <= 0) continue;
      sx += points[i].dx * weights[i];
      sy += points[i].dy * weights[i];
      sw += weights[i];
    }
    if (sw <= 0) return null;
    final cx = sx / sw, cy = sy / sw;
    double spread = 0;
    for (int i = 0; i < points.length; i++) {
      if (weights[i] <= 0) continue;
      spread += (points[i] - Offset(cx, cy)).distance * weights[i];
    }
    spread /= sw;
    if (spread < 1e-12) return null;
    final s = math.sqrt2 / spread;
    return Homography([s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1]);
  }

  /// Gaussian elimination with partial pivoting. Returns null if singular.
  static List<double>? _solve(List<List<double>> a, List<double> b) {
    final n = b.length;
    final m = [for (int i = 0; i < n; i++) [...a[i], b[i]]];
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
      }
      if (m[pivot][col].abs() < 1e-12) return null;
      final tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final f = m[r][col] / m[col][col];
        if (f == 0) continue;
        for (int c = col; c <= n; c++) {
          m[r][c] -= f * m[col][c];
        }
      }
    }
    return [for (int i = 0; i < n; i++) m[i][n] / m[i][i]];
  }

  List<double> toJson() => m;

  static Homography fromJson(List<dynamic> json) =>
      Homography([for (final v in json) (v as num).toDouble()]);

  @override
  bool operator ==(Object other) {
    if (other is! Homography) return false;
    for (int i = 0; i < 9; i++) {
      if (other.m[i] != m[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(m);

  @override
  String toString() =>
      'Homography(${m.map((v) => v.toStringAsFixed(4)).join(', ')})';
}
