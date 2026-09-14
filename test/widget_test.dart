import 'package:eighteen_xx_calculator/main.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/image_layout.dart';
import 'package:eighteen_xx_calculator/processing/revenue_ocr.dart';
import 'package:eighteen_xx_calculator/processing/tile_classifier.dart';
import 'package:eighteen_xx_calculator/screens/board_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A blank photo to stand in for a captured board, since these tests exercise
/// the overlay and controls rather than the vision pipeline.
img.Image blankPhoto({int width = 400, int height = 300}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(220, 220, 210));
  return image;
}

const calibration = Board(
  rows: 1,
  cols: 5,
  hexSize: 40,
  origin: Offset(60, 150),
);

const eastCity = HexCoord(0, 2);

Widget reviewScreen(img.Image photo, {Map<HexCoord, TileMatch>? matches}) {
  return MaterialApp(
    home: BoardReview(
      imagePath: 'test.jpg',
      image: photo,
      previewBytes: Uint8List.fromList(img.encodePng(photo)),
      calibration: calibration,
      // Two cities with plain track between them: the smallest board that
      // has a route worth finding. Each city is worth 20 by the tile data.
      placedTiles: {
        const HexCoord(0, 0): const PlacedTile('57'),
        const HexCoord(0, 1): const PlacedTile('9'),
        eastCity: const PlacedTile('57'),
      },
      matches: matches ?? {},
      gameName: 'Test Game',
      recognizedCount: 3,
    ),
  );
}

TileMatch scanned(String tileId, double confidence) =>
    TileMatch(tileId: tileId, rotation: 0, score: 100, confidence: confidence);

/// The scan was sure of everything except the east city's tile.
Map<HexCoord, TileMatch> eastTileDoubtful() => {
      const HexCoord(0, 0): scanned('57', 0.8),
      const HexCoord(0, 1): scanned('9', 0.8),
      eastCity: scanned('57', 0.05),
    };

/// Taps [imagePoint] (in photo pixels) on the review screen's board.
Future<void> tapBoard(WidgetTester tester, Offset imagePoint) async {
  final box = tester.renderObject<RenderBox>(find.byKey(boardCanvasKey));
  final layout = ImageLayout(imageSize: const Size(400, 300), containerSize: box.size);
  await tester.tapAt(box.localToGlobal(layout.imageToDisplay(imagePoint)));
  await tester.pumpAndSettle();
}

/// Lets any snack bar time out, so it isn't covering the route controls.
Future<void> waitOutSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Future<void> findRoute(WidgetTester tester) async {
  await tester.tap(find.text('Find route'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('app opens on the game picker', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Select 18xx Title'), findsOneWidget);
    expect(find.text('18xx Example Set'), findsOneWidget);
  });

  testWidgets('review screen summarises what was recognized', (tester) async {
    await tester.pumpWidget(reviewScreen(blankPhoto()));
    await tester.pumpAndSettle();
    // Three tiles were laid, two of which carry a city.
    expect(find.textContaining('3 tiles'), findsOneWidget);
    expect(find.textContaining('2 revenue centres'), findsOneWidget);
  });

  testWidgets('finding a route reports what it pays', (tester) async {
    await tester.pumpWidget(reviewScreen(blankPhoto()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Find route'));
    await tester.pumpAndSettle();

    // Both cities are worth 20, and the default stop limit reaches both.
    expect(find.textContaining('Best route pays 40'), findsOneWidget);
  });

  testWidgets('the stop limit changes the route', (tester) async {
    await tester.pumpWidget(reviewScreen(blankPhoto()));
    await tester.pumpAndSettle();

    // Drop the limit to a single stop, so no track can be run.
    await tester.tap(find.byIcon(Icons.remove));
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find route'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Best route pays 20'), findsOneWidget);
  });

  testWidgets('tapping a city opens its editor', (tester) async {
    await tester.pumpWidget(reviewScreen(blankPhoto()));
    await tester.pumpAndSettle();

    // The first city sits on the calibration origin.
    await tapBoard(tester, calibration.origin);

    expect(find.textContaining('City on hex'), findsOneWidget);
    expect(find.text('Station token'), findsOneWidget);
    expect(find.text('Revenue from tile 57.'), findsOneWidget);
  });

  group('revenue falls back to the photo only where tiles are doubtful', () {
    late int recognizerCalls;
    String? recognizerReply;

    setUp(() {
      recognizerCalls = 0;
      recognizerReply = null;
    });

    void installRecognizer(WidgetTester tester, String reply) {
      recognizerReply = reply;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RevenueOcr.channel,
        (call) async {
          recognizerCalls++;
          return recognizerReply;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(RevenueOcr.channel, null));
    }

    testWidgets('confident tiles supply revenue without reading the photo',
        (tester) async {
      installRecognizer(tester, '90');
      await tester.pumpWidget(reviewScreen(
        blankPhoto(),
        matches: {
          const HexCoord(0, 0): scanned('57', 0.8),
          const HexCoord(0, 1): scanned('9', 0.8),
          eastCity: scanned('57', 0.8),
        },
      ));
      await tester.pumpAndSettle();

      expect(recognizerCalls, 0);
      expect(find.textContaining('amber'), findsNothing);
      await findRoute(tester);
      expect(find.textContaining('Best route pays 40'), findsOneWidget);
    });

    testWidgets('a doubtful tile has its revenue read from the photo',
        (tester) async {
      installRecognizer(tester, '50');
      await tester.pumpWidget(reviewScreen(blankPhoto(), matches: eastTileDoubtful()));
      await tester.pumpAndSettle();
      await waitOutSnackBars(tester);

      // Only the one doubtful city was read.
      expect(recognizerCalls, 1);
      expect(find.textContaining('1 uncertain tile in amber'), findsOneWidget);
      await findRoute(tester);
      expect(find.textContaining('Best route pays 70'), findsOneWidget);
    });

    testWidgets('confirming a doubtful tile goes back to its tile value',
        (tester) async {
      installRecognizer(tester, '50');
      await tester.pumpWidget(reviewScreen(blankPhoto(), matches: eastTileDoubtful()));
      await tester.pumpAndSettle();
      await waitOutSnackBars(tester);

      // Tap inside the east hex but clear of its city, to open the tile editor.
      final hexCenter = calibration.centerOf(eastCity);
      await tapBoard(tester, hexCenter + const Offset(0, 28));
      expect(find.textContaining('Scanned as 57'), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.textContaining('amber'), findsNothing);
      await findRoute(tester);
      expect(find.textContaining('Best route pays 40'), findsOneWidget);
    });

    testWidgets('a value typed by the user is kept over the photo',
        (tester) async {
      installRecognizer(tester, '50');
      await tester.pumpWidget(reviewScreen(blankPhoto(), matches: eastTileDoubtful()));
      await tester.pumpAndSettle();
      await waitOutSnackBars(tester);

      await tapBoard(tester, calibration.centerOf(eastCity));
      expect(
        find.text('The tile match was uncertain, so this was read from the photo.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '60');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Asking for a re-read leaves the typed value alone.
      await tester.tap(find.byIcon(Icons.numbers));
      await tester.pumpAndSettle();
      await waitOutSnackBars(tester);
      expect(recognizerCalls, 1);

      await findRoute(tester);
      expect(find.textContaining('Best route pays 80'), findsOneWidget);
    });

    testWidgets('an unreadable value keeps the tile figure and is flagged',
        (tester) async {
      installRecognizer(tester, 'no digits here');
      await tester.pumpWidget(reviewScreen(blankPhoto(), matches: eastTileDoubtful()));
      await tester.pumpAndSettle();

      expect(find.textContaining('Check the amber ones by hand'), findsOneWidget);
      await waitOutSnackBars(tester);
      expect(find.textContaining('1 unread value'), findsOneWidget);
      await findRoute(tester);
      expect(find.textContaining('Best route pays 40'), findsOneWidget);
    });

    testWidgets('a device without a text recognizer says so', (tester) async {
      // What a platform with no native handler reports. Simulated rather than
      // left unhandled, because the test binding only delivers an unhandled
      // reply in real time, which the widget tester's fake clock never reaches.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RevenueOcr.channel,
        (call) async => throw MissingPluginException(),
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(RevenueOcr.channel, null));
      await tester.pumpWidget(reviewScreen(blankPhoto(), matches: eastTileDoubtful()));
      await tester.pumpAndSettle();

      expect(find.textContaining('not available on this device'), findsOneWidget);
      await waitOutSnackBars(tester);
      expect(find.textContaining('1 unread value'), findsOneWidget);
    });
  });
}
