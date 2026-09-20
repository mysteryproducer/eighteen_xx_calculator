import 'package:eighteen_xx_calculator/main.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/screens/session_board.dart';
import 'package:eighteen_xx_calculator/screens/session_list.dart';
import 'package:eighteen_xx_calculator/widgets/board_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_store.dart';

final title = GameTitle.byId('1844')!;

/// Tiles 57 and 4 run between edges 0 and 3 -- south-west to north-east --
/// so turning them four steps lays their track east-west, along a row.
const int eastWest = 4;

/// Three hexes the app isn't sure about: two neighbours and one far away.
void doubtfulHexes(GameSession session) {
  for (final id in ['C12', 'C14', 'G26']) {
    session.recordReading(title.map.byId(id)!,
        tile: null, confidence: 0.1, source: HexSource.overview);
  }
}

/// Taps the drawn board at [board] (in board coordinates), panning the board
/// first if that spot is off screen, as a player would.
Future<void> tapBoardAt(WidgetTester tester, Offset board) async {
  final geometry = BoardMapGeometry(title.map);
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

/// Taps the body of a hex, clear of the station at its centre.
Future<void> tapHex(WidgetTester tester, String hexId) => tapBoardAt(
    tester, title.map.byId(hexId)!.coord.boardCenter + const Offset(0, 0.55));

/// Taps a hex's station, at its centre.
Future<void> tapStation(WidgetTester tester, String hexId) =>
    tapBoardAt(tester, title.map.byId(hexId)!.coord.boardCenter);

/// Opens the tile list in the hex editor. The finder is scoped to the sheet
/// so it can't pick up the company list on the board behind it.
Future<void> openTilePicker(WidgetTester tester) async {
  final picker = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.byType(DropdownButton<String?>),
  );
  await tester.tap(picker);
  await tester.pumpAndSettle();
}

/// What the route panel says the best route pays, or 0 if it found none.
int _routeRevenue(WidgetTester tester) {
  final found = find.textContaining('Best route pays');
  if (found.evaluate().isEmpty) return 0;
  final text = tester.widget<Text>(found.first).data!;
  return int.parse(RegExp(r'pays (\d+)').firstMatch(text)!.group(1)!);
}

void main() {
  late FakeSessionStore store;

  setUp(() => store = FakeSessionStore());

  /// The drawn 1844 board is bigger than a default test window, and taps
  /// outside the window land nowhere.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(900, 1400);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  Future<GameSession> openSession(
    WidgetTester tester, {
    bool startedEmpty = true,
    void Function(GameSession)? setUp,
  }) async {
    final session = GameSession.start(
        title: title, name: 'Test game', startedEmpty: startedEmpty);
    setUp?.call(session);
    await store.save(session);
    await tester.pumpWidget(MaterialApp(
      home: SessionBoard(
        key: ValueKey('${session.id}-${session.hexes.length}'),
        title: title,
        session: session,
        store: store,
      ),
    ));
    await tester.pumpAndSettle();
    return session;
  }

  group('getting to a game', () {
    testWidgets('the app opens on the list of titles', (tester) async {
      await tester.pumpWidget(MyApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('Select 18xx title'), findsOneWidget);
      expect(find.text('1844'), findsOneWidget);
      expect(find.text('1854'), findsOneWidget);
      expect(find.textContaining('131 hexes'), findsOneWidget);
    });

    testWidgets('a title with no games says how to start one', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SessionList(title: title, store: store),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('No games yet'), findsOneWidget);
      expect(find.text('New game'), findsOneWidget);
    });

    testWidgets('starting a game saves it and opens the board', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SessionList(title: title, store: store),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New game'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Friday night');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text('Friday night'), findsWidgets);
      expect(store.sessions.values.single.name, 'Friday night');
    });

    testWidgets('saved games are listed with what still needs checking',
        (tester) async {
      final session = GameSession.start(
          title: title, name: 'Half done', startedEmpty: true);
      session.setManually(title.map.byId('C12')!, const PlacedTile('57'));
      session.recordReading(title.map.byId('D13')!,
          tile: const PlacedTile('9'),
          confidence: 0.2,
          source: HexSource.overview);
      await store.save(session);
      await tester.pumpWidget(MaterialApp(
        home: SessionList(title: title, store: store),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 tiles laid'), findsOneWidget);
      expect(find.textContaining('1 to check'), findsOneWidget);
    });
  });

  group('the board', () {
    testWidgets('a new game asks for a photo of the bare board',
        (tester) async {
      await openSession(tester);
      expect(find.textContaining('before anyone lays a tile'), findsOneWidget);
      expect(find.text('Photograph empty board'), findsOneWidget);
    });

    testWidgets('doubtful hexes are offered as close-ups, with a count',
        (tester) async {
      await openSession(tester, setUp: doubtfulHexes);
      expect(find.textContaining('3 hexes need a closer look'), findsOneWidget);
      // Neighbours share one photo, so three hexes here are two photos.
      expect(find.textContaining('2 photos'), findsOneWidget);
      expect(find.text('Choose'), findsOneWidget);
    });

    testWidgets('choosing starts with nothing selected', (tester) async {
      await openSession(tester, setUp: doubtfulHexes);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tap the hexes to photograph'), findsOneWidget);
      expect(find.textContaining('chosen'), findsNothing);
      // Nothing to take a photo of yet.
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Close-ups')).onPressed, isNull);
    });

    testWidgets('everything doubtful can be selected at once, then pruned',
        (tester) async {
      await openSession(tester, setUp: doubtfulHexes);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All 3'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 chosen'), findsOneWidget);
      // Toggling one off leaves the neighbouring pair, which is one photo.
      await tapHex(tester, 'G26');
      expect(find.textContaining('2 chosen'), findsOneWidget);
      expect(find.textContaining('1 photo'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('chosen'), findsNothing);
    });

    testWidgets('hexes can be chosen from scratch, without being doubtful',
        (tester) async {
      await openSession(tester);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tap the hexes to photograph'), findsOneWidget);
      await tapHex(tester, 'C12');
      await tapHex(tester, 'C14');
      expect(find.textContaining('2 chosen'), findsOneWidget);
      // Neighbouring hexes are covered by a single close-up.
      expect(find.textContaining('1 photo'), findsOneWidget);
    });

    testWidgets('a hex that never changes cannot be chosen', (tester) async {
      await openSession(tester);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pumpAndSettle();
      await tapHex(tester, 'M18'); // a red off-board area
      expect(find.textContaining('never changes'), findsOneWidget);
      expect(find.textContaining('chosen'), findsNothing);
    });

    testWidgets('the board summarises what is on it', (tester) async {
      await openSession(tester, setUp: (session) {
        session.setManually(title.map.byId('C12')!, const PlacedTile('57'));
      });
      expect(find.textContaining('1 tile laid'), findsOneWidget);
      expect(find.textContaining('revenue centres'), findsOneWidget);
    });
  });

  group('correcting what the app thinks', () {
    testWidgets('tapping a hex opens its editor, with what was read',
        (tester) async {
      await openSession(tester, setUp: (session) {
        session.recordReading(title.map.byId('C12')!,
            tile: const PlacedTile('57'),
            confidence: 0.45,
            source: HexSource.overview);
      });
      await tapHex(tester, 'C12');
      expect(find.text('C12 Basel'), findsOneWidget);
      expect(find.textContaining('45% sure'), findsOneWidget);
      expect(find.text('tile 57'), findsOneWidget);
    });

    testWidgets('the editor offers the tiles the rules allow', (tester) async {
      await openSession(tester);
      await tapHex(tester, 'C12');
      // Basel is a printed city, so city tiles are offered and track tiles
      // are not.
      await openTilePicker(tester);
      expect(find.text('Tile 57').hitTestable(), findsWidgets);
      expect(find.text('Tile 9'), findsNothing);
    });

    testWidgets('setting a tile by hand updates the board and saves it',
        (tester) async {
      final session = await openSession(tester);
      await tapHex(tester, 'C12');
      await openTilePicker(tester);
      await tester.tap(find.text('Tile 57').hitTestable().last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      final basel = title.map.byId('C12')!;
      expect(session.tileAt(basel)?.tileId, '57');
      expect(session.stateOf(basel).source, HexSource.manual);
      expect(store.sessions.values.single.tileAt(basel)?.tileId, '57');
    });

    testWidgets('a tile that cannot belong on a hex is flagged', (tester) async {
      await openSession(tester);
      await tapHex(tester, 'F13'); // Langnau, a printed town
      // Picking a city tile here is the sort of slip that makes every route
      // through the hex wrong, so the editor says what is off.
      await tester.tap(find.textContaining('Show every tile'));
      await tester.pumpAndSettle();
      await openTilePicker(tester);
      // Tile 5 is a city tile, and near the top of the list so the dropdown
      // doesn't have to be scrolled.
      await tester.tap(find.text('Tile 5').hitTestable().last);
      await tester.pumpAndSettle();
      expect(find.textContaining('F13'), findsWidgets);
      expect(find.textContaining('town'), findsWidgets);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    });

    testWidgets('a flagged tile is marked on the board too', (tester) async {
      await openSession(tester, setUp: (session) {
        session.setManually(title.map.byId('F13')!, const PlacedTile('57'));
      });
      expect(find.textContaining("1 in red doesn't fit the map"), findsOneWidget);
    });

    testWidgets('a hex that never takes a tile says so', (tester) async {
      await openSession(tester);
      await tapHex(tester, 'M18'); // Milano, a red off-board area
      expect(find.textContaining('no tile is ever laid here'), findsOneWidget);
    });

    testWidgets('tapping a station opens its revenue and token editor',
        (tester) async {
      await openSession(tester);
      await tapStation(tester, 'C12'); // Basel's printed city
      expect(find.textContaining('City on C12 Basel'), findsOneWidget);
      expect(find.text('Station token'), findsOneWidget);
    });
  });

  group('routes', () {
    testWidgets('a route is found and reported', (tester) async {
      await openSession(tester, setUp: (session) {
        session.setManually(
            title.map.byId('C12')!, const PlacedTile('57', rotation: eastWest));
        session.setManually(
            title.map.byId('C14')!, const PlacedTile('4', rotation: eastWest));
      });
      await tester.tap(find.text('Find route'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Best route pays'), findsOneWidget);
    });

    testWidgets("a company's route runs from the city it has tokened",
        (tester) async {
      await openSession(tester, setUp: (session) {
        final basel = title.map.byId('C12')!;
        // Basel's city and the town at Liestal next door, joined by track
        // running east-west along the row.
        session.setManually(basel, const PlacedTile('57', rotation: eastWest));
        session.setManually(
            title.map.byId('C14')!, const PlacedTile('4', rotation: eastWest));
        session.tokens['${basel.coord.row}_${basel.coord.col}_0'] = 'red';
      });
      await tester.tap(find.text('Any company'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Red').hitTestable().last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find route'));
      await tester.pumpAndSettle();
      final route = tester
          .widget<Text>(find.textContaining('Best route pays').first)
          .data!;
      expect(route, contains('C12'));
      expect(route, contains('C14'));
      expect(_routeRevenue(tester), 30); // a 20 city and a 10 town
    });
  });
}
