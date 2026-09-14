import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Row/column address of a hex in the board's offset grid.
class HexCoord {
  final int row;
  final int col;
  const HexCoord(this.row, this.col);

  @override
  String toString() => 'R$row C$col';

  @override
  bool operator ==(Object other) =>
      other is HexCoord && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);
}

class ClassifiedHex {
  final HexCoord coord;
  final Offset center; // in display coordinates
  final String tileId;
  final int rotation; // 0..5

  ClassifiedHex({
    required this.coord,
    required this.center,
    required this.tileId,
    this.rotation = 0,
  });
}

/// Geometry helpers for a pointy-top hexagon, shared by the grid painter,
/// the tile template renderer, and the revenue-OCR crop math so they all
/// agree on where hex vertices/edges/centers sit.
///
/// Edges are numbered 0..5 starting at the edge between the vertices at -30
/// and 30 degrees (the "east" edge) and running clockwise on screen:
/// 0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE. As in the tobymao/18xx tile DSL, the
/// edge shared with the neighboring hex across edge k is always `(k + 3) % 6`.
class HexGeometry {
  static const List<int> _vertexAngleOffsets = [0, 1, 2, 3, 4, 5];

  /// Position of vertex [i] (0..5) of a pointy-top hex centered at [center]
  /// with circumradius [size].
  static Offset vertex(Offset center, double size, int i) {
    final angle = (math.pi / 180.0) * (60.0 * _vertexAngleOffsets[i % 6] - 30.0);
    return Offset(
      center.dx + size * math.cos(angle),
      center.dy + size * math.sin(angle),
    );
  }

  /// Midpoint of edge [k] (0..5): the edge between vertex k and vertex k+1.
  static Offset edgeMidpoint(Offset center, double size, int k) {
    final v1 = vertex(center, size, k);
    final v2 = vertex(center, size, (k + 1) % 6);
    return Offset((v1.dx + v2.dx) / 2, (v1.dy + v2.dy) / 2);
  }

  /// The edge on a neighboring hex that touches this hex's edge [k].
  static int oppositeEdge(int k) => (k + 3) % 6;
}

/// Where the hex grid sits relative to an image, and how big it is.
///
/// The same object is used as the user's manual alignment (in display
/// coordinates while they drag sliders) and as the stored calibration (in
/// source-image pixels) that later screens use to crop tiles and revenue
/// numbers out of the photo.
class Board {
  final int rows;
  final int cols;
  final double hexSize; // circumradius
  final Offset origin; // center of hex (0, 0)
  final double rotation; // degrees

  const Board({
    required this.rows,
    required this.cols,
    required this.hexSize,
    required this.origin,
    this.rotation = 0.0,
  });

  Board copyWith({
    int? rows,
    int? cols,
    double? hexSize,
    Offset? origin,
    double? rotation,
  }) =>
      Board(
        rows: rows ?? this.rows,
        cols: cols ?? this.cols,
        hexSize: hexSize ?? this.hexSize,
        origin: origin ?? this.origin,
        rotation: rotation ?? this.rotation,
      );

  /// This calibration re-expressed in another coordinate space, e.g. moving
  /// from on-screen coordinates to source-image pixels. Points map as
  /// `p * scale + offset`.
  Board mapped({required double scale, required Offset offset}) => Board(
        rows: rows,
        cols: cols,
        hexSize: hexSize * scale,
        origin: origin * scale + offset,
        rotation: rotation,
      );

  /// Center of [coord] in this calibration's coordinate space.
  Offset centerOf(HexCoord coord) => rotateAround(
        centerFor(coord.row, coord.col, hexSize, origin),
        origin,
        rotation * (math.pi / 180.0),
      );

  Iterable<HexCoord> get coords sync* {
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        yield HexCoord(r, c);
      }
    }
  }

  /// Center, in local (unrotated) layout coordinates, of hex (r, c).
  ///
  /// Pointy-top hexes, offset coordinates, odd rows shifted right by half a
  /// hex width (the standard "odd-r horizontal layout" -- see
  /// https://www.redblobgames.com/grids/hexagons/#coordinates-offset).
  static Offset centerFor(int r, int c, double hexSize, Offset origin) {
    final width = math.sqrt(3) * hexSize;
    final rowSpacing = 1.5 * hexSize;
    final dx = origin.dx + c * width + (r.isOdd ? width / 2 : 0);
    final dy = origin.dy + r * rowSpacing;
    return Offset(dx, dy);
  }

  static Offset rotateAround(Offset p, Offset center, double radians) {
    final s = math.sin(radians);
    final c = math.cos(radians);
    final x = p.dx - center.dx;
    final y = p.dy - center.dy;
    final rx = x * c - y * s;
    final ry = x * s + y * c;
    return Offset(rx + center.dx, ry + center.dy);
  }

  /// Centers for every (row, col) in row-major order.
  List<Offset> computeCenters() => [for (final c in coords) centerOf(c)];

  /// The hex whose center is nearest [point], or null if nothing is within
  /// [maxDistance] (defaults to one hex radius).
  HexCoord? hexAt(Offset point, {double? maxDistance}) {
    final limit = maxDistance ?? hexSize;
    HexCoord? best;
    double bestDistance = double.infinity;
    for (final coord in coords) {
      final d = (centerOf(coord) - point).distance;
      if (d < bestDistance) {
        bestDistance = d;
        best = coord;
      }
    }
    return bestDistance <= limit ? best : null;
  }

  /// The neighboring hex across edge [edge] (0..5) of [coord], and the edge
  /// number on that neighbor which touches the same physical side. The
  /// returned coordinate may be out of the board's row/col bounds; callers
  /// should check against `rows`/`cols` (or a placed-tile map) themselves.
  static HexCoord neighborOf(HexCoord coord, int edge) {
    final e = edge % 6;
    final r = coord.row;
    final c = coord.col;
    // Odd-r offset neighbor deltas for pointy-top hexes, as [dCol, dRow].
    // Edge numbering follows the vertex order in [HexGeometry]: edge 0 spans
    // the vertices at -30 and 30 degrees, and since screen y grows downward
    // the edges run clockwise 0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE.
    final List<List<int>> evenRowDeltas = [
      [1, 0], // E
      [0, 1], // SE
      [-1, 1], // SW
      [-1, 0], // W
      [-1, -1], // NW
      [0, -1], // NE
    ];
    final List<List<int>> oddRowDeltas = [
      [1, 0], // E
      [1, 1], // SE
      [0, 1], // SW
      [-1, 0], // W
      [0, -1], // NW
      [1, -1], // NE
    ];
    final deltas = r.isOdd ? oddRowDeltas : evenRowDeltas;
    final d = deltas[e];
    return HexCoord(r + d[1], c + d[0]);
  }
}
