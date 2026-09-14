import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/board.dart';
import '../models/tile_definition.dart';

/// Draws a [TileDefinition] as a hex tile.
///
/// The same drawing is used two ways: rasterized into reference images the
/// classifier matches camera patches against, and (via [TilePainter]) shown in
/// the UI when the user is correcting a recognized tile. Because the picture
/// comes from the same data the route graph is built from, there is no
/// separate library of tile artwork to keep in sync.
class TileRenderer {
  TileRenderer._();

  static const Color trackColor = Color(0xFF1A1A1A);

  static Color backgroundFor(TileColor color) => switch (color) {
        TileColor.plain => const Color(0xFFEDE7D9),
        TileColor.yellow => const Color(0xFFFCE94F),
        TileColor.green => const Color(0xFF73C26B),
        TileColor.brown => const Color(0xFFB97A3D),
        TileColor.grey => const Color(0xFFBDBDBD),
      };

  /// Where a station sits inside the hex: at the centre normally, or nudged
  /// toward the edges it serves when a tile carries more than one station.
  static Offset stationPosition(
    TileDefinition def,
    int stationIndex,
    Offset center,
    double radius,
  ) {
    if (def.stations.length < 2) return center;
    final directions = <Offset>[];
    for (final seg in def.segments) {
      final endpoints = [seg.a, seg.b];
      final touchesStation = endpoints.any(
          (e) => e is StationEndpoint && e.stationIndex == stationIndex);
      if (!touchesStation) continue;
      for (final e in endpoints) {
        if (e is EdgeEndpoint) {
          final mid = HexGeometry.edgeMidpoint(center, radius, e.edge);
          directions.add(mid - center);
        }
      }
    }
    if (directions.isEmpty) return center;
    var sum = Offset.zero;
    for (final d in directions) {
      sum += d;
    }
    final avg = sum / directions.length.toDouble();
    final len = avg.distance;
    if (len < 0.01) return center;
    return center + (avg / len) * (radius * 0.42);
  }

  /// Paints [def] centered in a [size] x [size] square.
  static void paint(Canvas canvas, TileDefinition def, double size) {
    final center = Offset(size / 2, size / 2);
    final radius = size * 0.48;

    // Hex body.
    final hexPath = Path();
    for (int i = 0; i < 6; i++) {
      final v = HexGeometry.vertex(center, radius, i);
      if (i == 0) {
        hexPath.moveTo(v.dx, v.dy);
      } else {
        hexPath.lineTo(v.dx, v.dy);
      }
    }
    hexPath.close();
    canvas.drawPath(hexPath, Paint()..color = backgroundFor(def.color));
    canvas.drawPath(
      hexPath,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.015,
    );

    Offset positionOf(TileEndpoint e) => switch (e) {
          EdgeEndpoint(:final edge) => HexGeometry.edgeMidpoint(center, radius, edge),
          StationEndpoint(:final stationIndex) =>
            stationPosition(def, stationIndex, center, radius),
        };

    // Track. Segments bend toward the hex centre, which makes straights
    // straight and turns curve the way real tile art does.
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.09
      ..strokeCap = StrokeCap.round;
    for (final seg in def.segments) {
      final from = positionOf(seg.a);
      final to = positionOf(seg.b);
      final path = Path()..moveTo(from.dx, from.dy);
      if (seg.a is EdgeEndpoint && seg.b is EdgeEndpoint) {
        path.quadraticBezierTo(center.dx, center.dy, to.dx, to.dy);
      } else {
        path.lineTo(to.dx, to.dy);
      }
      canvas.drawPath(path, trackPaint);
    }

    // Revenue centres: cities are open circles, towns are filled bars/dots.
    for (final station in def.stations) {
      final pos = stationPosition(def, station.index, center, radius);
      if (station.kind == StationKind.city) {
        final r = size * (station.slots > 1 ? 0.15 : 0.13);
        if (station.slots > 1) {
          // Multi-slot cities are drawn as a stadium shape, as on real tiles.
          final rect = Rect.fromCenter(
            center: pos,
            width: r * 2 * station.slots,
            height: r * 2,
          );
          final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));
          canvas.drawRRect(rrect, Paint()..color = Colors.white);
          canvas.drawRRect(
            rrect,
            Paint()
              ..color = trackColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = size * 0.03,
          );
        } else {
          canvas.drawCircle(pos, r, Paint()..color = Colors.white);
          canvas.drawCircle(
            pos,
            r,
            Paint()
              ..color = trackColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = size * 0.03,
          );
        }
      } else {
        canvas.drawCircle(pos, size * 0.07, Paint()..color = trackColor);
      }
    }
  }

  /// Rasterizes [def] into an [img.Image] for template matching.
  static Future<img.Image> rasterize(TileDefinition def, {int size = 64}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = Colors.white,
    );
    paint(canvas, def, size.toDouble());
    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(size, size);
    final data = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    uiImage.dispose();
    if (data == null) {
      throw StateError('Failed to rasterize tile ${def.id}');
    }
    return img.Image.fromBytes(
      width: size,
      height: size,
      bytes: data.buffer,
      numChannels: 4,
    );
  }
}

/// Shows a tile definition as a widget, for the tile-correction UI.
class TilePainter extends CustomPainter {
  final TileDefinition definition;

  const TilePainter(this.definition);

  @override
  void paint(Canvas canvas, Size size) {
    TileRenderer.paint(canvas, definition, math.min(size.width, size.height));
  }

  @override
  bool shouldRepaint(covariant TilePainter oldDelegate) =>
      oldDelegate.definition != definition;
}
