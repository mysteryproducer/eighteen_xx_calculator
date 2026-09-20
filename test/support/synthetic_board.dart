import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Stand-in board photos for tests: a title's map drawn from its own data,
/// then re-photographed through a perspective transform. Nothing here
/// depends on a real photo, so the tests run anywhere.
final title = GameTitle.byId('1844')!;

/// Draws a title's map flat, as if the board were photographed square-on
/// from directly above, with the tiles in [laid] on it.
Future<img.Image> drawBoard(
  MapLayout map, {
  double hexRadius = 26,
  Map<HexCoord, PlacedTile> laid = const {},
}) async {
  final bounds = map.boardBounds.inflate(1.2);
  final width = (bounds.width * hexRadius).round();
  final height = (bounds.height * hexRadius).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // A table top around the board, so the edge of the map is a real edge.
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF6E6152));
  final tileSize = hexRadius / 0.48;
  for (final hex in map.hexes) {
    final placed = laid[hex.coord];
    final def = placed == null
        ? hex.printed
        : title.tiles[placed.tileId]!.rotated(placed.rotation);
    final centre = (hex.coord.boardCenter - bounds.topLeft) * hexRadius;
    canvas.save();
    canvas.translate(centre.dx - tileSize / 2, centre.dy - tileSize / 2);
    TileRenderer.paint(canvas, def, tileSize);
    canvas.restore();
  }
  final picture = recorder.endRecording();
  final rendered = await picture.toImage(width, height);
  final data = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
  return img.Image.fromBytes(
      width: width, height: height, bytes: data!.buffer, numChannels: 4);
}

/// Where each hex centre ended up in [drawBoard]'s picture.
Homography boardToDrawn(MapLayout map, double hexRadius) {
  final bounds = map.boardBounds.inflate(1.2);
  return Homography.similarity(
    scale: hexRadius,
    translation: -bounds.topLeft * hexRadius,
  );
}

/// Re-photographs [source] through [h], as a camera held off-square would
/// see it, optionally dimming one side the way a lamp does.
img.Image warp(img.Image source, Homography h,
    {required int width, required int height, double shading = 0}) {
  final out = img.Image(width: width, height: height);
  final back = h.inverse;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final p = back.apply(Offset(x + 0.5, y + 0.5));
      if (p.dx < 0 || p.dy < 0 || p.dx >= source.width || p.dy >= source.height) {
        out.setPixelRgb(x, y, 40, 36, 32);
        continue;
      }
      final pixel = source.getPixel(p.dx.floor(), p.dy.floor());
      final light = 1 - shading * (x / width);
      out.setPixelRgb(
        x,
        y,
        (pixel.r * light).round().clamp(0, 255),
        (pixel.g * light).round().clamp(0, 255),
        (pixel.b * light).round().clamp(0, 255),
      );
    }
  }
  return out;
}

/// How far the fit puts each hex from where it really is, as a share of a
/// hex's radius.
double worstError(GridFit fit, Homography truth, Iterable<HexCoord> hexes) {
  double worst = 0;
  for (final hex in hexes) {
    final expected = truth.apply(hex.boardCenter);
    final actual = fit.boardToImage.apply(hex.boardCenter);
    final radius = truth.localScale(hex.boardCenter);
    worst = math.max(worst, (expected - actual).distance / radius);
  }
  return worst;
}


/// The transform a 90 degree clockwise turn of [source] applies.
Homography rotate90(img.Image source) => Homography([
      0, -1, source.height.toDouble(), //
      1, 0, 0, //
      0, 0, 1,
    ]);
