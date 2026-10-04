import 'package:eighteen_scanner/models/tile_definition.dart';
import 'package:eighteen_scanner/models/tile_seed_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseDsl', () {
    test('plain track connects two hex edges', () {
      final tile = TileDefinition.parseDsl('9', TileColor.yellow, 'path=a:0,b:3');
      expect(tile.stations, isEmpty);
      expect(tile.segments, hasLength(1));
      expect(tile.segments.single.a, const EdgeEndpoint(0));
      expect(tile.segments.single.b, const EdgeEndpoint(3));
      expect(tile.touchesEdge(0), isTrue);
      expect(tile.touchesEdge(3), isTrue);
      expect(tile.touchesEdge(1), isFalse);
    });

    test('city tile records revenue and its track', () {
      final tile = TileDefinition.parseDsl(
        '5',
        TileColor.yellow,
        'city=revenue:20;path=a:0,b:_0;path=a:1,b:_0',
      );
      expect(tile.stations, hasLength(1));
      expect(tile.stations.single.kind, StationKind.city);
      expect(tile.stations.single.revenue, 20);
      expect(tile.stations.single.slots, 1);
      expect(tile.segments, hasLength(2));
      expect(tile.segments[0].b, const StationEndpoint(0));
      expect(tile.segments[1].a, const EdgeEndpoint(1));
    });

    test('multi-slot city reads its slot count', () {
      final tile = TileDefinition.parseDsl(
        '14',
        TileColor.green,
        'city=revenue:30,slots:2;path=a:0,b:_0',
      );
      expect(tile.stations.single.slots, 2);
      expect(tile.stations.single.revenue, 30);
    });

    test('two towns are indexed in declaration order', () {
      final tile = TileDefinition.parseDsl(
        '1',
        TileColor.yellow,
        'town=revenue:10;town=revenue:10;path=a:1,b:_0;path=a:_0,b:3;'
        'path=a:0,b:_1;path=a:_1,b:4',
      );
      expect(tile.stations, hasLength(2));
      expect(tile.stations[0].index, 0);
      expect(tile.stations[1].index, 1);
      expect(tile.stations.every((s) => s.kind == StationKind.town), isTrue);
      expect(tile.segments, hasLength(4));
      // Station 1 is the one reached from edges 0 and 4.
      expect(tile.segments[2].a, const EdgeEndpoint(0));
      expect(tile.segments[2].b, const StationEndpoint(1));
    });

    test('unsupported parts are skipped rather than breaking the parse', () {
      final tile = TileDefinition.parseDsl(
        '438',
        TileColor.yellow,
        'city=revenue:40;path=a:0,b:_0;path=a:2,b:_0;label=H;upgrade=cost:80',
      );
      expect(tile.stations, hasLength(1));
      expect(tile.segments, hasLength(2));
    });

    test('an empty string is a blank hex', () {
      final tile = TileDefinition.parseDsl('blank', TileColor.plain, '');
      expect(tile.stations, isEmpty);
      expect(tile.segments, isEmpty);
    });
  });

  group('rotation', () {
    test('shifts edges and wraps around the hex', () {
      final straight = TileDefinition.parseDsl('9', TileColor.yellow, 'path=a:0,b:3');
      final turned = straight.rotated(1);
      expect(turned.segments.single.a, const EdgeEndpoint(1));
      expect(turned.segments.single.b, const EdgeEndpoint(4));

      final wrapped = straight.rotated(4);
      expect(wrapped.segments.single.a, const EdgeEndpoint(4));
      expect(wrapped.segments.single.b, const EdgeEndpoint(1));
    });

    test('leaves station references alone', () {
      final city = TileDefinition.parseDsl(
        '5',
        TileColor.yellow,
        'city=revenue:20;path=a:0,b:_0;path=a:1,b:_0',
      );
      final turned = city.rotated(2);
      expect(turned.segments[0].a, const EdgeEndpoint(2));
      expect(turned.segments[0].b, const StationEndpoint(0));
      expect(turned.stations.single.revenue, 20);
    });

    test('six rotations returns the original layout', () {
      final tile = TileDefinition.parseDsl('8', TileColor.yellow, 'path=a:0,b:2');
      final full = tile.rotated(6);
      expect(full.segments.single.a, const EdgeEndpoint(0));
      expect(full.segments.single.b, const EdgeEndpoint(2));
    });
  });

  group('seed data', () {
    test('every seed tile parses and keeps its id', () {
      expect(TileSeedData.all, isNotEmpty);
      TileSeedData.all.forEach((id, def) {
        expect(def.id, id);
      });
    });

    test('includes the blank map hex with no track', () {
      final blank = TileSeedData.all[TileSeedData.blankTileId];
      expect(blank, isNotNull);
      expect(blank!.segments, isEmpty);
      expect(blank.color, TileColor.plain);
    });

    test('known tiles carry the expected revenue centres', () {
      expect(TileSeedData.all['9']!.stations, isEmpty);
      expect(TileSeedData.all['57']!.stations.single.kind, StationKind.city);
      expect(TileSeedData.all['58']!.stations.single.kind, StationKind.town);
      expect(TileSeedData.all['15']!.stations.single.slots, 2);
    });
  });
}
