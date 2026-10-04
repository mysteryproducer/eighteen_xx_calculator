import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eighteen_scanner/geometry/homography.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/processing/grid_detector.dart';
import 'package:eighteen_scanner/processing/guide_follower.dart';
import 'package:eighteen_scanner/screens/capture.dart';
import 'package:eighteen_scanner/services/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final title = GameTitle.byId('1844')!;

/// The guide for a close-up of Langnau with a yellow tile on it, drawn over
/// a black preview, and the colour in the middle of the tile.
Future<Color> middleOfGuide(double opacity) async {
  final langnau = title.map.byId('F13')!;
  final guide = CaptureGuide(
    target: langnau.coord,
    hexes: [langnau],
    instruction: '',
    tiles: {langnau.coord: title.tiles['9']!.rotated(1)},
  );
  const size = Size(400, 400);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
  CaptureGuidePainter(guide, tileOpacity: opacity).paint(canvas, size);
  final image = await recorder.endRecording().toImage(400, 400);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  // Off the track, which tile 9 turned once runs across the middle.
  final at = guide.homographyFor(size).apply(langnau.coord.boardCenter) +
      const Offset(0, 30);
  final i = (at.dy.round() * 400 + at.dx.round()) * 4;
  return Color.fromARGB(255, bytes.getUint8(i), bytes.getUint8(i + 1),
      bytes.getUint8(i + 2));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late AppSettings original;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_test');
    original = AppSettings.shared;
    AppSettings.shared = AppSettings(file: () async => File('${dir.path}/s.json'));
  });
  tearDown(() async {
    AppSettings.shared = original;
    await dir.delete(recursive: true);
  });

  test('a guide turned the way the board faces keeps its target in the '
      'middle', () {
    final target = title.map.byId('F13')!.coord;
    final guide = CaptureGuide(
        target: target, hexes: const [], instruction: '', turn: math.pi / 2);
    const size = Size(800, 600);
    final h = guide.homographyFor(size);
    final middle = h.apply(target.boardCenter);
    expect(middle.dx, closeTo(400, 1e-6));
    expect(middle.dy, closeTo(300, 1e-6));
    // The map's rows run down the frame, as from the board's east edge.
    expect(GridFit.facingOf(h, target.boardCenter), closeTo(math.pi / 2, 1e-9));
  });

  test('a guide locked onto the board in a preview holds on the photo', () {
    final target = title.map.byId('F13')!.coord;
    final guide = CaptureGuide(target: target, hexes: const [], instruction: '');
    const preview = Size(640, 360), photo = Size(1920, 1080);
    // Locked on with the camera tilted: perspective the guide's own turn
    // and scale can't give.
    final tilted = Homography.fromFourPoints(const [
      Offset(0, 0),
      Offset(640, 0),
      Offset(640, 360),
      Offset(0, 360),
    ], const [
      Offset(60, 40),
      Offset(580, 40),
      Offset(640, 360),
      Offset(0, 360),
    ])!;
    final placed = guide.homographyFor(preview).then(tilted);
    final locked = guide.lockedTo(placed, preview);
    expect(locked.locked, isNotNull);
    for (final c in [target, ...title.map.around([target], 1)]) {
      final inPreview = placed.apply(c.boardCenter);
      final inPhoto = locked.homographyFor(photo).apply(c.boardCenter);
      expect(inPhoto.dx, closeTo(inPreview.dx * 3, 1e-6));
      expect(inPhoto.dy, closeTo(inPreview.dy * 3, 1e-6));
    }
    // Following it flat afterwards doesn't undo the lock.
    expect(locked.adjusted(GuideAdjustment.none).locked, isNotNull);
    expect(guide.lockedTo(null, preview).locked, isNull);
  });

  test('the overlay starts at half strength and remembers a change', () async {
    await AppSettings.shared.load();
    expect(AppSettings.shared.overlayOpacity.value, 0.5);
    await AppSettings.shared.setOverlayOpacity(0.3);
    final again = AppSettings(file: () async => File('${dir.path}/s.json'));
    await again.load();
    expect(again.overlayOpacity.value, closeTo(0.3, 1e-9));
  });

  test('the tiles already laid are drawn into the guide, as strongly as set',
      () async {
    final half = await middleOfGuide(0.5);
    final none = await middleOfGuide(0);
    // Yellow at half strength over black: red and green well up, blue low.
    expect(half.r * 255, inInclusiveRange(100, 150));
    expect(half.g * 255, inInclusiveRange(90, 140));
    expect(half.b * 255, lessThan(70));
    expect(none.r * 255, lessThan(10));
  });

  testWidgets('the slider sets how strongly tiles are shown', (tester) async {
    // Real file access has to run outside the test's simulated clock.
    await tester.runAsync(() => AppSettings.shared.load());
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: OverlayOpacityControl()),
    ));
    expect(find.text('50%'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(AppSettings.shared.overlayOpacity.value, 0);
    expect(find.text('0%'), findsOneWidget);
    // Let the save finish before the folder is cleared away.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });
}
