import 'dart:io';
import 'dart:ui' as ui;

import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/screens/capture.dart';
import 'package:eighteen_xx_calculator/services/app_settings.dart';
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
