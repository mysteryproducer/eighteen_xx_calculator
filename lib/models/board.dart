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

  // Cube coordinates (x + y + z == 0) make rotating and measuring simple; see
  // https://www.redblobgames.com/grids/hexagons/#conversions-offset.
  int get cubeX => col - (row - (row & 1)) ~/ 2;
  int get cubeZ => row;
  int get cubeY => -cubeX - cubeZ;

  static HexCoord fromCube(int x, int z) =>
      HexCoord(z, x + (z - (z & 1)) ~/ 2);

  /// Steps between this hex and [other].
  int distanceTo(HexCoord other) {
    final dx = (cubeX - other.cubeX).abs();
    final dy = (cubeY - other.cubeY).abs();
    final dz = (cubeZ - other.cubeZ).abs();
    return math.max(dx, math.max(dy, dz));
  }

  /// This hex turned [steps] x 60 degrees clockwise about [pivot]. Turning
  /// by one step carries a hex's edge k onto edge k + 1.
  HexCoord rotatedAbout(HexCoord pivot, int steps) {
    var x = cubeX - pivot.cubeX;
    var y = cubeY - pivot.cubeY;
    var z = cubeZ - pivot.cubeZ;
    for (int i = 0; i < ((steps % 6) + 6) % 6; i++) {
      final nx = -z, ny = -x, nz = -y;
      x = nx;
      y = ny;
      z = nz;
    }
    return fromCube(x + pivot.cubeX, z + pivot.cubeZ);
  }

  /// This hex moved by the cube offset that takes [from] to [to].
  HexCoord translated(HexCoord from, HexCoord to) => fromCube(
        cubeX + to.cubeX - from.cubeX,
        cubeZ + to.cubeZ - from.cubeZ,
      );

  /// The six hexes around this one, in edge order 0..5.
  List<HexCoord> get neighbors =>
      [for (int e = 0; e < 6; e++) Board.neighborOf(this, e)];

  /// Position of this hex's centre on the flat board, in units of the hex
  /// circumradius, with hex (0, 0) at the origin.
  Offset get boardCenter => Board.centerFor(row, col, 1, Offset.zero);

  /// The hex whose centre is nearest [point] on the flat board (in the units
  /// of [boardCenter]).
  static HexCoord nearestTo(Offset point) {
    // Fractional axial coordinates for a pointy-top layout, then cube
    // rounding (redblobgames.com/grids/hexagons/#rounding).
    final q = (math.sqrt(3) / 3 * point.dx - point.dy / 3);
    final r = (2 / 3 * point.dy);
    final x = q, z = r, y = -q - r;
    var rx = x.roundToDouble(), ry = y.roundToDouble(), rz = z.roundToDouble();
    final dx = (rx - x).abs(), dy = (ry - y).abs(), dz = (rz - z).abs();
    if (dx > dy && dx > dz) {
      rx = -ry - rz;
    } else if (dy > dz) {
      ry = -rx - rz;
    } else {
      rz = -rx - ry;
    }
    return fromCube(rx.toInt(), rz.toInt());
  }
}

/// Geometry helpers for a pointy-top hexagon, shared by the tile renderer,
/// the grid detector and the drawn board, so they all agree on where hex
/// vertices, edges and centres sit.
///
/// Edges are numbered as in the tobymao/18xx tile DSL: 0 is the south-west
/// side and they run clockwise on screen, so 0=SW, 1=W, 2=NW, 3=NE, 4=E,
/// 5=SE. (Checked against printed 1844 hexes: A20's `path=a:0` and
/// `path=a:5` are the sides facing B19 and B21, and Bern's `path=a:5` faces
/// G12.) The edge shared with the hex across edge k is always `(k + 3) % 6`.
class HexGeometry {
  /// Direction, in degrees clockwise from east, of the outward normal of
  /// edge 0. The rest follow every 60 degrees.
  static const double _firstEdgeAngle = 120;

  /// Position of vertex [i] (0..5) of a pointy-top hex centered at [center]
  /// with circumradius [size]. Vertex i and vertex i + 1 are the ends of
  /// edge i.
  static Offset vertex(Offset center, double size, int i) {
    final angle = (math.pi / 180.0) * (_firstEdgeAngle - 30 + 60.0 * (i % 6));
    return Offset(
      center.dx + size * math.cos(angle),
      center.dy + size * math.sin(angle),
    );
  }

  /// Unit vector pointing out of the hex across edge [k].
  static Offset edgeNormal(int k) {
    final angle = (math.pi / 180.0) * (_firstEdgeAngle + 60.0 * (k % 6));
    return Offset(math.cos(angle), math.sin(angle));
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

/// The flat board's geometry: where hexes sit, and which hex is across a
/// given side.
///
/// Positions are in units of a hex's circumradius with hex (0, 0) at the
/// origin; a photo is tied to this space by a perspective transform (see
/// `GridDetector`), and the drawn board by a simple scale (see
/// `BoardMapGeometry`).
class Board {
  Board._();

  /// Centre of hex (r, c), [hexSize] being the circumradius and [origin] the
  /// centre of hex (0, 0).
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

  /// The hex across edge [edge] (0..5) of [coord]. The hex may not exist on
  /// the map, which callers check with `MapLayout.contains`.
  static HexCoord neighborOf(HexCoord coord, int edge) {
    final e = edge % 6;
    final r = coord.row;
    final c = coord.col;
    // Odd-r offset neighbour deltas for pointy-top hexes, as [dCol, dRow],
    // in the edge order [HexGeometry] documents: SW, W, NW, NE, E, SE.
    final List<List<int>> evenRowDeltas = [
      [-1, 1], // SW
      [-1, 0], // W
      [-1, -1], // NW
      [0, -1], // NE
      [1, 0], // E
      [0, 1], // SE
    ];
    final List<List<int>> oddRowDeltas = [
      [0, 1], // SW
      [-1, 0], // W
      [0, -1], // NW
      [1, -1], // NE
      [1, 0], // E
      [1, 1], // SE
    ];
    final deltas = r.isOdd ? oddRowDeltas : evenRowDeltas;
    final d = deltas[e];
    return HexCoord(r + d[1], c + d[0]);
  }
}
