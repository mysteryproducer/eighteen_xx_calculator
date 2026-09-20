import 'dart:math' as math;
import 'dart:typed_data';

/// In-place radix-2 fast Fourier transform, used to find the repeat distance
/// of the hex grid in a photo (via autocorrelation). Sizes must be powers of
/// two.
class Fft {
  Fft._();

  /// Transforms [re]/[im] of length n (a power of two) in place. [inverse]
  /// runs the inverse transform, including the 1/n scaling.
  static void transform(Float64List re, Float64List im, {bool inverse = false}) {
    final n = re.length;
    // Bit-reversal permutation.
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final angle = 2 * math.pi / len * (inverse ? 1 : -1);
      final wr = math.cos(angle), wi = math.sin(angle);
      for (int i = 0; i < n; i += len) {
        double cr = 1, ci = 0;
        for (int k = 0; k < len ~/ 2; k++) {
          final a = i + k, b = a + len ~/ 2;
          final xr = re[b] * cr - im[b] * ci;
          final xi = re[b] * ci + im[b] * cr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
    if (inverse) {
      for (int i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }

  /// 2-D transform of an [n] x [n] grid stored row-major.
  static void transform2d(Float64List re, Float64List im, int n,
      {bool inverse = false}) {
    final rr = Float64List(n), ri = Float64List(n);
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        rr[x] = re[y * n + x];
        ri[x] = im[y * n + x];
      }
      transform(rr, ri, inverse: inverse);
      for (int x = 0; x < n; x++) {
        re[y * n + x] = rr[x];
        im[y * n + x] = ri[x];
      }
    }
    for (int x = 0; x < n; x++) {
      for (int y = 0; y < n; y++) {
        rr[y] = re[y * n + x];
        ri[y] = im[y * n + x];
      }
      transform(rr, ri, inverse: inverse);
      for (int y = 0; y < n; y++) {
        re[y * n + x] = rr[y];
        im[y * n + x] = ri[y];
      }
    }
  }

  /// Circular autocorrelation of an [n] x [n] grid: entry (dx, dy) (wrapped
  /// modulo n) is the sum over all pixels of v(p) * v(p + (dx, dy)).
  static Float64List autocorrelation(Float64List values, int n) {
    final re = Float64List.fromList(values);
    final im = Float64List(n * n);
    transform2d(re, im, n);
    for (int i = 0; i < n * n; i++) {
      re[i] = re[i] * re[i] + im[i] * im[i];
      im[i] = 0;
    }
    transform2d(re, im, n, inverse: true);
    return re;
  }
}
