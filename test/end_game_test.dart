import 'dart:convert';

import 'package:eighteen_scanner/models/end_game.dart';
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final g1889 = GameTitle.byId('1889')!;
  // Ann holds the director's 20% of Awa and 10% more; Ben 10% of Awa and
  // 20% of Iyo.
  final holdings = {
    'Ann': {
      'AR': [20, 10],
    },
    'Ben': {
      'AR': [10],
      'IR': [20],
    },
  };
  final calc = EndGame(g1889, holdings);

  group('what a player is worth', () {
    test('cash, and shares at their share values, counted in the smallest '
        'certificate', () {
      expect(calc.shares('AR', 30), 3);
      expect(calc.sharesWorth('Ann', {'AR': 100}), 300);
      expect(calc.worth('Ben', cash: 400, values: {'AR': 100, 'IR': 80}),
          400 + 100 + 160);
      // 1844's pre-SBB companies come in quarters: 50% is two shares.
      final g1844 = GameTitle.byId('1844')!;
      expect(EndGame(g1844, const {}).shares('NOB', 50), 2);
    });

    test('in shares of what a share is, where the game says', () {
      final fives = EndGame(g1889, holdings, stakes: const {'AR': 5});
      expect(fives.shares('AR', 30), 6);
      expect(fives.sharesWorth('Ann', {'AR': 100}), 600);
      // Dividends go by the part of the company held, whatever a share is.
      expect(fives.dividend('Ann', 'AR', 175), 53);
    });

    test("a holder's dividend is rounded up, as tobymao pays it", () {
      // 175 paid on Awa: 30% is 52.5.
      expect(calc.dividend('Ann', 'AR', 175), 53);
      expect(calc.dividend('Ben', 'AR', 175), 18);
      expect(calc.dividend('Ann', 'IR', 175), 0);
    });

    test("a minor pays its owner half in 1854, none of 1880's investors'",
        () {
      final g1854 = GameTitle.byId('1854')!;
      final minor = g1854.companies.firstWhere((c) => c.kind == 'minor').id;
      expect(
          EndGame(g1854, {
            'Ann': {
              minor: [100],
            },
          }).dividend('Ann', minor, 100),
          50);
      final g1880 = GameTitle.byId('1880')!;
      expect(
          EndGame(g1880, {
            'Ann': {
              '1': [100],
            },
          }).dividend('Ann', '1', 100),
          0);
    });
  });

  group('an end game OR set', () {
    test('pays out each round, share values rising', () {
      final set = EndGameSet(
        prices: {'AR': 100, 'IR': 80},
        revenue: {'AR': 150},
        rounds: 3,
      );
      final result = calc.run(set);
      expect(result.values['AR'], [100, 110, 125, 140]);
      // Iyo's takings aren't known: it pays, as companies do, and rises;
      // what it pays its holders can't be worked out.
      expect(result.values['IR'], [80, 90, 100, 110]);
      expect(result.dividends['Ann'], [45, 45, 45]);
      expect(result.paid('Ben'), 45);
      expect(result.finalValues, {'AR': 140, 'IR': 110});
    });

    test('a company that withholds falls', () {
      final result = calc.run(EndGameSet(
        prices: {'IR': 80},
        revenue: {'IR': 100},
        withheld: {'IR'},
        rounds: 3,
      ));
      expect(result.values['IR'], [80, 75, 70, 65]);
      expect(result.paid('Ben'), 0);
    });

    test('a share value put right at one round carries on from there', () {
      final set = EndGameSet(
        prices: {'AR': 100},
        revenue: {'AR': 150},
        rounds: 3,
      )..correct(0, 'AR', 125);
      final result = calc.run(set);
      expect(result.values['AR'], [100, 125, 140, 155]);
      expect(result.correctedAt['AR'], {1});
      set.correct(0, 'AR', null);
      expect(calc.run(set).values['AR'], [100, 110, 125, 140]);
    });

    test("1807's companies move only for a payout of at least their value",
        () {
      final g1807 = GameTitle.byId('1807')!;
      final public = g1807.companies.firstWhere((c) => c.kind == 'public').id;
      final run = EndGame(g1807, const {}).run(EndGameSet(
        prices: {public: 100},
        revenue: {public: 90},
        rounds: 2,
      ));
      expect(run.values[public], [100, 100, 100]);
    });

    test("a title whose market isn't known: share values stay, unless a "
        'photo of the market gave one', () {
      final unknown = GameTitle(
        id: 'unknown',
        name: 'Unknown',
        description: '',
        map: g1889.map,
        tiles: const {},
        companies: g1889.companies,
      );
      final set = EndGameSet(prices: {'AR': 100}, revenue: {'AR': 50});
      final still = EndGame(unknown, holdings).run(set);
      expect(still.values['AR'], [100, 100]);
      expect(still.stuck, {'AR'});
      final photographed = EndGame(unknown, holdings, photographedMarket: [
        [90, 100, 110, 120],
      ]);
      expect(photographed.run(set).values['AR'], [100, 110]);
    });

    test('is kept with the game, with its holdings as they were', () {
      final session =
          GameSession.start(title: g1889, name: 'test', startedEmpty: true)
            ..cash['Ann'] = 500
            ..sharePrices['AR'] = 110
            ..shareStakes['IR'] = 5
            ..photographedMarket.add([90, 100]);
      session.endGameSets.add(EndGameSet(
        cash: {'Ann': 500},
        prices: {'AR': 100},
        holdings: holdings,
        revenue: {'AR': 150},
        withheld: {'IR'},
        rounds: 3,
      )..correct(1, 'AR', 140));
      final back = GameSession.fromJson(
          jsonDecode(jsonEncode(session.toJson())) as Map<String, Object?>);
      expect(back.cash, {'Ann': 500});
      expect(back.sharePrices, {'AR': 110});
      expect(back.shareStakes, {'IR': 5});
      expect(back.photographedMarket, [
        [90, 100],
      ]);
      final set = back.endGameSets.single;
      expect(set.cash, {'Ann': 500});
      expect(set.prices, {'AR': 100});
      expect(set.holdings, holdings);
      expect(set.revenue, {'AR': 150});
      expect(set.withheld, {'IR'});
      expect(set.rounds, 3);
      expect(set.correction(1, 'AR'), 140);
    });
  });
}
