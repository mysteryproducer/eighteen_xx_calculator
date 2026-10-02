import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
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
  Map<HexCoord, TileDefinition> drawn = const {},
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
    final def = drawn[hex.coord] ??
        (placed == null
            ? hex.printed
            : title.tiles[placed.tileId]!.rotated(placed.rotation));
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

/// Lays a mountain railway plate on [hex] of a board drawn by [drawBoard],
/// which [toImage] places: pale card with a box per phase in the phase's
/// colour, left to right -- 1844 prints brown's box salmon. The boxes are
/// left blank; a figure in each would be a font the test can't count on.
void drawPlate(img.Image board, Homography toImage, MapHex hex) {
  void fill(double left, double right, double half, img.Color colour) {
    final a = toImage.apply(hex.coord.boardCenter + Offset(left, -half));
    final b = toImage.apply(hex.coord.boardCenter + Offset(right, half));
    img.fillRect(board,
        x1: a.dx.round(), y1: a.dy.round(),
        x2: b.dx.round(), y2: b.dy.round(),
        color: colour);
  }

  fill(-0.62, 0.62, 0.22, img.ColorRgb8(240, 236, 226));
  final boxes = [
    img.ColorRgb8(240, 215, 60),
    img.ColorRgb8(80, 165, 95),
    img.ColorRgb8(235, 160, 150),
    img.ColorRgb8(170, 170, 170),
  ];
  for (int i = 0; i < boxes.length; i++) {
    final left = -0.56 + i * 0.29;
    fill(left, left + 0.25, 0.14, boxes[i]);
  }
}

/// [board] as a camera under a lamp sees it: exposed darker than the
/// drawing's near-white paper, and with a veil of glare of [glare] centred
/// on [at], fading out over [reach] pixels.
void underLamp(img.Image board,
    {double glare = 0, Offset at = Offset.zero, double reach = 1}) {
  for (final p in board) {
    final d = (Offset(p.x.toDouble(), p.y.toDouble()) - at).distance / reach;
    final veil = glare * (1 - d * d).clamp(0.0, 1.0);
    num lit(num c) => c * 0.75 + (255 - c * 0.75) * veil;
    p
      ..r = lit(p.r)
      ..g = lit(p.g)
      ..b = lit(p.b);
  }
}
