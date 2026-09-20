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
      // Edges run clockwise from the south-west, as tobymao/18xx numbers
      // them, so east is 4 and west is 1.
      expect(Board.neighborOf(const HexCoord(0, 1), 4), const HexCoord(0, 2));
      expect(Board.neighborOf(const HexCoord(0, 1), 1), const HexCoord(0, 0));
      expect(Board.neighborOf(const HexCoord(1, 1), 4), const HexCoord(1, 2));
      expect(Board.neighborOf(const HexCoord(1, 1), 1), const HexCoord(1, 0));
    });

    test('the sides are where the printed maps say they are', () {
      // Checked against the 1844 board: A20's `path=a:0` and `path=a:5` are
      // the sides facing B19 (south-west) and B21 (south-east).
      const a20 = HexCoord(0, 10); // 1844 numbers this hex A20
      expect(Board.neighborOf(a20, 0), const HexCoord(1, 9)); // B19
      expect(Board.neighborOf(a20, 5), const HexCoord(1, 10)); // B21
      // And the outward normals match: edge 0 points down-left, 5 down-right.
      expect(HexGeometry.edgeNormal(0).dx, lessThan(0));
      expect(HexGeometry.edgeNormal(0).dy, greaterThan(0));
      expect(HexGeometry.edgeNormal(5).dx, greaterThan(0));
      expect(HexGeometry.edgeNormal(5).dy, greaterThan(0));
      expect(HexGeometry.edgeNormal(4).dx, greaterThan(0)); // east
      expect(HexGeometry.edgeNormal(4).dy, closeTo(0, 1e-9));
    });

    test('the hex nearest a point is the one the topology names', () {
      // Cross-check the topology against the geometry: the hex the maths says
      // is across edge k really is the closest hex in that direction.
      const coord = HexCoord(2, 2);
      final centre = coord.boardCenter;
      for (int edge = 0; edge < 6; edge++) {
        final midpoint = HexGeometry.edgeMidpoint(centre, 1, edge);
        final beyond = centre + (midpoint - centre) * 1.6;
        expect(HexCoord.nearestTo(beyond), Board.neighborOf(coord, edge),
            reason: 'edge $edge');
      }
    });

    test('a hex is nearest to its own centre', () {
      for (final coord in [
        const HexCoord(0, 0),
        const HexCoord(1, 3),
        const HexCoord(4, -2),
        const HexCoord(-3, 5),
      ]) {
        expect(HexCoord.nearestTo(coord.boardCenter), coord);
      }
    });
  });

  group('cube coordinates', () {
    test('turning by six steps comes back to where it started', () {
      const pivot = HexCoord(3, 3);
      for (final coord in [const HexCoord(1, 2), const HexCoord(5, 4)]) {
        expect(coord.rotatedAbout(pivot, 6), coord);
        expect(coord.rotatedAbout(pivot, 0), coord);
      }
    });

    test('one turn carries a hex onto the next side', () {
      const centre = HexCoord(2, 2);
      for (int edge = 0; edge < 6; edge++) {
        expect(
          Board.neighborOf(centre, edge).rotatedAbout(centre, 1),
          Board.neighborOf(centre, (edge + 1) % 6),
          reason: 'edge $edge',
        );
      }
    });

    test('turning keeps distances', () {
      const pivot = HexCoord(0, 0);
      const coord = HexCoord(2, 3);
      for (int k = 0; k < 6; k++) {
        expect(coord.rotatedAbout(pivot, k).distanceTo(pivot),
            coord.distanceTo(pivot));
      }
    });

    test('distance counts steps between hexes', () {
      const coord = HexCoord(2, 2);
      expect(coord.distanceTo(coord), 0);
      for (int edge = 0; edge < 6; edge++) {
        expect(coord.distanceTo(Board.neighborOf(coord, edge)), 1);
      }
      expect(coord.distanceTo(const HexCoord(2, 5)), 3);
    });

    test('a translation moves every hex the same way', () {
      const from = HexCoord(1, 1);
      const to = HexCoord(4, 2);
      expect(from.translated(from, to), to);
      for (int edge = 0; edge < 6; edge++) {
        expect(
          Board.neighborOf(from, edge).translated(from, to),
          Board.neighborOf(to, edge),
        );
      }
    });
  });

  group('geometry', () {
    test('hexes tile without gaps or overlaps', () {
      // Neighbouring centres are always one hex width apart, whichever way.
      for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
          final coord = HexCoord(row, col);
          for (int edge = 0; edge < 6; edge++) {
            final neighbour = Board.neighborOf(coord, edge);
            final distance =
                (coord.boardCenter - neighbour.boardCenter).distance;
            expect(distance, closeTo(math.sqrt(3), 0.001),
                reason: '$coord to $neighbour across edge $edge');
          }
        }
      }
    });

    test('opposite edges are three apart', () {
      for (int edge = 0; edge < 6; edge++) {
        expect(HexGeometry.oppositeEdge(HexGeometry.oppositeEdge(edge)), edge);
        expect(HexGeometry.oppositeEdge(edge), (edge + 3) % 6);
      }
    });

  });
}
