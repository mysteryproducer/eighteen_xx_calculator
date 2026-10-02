import 'package:eighteen_xx_calculator/models/company_rules.dart';
import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/models/tile_definition.dart';
import 'package:eighteen_xx_calculator/screens/play_area_review.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final title = GameTitle.byId('1844')!;
  final rules = CompanyRules(title);
  final gb = title.companyById('GB')!;
  GameSession newGame() =>
      GameSession.start(title: title, name: 'Test game', startedEmpty: true);

  /// GB's home token on G18's city.
  String home(GameSession session) {
    final g18 = title.map.byId('G18')!.coord;
    return GameSession.slotId('${g18.row}_${g18.col}_0', 0);
  }

  group('the phase', () {
    test('comes from the trains the companies have', () {
      final session = newGame();
      expect(rules.phase(session)!.name, '1');
      session.companyTrains['NOB'] = ['2'];
      expect(rules.phase(session)!.name, '2');
      expect(rules.phase(session, alsoSeen: ['3H'])!.name, '3');
    });

    test('or from the colour of tile being laid', () {
      final session = newGame()..phase = TileColor.brown;
      expect(rules.phase(session)!.name, '5');
      session.companyTrains['NOB'] = ['6'];
      expect(rules.phase(session)!.name, '6');
    });
  });

  group("a company's trains", () {
    test("GB's 3H and 2H are allowed", () {
      expect(rules.trainProblems(newGame(), gb, ['3H', '2H']), isEmpty);
    });

    test('no more than the phase allows', () {
      expect(rules.trainProblems(newGame(), gb, ['3H', '2H', '2']),
          ['GB can own at most 2 trains in phase 3, not 3.']);
      // A historical company may own four in the early phases.
      expect(
          rules.trainProblems(
              newGame(), title.companyById('BLS')!, ['3', '2', '2', '2']),
          isEmpty);
    });

    test('not one a train in the same photo would have scrapped', () {
      expect(rules.trainProblems(newGame(), gb, ['2H'], alsoSeen: ['4']).last,
          contains('A 2H train is scrapped when the first 4 is bought'));
    });

    test("nor one another company's train would have scrapped", () {
      final session = newGame()..companyTrains['NOB'] = ['4H'];
      expect(rules.trainProblems(session, gb, ['2H']).last,
          contains('now that NOB has a 4H'));
      // What was noted for GB itself before doesn't count.
      session.companyTrains
        ..remove('NOB')
        ..['GB'] = ['4'];
      expect(rules.trainProblems(session, gb, ['2H']), isEmpty);
    });

    test("nor a train the title doesn't have", () {
      expect(rules.trainProblems(newGame(), gb, ['9X']),
          contains("There's no 9X train in 1844."));
    });
  });

  group('tokens', () {
    test('on the board and on the charter make up what a company has', () {
      final session = newGame();
      session.tokens[home(session)] = 'GB';
      expect(rules.tokenCountProblems(session, gb, 1), isEmpty);
      expect(rules.tokens(session, gb).missing, isNull);
      session.charterTokens['GB'] = 1;
      expect(rules.tokens(session, gb).missing, 0);
    });

    test('one unaccounted for is pointed out', () {
      final session = newGame();
      expect(rules.tokenCountProblems(session, gb, 1).single,
          contains('0 on the board and 1 on its charter leaves 1 '
              'unaccounted for'));
      session.tokens[home(session)] = 'GB';
      expect(rules.tokenCountProblems(session, gb, 2).single,
          contains('only 2 tokens'));
    });
  });

  group('certificates', () {
    test('no more of a size than the company prints', () {
      final session = newGame();
      expect(rules.certificateProblems(session, gb, 'Ann', [50, 25]), isEmpty);
      expect(rules.certificateProblems(session, gb, 'Ann', [50, 50]),
          ['GB has only 1 50% certificate.']);
      expect(rules.certificateProblems(session, gb, 'Ann', [10]),
          ['GB has no 10% certificate.']);
    });

    test('no more than all of it between the players', () {
      final session = newGame()
        ..addPlayer('Ann')
        ..addPlayer('Bob')
        ..setHolding('Bob', 'GB', [50, 25]);
      expect(rules.certificateProblems(session, gb, 'Ann', [25, 25]).last,
          contains('that makes 125% of GB'));
    });

    test('pay their share of the revenue, rounded down', () {
      final session = newGame()..setHolding('Ann', 'GB', [50, 25]);
      expect(rules.dividend(session, 'Ann', 'GB', 210), 157);
      expect(rules.dividend(session, 'Ann', 'GB', 210, half: true), 78);
      expect(rules.dividend(session, 'Bob', 'GB', 210), 0);
    });
  });

  test('what a photo of a player area confirmed goes into the session', () {
    final session = newGame()..companyTrains['GB'] = ['2'];
    const PlayAreaConfirmed(
      trains: {
        'GB': ['3H', '2H'],
      },
      charterTokens: {'GB': 1},
      player: 'Ann',
      certificates: {
        'GB': [50, 25],
      },
    ).applyTo(session);
    expect(session.companyTrains['GB'], ['3H', '2H']);
    expect(session.charterTokens['GB'], 1);
    expect(session.players, ['Ann']);
    expect(session.percentHeld('Ann', 'GB'), 75);
    // Without a player, certificates aren't recorded.
    const PlayAreaConfirmed(certificates: {
      'NOB': [50],
    }).applyTo(session);
    expect(session.holdings.keys, ['Ann']);
  });
}
