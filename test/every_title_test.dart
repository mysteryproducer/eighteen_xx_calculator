// What every imported title must hold to, whatever its game: a title
// imported with tool/import_tobymao_title.dart that breaks one of these
// needs the importer, the app's tile parser or the title's hand-kept rules
// put right before it can be played (see docs/importing-a-title.md).
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/models/tile_definition.dart';
import 'package:eighteen_scanner/titles/titles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every title in lib/titles is in the app, once', () {
    expect([for (final t in GameTitle.all) t.id],
        [for (final d in importedTitles) d.id]);
    expect({for (final t in GameTitle.all) t.id}, hasLength(GameTitle.all.length));
  });

  for (final title in GameTitle.all) {
    final data = importedTitles.firstWhere((d) => d.id == title.id);
    group(title.id, () {
      test('each hex has its own place on the board', () {
        final seen = <Object, String>{};
        for (final hex in title.map.hexes) {
          final other = seen[hex.coord];
          expect(other, isNull, reason: '${hex.id} sits where $other does');
          seen[hex.coord] = hex.id;
          expect(title.map.byId(hex.id), same(hex));
        }
      });

      test('every track leads to a side or a stop that is there', () {
        final pieces = {
          for (final hex in title.map.hexes) 'hex ${hex.id}': hex.printed,
          for (final tile in title.tiles.entries) 'tile ${tile.key}': tile.value,
        };
        pieces.forEach((name, piece) {
          for (final segment in piece.segments) {
            for (final end in [segment.a, segment.b]) {
              switch (end) {
                case EdgeEndpoint(:final edge):
                  expect(edge, inInclusiveRange(0, 5), reason: '$name: $segment');
                case StationEndpoint(:final stationIndex):
                  expect(stationIndex, lessThan(piece.stations.length),
                      reason: '$name has track to stop $stationIndex of '
                          '${piece.stations.length}: tile code the parser '
                          'skips (a junction?) has shifted the numbering');
              }
            }
          }
        });
      });

      test('every tile has track or a stop, in a colour the app knows', () {
        for (final MapEntry(key: id, value: tile) in title.tiles.entries) {
          expect(tile.segments.isNotEmpty || tile.stations.isNotEmpty, isTrue,
              reason: 'tile $id is empty');
          expect(tile.color, isNot(TileColor.plain),
              reason: 'tile $id: ${data.tiles.firstWhere((t) => t.id == id).color}');
        }
      });

      test('every company has its own id, and a home on the map', () {
        expect({for (final c in title.companies) c.id},
            hasLength(title.companies.length));
        for (final company in title.companies) {
          final home = company.homeHex;
          if (home == null) continue;
          final hex = title.map.byId(home);
          expect(hex, isNotNull, reason: '${company.id} starts at $home');
          final city = company.homeCity;
          if (city != null) {
            expect(city, lessThan(hex!.printed.stations.length),
                reason: '${company.id} starts in stop $city of $home');
          }
        }
      });

      test('trains rust on, and phases start with, trains it has', () {
        final names = {for (final t in title.trains) t.name, for (final t in title.trains) t.base};
        expect({for (final t in title.trains) t.name}, hasLength(title.trains.length));
        for (final train in title.trains) {
          if (train.rustsOn != null) {
            expect(names, contains(train.rustsOn), reason: '${train.name} rusts on');
          }
        }
        for (final phase in title.phases) {
          if (phase.on != null) {
            expect(names, contains(phase.on), reason: 'phase ${phase.name}');
          }
          for (final colour in phase.tiles) {
            expect(colour, isNot(TileColor.plain), reason: 'phase ${phase.name}');
          }
        }
      });

      test('every cell of the stock market has a price', () {
        for (final row in data.market) {
          for (final code in row) {
            expect(code.isEmpty || RegExp(r'^\d+').hasMatch(code), isTrue,
                reason: code);
          }
        }
        if (data.market.isNotEmpty) expect(title.market.isEmpty, isFalse);
      });
    });
  }
}
