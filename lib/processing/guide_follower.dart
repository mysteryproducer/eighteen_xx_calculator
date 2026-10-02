import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/map_layout.dart';
import 'grid_detector.dart';

/// A small correction to where a capture guide is drawn: turned and scaled
/// about the middle of the frame, then shifted. Kept in frame units -- the
/// frame's shorter side is one long -- so one worked out on the camera's
/// preview applies to the photo taken from it.
class GuideAdjustment {
  /// Radians, clockwise.
  final double turn;
  final double scale;

  /// In frame units.
  final Offset shift;

  const GuideAdjustment({
    this.turn = 0,
    this.scale = 1,
    this.shift = Offset.zero,
  });

  static const none = GuideAdjustment();

  bool get isNone =>
      turn.abs() < 1e-4 && (scale - 1).abs() < 1e-4 && shift.distance < 1e-4;

  /// The adjustment as a map of a frame's pixels, for a frame of [size].
  Homography inFrame(Size size) {
    final short = math.min(size.width, size.height);
    final centre = Offset(size.width / 2, size.height / 2);
    final c = math.cos(turn) * scale, s = math.sin(turn) * scale;
    final turned =
        Offset(c * centre.dx - s * centre.dy, s * centre.dx + c * centre.dy);
    return Homography.similarity(
        scale: scale,
        radians: turn,
        translation: centre - turned + shift * short);
  }

  /// Part of the way from this to [other], [t] of it: a guide follows the
  /// board smoothly rather than jumping at every frame.
  GuideAdjustment toward(GuideAdjustment other, double t) => GuideAdjustment(
        turn: turn + (other.turn - turn) * t,
        scale: scale + (other.scale - scale) * t,
        shift: Offset.lerp(shift, other.shift, t)!,
      );

  @override
  String toString() => 'GuideAdjustment(turn '
      '${(turn * 180 / math.pi).toStringAsFixed(1)} degrees, scale '
      '${scale.toStringAsFixed(2)}, shift $shift)';
}

/// How bright each pixel of a camera's preview frame is, a byte each.
class GrayFrame {
  final int width;
  final int height;
  final Uint8List luminance;

  const GrayFrame(this.width, this.height, this.luminance);

  /// From four bytes a pixel, [bytesPerRow] apart, with alpha last and red
  /// and blue either way round -- as Apple's cameras give them. Brightness
  /// doesn't care which way round they are.
  factory GrayFrame.fromFourBytes(
      Uint8List bytes, int width, int height, int bytesPerRow) {
    final out = Uint8List(width * height);
    for (int y = 0; y < height; y++) {
      final row = y * bytesPerRow;
      for (int x = 0; x < width; x++) {
        final i = row + x * 4;
        out[y * width + x] = (bytes[i] + bytes[i + 1] + bytes[i + 2]) ~/ 3;
      }
    }
    return GrayFrame(width, height, out);
  }

  img.Image toImage() {
    final image = img.Image(width: width, height: height);
    for (final p in image) {
      final v = luminance[p.y * width + p.x];
      p
        ..r = v
        ..g = v
        ..b = v;
    }
    return image;
  }
}

/// The [GuideAdjustment] that puts a close-up guide on the board the camera
/// sees in [frame]: [guide] is where the guide is drawn (board to the
/// frame's pixels), [target] the hex it is centred on.
///
/// Only a small correction is ever made -- a slight turn, a little bigger
/// or smaller, less than half a hex across -- and always from where the
/// guide was first drawn, never from the last correction, so the outline
/// can't wander off or lock onto the hex next door. Null when the board
/// isn't clear enough in the frame, or needs more than that.
GuideAdjustment? followGuide(
  MapLayout map,
  GrayFrame frame,
  Homography guide,
  HexCoord target,
) {
  final fit = GridDetector(map, workingSize: _workingSize)
      .fitCloseUp(frame.toImage(), guide, target);
  if (fit == null || fit.coverage < _clearEnough) return null;
  final at = target.boardCenter;
  var turn =
      GridFit.facingOf(fit.boardToImage, at) - GridFit.facingOf(guide, at);
  while (turn <= -math.pi) {
    turn += 2 * math.pi;
  }
  while (turn > math.pi) {
    turn -= 2 * math.pi;
  }
  final hex = guide.localScale(at);
  final scale = fit.boardToImage.localScale(at) / hex;
  final from = guide.apply(at), to = fit.boardToImage.apply(at);
  if (turn.abs() > _mostTurn ||
      (scale - 1).abs() > _mostScale ||
      (to - from).distance > _mostShift * hex) {
    return null;
  }
  final size = Size(frame.width.toDouble(), frame.height.toDouble());
  final centre = Offset(size.width / 2, size.height / 2);
  final c = math.cos(turn) * scale, s = math.sin(turn) * scale;
  final d = from - centre;
  final moved = centre + Offset(c * d.dx - s * d.dy, s * d.dx + c * d.dy);
  return GuideAdjustment(
    turn: turn,
    scale: scale,
    shift: (to - moved) / math.min(size.width, size.height),
  );
}

/// Where a close-up guide that has locked onto the board -- [current],
/// board to the frame's pixels -- has moved to in [frame], perspective and
/// all: the camera tilted to keep the lamp's reflection off the board,
/// say, which no turn and scale can follow.
///
/// It is tracked from where it last was, a small step at a time: the step
/// is refused if any corner of the [target] hex would move more than a
/// third of a hex, so the outline can't slide onto the hex next door. Null
/// when the board isn't clear enough in the frame, or the step is too big.
Homography? trackGuide(
  MapLayout map,
  GrayFrame frame,
  Homography current,
  HexCoord target,
) {
  final fit = GridDetector(map, workingSize: _workingSize).refine(
    frame.toImage(),
    current,
    at: target.boardCenter,
    restrictTo: map.around([target], 2).toSet(),
  );
  if (fit.coverage < _clearEnough) return null;
  final next = fit.boardToImage;
  final hex = current.localScale(target.boardCenter);
  for (int i = 0; i < 6; i++) {
    final corner = HexGeometry.vertex(target.boardCenter, 1, i);
    final a = current.apply(corner), b = next.apply(corner);
    if (!b.dx.isFinite || !b.dy.isFinite) return null;
    if ((b - a).distance > _mostStep * hex) return null;
  }
  return next;
}

/// Part of the way from [from] to [to], [t] of it, judged by where the
/// hexes around [at] (board units) go: a tracked guide moves smoothly too.
Homography stepToward(
    Homography from, Homography to, Offset at, double t) {
  final corners = [
    for (final d in const [
      Offset(-1.5, -1.5),
      Offset(1.5, -1.5),
      Offset(1.5, 1.5),
      Offset(-1.5, 1.5),
    ])
      at + d,
  ];
  return Homography.fromFourPoints(corners, [
        for (final c in corners)
          Offset.lerp(from.apply(c), to.apply(c), t)!,
      ]) ??
      to;
}

/// The furthest a tracked guide's target hex may move in one look, in hex
/// radii.
const double _mostStep = 0.35;

/// Preview frames are fitted small: a guide only needs to be close.
const int _workingSize = 640;

/// How much of the outline the fit has to find on the printed lines.
const double _clearEnough = 0.25;

/// The most a guide is turned (radians), scaled (as a share) and shifted
/// (in hex radii) to follow the board.
const double _mostTurn = 25 * math.pi / 180;
const double _mostScale = 0.25;
const double _mostShift = 0.7;
