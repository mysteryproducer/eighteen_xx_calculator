import 'dart:math' as math;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

final title = GameTitle.byId('1844')!;

/// Where stop [index] of [def] sits, in a hex of circumradius 1 centred on
/// the origin.
Offset stop(TileDefinition def, int index) =>
    TileRenderer.stationPosition(def, index, Offset.zero, 1);

/// The middle of side [edge] of that hex.
Offset side(int edge) => HexGeometry.edgeMidpoint(Offset.zero, 1, edge);

void main() {
  group('stops sit where tiles print them', () {
    test('a city on its own is in the middle', () {
      expect(stop(title.tiles['57']!, 0), Offset.zero);
      expect(stop(title.tiles['619']!.rotated(2), 0), Offset.zero);
    });

    test('a town on a gentle curve sits on the curve, not in the middle', () {
      // Tile 58: a town between sides 0 and 2. The curve's centre is the
      // next hex's, across side 1, and it passes a quarter of a radius from
      // the middle.
      final at = stop(title.tiles['58']!, 0);
      final nextHex = HexGeometry.edgeNormal(1) * math.sqrt(3);
      expect((at - nextHex).distance, closeTo(1.5, 0.01));
      expect(at.distance, closeTo(math.sqrt(3) - 1.5, 0.01));
    });

    test('a town on a tight turn sits on the turn, round the corner', () {
      // Tile 3: sides 0 and 1. The turn's centre is the corner they share.
      final at = stop(title.tiles['3']!, 0);
      final corner = HexGeometry.vertex(Offset.zero, 1, 1);
      expect((at - corner).distance, closeTo(0.5, 0.01));
      expect(at.distance, closeTo(0.5, 0.01));
    });

    test("tile 67, as laid at Fribourg, has a city on each of its runs", () {
      // Photographed on the board: one city on the straight from south-west
      // to north-east, a little way towards the north-east; the other on the
      // gentle curve from west to south-east, towards the south-east -- the
      // two stacked on the east side of the hex.
      final def = title.tiles['67']!.rotated(3);
      final straight = stop(def, 0);
      final curve = stop(def, 1);
      expect(straight.distance, closeTo(0.4, 0.05));
      // On the line through the middle towards side 3 (north-east).
      final northEast = HexGeometry.edgeNormal(3);
      expect(straight.dx * northEast.dy - straight.dy * northEast.dx,
          closeTo(0, 0.01));
      expect(straight.dx * northEast.dx + straight.dy * northEast.dy,
          greaterThan(0));
      // On the curve round the next hex across side 0, at its south-east end.
      final nextHex = HexGeometry.edgeNormal(0) * math.sqrt(3);
      expect((curve - nextHex).distance, closeTo(1.5, 0.01));
      expect(curve.dx, greaterThan(0));
      expect(curve.dy, greaterThan(0));
    });

    test('no two cities on a tile overlap, however it is turned', () {
      for (final id in ['59', '64', '65', '66', '67', '68']) {
        for (int turn = 0; turn < 6; turn++) {
          final def = title.tiles[id]!.rotated(turn);
          final cities = [
            for (final s in def.stations)
              if (s.kind == StationKind.city) s,
          ];
          for (int i = 0; i < cities.length; i++) {
            for (int j = i + 1; j < cities.length; j++) {
              final apart =
                  (stop(def, cities[i].index) - stop(def, cities[j].index))
                      .distance;
              expect(
                  apart,
                  greaterThanOrEqualTo(TileRenderer.slotRadiusFor(cities[i]) +
                      TileRenderer.slotRadiusFor(cities[j])),
                  reason: 'tile $id turned $turn');
            }
          }
        }
      }
    });

    test('the printed OO hexes are laid out as the board prints them', () {
      // Romont & Fribourg one above the other; Winterthur & Frauenfeld on a
      // line rising to the right.
      final fribourg = title.map.byId('G8')!.printed;
      final upper = stop(fribourg, 0), lower = stop(fribourg, 1);
      expect(upper.dx, closeTo(0, 0.01));
      expect(lower.dx, closeTo(0, 0.01));
      expect(upper.dy, lessThan(-0.4));
      expect(lower.dy, greaterThan(0.4));
      final winterthur = title.map.byId('C20')!.printed;
      final right = stop(winterthur, 0), left = stop(winterthur, 1);
      expect(right.dx, greaterThan(0.3));
      expect(right.dy, lessThan(-0.2));
      expect(left.dx, lessThan(-0.3));
      expect(left.dy, greaterThan(0.2));
    });
  });
}
