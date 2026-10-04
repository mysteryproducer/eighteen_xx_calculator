import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/screens/end_game.dart';
import 'package:eighteen_scanner/screens/players_screen.dart';
import 'package:eighteen_scanner/widgets/holdings_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final g1889 = GameTitle.byId('1889')!;

  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 1800);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  GameSession game() =>
      GameSession.start(title: g1889, name: 'test', startedEmpty: true)
        ..addPlayer('Ann')
        ..addPlayer('Ben')
        ..setHolding('Ann', 'AR', [20, 10])
        ..setHolding('Ben', 'IR', [20]);

  /// The number field [key] names.
  Finder field(String key) => find.descendant(
      of: find.byKey(ValueKey(key)), matching: find.byType(TextField));

  String shown(WidgetTester tester, String key) =>
      tester.widget<TextField>(field(key)).controller!.text;

  Finder rounds(String n) => find.descendant(
      of: find.byType(SegmentedButton<int>), matching: find.text(n));

  testWidgets('the end of the game: worth now, and after ORs run',
      (tester) async {
    final session = game();
    await tester.pumpWidget(MaterialApp(
      home: EndGameScreen(title: g1889, session: session, onChanged: () {}),
    ));
    await tester.enterText(field('cash-Ann'), '500');
    await tester.enterText(field('price-AR'), '100');
    await tester.pumpAndSettle();
    expect(session.cash, {'Ann': 500});
    expect(session.sharePrices, {'AR': 100});
    // Ann: 500 and three shares at 100.
    expect(find.text('800'), findsOneWidget);
    // No ORs run until asked for.
    expect(field('takings-AR'), findsNothing);

    await tester.tap(rounds('3'));
    await tester.pumpAndSettle();
    await tester.enterText(field('takings-AR'), '150');
    await tester.pumpAndSettle();
    expect(shown(tester, 'value-AR-3'), '140');
    // After: 500, 45 paid three times, three shares at 140.
    expect(find.text('${500 + 135 + 3 * 140}'), findsOneWidget);

    // A round's share value put right: the rounds after follow from it.
    await tester.enterText(field('value-AR-1'), '125');
    await tester.pumpAndSettle();
    expect(shown(tester, 'value-AR-3'), '155');

    await tester.tap(find.text('Keep this OR set'));
    await tester.pumpAndSettle();
    expect(session.endGameSets, hasLength(1));
    expect(session.cash['Ann'], 500 + 135);
    expect(session.sharePrices['AR'], 155);
    expect(field('takings-AR'), findsNothing);
    expect(find.text('OR set 1: 3 rounds'), findsOneWidget);
  });

  testWidgets('a company hidden on the market is added by hand',
      (tester) async {
    final session = game();
    await tester.pumpWidget(MaterialApp(
      home: PlayersScreen(title: g1889, session: session, onChanged: () {}),
    ));
    expect(field('price-KU'), findsNothing);
    await tester.tap(find.text('Add a company'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Tosa Kuroshio'));
    await tester.pumpAndSettle();
    await tester.enterText(field('price-KU'), '110');
    await tester.pumpAndSettle();
    expect(session.sharePrices['KU'], 110);
  });

  testWidgets("a player's holding is typed in shares, a digit taken as typed",
      (tester) async {
    final session = game();
    await tester.pumpWidget(MaterialApp(
      home: PlayersScreen(title: g1889, session: session, onChanged: () {}),
    ));
    // Ann's director's certificate and one more: three shares of 10%.
    expect(shown(tester, 'held-Ann-AR'), '3');
    expect(find.text('3 (30%)'), findsOneWidget);
    await tester.enterText(field('held-Ann-AR'), '4');
    await tester.pumpAndSettle();
    // The director's certificate kept, the rest in tens.
    expect(session.holdings['Ann']!['AR'], [20, 10, 10]);
    expect(find.text('4 (40%)'), findsOneWidget);
    // No one holds ten: a single digit is all there is to type.
    expect(tester.widget<TextField>(field('held-Ann-AR')).focusNode!.hasFocus,
        isFalse);
    // A share value is typed digit by digit, warned of on the way.
    await tester.enterText(field('price-AR'), '1');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Not on the market'), findsOneWidget);
    expect(tester.widget<TextField>(field('price-AR')).focusNode!.hasFocus,
        isTrue);
    await tester.enterText(field('price-AR'), '110');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Not on the market'), findsNothing);
    expect(session.sharePrices['AR'], 110);
  });

  testWidgets('what a share is, picked for a company: shares stay, worth '
      'follows', (tester) async {
    final session = game()..sharePrices['AR'] = 100;
    await tester.pumpWidget(MaterialApp(
      home: PlayersScreen(title: g1889, session: session, onChanged: () {}),
    ));
    expect(find.text('300'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stake-AR')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5%').last);
    await tester.pumpAndSettle();
    expect(session.shareStakes, {'AR': 5});
    expect(session.holdings['Ann']!['AR'], [10, 5]);
    expect(shown(tester, 'held-Ann-AR'), '3');
    expect(find.text('3 (15%)'), findsOneWidget);
    // Three shares at 100 still.
    expect(find.text('300'), findsOneWidget);
  });

  testWidgets('more shares held than tens could make: taken as fives',
      (tester) async {
    final session = game();
    await tester.pumpWidget(MaterialApp(
      home: PlayersScreen(title: g1889, session: session, onChanged: () {}),
    ));
    await tester.enterText(field('held-Ann-IR'), '6');
    await tester.pumpAndSettle();
    expect(session.shareStakes, isEmpty);
    // Ben's six more make twelve: 120% at 10% each.
    await tester.enterText(field('held-Ben-IR'), '6');
    await tester.pumpAndSettle();
    expect(session.shareStakes, {'IR': 5});
    expect(session.holdings['Ann']!['IR'], [5, 5, 5, 5, 5, 5]);
    expect(session.holdings['Ben']!['IR'], [10, 5, 5, 5, 5]);
    expect(find.text('12 (60%)'), findsOneWidget);
    expect(find.textContaining('taken as 5% each'), findsOneWidget);
  });

  test('certificates for a percentage keep those held where they can', () {
    final awa = g1889.companyById('AR')!;
    expect(certificatesFor(awa, 30, [20, 10]), [20, 10]);
    expect(certificatesFor(awa, 50, [20, 10]), [20, 10, 10, 10]);
    expect(certificatesFor(awa, 30, [10]), [10, 10, 10]);
    expect(certificatesFor(awa, 0, [20]), isEmpty);
    expect(certificatesFor(awa, 20, [10, 5], stake: 5), [10, 5, 5]);
  });
}
