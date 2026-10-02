import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/play_area_reader.dart';
import 'package:eighteen_xx_calculator/screens/play_area_review.dart';
import 'package:eighteen_xx_calculator/screens/players_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final title = GameTitle.byId('1844')!;
  final gb = title.companyById('GB')!;

  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(800, 900);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  /// Opens the review of [reading] from a page that keeps what it pops.
  Future<List<PlayAreaConfirmed?>> review(WidgetTester tester,
      GameSession session, PlayAreaReading reading) async {
    final popped = <PlayAreaConfirmed?>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => popped.add(
                await Navigator.of(context).push<PlayAreaConfirmed>(
                    MaterialPageRoute(
                        builder: (_) => PlayAreaReview(
                            title: title, session: session, reading: reading)))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  /// What the reader found in the photo of GB's charter and certificates.
  const slot = Rect.fromLTRB(0.8, 0.1, 0.85, 0.12);
  final gbPhoto = PlayAreaReading(
    charters: [
      CharterReading(gb, trains: const ['3H', '2H'], slots: const [
        TokenSlot(0, slot, filled: false),
        TokenSlot(40, slot, filled: true),
      ]),
    ],
    certificates: [CertificateReading(gb, const [50, 25])],
  );

  testWidgets('what was read is shown, checked, and confirmed for a player',
      (tester) async {
    final session =
        GameSession.start(title: title, name: 'Test', startedEmpty: true)
          ..addPlayer('Ann');
    final popped = await review(tester, session, gbPhoto);
    expect(find.widgetWithText(InputChip, '3H'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '2H'), findsOneWidget);
    expect(find.text('50%'), findsWidgets);
    expect(find.text('= 75%'), findsOneWidget);
    // The board has no GB token yet: its home token is unaccounted for.
    expect(find.textContaining('leaves 1 unaccounted for'), findsOneWidget);
    expect(find.textContaining('only recorded once'), findsOneWidget);

    await tester.tap(find.text('Choose a player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ann').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    final confirmed = popped.single!;
    expect(confirmed.trains, {
      'GB': ['3H', '2H'],
    });
    expect(confirmed.charterTokens, {'GB': 1});
    expect(confirmed.player, 'Ann');
    expect(confirmed.certificates, {
      'GB': [50, 25],
    });
  });

  testWidgets('trains that rust each other are flagged as they are set',
      (tester) async {
    final session =
        GameSession.start(title: title, name: 'Test', startedEmpty: true);
    await review(tester, session, gbPhoto);
    await tester.tap(find.widgetWithText(ActionChip, '4'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('A 2H train is scrapped when the first 4 is '
            'bought'),
        findsOneWidget);
  });

  testWidgets('a photo with nothing read can be filled in by hand',
      (tester) async {
    final session =
        GameSession.start(title: title, name: 'Test', startedEmpty: true);
    final popped = await review(tester, session, const PlayAreaReading());
    expect(find.textContaining("No company's name could be read"),
        findsOneWidget);
    await tester.tap(find.text('A charter'));
    await tester.pumpAndSettle();
    expect(find.text('No trains'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(popped.single, isNull);
  });

  testWidgets('players are added and given certificates', (tester) async {
    final session =
        GameSession.start(title: title, name: 'Test', startedEmpty: true);
    var saves = 0;
    await tester.pumpWidget(MaterialApp(
      home: PlayersScreen(
          title: title, session: session, onChanged: () => saves++),
    ));
    expect(find.textContaining("Add the game's players"), findsOneWidget);
    await tester.tap(find.text('Add player'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Ann');
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(session.players, ['Ann']);

    await tester.tap(find.text('Add a certificate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Company'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Gotthardbahn').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('50%'));
    await tester.pumpAndSettle();
    expect(session.percentHeld('Ann', 'GB'), 50);
    expect(find.text('= 50%'), findsOneWidget);
    expect(saves, 2);
  });
}
