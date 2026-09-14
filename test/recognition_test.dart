import 'package:eighteen_xx_calculator/models/company.dart';
import 'package:eighteen_xx_calculator/models/tile_seed_data.dart';
import 'package:eighteen_xx_calculator/processing/revenue_ocr.dart';
import 'package:eighteen_xx_calculator/processing/tile_classifier.dart';
import 'package:eighteen_xx_calculator/processing/tile_renderer.dart';
import 'package:eighteen_xx_calculator/processing/token_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A white square with a coloured disc in the middle, standing in for a city
/// circle with a station token dropped in it.
img.Image discOnWhite(Color? disc, {int size = 40}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  if (disc != null) {
    img.fillCircle(
      image,
      x: size ~/ 2,
      y: size ~/ 2,
      radius: size ~/ 4,
      color: img.ColorRgb8(
        (disc.r * 255).round(),
        (disc.g * 255).round(),
        (disc.b * 255).round(),
      ),
    );
  }
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TileClassifier', () {
    late TileClassifier classifier;

    setUpAll(() async {
      classifier = TileClassifier();
      await classifier.loadTemplates();
    });

    test('renders a template for every tile and rotation', () {
      // Every tile gets six rotations except the blank hex, which has none.
      final withTrack = TileSeedData.all.length - 1;
      expect(classifier.templateCount, withTrack * 6 + 1);
    });

    test('recognizes a tile from its own rendering', () async {
      final tile = TileSeedData.all['9']!;
      final patch = await TileRenderer.rasterize(tile, size: 64);
      final match = classifier.matchTile(patch);
      expect(match, isNotNull);
      expect(match!.tileId, '9');
    });

    test('recognizes which way round an asymmetric tile is', () async {
      // Tile 5 is a city with track out of two adjacent edges, so all six
      // rotations look different.
      for (final rotation in [0, 1, 3, 5]) {
        final tile = TileSeedData.all['5']!.rotated(rotation);
        final patch = await TileRenderer.rasterize(tile, size: 64);
        final match = classifier.matchTile(patch);
        expect(match!.tileId, '5');
        expect(match.rotation, rotation);
      }
    });

    test('recognizes an empty hex as blank', () async {
      final blank = TileSeedData.all[TileSeedData.blankTileId]!;
      final patch = await TileRenderer.rasterize(blank, size: 64);
      final match = classifier.matchTile(patch);
      expect(match!.tileId, TileSeedData.blankTileId);
    });

    test('matching works at a different patch size than the templates',
        () async {
      final tile = TileSeedData.all['57']!;
      final patch = await TileRenderer.rasterize(tile, size: 128);
      final match = classifier.matchTile(patch);
      expect(match!.tileId, '57');
    });

    test('a classifier with no templates loaded matches nothing', () {
      final empty = TileClassifier(definitions: const {});
      expect(empty.matchTile(img.Image(width: 8, height: 8)), isNull);
    });
  });

  group('TokenDetector', () {
    const detector = TokenDetector();

    test('reads a token colour out of a city circle', () {
      final red = Company.defaults.firstWhere((c) => c.id == 'red');
      final image = discOnWhite(red.color);
      final detection = detector.detect(image, 20, 20, 10);
      expect(detection.looksEmpty, isFalse);
      expect(detection.company?.id, 'red');
    });

    test('tells apart two different company colours', () {
      final blue = Company.defaults.firstWhere((c) => c.id == 'blue');
      final green = Company.defaults.firstWhere((c) => c.id == 'green');
      expect(detector.detect(discOnWhite(blue.color), 20, 20, 10).company?.id,
          'blue');
      expect(detector.detect(discOnWhite(green.color), 20, 20, 10).company?.id,
          'green');
    });

    test('an empty white circle reads as having no token', () {
      final detection = detector.detect(discOnWhite(null), 20, 20, 10);
      expect(detection.looksEmpty, isTrue);
      expect(detection.company, isNull);
    });

    test('sampling off the edge of the image is harmless', () {
      final detection = detector.detect(discOnWhite(Colors.red), 500, 500, 10);
      expect(detection.company, isNull);
    });
  });

  group('revenue text', () {
    test('reads a plain number', () {
      final reading = RevenueOcr.parseRecognizedText('30');
      expect(reading.value, 30);
      expect(reading.recognized, isTrue);
    });

    test('picks the revenue when the crop caught other text', () {
      // City circles often sit next to a slot marker or tile number.
      expect(RevenueOcr.parseRecognizedText('2\n40').value, 40);
      expect(RevenueOcr.parseRecognizedText('B 60 OO').value, 60);
    });

    test('reports nothing readable rather than guessing', () {
      final reading = RevenueOcr.parseRecognizedText('   ');
      expect(reading.recognized, isFalse);
      expect(reading.value, isNull);
    });

    test('ignores numbers too large to be revenue', () {
      expect(RevenueOcr.parseRecognizedText('1830').recognized, isFalse);
      expect(RevenueOcr.parseRecognizedText('1830 40').value, 40);
    });
  });
}
