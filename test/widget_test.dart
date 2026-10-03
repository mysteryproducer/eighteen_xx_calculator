import 'package:eighteen_xx_calculator/main.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/board_graph.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/screens/session_board.dart';
import 'package:eighteen_xx_calculator/screens/session_list.dart';
import 'package:eighteen_xx_calculator/widgets/board_map.dart';
import 'package:eighteen_xx_calculator/widgets/tile_choices.dart';
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

/// The drawn tile choices in the hex editor.
Finder tileChoice(String label) => find.descendant(
      of: find.byType(TileChoices),
      matching: find.text(label),
    );

/// Picks a tile in the hex editor by what it is labelled, scrolling the row
/// of choices along until it shows.
Future<void> chooseTile(WidgetTester tester, String label) async {
  // The choices run off the side of the screen, so scroll the row of tiles
  // along until this one shows.
  final tiles = find
      .descendant(of: find.byType(TileChoices), matching: find.byType(ListView))
      .first;
  for (int i = 0; i < 15 && tileChoice(label).hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(tiles, const Offset(-220, 0));
    await tester.pumpAndSettle();
  }
  await tester.tap(tileChoice(label).first);
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

  /// The size a Mac window opens at, which is smaller than the drawn 1844
  /// board: everything has to work in it without the user resizing anything.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(800, 600);
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

    testWidgets('every hex can be chosen, even when the map is bigger than '
        'the window', (tester) async {
      // The window is smaller than the drawn map; the far corners of the
      // map must still take taps.
      await openSession(tester);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pumpAndSettle();
      await tapHex(tester, 'K22'); // Bellinzona, near the south-east corner
      await tapHex(tester, 'B19'); // Schaffhausen, at the top
      expect(find.textContaining('2 chosen'), findsOneWidget);
    });

    testWidgets('a hex a tunnel can go through can be chosen', (tester) async {
      await openSession(tester);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pumpAndSettle();
      await tapHex(tester, 'I12'); // Loetschberg: no tile, but a tunnel
      expect(find.textContaining('1 chosen'), findsOneWidget);
    });

    testWidgets('a tunnel is set in the hex editor', (tester) async {
      final session = await openSession(tester);
      await tapHex(tester, 'I12');
      expect(find.textContaining('a tunnel can be driven through'),
          findsOneWidget);
      await tester.tap(find.text('tunnel').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.tunnels['I12'], isNotNull);
    });

    testWidgets('a mountain a railway can climb can be chosen', (tester) async {
      await openSession(tester);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pumpAndSettle();
      await tapHex(tester, 'G14'); // Pilatus: no tile, but a mountain railway
      expect(find.textContaining('1 chosen'), findsOneWidget);
    });

    testWidgets('a plate a photo found is named in the hex editor',
        (tester) async {
      final session = await openSession(tester, setUp: (session) {
        session.mountains['G14'] = GameSession.unknownPlate;
        session.mountainDoubts.add('G14');
      });
      expect(find.textContaining('1 mountain railway to check'),
          findsOneWidget);
      await tapHex(tester, 'G14');
      expect(find.textContaining('a mountain railway can put'), findsOneWidget);
      expect(find.textContaining('but not which one'), findsOneWidget);
      // The plates are shown as printed, by what they pay: XM2 is the one
      // paying 40 in green.
      await tester.tap(find.ancestor(
          of: find.text('40'), matching: find.byType(ChoiceChip)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.mountains['G14'], 'XM2');
      expect(session.mountainDoubts, isEmpty);
      expect(find.textContaining('to check'), findsNothing);
    });

    testWidgets('a hex that never changes cannot be chosen', (tester) async {
      await openSession(tester);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pumpAndSettle();
      await tapHex(tester, 'M18'); // a red off-board area
      expect(find.textContaining('never changes'), findsOneWidget);
      expect(find.textContaining('chosen'), findsNothing);
    });

    testWidgets("a token naming a company the game doesn't have is up for "
        'checking', (tester) async {
      final session = await openSession(tester, setUp: (session) {
        final stans = title.map.byId('G18')!;
        session.tokens[GameSession.slotId(
            '${stans.coord.row}_${stans.coord.col}_0', 0)] = 'white';
      });
      expect(session.tokenDoubts, hasLength(1));
      expect(find.textContaining('1 token to check'), findsOneWidget);
    });

    testWidgets('colours can be calibrated, and the calibration forgotten',
        (tester) async {
      final session = await openSession(tester, setUp: (session) {
        session.colourProfile = ColourProfile(
            colours: const {TileColor.yellow: Offset(0.02, 0.15)},
            measured: DateTime(2026, 10, 1));
      });
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Recalibrate colours'), findsOneWidget);
      await tester.tap(find.text('Forget colour calibration'));
      await tester.pumpAndSettle();
      expect(session.colourProfile, isNull);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Calibrate colours'), findsOneWidget);
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
      // The choices are drawn, turned the way they would be laid, rather
      // than listed by number.
      expect(find.byType(TileChoices), findsOneWidget);
      expect(tileChoice('none'), findsOneWidget);
      // Basel is a printed city, so city tiles are on offer...
      await chooseTile(tester, '57');
      expect(find.byIcon(Icons.warning_amber), findsNothing);
      // ...and the count says how many the rules allow.
      expect(find.textContaining('the rules allow here'), findsOneWidget);
    });

    testWidgets('setting a tile by hand updates the board and saves it',
        (tester) async {
      final session = await openSession(tester);
      await tapHex(tester, 'C12');
      await chooseTile(tester, '57');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      final basel = title.map.byId('C12')!;
      expect(session.tileAt(basel)?.tileId, '57');
      expect(session.stateOf(basel).source, HexSource.manual);
      expect(store.sessions.values.single.tileAt(basel)?.tileId, '57');
    });

    testWidgets('a hex already holding a yellow tile still offers the others',
        (tester) async {
      // Langnau holds a 58; if that was misread, the right one has to be on
      // offer -- not just the 58 and what could follow it.
      final session = await openSession(tester, setUp: (session) {
        session.setManually(
            title.map.byId('F13')!, const PlacedTile('58', rotation: 4));
      });
      await tapHex(tester, 'F13');
      await chooseTile(tester, '4');
      expect(find.byIcon(Icons.warning_amber), findsNothing);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.tileAt(title.map.byId('F13')!)?.tileId, '4');
    });

    testWidgets('a tile is chosen first, then which way round', (tester) async {
      // Sarnen, a printed town, has the Pilatus railway's printed track
      // running up to its west side.
      final sarnen = title.map.byId('G16')!;
      final pilatus = title.map.byId('G14')!;
      final session = await openSession(tester);
      await tapHex(tester, 'G16');
      await chooseTile(tester, '4');
      // The way that joins the track already there comes first, and is what
      // picking the tile gives.
      expect(find.text('Turned:'), findsOneWidget);
      expect(find.text('joins 1'), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final towardsPilatus = [
        for (int e = 0; e < 6; e++)
          if (Board.neighborOf(sarnen.coord, e) == pilatus.coord) e,
      ].single;
      expect(
          title.tiles['4']!.rotated(session.tileAt(sarnen)!.rotation).edges,
          contains(towardsPilatus));

      // Any other way round is a second tap.
      await tapHex(tester, 'G16');
      await tester.tap(find.textContaining('turn ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
          title.tiles['4']!.rotated(session.tileAt(sarnen)!.rotation).edges,
          isNot(contains(towardsPilatus)));
    });

    testWidgets('the Furka-Oberalp line is laid and taken up as one piece',
        (tester) async {
      final session = await openSession(tester);
      final line = ['H17', 'H19', 'H21', 'H23', 'I16'];
      await tapHex(tester, 'H17');
      expect(find.textContaining('one piece'), findsOneWidget);
      await chooseTile(tester, 'OP3');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      for (final id in line) {
        expect(session.tileAt(title.map.byId(id)!)?.tileId, startsWith('OP'),
            reason: id);
      }
      // And lifted again from any of its hexes.
      await tapHex(tester, 'H21');
      await chooseTile(tester, 'none');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      for (final id in line) {
        expect(session.tileAt(title.map.byId(id)!), isNull, reason: id);
      }
    });

    testWidgets('a photo that disagrees with the user is offered, not taken',
        (tester) async {
      final langnau = title.map.byId('F13')!;
      final session = await openSession(tester, setUp: (session) {
        session.setManually(langnau, const PlacedTile('58', rotation: 4));
        session.recordReading(langnau,
            tile: const PlacedTile('4', rotation: 1),
            confidence: 0.85,
            source: HexSource.closeUp);
      });
      expect(session.tileAt(langnau)?.tileId, '58');
      expect(find.textContaining('something other than what you set'),
          findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The photo shows tile 4 turned 1'),
          findsOneWidget);
      await tester.tap(find.text('Use that'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.tileAt(langnau)?.tileId, '4');
      expect(session.suggestedHexes(title.map), isEmpty);
      expect(find.textContaining('something other than what you set'),
          findsNothing);
    });

    testWidgets('a tile that cannot belong on a hex is flagged', (tester) async {
      await openSession(tester);
      await tapHex(tester, 'F13'); // Langnau, a printed town
      // Picking a city tile here is the sort of slip that makes every route
      // through the hex wrong, so the editor says what is off.
      await tester.tap(find.textContaining('Show every tile'));
      await tester.pumpAndSettle();
      // Tile 5 carries a city, which a town hex can't take.
      await chooseTile(tester, '5');
      expect(find.textContaining('F13'), findsWidgets);
      expect(find.textContaining('town'), findsWidgets);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    });

    testWidgets('a flagged tile is marked on the board too', (tester) async {
      await openSession(tester, setUp: (session) {
        session.setManually(title.map.byId('F13')!, const PlacedTile('57'));
      });
      expect(find.textContaining("1 tile in red isn't allowed there"),
          findsOneWidget);
    });

    testWidgets("a token in a circle another company's home token needs is "
        'flagged', (tester) async {
      await openSession(tester, setUp: (session) {
        final altdorf = title.map.byId('G18')!;
        session.setManually(altdorf, const PlacedTile('5', rotation: 4));
        session.tokens[GameSession.slotId(
            '${altdorf.coord.row}_${altdorf.coord.col}_0', 0)] = 'FNM';
      });
      expect(find.textContaining("1 token in red isn't allowed there"),
          findsOneWidget);
      await tapStation(tester, 'G18');
      expect(find.textContaining("is GB's home"), findsOneWidget);
    });

    testWidgets('each circle of a city takes its own token', (tester) async {
      final session = await openSession(tester, setUp: (session) {
        session.setManually(title.map.byId('D19')!, const PlacedTile('907'));
      });
      await tapStation(tester, 'D19');
      expect(find.text('Station token, circle 1 of 2'), findsOneWidget);
      expect(find.text('Station token, circle 2 of 2'), findsOneWidget);
      // NOB in the first circle, SCB in the second.
      await tester.tap(find.widgetWithText(ChoiceChip, 'NOB').first);
      await tester.pumpAndSettle();
      // The second circle's row is further down the sheet.
      final second = find.widgetWithText(ChoiceChip, 'SCB').last;
      await tester.ensureVisible(second);
      await tester.pumpAndSettle();
      await tester.tap(second);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final zurich = title.map.byId('D19')!;
      final id = '${zurich.coord.row}_${zurich.coord.col}_0';
      expect(session.tokens, {
        GameSession.slotId(id, 0): 'NOB',
        GameSession.slotId(id, 1): 'SCB',
      });
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
      // The title's own companies, not a set of plain colours.
      expect(find.text('SCB'), findsOneWidget);
      expect(find.text('BLS'), findsOneWidget);
      expect(find.text('Red'), findsNothing);
    });

    testWidgets('a token whose company was guessed is flagged until settled',
        (tester) async {
      final session = await openSession(tester, setUp: (session) {
        final basel = title.map.byId('C12')!;
        final id =
            GameSession.slotId('${basel.coord.row}_${basel.coord.col}_0', 0);
        session.tokens[id] = 'SCB';
        session.tokenDoubts.add(id);
      });
      expect(find.textContaining('1 token to check'), findsOneWidget);
      await tapStation(tester, 'C12');
      expect(find.textContaining('whose it is was a guess'), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.tokenDoubts, isEmpty);
      expect(session.tokens.values, ['SCB']);
      expect(find.textContaining('to check'), findsNothing);
    });
  });

  group('a flat-topped title (1889)', () {
    testWidgets('its board is drawn as printed, and a tap finds the hex',
        (tester) async {
      final g1889 = GameTitle.byId('1889')!;
      final session = GameSession.start(
          title: g1889, name: 'Shikoku', startedEmpty: true);
      await store.save(session);
      await tester.pumpWidget(MaterialApp(
        home: SessionBoard(title: g1889, session: session, store: store),
      ));
      await tester.pumpAndSettle();
      // Takamatsu, tapped where the board shows it, clear of its city.
      final geometry = BoardMapGeometry(g1889.map, turn: g1889.displayTurn);
      final takamatsu = g1889.map.byId('K4')!;
      Offset where() => tester
          .renderObject<RenderBox>(find.byKey(sessionBoardKey))
          .localToGlobal(geometry
              .toScreen(takamatsu.coord.boardCenter + const Offset(0, 0.6)));
      final middle = const Offset(400, 300);
      if ((where() - middle).distance > 150) {
        await tester.drag(find.byKey(sessionBoardKey), middle - where());
        await tester.pumpAndSettle();
      }
      await tester.tapAt(where());
      await tester.pumpAndSettle();
      expect(find.text('K4 Takamatsu'), findsOneWidget);
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
        // Basel is the Centralbahn's home.
        session.tokens[GameSession.slotId(
            '${basel.coord.row}_${basel.coord.col}_0', 0)] = 'SCB';
      });
      await tester.tap(find.text('Any company'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('SCB').hitTestable().last);
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

    /// Basel and Liestal joined, SCB's token in Basel, and two players
    /// with SCB certificates.
    void basel(GameSession session) {
      final basel = title.map.byId('C12')!;
      session.setManually(basel, const PlacedTile('57', rotation: eastWest));
      session.setManually(
          title.map.byId('C14')!, const PlacedTile('4', rotation: eastWest));
      session.tokens[GameSession.slotId(
          '${basel.coord.row}_${basel.coord.col}_0', 0)] = 'SCB';
      session
        ..addPlayer('Ann')
        ..addPlayer('Bob')
        ..setHolding('Ann', 'SCB', [50])
        ..setHolding('Bob', 'SCB', [25]);
    }

    Future<void> chooseScb(WidgetTester tester) async {
      await tester.tap(find.text('Any company'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('SCB').hitTestable().last);
      await tester.pumpAndSettle();
    }

    testWidgets("a company's trains run and pay its shareholders",
        (tester) async {
      await openSession(tester, setUp: (session) {
        basel(session);
        session.companyTrains['SCB'] = ['2', '2H'];
      });
      await chooseScb(tester);
      expect(find.text('SCB runs 2, 2H.'), findsOneWidget);
      // Trains noted: no stop count to set.
      expect(find.text('Stops'), findsNothing);
      await tester.tap(find.text('Find routes'));
      await tester.pumpAndSettle();
      // One train runs Basel to Liestal; there's no other track out of
      // Basel for the second.
      expect(find.textContaining('C12 - C14 pays 30'), findsOneWidget);
      expect(find.textContaining('nowhere left to run'), findsOneWidget);
      expect(find.text('SCB earns 30.'), findsOneWidget);
      expect(find.text('Ann 15 (50%)   Bob 7 (25%)'), findsOneWidget);
    });

    testWidgets("a company's trains and tokens are set from the route panel",
        (tester) async {
      final session = await openSession(tester, setUp: basel);
      await chooseScb(tester);
      expect(find.text('No trains noted for SCB.'), findsOneWidget);
      await tester.tap(find.text('Trains and tokens'));
      await tester.pumpAndSettle();
      for (final train in ['3H', '2H', '2']) {
        await tester.tap(find.widgetWithText(ActionChip, train));
        await tester.pumpAndSettle();
      }
      // A pre-SBB company runs two trains at most.
      expect(find.textContaining('at most 2 trains in phase 3, not 3'),
          findsOneWidget);
      await tester.tap(find.descendant(
          of: find.widgetWithText(InputChip, '2'),
          matching: find.byTooltip('Delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('at most 2 trains'), findsNothing);
      await tester.tap(find.byTooltip('One more'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('One more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(session.companyTrains['SCB'], ['3H', '2H']);
      expect(session.charterTokens['SCB'], 1);
      expect(find.text('SCB runs 3H, 2H.'), findsOneWidget);
    });

    Future<void> chooseCompany(WidgetTester tester, String label) async {
      await tester.tap(find.text('Any company'));
      await tester.pumpAndSettle();
      // Further down the list than the window shows, and only built once
      // scrolled to.
      await tester.scrollUntilVisible(find.textContaining(label), 100,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(label).hitTestable().last);
      await tester.pumpAndSettle();
    }

    testWidgets("a company's tokens away from its home are pointed out",
        (tester) async {
      // MOB's home is Montreux (I6); a token at Thun (H13) and none there
      // (its home token turned off) means one is on the wrong hex.
      await openSession(tester, setUp: (session) {
        session.homeTokensOff.add('MOB');
        final h13 = title.map.byId('H13')!.coord;
        session.tokens[GameSession.slotId('${h13.row}_${h13.col}_0', 0)] =
            'MOB';
      });
      expect(find.textContaining('1 token in red'), findsOneWidget);
      await chooseCompany(tester, 'MOB');
      expect(
          find.text("MOB's first token goes on its home, I6 Montreux, and "
              'none of its tokens is there: one of them is on the wrong hex.'),
          findsOneWidget);
    });

    testWidgets("a route's bonus is spelt out at a tap", (tester) async {
      // MOB from Bern's neighbour H13 through H11's curve and the tunnel
      // under I12 to Brig: tunnel track pays 10 a stop.
      await openSession(tester, setUp: (session) {
        session.setManually(
            title.map.byId('H13')!, const PlacedTile('915', rotation: 4));
        session.setManually(
            title.map.byId('H11')!, const PlacedTile('29', rotation: 4));
        session.tunnels['I12'] = (2, 5);
        final h13 = title.map.byId('H13')!.coord;
        session.tokens[GameSession.slotId('${h13.row}_${h13.col}_0', 0)] =
            'MOB';
        session.companyTrains['MOB'] = ['2'];
      });
      await chooseCompany(tester, 'MOB');
      await tester.tap(find.text('Find routes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('H13 - J13 pays 90'), findsOneWidget);
      expect(find.textContaining('Tunnel track'), findsNothing);
      await tester.tap(find.text(' (20 of it bonus ▸)'));
      await tester.pumpAndSettle();
      expect(
          find.text('Tunnel track: 10 for each of the 2 stops paid for: 20'),
          findsOneWidget);
    });

    testWidgets('the camera takes a photo of the board or of a player area',
        (tester) async {
      await openSession(tester);
      await tester.tap(find.byTooltip('Take a photo'));
      await tester.pumpAndSettle();
      expect(find.text('The whole board'), findsOneWidget);
      expect(find.text("A player's area"), findsOneWidget);
    });
  });
}
