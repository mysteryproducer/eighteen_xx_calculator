import 'dart:typed_data';

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/screens/align_board.dart';
import 'package:flutter/gestures.dart';
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

/// Where the screen starts the map when detection found nothing to go on.
Homography startingPlacement() => placeOverPhoto(
    Size(photo().width.toDouble(), photo().height.toDouble()), title.map.coords);

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

  group('placing the grid by hand', () {
    /// Where the map's middle and its scale end up, from what the screen
    /// hands back when the board is read.
    Future<Homography> readBoard(
        WidgetTester tester, List<Homography?> returned) async {
      await tester.tap(find.text('Read board'));
      await tester.pumpAndSettle();
      return returned.single!;
    }

    bool mapInsidePhoto(Homography h) {
      final image = photo();
      return title.map.coords.every((c) {
        final p = h.apply(c.boardCenter);
        return p.dx >= 0 && p.dy >= 0 && p.dx <= image.width && p.dy <= image.height;
      });
    }

    double scaleOf(Homography h) =>
        h.localScale(title.map.boardBounds.center);

    testWidgets('with no grid found, the map starts laid over the photo',
        (tester) async {
      final returned = await showAlign(tester, FakePhotoPipeline());
      // Something to drag from, rather than nothing on screen at all.
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Read board')).onPressed,
          isNotNull);
      expect(mapInsidePhoto(await readBoard(tester, returned)), isTrue);
    });

    testWidgets('a grid found far too big for the photo is not what the user '
        'starts from', (tester) async {
      // Detection that settles on the wrong repeat puts a few enormous hexes
      // over the photo, with the handles to fix it far off screen.
      final returned = await showAlign(
          tester,
          FakePhotoPipeline(
              fit: FakePhotoPipeline.fitFor(title.map, scale: 400, coverage: 0.3)));
      expect(mapInsidePhoto(await readBoard(tester, returned)), isTrue);
    });

    testWidgets('the grid can be made bigger and smaller with buttons',
        (tester) async {
      final returned = await showAlign(tester, FakePhotoPipeline());
      await tester.tap(find.byTooltip('Bigger'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bigger'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Smaller'));
      await tester.pumpAndSettle();
      final start = scaleOf(startingPlacement());
      expect(scaleOf(await readBoard(tester, returned)) / start,
          closeTo(1.1, 0.01));
    });

    testWidgets('the grid can be turned a quarter at a time', (tester) async {
      final returned = await showAlign(tester, FakePhotoPipeline());
      await tester.tap(find.byTooltip('Turn a quarter'));
      await tester.pumpAndSettle();
      final h = await readBoard(tester, returned);
      final centre = title.map.boardBounds.center;
      final east = h.apply(centre + const Offset(1, 0)) - h.apply(centre);
      // Board east now points down the photo.
      expect(east.dx.abs(), lessThan(0.01 * east.distance));
      expect(east.dy, greaterThan(0));
    });

    testWidgets('scrolling the mouse wheel resizes the grid', (tester) async {
      final returned = await showAlign(tester, FakePhotoPipeline());
      final centre = tester.getCenter(find.byKey(alignCanvasKey));
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(centre));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
      await tester.pumpAndSettle();
      final start = scaleOf(startingPlacement());
      expect(scaleOf(await readBoard(tester, returned)), greaterThan(start * 1.2));
    });

    testWidgets('pinching resizes the grid', (tester) async {
      final returned = await showAlign(tester, FakePhotoPipeline());
      final centre = tester.getCenter(find.byKey(alignCanvasKey));
      // Two fingers well away from the handles, spread apart.
      final a = await tester.startGesture(centre + const Offset(-30, 5));
      final b = await tester.startGesture(centre + const Offset(30, 5));
      for (int i = 0; i < 5; i++) {
        await a.moveBy(const Offset(-6, 0));
        await b.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      final start = scaleOf(startingPlacement());
      expect(scaleOf(await readBoard(tester, returned)) / start,
          closeTo(2, 0.1));
    });

    testWidgets('the grid can always be put back over the photo',
        (tester) async {
      final returned = await showAlign(tester, FakePhotoPipeline());
      for (int i = 0; i < 12; i++) {
        await tester.tap(find.byTooltip('Bigger'));
        await tester.pump();
      }
      await tester.tap(find.byTooltip('Fit to the photo'));
      await tester.pumpAndSettle();
      expect(mapInsidePhoto(await readBoard(tester, returned)), isTrue);
    });
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
