import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/models/tile_rules.dart';
import 'package:flutter_test/flutter_test.dart';

final title = GameTitle.byId('1844')!;
final rules = TileRules(title);

Set<String?> tileIds(Iterable<TileOption> options) =>
    {for (final o in options) o.tileId};

/// A hex away from the map's edge, where no rotation is ruled out just for
/// pointing off the board.
MapHex inland(bool Function(MapHex) matching) => title.map.hexes.firstWhere(
      (h) =>
          matching(h) &&
          h.coord.neighbors.every(title.map.contains) &&
          h.printed.impassable.isEmpty,
    );

void main() {
  group('what can go on a hex', () {
    test('a plain hex takes yellow track first', () {
      final hex = inland((h) => h.takesTiles && h.printed.stations.isEmpty);
      final options = rules.options(hex, null, maxSteps: 1);
      expect(options.first, TileOption.printed);
      expect(tileIds(options), containsAll(<String>{'7', '8', '9'}));
      // Not a city tile: there is no city printed here.
      expect(tileIds(options), isNot(contains('57')));
    });

    test('a printed city takes city tiles, a printed town takes town tiles', () {
      final basel = title.map.byId('C12')!;
      expect(tileIds(rules.options(basel, null, maxSteps: 1)),
          containsAll(<String>{'5', '6', '57'}));
      final town = inland((h) => h.takesTiles && h.printed.townCount == 1);
      expect(tileIds(rules.options(town, null, maxSteps: 1)),
          containsAll(<String>{'3', '4', '58'}));
      expect(tileIds(rules.options(town, null, maxSteps: 1)),
          isNot(contains('57')));
    });

    test('upgrades follow the colour order', () {
      final basel = title.map.byId('C12')!;
      // Start from a yellow tile the rules allow on Basel, rather than
      // assuming which way round it goes.
      final yellow = rules
          .options(basel, null, maxSteps: 1)
          .firstWhere((o) => o.tileId == '57');
      final green = rules.options(basel, yellow.placed, maxSteps: 1);
      expect(
        {for (final o in green.where((o) => o.steps > 0))
          rules.contentOf(basel, o)!.color},
        {TileColor.green},
        reason: 'only green tiles follow a yellow one',
      );
      expect(tileIds(green), isNot(contains('5'))); // no going back to yellow
      final brown = rules.options(
          basel, green.firstWhere((o) => o.steps > 0).placed, maxSteps: 1);
      expect(
        {for (final o in brown.where((o) => o.steps > 0))
          rules.contentOf(basel, o)!.color},
        {TileColor.brown},
      );
    });

    test('an upgrade has to keep the track that is already there', () {
      final basel = title.map.byId('C12')!;
      // Tile 57 unturned runs east-west through the city.
      for (final option in rules.options(basel, const PlacedTile('57'), maxSteps: 1)) {
        if (option.isPrinted) continue;
        final def = rules.contentOf(basel, option)!;
        expect(def.edges, containsAll(<int>{0, 3}),
            reason: '$option drops track that is already laid');
      }
    });

    test('a labelled hex only takes tiles with its label', () {
      final winterthur = title.map.byId('C20')!; // printed yellow OO
      final options = rules.options(winterthur, null, maxSteps: 1);
      for (final option in options.where((o) => !o.isPrinted)) {
        expect(rules.contentOf(winterthur, option)!.label, 'OO');
      }
      // Zurich takes plain city tiles in yellow, then Z tiles in green.
      final zurich = title.map.byId('D19')!;
      expect(tileIds(rules.options(zurich, null, maxSteps: 1)), contains('57'));
      expect(tileIds(rules.options(zurich, const PlacedTile('57'), maxSteps: 1)),
          containsAll(<String>{'907', '908'}));
    });

    test('track may not run off the map or across an impassable border', () {
      // Vaduz sits on the eastern edge; nothing may point off the board.
      final edge = title.map.byId('F27')!;
      for (final option in rules.options(edge, null, maxSteps: 1)) {
        final def = rules.contentOf(edge, option)!;
        for (final e in def.edges) {
          expect(title.map.contains(edge.coord.neighbors[e]), isTrue,
              reason: '$option runs off the map');
        }
      }
      final lake = title.map.byId('E20')!; // borders on sides 2 and 3
      for (final option in rules.options(lake, null, maxSteps: 1)) {
        final def = rules.contentOf(lake, option)!;
        expect(def.edges.intersection({2, 3}), isEmpty,
            reason: '$option crosses the lake');
      }
    });

    test('hexes that never take tiles offer only what is printed', () {
      expect(rules.options(title.map.byId('M18')!, null), // red off-board
          [TileOption.printed]);
      expect(rules.options(title.map.byId('K2')!, null), // grey Geneve
          [TileOption.printed]);
    });

    test('rotations that come to the same thing are offered once', () {
      final hex = inland((h) => h.takesTiles && h.printed.stations.isEmpty);
      final straights = rules
          .options(hex, null, maxSteps: 1)
          .where((o) => o.tileId == '9')
          .toList();
      // A straight looks the same turned three steps, so there are three.
      expect(straights, hasLength(3));
    });

    test('a tile that cannot belong on a hex is explained', () {
      final town = title.map.byId('F13')!; // Langnau, a printed town
      // A city tile on a town hex: easy to pick by mistake in the editor,
      // and it quietly makes every route through the hex wrong.
      final problem = rules.explain(town, const PlacedTile('57'));
      expect(problem, isNotNull);
      expect(problem, contains('F13'));
      expect(problem, contains('town'));
      expect(problem, contains('city'));
      expect(rules.fits(town, const PlacedTile('57')), isFalse);
    });

    test('a tile the rules do allow is not flagged', () {
      final town = title.map.byId('F13')!;
      final legal = rules
          .options(town, null, maxSteps: 1)
          .firstWhere((o) => o.steps > 0)
          .placed!;
      expect(rules.explain(town, legal), isNull);
      expect(rules.fits(town, legal), isTrue);
    });

    test('track that would run off the map is explained', () {
      final edge = title.map.hexes.firstWhere((h) =>
          h.takesTiles &&
          h.printed.stations.isEmpty &&
          h.coord.neighbors.where(title.map.contains).length < 6);
      final offMap = [
        for (int r = 0; r < 6; r++)
          if (title.tiles['9']!.rotated(r).edges.any(
              (e) => !title.map.contains(Board.neighborOf(edge.coord, e))))
            r,
      ];
      expect(offMap, isNotEmpty);
      expect(rules.explain(edge, PlacedTile('9', rotation: offMap.first)),
          contains('off the edge of the map'));
    });

    test('a hex nothing is ever laid on says so', () {
      expect(rules.explain(title.map.byId('M18')!, const PlacedTile('9')),
          contains('no tile is ever laid here'));
    });

    test('several steps reach later colours for a board joined part-way', () {
      final basel = title.map.byId('C12')!;
      final deep = rules.options(basel, null, maxSteps: 3);
      final colours = {
        for (final o in deep.where((o) => !o.isPrinted))
          rules.contentOf(basel, o)!.color,
      };
      expect(colours, containsAll(<TileColor>{
        TileColor.yellow,
        TileColor.green,
        TileColor.brown,
      }));
      // And each records how many lays away it is.
      expect(deep.where((o) => o.tileId == '14').first.steps, 2);
    });
  });
}
