import 'dart:typed_data';

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/screens/align_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/fake_pipeline.dart';

final title = GameTitle.byId('1844')!;

img.Image photo({int width = 400, int height = 300}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(215, 205, 185));
  return image;
}

/// Opens the align screen and collects whatever it hands back when it closes.
Future<List<Homography?>> showAlign(
  WidgetTester tester,
  FakePhotoPipeline pipeline, {
  Homography? initial,
}) async {
  final image = photo();
  final returned = <Homography?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => ElevatedButton(
        child: const Text('open'),
        onPressed: () async {
          returned.add(await Navigator.of(context).push<Homography>(
            MaterialPageRoute(
              builder: (_) => AlignBoard(
                title: title,
                photo: image,
                previewBytes: Uint8List.fromList(img.encodeJpg(image)),
                initial: initial,
                focus: initial == null
                    ? null
                    : title.map.around([title.map.byId('F11')!.coord], 2),
                pipeline: pipeline,
              ),
            ),
          ));
        },
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return returned;
}

void main() {
  testWidgets('a board that is found is reported and can be read',
      (tester) async {
    final pipeline = FakePhotoPipeline(fit: FakePhotoPipeline.fitFor(title.map));
    await showAlign(tester, pipeline);
    expect(pipeline.fitBoardCalls, 1);
    expect(find.textContaining('Found the board'), findsOneWidget);
    expect(find.textContaining('131 hexes in frame'), findsOneWidget);
    expect(find.text('Read board'), findsOneWidget);
  });

  testWidgets('when no grid is found the user is asked to place it',
      (tester) async {
    await showAlign(tester, FakePhotoPipeline());
    expect(find.textContaining('No hex grid found'), findsOneWidget);
    // The hexes to drag are named, so there is something to aim with.
    expect(find.textContaining('Drag each labelled circle'), findsOneWidget);
  });

  testWidgets('a failure deep in detection is reported in a line, not dumped',
      (tester) async {
    // Whatever goes wrong, the screen has to stay usable: this used to put
    // the whole error on screen, which overflowed the layout.
    await showAlign(
      tester,
      FakePhotoPipeline(
        failure: ArgumentError('Illegal argument in isolate message: '
            '${'object is unsendable ' * 40}'),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(find.textContaining('unsendable'), findsNothing);
    expect(find.text('Read board'), findsOneWidget);
  });

  testWidgets('snapping asks the detector again and keeps the result',
      (tester) async {
    final pipeline = FakePhotoPipeline(
        fit: FakePhotoPipeline.fitFor(title.map, coverage: 0.4));
    await showAlign(tester, pipeline);
    expect(find.textContaining('Not sure about this one'), findsOneWidget);
    pipeline.fit = FakePhotoPipeline.fitFor(title.map, coverage: 0.95);
    await tester.tap(find.text('Snap to lines'));
    await tester.pumpAndSettle();
    expect(pipeline.snapCalls, 1);
    expect(find.textContaining('Found the board'), findsOneWidget);
  });

  testWidgets('a close-up placed by hand snaps rather than searching',
      (tester) async {
    final pipeline = FakePhotoPipeline(fit: FakePhotoPipeline.fitFor(title.map));
    await showAlign(tester, pipeline,
        initial: Homography.similarity(scale: 20));
    expect(pipeline.fitBoardCalls, 0);
    expect(pipeline.snapCalls, 1);
    expect(find.text('Align close-up'), findsOneWidget);
  });

  testWidgets('reading the board hands back where the map sits', (tester) async {
    final fit = FakePhotoPipeline.fitFor(title.map);
    final returned = await showAlign(tester, FakePhotoPipeline(fit: fit));
    await tester.tap(find.text('Read board'));
    await tester.pumpAndSettle();
    expect(find.text('Read board'), findsNothing, reason: 'screen closed');
    expect(returned.single, fit.boardToImage);
  });
}
