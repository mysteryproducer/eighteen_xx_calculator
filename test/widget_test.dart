import 'dart:typed_data';

import 'package:eighteen_xx_calculator/main.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/image_layout.dart';
import 'package:eighteen_xx_calculator/screens/board_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A blank photo to stand in for a captured board, since these tests exercise
/// the overlay and controls rather than the vision pipeline.
img.Image blankPhoto({int width = 400, int height = 300}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(220, 220, 210));
  return image;
}

Widget reviewScreen(img.Image photo) {
  return MaterialApp(
    home: BoardReview(
      imagePath: 'test.jpg',
      image: photo,
      previewBytes: Uint8List.fromList(img.encodePng(photo)),
      calibration: const Board(
        rows: 1,
        cols: 5,
        hexSize: 40,
        origin: Offset(60, 150),
      ),
      // Two cities with plain track between them: the smallest board that
      // has a route worth finding.
      placedTiles: {
        const HexCoord(0, 0): const PlacedTile('57'),
        const HexCoord(0, 1): const PlacedTile('9'),
        const HexCoord(0, 2): const PlacedTile('57'),
      },
      matches: const {},
      gameName: 'Test Game',
      recognizedCount: 3,
    ),
  );
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

    // The first city sits on the calibration origin; convert that image pixel
    // into a position on screen the same way the screen itself does.
    final box = tester.renderObject<RenderBox>(find.byKey(boardCanvasKey));
    final layout = ImageLayout(
      imageSize: const Size(400, 300),
      containerSize: box.size,
    );
    await tester.tapAt(
      box.localToGlobal(layout.imageToDisplay(const Offset(60, 150))),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('City on hex'), findsOneWidget);
    expect(find.text('Station token'), findsOneWidget);
  });
}
