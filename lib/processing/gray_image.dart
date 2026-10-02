import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A single-channel image stored as floats in 0..1, for the numeric work in
/// grid detection. Reading pixels through `package:image` allocates per call,
/// which is far too slow for the millions of samples detection takes.
class GrayImage {
  final int width;
  final int height;
  final Float32List data;

  GrayImage(this.width, this.height, [Float32List? data])
      : data = data ?? Float32List(width * height);

  /// Luminance of [source], averaged down so its longer side is at most
  /// [maxSide] pixels (or full size if null). [scaleOf] reports the scale
  /// actually used.
  factory GrayImage.fromImage(img.Image source, {int? maxSide}) {
    final bytes = source.getBytes(order: img.ChannelOrder.rgb);
    final sw = source.width, sh = source.height;
    final scale = maxSide == null
        ? 1.0
        : math.min(1.0, maxSide / math.max(sw, sh));
    final tw = math.max(1, (sw * scale).round());
    final th = math.max(1, (sh * scale).round());
    final sums = Float32List(tw * th);
    final counts = Int32List(tw * th);
    final fx = tw / sw, fy = th / sh;
    final bpp = bytes.length ~/ (sw * sh);
    final maxValue = source.maxChannelValue.toDouble();
    for (int y = 0; y < sh; y++) {
      final ty = math.min(th - 1, (y * fy).floor());
      int i = y * sw * bpp;
      for (int x = 0; x < sw; x++, i += bpp) {
        final tx = math.min(tw - 1, (x * fx).floor());
        final l = bpp >= 3
            ? 0.299 * bytes[i] + 0.587 * bytes[i + 1] + 0.114 * bytes[i + 2]
            : bytes[i].toDouble();
        final t = ty * tw + tx;
        sums[t] += l;
        counts[t]++;
      }
    }
    final out = GrayImage(tw, th);
    for (int i = 0; i < out.data.length; i++) {
      out.data[i] = counts[i] == 0 ? 0 : sums[i] / counts[i] / maxValue;
    }
    return out;
  }

  /// The scale [GrayImage.fromImage] would use for an image of this size.
  static double scaleFor(int width, int height, int? maxSide) => maxSide == null
      ? 1.0
      : math.min(1.0, maxSide / math.max(width, height));

  double at(int x, int y) => data[y * width + x];

  bool contains(double x, double y) =>
      x >= 0 && y >= 0 && x <= width - 1 && y <= height - 1;

  /// Bilinear sample at ([x], [y]); coordinates outside are clamped to the
  /// border.
  double sample(double x, double y) {
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > width - 1) x = (width - 1).toDouble();
    if (y > height - 1) y = (height - 1).toDouble();
    final x0 = x.floor(), y0 = y.floor();
    final x1 = x0 + 1 < width ? x0 + 1 : x0;
    final y1 = y0 + 1 < height ? y0 + 1 : y0;
    final ax = x - x0, ay = y - y0;
    final top = data[y0 * width + x0] * (1 - ax) + data[y0 * width + x1] * ax;
    final bottom = data[y1 * width + x0] * (1 - ax) + data[y1 * width + x1] * ax;
    return top * (1 - ay) + bottom * ay;
  }

  /// Mean filter over a (2r+1)-pixel square, done as two running sums.
  GrayImage boxBlur(int r) {
    if (r <= 0) return GrayImage(width, height, Float32List.fromList(data));
    final tmp = Float32List(width * height);
    final out = GrayImage(width, height);
    for (int y = 0; y < height; y++) {
      final row = y * width;
      double sum = 0;
      for (int x = -r; x <= r; x++) {
        sum += data[row + x.clamp(0, width - 1)];
      }
      for (int x = 0; x < width; x++) {
        tmp[row + x] = sum / (2 * r + 1);
        sum += data[row + (x + r + 1).clamp(0, width - 1)] -
            data[row + (x - r).clamp(0, width - 1)];
      }
    }
    for (int x = 0; x < width; x++) {
      double sum = 0;
      for (int y = -r; y <= r; y++) {
        sum += tmp[y.clamp(0, height - 1) * width + x];
      }
      for (int y = 0; y < height; y++) {
        out.data[y * width + x] = sum / (2 * r + 1);
        sum += tmp[(y + r + 1).clamp(0, height - 1) * width + x] -
            tmp[(y - r).clamp(0, height - 1) * width + x];
      }
    }
    return out;
  }

  /// Area-averaged copy scaled by [scale] (< 1 to shrink).
  /// The [width] x [height] part of this image whose top left is ([left],
  /// [top]).
  GrayImage cropped(int left, int top, int width, int height) {
    final out = GrayImage(width, height);
    for (int y = 0; y < height; y++) {
      final from = (top + y) * this.width + left;
      out.data.setRange(y * width, (y + 1) * width, data, from);
    }
    return out;
  }

  /// This image stretched [factor] times taller, sampled between pixels.
  GrayImage stretchedTall(double factor) {
    final th = math.max(1, (height * factor).round());
    final out = GrayImage(width, th);
    for (int y = 0; y < th; y++) {
      final sy = (y + 0.5) / factor - 0.5;
      for (int x = 0; x < width; x++) {
        out.data[y * width + x] = sample(x.toDouble(), sy);
      }
    }
    return out;
  }

  GrayImage scaled(double scale) {
    final tw = math.max(1, (width * scale).round());
    final th = math.max(1, (height * scale).round());
    final sums = Float32List(tw * th);
    final counts = Int32List(tw * th);
    final fx = tw / width, fy = th / height;
    for (int y = 0; y < height; y++) {
      final ty = math.min(th - 1, (y * fy).floor());
      for (int x = 0; x < width; x++) {
        final t = ty * tw + math.min<int>(tw - 1, (x * fx).floor());
        sums[t] += data[y * width + x];
        counts[t]++;
      }
    }
    final out = GrayImage(tw, th);
    for (int i = 0; i < out.data.length; i++) {
      out.data[i] = counts[i] == 0 ? 0 : sums[i] / counts[i];
    }
    return out;
  }

  /// How strongly each pixel sits on a thin dark line: its darkness relative
  /// to the surrounding area, as a fraction of that area's brightness so
  /// dim corners of a photo count as much as the brightly lit middle.
  ///
  /// Hex outlines on a printed map are thin dark lines, so this is what grid
  /// detection looks for. [lineRadius] is roughly half the line width in
  /// pixels and [surroundRadius] a few times that.
  GrayImage darkLines({int lineRadius = 1, int surroundRadius = 4}) {
    final line = boxBlur(lineRadius);
    final surround = boxBlur(surroundRadius);
    final out = GrayImage(width, height);
    for (int i = 0; i < data.length; i++) {
      final d = (surround.data[i] - line.data[i]) / (surround.data[i] + 0.05);
      out.data[i] = d > 0 ? d : 0;
    }
    return out;
  }

  double get mean {
    double s = 0;
    for (final v in data) {
      s += v;
    }
    return data.isEmpty ? 0 : s / data.length;
  }

  /// Converts back to a viewable image, for debugging.
  img.Image toImage({double gain = 1}) {
    final out = img.Image(width: width, height: height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final v = (data[y * width + x] * gain * 255).clamp(0, 255).round();
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }
}

/// An RGB image as bytes, for fast bilinear colour sampling when cutting
/// deskewed hexes out of a photo.
class RgbImage {
  final int width;
  final int height;
  final Uint8List bytes; // r, g, b per pixel

  RgbImage(this.width, this.height, this.bytes);

  factory RgbImage.fromImage(img.Image source) {
    final converted = source.format == img.Format.uint8 && source.numChannels >= 3
        ? source
        : source.convert(format: img.Format.uint8, numChannels: 3);
    return RgbImage(
      converted.width,
      converted.height,
      converted.getBytes(order: img.ChannelOrder.rgb),
    );
  }

  bool contains(double x, double y) =>
      x >= 0 && y >= 0 && x <= width - 1 && y <= height - 1;

  /// Bilinear sample of channel values 0..255 into [out] (length 3).
  void sample(double x, double y, List<double> out) {
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > width - 1) x = (width - 1).toDouble();
    if (y > height - 1) y = (height - 1).toDouble();
    final x0 = x.floor(), y0 = y.floor();
    final x1 = x0 + 1 < width ? x0 + 1 : x0;
    final y1 = y0 + 1 < height ? y0 + 1 : y0;
    final ax = x - x0, ay = y - y0;
    final i00 = (y0 * width + x0) * 3, i01 = (y0 * width + x1) * 3;
    final i10 = (y1 * width + x0) * 3, i11 = (y1 * width + x1) * 3;
    for (int c = 0; c < 3; c++) {
      final top = bytes[i00 + c] * (1 - ax) + bytes[i01 + c] * ax;
      final bottom = bytes[i10 + c] * (1 - ax) + bytes[i11 + c] * ax;
      out[c] = top * (1 - ay) + bottom * ay;
    }
  }
}
