import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'board.dart';

/// Maps between source-image pixels and on-screen positions for an image
/// displayed with `BoxFit.contain`.
///
/// Grid calibration is stored in image pixels so it survives being shown on
/// screens of different sizes; this converts it for painting and for hit
/// testing taps.
class ImageLayout {
  final Size imageSize;
  final Size containerSize;

  const ImageLayout({required this.imageSize, required this.containerSize});

  /// Display pixels per source-image pixel.
  double get scale {
    if (imageSize.width <= 0 || imageSize.height <= 0) return 1;
    return math.min(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height,
    );
  }

  Size get displaySize => Size(imageSize.width * scale, imageSize.height * scale);

  Offset get topLeft => Offset(
        (containerSize.width - displaySize.width) / 2,
        (containerSize.height - displaySize.height) / 2,
      );

  Rect get displayRect => topLeft & displaySize;

  Offset imageToDisplay(Offset p) => p * scale + topLeft;

  Offset displayToImage(Offset p) => (p - topLeft) / scale;

  /// [board] (in image pixels) expressed in display coordinates.
  Board boardToDisplay(Board board) => board.mapped(scale: scale, offset: topLeft);

  /// [board] (in display coordinates) expressed in image pixels.
  Board boardToImage(Board board) =>
      board.mapped(scale: 1 / scale, offset: -topLeft / scale);
}
