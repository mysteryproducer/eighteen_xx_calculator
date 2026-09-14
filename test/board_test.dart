import 'dart:math' as math;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hex neighbours', () {
    test('crossing an edge and coming back lands where you started', () {
      // The invariant that makes the route graph work: edge k of a hex and
      // edge k+3 of the hex beyond it are the same physical side.
      for (final coord in [
        const HexCoord(0, 0),
        const HexCoord(1, 0), // odd row, different offset
        const HexCoord(2, 3),
        const HexCoord(3, 4),
        const HexCoord(5, 2),
      ]) {
        for (int edge = 0; edge < 6; edge++) {
          final neighbour = Board.neighborOf(coord, edge);
          final back = Board.neighborOf(neighbour, HexGeometry.oppositeEdge(edge));
          expect(back, coord,
              reason: 'hex $coord edge $edge -> $neighbour and back');
        }
      }
    });

    test('a hex has six distinct neighbours', () {
      for (final coord in [const HexCoord(2, 2), const HexCoord(3, 2)]) {
        final neighbours = {
          for (int edge = 0; edge < 6; edge++) Board.neighborOf(coord, edge),
        };
        expect(neighbours, hasLength(6));
        expect(neighbours.contains(coord), isFalse);
      }
    });

    test('east and west neighbours are the adjacent columns', () {
      expect(Board.neighborOf(const HexCoord(0, 1), 0), const HexCoord(0, 2));
      expect(Board.neighborOf(const HexCoord(0, 1), 3), const HexCoord(0, 0));
      expect(Board.neighborOf(const HexCoord(1, 1), 0), const HexCoord(1, 2));
      expect(Board.neighborOf(const HexCoord(1, 1), 3), const HexCoord(1, 0));
    });

    test('neighbours found by coordinate are the nearest ones on screen', () {
      // Cross-check the topology against the geometry: the hex the maths says
      // is across edge k really is the closest hex in that direction.
      const board = Board(
        rows: 5,
        cols: 5,
        hexSize: 30,
        origin: Offset(200, 200),
      );
      const coord = HexCoord(2, 2);
      final center = board.centerOf(coord);
      for (int edge = 0; edge < 6; edge++) {
        final expected = Board.neighborOf(coord, edge);
        // Step from the center out past the edge midpoint.
        final midpoint = HexGeometry.edgeMidpoint(center, board.hexSize, edge);
        final beyond = center + (midpoint - center) * 1.6;
        expect(board.hexAt(beyond), expected, reason: 'edge $edge');
      }
    });
  });

  group('geometry', () {
    test('hexes tile without gaps or overlaps', () {
      const board = Board(rows: 4, cols: 4, hexSize: 40, origin: Offset.zero);
      final expectedSpacing = math.sqrt(3) * board.hexSize;
      for (final coord in board.coords) {
        for (int edge = 0; edge < 6; edge++) {
          final neighbour = Board.neighborOf(coord, edge);
          if (neighbour.row < 0 ||
              neighbour.col < 0 ||
              neighbour.row >= board.rows ||
              neighbour.col >= board.cols) {
            continue;
          }
          final distance =
              (board.centerOf(coord) - board.centerOf(neighbour)).distance;
          expect(distance, closeTo(expectedSpacing, 0.001),
              reason: '$coord to $neighbour across edge $edge');
        }
      }
    });

    test('opposite edges are three apart', () {
      for (int edge = 0; edge < 6; edge++) {
        expect(HexGeometry.oppositeEdge(HexGeometry.oppositeEdge(edge)), edge);
        expect(HexGeometry.oppositeEdge(edge), (edge + 3) % 6);
      }
    });

    test('calibration maps between image and display space', () {
      const board = Board(
        rows: 2,
        cols: 2,
        hexSize: 10,
        origin: Offset(100, 100),
        rotation: 12,
      );
      final display = board.mapped(scale: 2, offset: const Offset(5, 7));
      expect(display.hexSize, 20);
      expect(display.origin, const Offset(205, 207));
      final roundTrip =
          display.mapped(scale: 0.5, offset: const Offset(-2.5, -3.5));
      expect(roundTrip.origin.dx, closeTo(board.origin.dx, 0.001));
      expect(roundTrip.origin.dy, closeTo(board.origin.dy, 0.001));
      expect(roundTrip.hexSize, closeTo(board.hexSize, 0.001));
      expect(roundTrip.rotation, board.rotation);
    });

    test('rotation turns the grid about the origin', () {
      const board = Board(
        rows: 2,
        cols: 2,
        hexSize: 20,
        origin: Offset.zero,
        rotation: 90,
      );
      final unrotated = Board.centerFor(0, 1, 20, Offset.zero);
      final rotated = board.centerOf(const HexCoord(0, 1));
      expect(rotated.dx, closeTo(-unrotated.dy, 0.001));
      expect(rotated.dy, closeTo(unrotated.dx, 0.001));
    });
  });
}
