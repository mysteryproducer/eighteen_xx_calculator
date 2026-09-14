import 'dart:math' as math;

import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/tile_seed_data.dart';
import 'package:eighteen_xx_calculator/processing/revenue_ocr.dart';
import 'package:eighteen_xx_calculator/processing/revenue_resolver.dart';
import 'package:eighteen_xx_calculator/processing/tile_classifier.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Two cities on tile 57, each worth 20 by the tile data.
const west = HexCoord(0, 0);
const east = HexCoord(0, 2);
BoardGraph twoCities() => BoardGraph.build(
      {
        west: const PlacedTile('57'),
        const HexCoord(0, 1): const PlacedTile('9'),
        east: const PlacedTile('57'),
      },
      TileSeedData.all,
    );

bool Function(HexCoord) trustAllBut(HexCoord doubtful) =>
    (hex) => hex != doubtful;

void main() {
  group('RevenueResolver', () {
    test('a trusted tile supplies its own revenue', () {
      final graph = twoCities();
      RevenueResolver.apply(
        graph,
        isTileTrusted: (_) => true,
        manual: const {},
        readings: const {},
      );
      for (final station in graph.stations) {
        expect(station.revenue, 20);
        expect(station.revenueSource, RevenueSource.tile);
      }
    });

    test('the photo is ignored where the tile is trusted', () {
      // Tile data is the better source, so a stray reading doesn't override it.
      final graph = twoCities();
      RevenueResolver.apply(
        graph,
        isTileTrusted: (_) => true,
        manual: const {},
        readings: const {'0_0_0': RevenueReading(value: 90, rawText: '90')},
      );
      expect(graph.stationById('0_0_0')!.revenue, 20);
      expect(graph.stationById('0_0_0')!.revenueSource, RevenueSource.tile);
    });

    test('the photo stands in where the tile match is doubtful', () {
      final graph = twoCities();
      RevenueResolver.apply(
        graph,
        isTileTrusted: trustAllBut(east),
        manual: const {},
        readings: const {'0_2_0': RevenueReading(value: 50, rawText: '50')},
      );
      final doubtful = graph.stationById('0_2_0')!;
      expect(doubtful.revenue, 50);
      expect(doubtful.revenueSource, RevenueSource.photo);
      expect(graph.stationById('0_0_0')!.revenueSource, RevenueSource.tile);
    });

    test('a doubtful tile with no reading is flagged, not guessed', () {
      final graph = twoCities();
      RevenueResolver.apply(
        graph,
        isTileTrusted: trustAllBut(east),
        manual: const {},
        readings: const {'0_2_0': RevenueReading(value: null, rawText: '?')},
      );
      final doubtful = graph.stationById('0_2_0')!;
      expect(doubtful.revenueSource, RevenueSource.unverified);
      // The doubtful tile's own value is still used, so routes can run.
      expect(doubtful.revenue, 20);
    });

    test('what the user types beats both tile and photo', () {
      final graph = twoCities();
      RevenueResolver.apply(
        graph,
        isTileTrusted: trustAllBut(east),
        manual: const {'0_0_0': 30, '0_2_0': 40},
        readings: const {'0_2_0': RevenueReading(value: 50, rawText: '50')},
      );
      expect(graph.stationById('0_0_0')!.revenue, 30);
      expect(graph.stationById('0_2_0')!.revenue, 40);
      expect(
        graph.stations.map((s) => s.revenueSource),
        everyElement(RevenueSource.manual),
      );
    });

    test('only doubtful stations without a typed value need the photo', () {
      final graph = twoCities();
      expect(
        RevenueResolver.stationsNeedingPhoto(
          graph,
          isTileTrusted: (_) => true,
          manual: const {},
        ),
        isEmpty,
      );
      expect(
        RevenueResolver.stationsNeedingPhoto(
          graph,
          isTileTrusted: trustAllBut(east),
          manual: const {},
        ).map((s) => s.id),
        ['0_2_0'],
      );
      expect(
        RevenueResolver.stationsNeedingPhoto(
          graph,
          isTileTrusted: trustAllBut(east),
          manual: const {'0_2_0': 40},
        ),
        isEmpty,
      );
    });
  });

  group('TileMatch.isReliable', () {
    TileMatch withConfidence(double c) =>
        TileMatch(tileId: '57', rotation: 0, score: 1, confidence: c);

    test('trusts matches at or above the threshold', () {
      expect(withConfidence(TileMatch.reliableConfidence).isReliable, isTrue);
      expect(withConfidence(0.9).isReliable, isTrue);
    });

    test('doubts matches below it', () {
      expect(withConfidence(TileMatch.reliableConfidence - 0.01).isReliable,
          isFalse);
      expect(withConfidence(0).isReliable, isFalse);
    });
  });

  group('RevenueOcr platform channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final photo = img.Image(width: 100, height: 100);
    const region = math.Rectangle<int>(10, 10, 40, 40);

    tearDown(() => messenger.setMockMethodCallHandler(RevenueOcr.channel, null));

    test('sends the crop as PNG and parses the reply', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(RevenueOcr.channel, (call) async {
        received = call;
        return 'B\n40';
      });

      final reading = await const RevenueOcr().readRegion(photo, region);

      expect(reading.value, 40);
      expect(received?.method, 'recognizeText');
      final bytes = (received?.arguments as Map)['image'] as Uint8List;
      // PNG signature, so the native side can decode it as an image.
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      // Small crops are enlarged before recognition.
      expect(img.decodePng(bytes)!.width, 160);
    });

    test('a native failure on one crop reads as nothing, not an error',
        () async {
      messenger.setMockMethodCallHandler(RevenueOcr.channel, (call) async {
        throw PlatformException(code: 'recognition_failed');
      });
      final reading = await const RevenueOcr().readRegion(photo, region);
      expect(reading.recognized, isFalse);
    });

    test('no native recognizer at all is reported as unavailable', () async {
      expect(
        () => const RevenueOcr().readRegion(photo, region),
        throwsA(isA<TextRecognitionUnavailable>()),
      );
    });
  });
}
