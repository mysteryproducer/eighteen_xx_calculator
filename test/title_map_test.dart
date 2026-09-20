import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two titles whose maps are imported from tobymao/18xx.
final g1844 = GameTitle.byId('1844')!;
final g1854 = GameTitle.byId('1854')!;

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
