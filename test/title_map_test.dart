import 'dart:math' as math;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:flutter_test/flutter_test.dart';

/// The titles whose maps are imported from tobymao/18xx.
final g1844 = GameTitle.byId('1844')!;
final g1854 = GameTitle.byId('1854')!;
final g1889 = GameTitle.byId('1889')!;

void main() {
  group('printed coordinates', () {
    test('a hex id becomes the position the board prints it at', () {
      // 1844 numbers rows A.. down and columns 1.. across, two apart within
      // a row. Zurich is D19, Basel C12.
      final zurich = g1844.map.byId('D19')!;
      final basel = g1844.map.byId('C12')!;
      expect(zurich.name, 'Zurich');
      // Three rows apart on the board means three row steps.
      expect(zurich.coord.row - basel.coord.row, 1);
      // Half a hex width to the right: doubled column 19 against 12.
      expect(zurich.coord.boardCenter.dx - basel.coord.boardCenter.dx,
          closeTo(3.5 * 1.7320508, 1e-6));
    });

    test('neighbours by id really are neighbours on the grid', () {
      // Along a row, the printed number goes up by two.
      final bern = g1844.map.byId('F11')!;
      final langnau = g1844.map.byId('F13')!;
      expect(bern.coord.distanceTo(langnau.coord), 1);
      // East is edge 4 in tobymao's numbering.
      expect(Board.neighborOf(bern.coord, 4), langnau.coord);
      // And diagonally, by one.
      expect(g1844.map.byId('E10')!.coord.distanceTo(bern.coord), 1);
    });

    test('titles that number their rows the other way round still line up', () {
      // 1854's row A carries odd column numbers where 1844's carries even
      // ones, which the row shift takes care of.
      final wien = g1854.map.byId('C23')!;
      final pressburg = g1854.map.byId('C27')!;
      expect(wien.coord.row, pressburg.coord.row);
      expect(wien.coord.distanceTo(pressburg.coord), 2);
      expect(g1854.map.byId('B22')!.coord.distanceTo(wien.coord), 1);
    });
  });

  group('a flat-topped map (1889)', () {
    test("each side leads where the board's does", () {
      // 1889 letters its columns and numbers its rows. Takamatsu (K4)
      // prints track out of its bottom, lower-left and upper-left sides --
      // 0, 1 and 2 -- towards K6, J5 (Ritsurin Kouen) and J3.
      final takamatsu = g1889.map.byId('K4')!;
      expect(takamatsu.name, 'Takamatsu');
      expect(Board.neighborOf(takamatsu.coord, 0), g1889.map.byId('K6')!.coord);
      expect(Board.neighborOf(takamatsu.coord, 1), g1889.map.byId('J5')!.coord);
      expect(Board.neighborOf(takamatsu.coord, 2), g1889.map.byId('J3')!.coord);
      // Two apart down a column, one apart diagonally.
      expect(g1889.map.byId('K8')!.coord.distanceTo(takamatsu.coord), 2);
      expect(g1889.map.byId('I4')!.coord.distanceTo(g1889.map.byId('J5')!.coord),
          1);
    });

    test('every printed track leads onto the map', () {
      for (final hex in g1889.map.hexes) {
        for (final edge in hex.printed.edges) {
          expect(g1889.map.contains(Board.neighborOf(hex.coord, edge)), isTrue,
              reason: '${hex.id} side $edge');
        }
      }
    });

    test('drawn turned back, its columns run straight down the page', () {
      expect(g1889.flat, isTrue);
      expect(g1844.displayTurn, 0);
      Offset drawn(String id) {
        final p = g1889.map.byId(id)!.coord.boardCenter;
        final c = math.cos(g1889.displayTurn), s = math.sin(g1889.displayTurn);
        return Offset(c * p.dx - s * p.dy, s * p.dx + c * p.dy);
      }

      expect(drawn('K4').dx, closeTo(drawn('K8').dx, 1e-9));
      expect(drawn('K8').dy, greaterThan(drawn('K4').dy));
      expect(drawn('C4').dx, lessThan(drawn('K4').dx));
    });

    test("a session's phases are the colours the title's phases bring", () {
      expect(g1889.phaseColours,
          [TileColor.yellow, TileColor.green, TileColor.brown]);
      expect(g1844.phaseColours.last, TileColor.grey);
      expect(g1854.phaseColours.last, TileColor.grey);
    });

    test('off-boards pay by phase, and a D train more', () {
      final imabari = g1889.map.byId('F1')!.printed.stations.single;
      expect(imabari.revenueIn(TileColor.yellow), 30);
      expect(imabari.revenueIn(TileColor.green), 30);
      expect(imabari.revenueIn(TileColor.brown), 60);
      // Phase D brings no new colour of tile, and a train other than a D
      // is still paid the brown figure.
      expect(imabari.revenueIn(TileColor.grey), 60);
      expect(imabari.dieselRevenue, 100);
    });

    test('tiles listed twice for a variant are imported once', () {
      expect(g1889.tiles.containsKey('6'), isTrue);
      expect(g1889.tiles.keys.where((id) => id.startsWith('Beg')), isEmpty);
    });
  });

  group('printed content', () {
    test('off-board areas carry revenue per phase', () {
      final milano = g1844.map.byId('M18')!;
      final station = milano.printed.stations.single;
      expect(station.kind, StationKind.offboard);
      expect(station.revenueIn(TileColor.yellow), 40);
      expect(station.revenueIn(TileColor.brown), 70);
      expect(station.revenueIn(TileColor.grey), 90);
    });

    test('cities, towns and plain hexes are told apart', () {
      expect(g1844.map.byId('C12')!.printed.cityCount, 1); // Basel
      expect(g1844.map.byId('C20')!.printed.cityCount, 2); // Winterthur OO
      expect(g1844.map.byId('B23')!.printed.townCount, 1); // Rorschach
      expect(g1844.map.byId('C10')!.printed.stations, isEmpty); // blank
    });

    test('labels and future labels are kept', () {
      expect(g1844.map.byId('C20')!.printed.label, 'OO');
      // Zurich has no label printed but becomes a Z hex in green.
      expect(g1844.map.byId('D19')!.printed.label, isNull);
      expect(g1844.map.byId('D19')!.futureLabel, 'Z');
    });

    test('impassable borders are kept', () {
      expect(g1844.map.byId('D19')!.printed.impassable, hasLength(1));
      expect(g1844.map.byId('E20')!.printed.impassable, hasLength(2));
    });

    test('hexes that never take a tile are marked as such', () {
      expect(g1844.map.byId('C12')!.takesTiles, isTrue); // white
      expect(g1844.map.byId('M18')!.takesTiles, isFalse); // red off-board
      expect(g1844.map.byId('K2')!.takesTiles, isFalse); // grey Geneve
      expect(g1844.map.byId('K16')!.takesTiles, isFalse); // lake
    });

    test('pre-printed track knows which sides it reaches', () {
      // Chur is printed with a stub of track out of one side, towards the
      // hex the stub actually meets on the board.
      final chur = g1844.map.byId('G26')!;
      expect(chur.printed.edges, hasLength(1));
      final side = chur.printed.edges.single;
      expect(g1844.map.contains(Board.neighborOf(chur.coord, side)), isTrue);
    });
  });

  group('tile manifest', () {
    test('standard tiles come with their track', () {
      final straight = g1844.tiles['9']!;
      expect(straight.color, TileColor.yellow);
      expect(straight.edges, {0, 3});
      expect(g1844.tileCounts['9'], 11);
    });

    test("a title's own tiles are imported with their code", () {
      // 1844's Zurich green tile, which only Zurich takes.
      final z = g1844.tiles['907']!;
      expect(z.color, TileColor.green);
      expect(z.label, 'Z');
      expect(z.stations.single.slots, 2);
    });

    test('1854 has its own tile set', () {
      expect(g1854.tiles['433']!.label, 'W'); // Wien
      expect(g1854.tiles.containsKey('907'), isFalse);
    });
  });

  group('map shape', () {
    test('the map is the hexes that exist, not a rectangle', () {
      expect(g1844.map.hexes.length, 131);
      // A hex at the top of the map has neighbours that aren't on it.
      final corner = g1844.map.byId('A18')!.coord;
      expect(corner.neighbors.where(g1844.map.contains).length, lessThan(6));
    });

    test("1889's hexes to drag are places printed on its board", () {
      // It prints no grid references: the bare hex nearest a corner (A8)
      // gives way to the town beside it.
      expect(g1889.map.anchors.map((h) => h.id), ['A10', 'J1', 'L7', 'G14']);
      expect(g1889.map.anchors.map((h) => h.name),
          ['Sukumo', 'Sakaide & Okayama', 'Naruto & Awaji', 'Muroto']);
    });

    test('anchors are spread to the corners of the map', () {
      final anchors = g1844.map.anchors;
      expect(anchors, hasLength(4));
      expect(anchors.toSet(), hasLength(4));
      final bounds = g1844.map.boardBounds;
      for (final anchor in anchors) {
        final c = anchor.coord.boardCenter;
        expect(
          (c - bounds.topLeft).distance < bounds.longestSide * 0.4 ||
              (c - bounds.bottomRight).distance < bounds.longestSide * 0.4 ||
              (c - bounds.topRight).distance < bounds.longestSide * 0.4 ||
              (c - bounds.bottomLeft).distance < bounds.longestSide * 0.4,
          isTrue,
          reason: '${anchor.id} is not near a corner',
        );
      }
    });

    test('around gathers a hex and its neighbours that exist', () {
      final bern = g1844.map.byId('F11')!.coord;
      expect(g1844.map.around([bern], 1), hasLength(7));
      // At the edge of the map there are fewer.
      final edge = g1844.map.byId('L1')!.coord;
      expect(g1844.map.around([edge], 1).length, lessThan(7));
    });

    test('a plain rectangle is available for boards with no title data', () {
      final grid = MapLayout.rectangle(3, 4);
      expect(grid.hexes, hasLength(12));
      expect(grid.byId('A1')!.coord, const HexCoord(0, 0));
      expect(grid.byId('C4')!.coord, const HexCoord(2, 3));
    });
  });
}
