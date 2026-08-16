import 'package:flutter/material.dart';
import 'dart:math' as math;

class HexCoord {
  final int row;
  final int col;
  HexCoord(this.row, this.col);

  @override
  String toString() => 'R$row C$col';
}

class ClassifiedHex {
  final HexCoord coord;
  final Offset center; // in display coordinates
  final String tileId;

  ClassifiedHex({required this.coord, required this.center, required this.tileId});
}

class Board {
  final int rows;
  final int cols;
  final double hexSize;
  final Offset origin;
  Board({required this.rows, required this.cols, required this.hexSize, required this.origin});

  List<Offset> computeCenters({double rotation = 0.0}) {
    // return list of centers in display coordinates in row-major order
    final centers = <Offset>[];
    final w = hexSize * 2;
    final h = math.sqrt(3) * hexSize;
    final horiz = w * 3 / 4;
    final vert = h;
    final rot = rotation * (math.pi / 180.0);

    Offset rotPoint(Offset p) {
      final s = math.sin(rot);
      final c = math.cos(rot);
      final x = p.dx - origin.dx;
      final y = p.dy - origin.dy;
      final rx = x * c - y * s;
      final ry = x * s + y * c;
      return Offset(rx + origin.dx, ry + origin.dy);
    }

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final dx = origin.dx + (c * horiz) + (r.isOdd ? horiz / 2 : 0);
        final dy = origin.dy + (r * (vert * 0.5));
        centers.add(rotPoint(Offset(dx, dy)));
      }
    }
    return centers;
  }
}

double mathSin(double v) => v == 0.0 ? 0.0 : (v).sin();
double mathCos(double v) => v == 0.0 ? 1.0 : (v).cos();
// no extra helpers needed
