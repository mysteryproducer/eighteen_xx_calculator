import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/screens/session_board.dart';
import 'package:eighteen_xx_calculator/services/training_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eighteen_xx_calculator/widgets/board_map.dart';
import 'package:eighteen_xx_calculator/widgets/tile_choices.dart';

import 'support/fake_store.dart';
import 'support/fake_training_log.dart';

final title = GameTitle.byId('1844')!;

/// A real (1x1) PNG, so the editor's picture decodes as it would in the app.
final aPicture = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

LabelledHex example({
  String hexId = 'C12',
  String? tileId = '57',
  String? readAs,
  double confidence = 0.3,
}) =>
    LabelledHex(
      titleId: '1844',
      hexId: hexId,
      tileId: tileId,
      rotation: 4,
      readAsTileId: readAs,
      readAsRotation: readAs == null ? null : 4,
      readConfidence: confidence,
      when: DateTime(2026, 9, 21, 12),
      picture: '$hexId.png',
    );

/// Taps the body of a hex, clear of the station at its centre, panning the
/// board first if that spot is off screen.
Future<void> tapHexBody(WidgetTester tester, String hexId) async {
  final geometry = BoardMapGeometry(title.map);
  final board =
      title.map.byId(hexId)!.coord.boardCenter + const Offset(0, 0.55);
  Offset where() => tester
      .renderObject<RenderBox>(find.byKey(sessionBoardKey))
      .localToGlobal(geometry.toScreen(board));
  final view = tester.view;
  final screen = view.physicalSize / view.devicePixelRatio;
  final middle = Offset(screen.width / 2, screen.height / 2);
  if ((where() - middle).distance > 150) {
    await tester.drag(find.byKey(sessionBoardKey), middle - where());
    await tester.pumpAndSettle();
  }
  await tester.tapAt(where());
  await tester.pumpAndSettle();
}

/// Picks a tile from the drawn choices, scrolling along until it shows.
Future<void> chooseTile(WidgetTester tester, String label) async {
  Finder choice() => find.descendant(
        of: find.byType(TileChoices),
        matching: find.text(label),
      );
  for (int i = 0; i < 15 && choice().evaluate().isEmpty; i++) {
    await tester.drag(find.byType(TileChoices), const Offset(-220, 0));
    await tester.pumpAndSettle();
  }
  await tester.tap(choice().first);
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  late TrainingLog log;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('training_test');
    log = TrainingLog(root: () async => dir);
  });
  tearDown(() async => dir.delete(recursive: true));

  group('banking examples', () {
    test('an example keeps the picture and what was really there', () async {
      await log.record(example(), Uint8List.fromList([1, 2, 3]));
      final entries = await log.entries();
      expect(entries, hasLength(1));
      expect(entries.single.tileId, '57');
      expect(entries.single.rotation, 4);
      expect(entries.single.hexId, 'C12');
      expect(await File('${dir.path}/pictures/C12.png').readAsBytes(),
          [1, 2, 3]);
    });

    test('it records whether recognition had it right', () async {
      // Read as nothing, but a tile was there: the interesting case.
      await log.record(example(readAs: null), Uint8List.fromList([1]));
      // Read correctly, merely doubted.
      await log.record(
          example(hexId: 'D13', readAs: '57'), Uint8List.fromList([1]));
      final entries = await log.entries();
      expect(entries.map((e) => e.wasRight), [false, true]);
      expect(await log.tally(), (2, 1));
    });

    test('examples pile up across games', () async {
      for (final id in ['C12', 'C14', 'D13']) {
        await log.record(example(hexId: id), Uint8List.fromList([1]));
      }
      expect((await log.entries()).map((e) => e.hexId), ['C12', 'C14', 'D13']);
    });

    test('a half-written line does not lose the rest', () async {
      await log.record(example(), Uint8List.fromList([1]));
      await File('${dir.path}/labels.jsonl')
          .writeAsString('{"title": "184', mode: FileMode.append);
      expect(await log.entries(), hasLength(1));
    });

    test('nothing banked yet is not an error', () async {
      expect(await log.entries(), isEmpty);
      expect(await log.tally(), (0, 0));
    });

    test('picture names do not collide between hexes or times', () {
      final first = TrainingLog.pictureName('g1', 'C12', DateTime(2026, 1, 1));
      final second = TrainingLog.pictureName('g1', 'C14', DateTime(2026, 1, 1));
      final later = TrainingLog.pictureName(
          'g1', 'C12', DateTime(2026, 1, 1, 0, 0, 1));
      expect({first, second, later}, hasLength(3));
    });
  });

  group('from the board', () {
    testWidgets('correcting a hex banks it, with what was read', (tester) async {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(900, 1400);
      view.devicePixelRatio = 1;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      final store = FakeSessionStore();
      final banked = FakeTrainingLog();
      final session =
          GameSession.start(title: title, name: 'g', startedEmpty: true);
      final basel = title.map.byId('C12')!;
      // The app read the hex as nothing laid, and wasn't sure of it.
      session.recordReading(basel,
          tile: null, confidence: 0.2, source: HexSource.overview);
      await store.saveHexPicture(session.id, 'C12', aPicture);

      await tester.pumpWidget(MaterialApp(
        home: SessionBoard(
          title: title,
          session: session,
          store: store,
          trainingLog: banked,
        ),
      ));
      await tester.pumpAndSettle();

      // Tell it what is really there.
      await tapHexBody(tester, 'C12');
      await chooseTile(tester, '57');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(banked.banked, hasLength(1));
      final entry = banked.banked.single;
      expect(entry.hexId, 'C12');
      expect(entry.tileId, '57');
      expect(entry.readAsTileId, isNull, reason: 'it had read bare map');
      expect(entry.readConfidence, closeTo(0.2, 0.001));
      expect(entry.wasRight, isFalse);
      expect(banked.pictures.single, aPicture);
    });

    testWidgets('a hex never photographed banks nothing', (tester) async {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(900, 1400);
      view.devicePixelRatio = 1;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      final banked = FakeTrainingLog();
      final session =
          GameSession.start(title: title, name: 'g', startedEmpty: true);
      await tester.pumpWidget(MaterialApp(
        home: SessionBoard(
          title: title,
          session: session,
          store: FakeSessionStore(),
          trainingLog: banked,
        ),
      ));
      await tester.pumpAndSettle();
      await tapHexBody(tester, 'C12');
      await chooseTile(tester, '57');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      // No picture to learn from, so nothing is kept.
      expect(banked.banked, isEmpty);
      expect(session.tileAt(title.map.byId('C12')!)?.tileId, '57');
    });
  });
}
