import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/models/stock_market.dart';
import 'package:flutter_test/flutter_test.dart';

/// The prices a share passes through moving [times] spaces right from
/// [price] on [title]'s market, one payout's worth at a time.
List<int> rightFrom(GameTitle title, int price, int times, {String? kind}) {
  final market = title.market;
  var spot = market.find(price)!;
  final prices = [price];
  for (int i = 0; i < times; i++) {
    spot = title.marketRules
        .move(market, spot, paid: 1000, price: market.at(spot)!.price, kind: kind);
    prices.add(market.at(spot)!.price);
  }
  return prices;
}

void main() {
  group('markets, as tobymao moves prices on them', () {
    final g1889 = GameTitle.byId('1889')!;

    test("1889's grid: along the row, and up off its end", () {
      expect(g1889.market.kind, MarketKind.grid);
      expect(rightFrom(g1889, 100, 3), [100, 110, 125, 140]);
      // 140 ends the fourth row; the next payout moves it up to 155.
      final end = (row: 3, col: 9);
      expect(g1889.market.at(end)!.price, 140);
      expect(g1889.market.at(g1889.market.right(end))!.price, 155);
    });

    test("1854's hex market: off a row's end, diagonally up", () {
      final g1854 = GameTitle.byId('1854')!;
      expect(g1854.market.kind, MarketKind.hex);
      final end = (row: 1, col: 15);
      expect(g1854.market.at(end)!.price, 200);
      expect(g1854.market.at(g1854.market.right(end))!.price, 230);
    });

    test("1807's single row: along it, and no further than its end", () {
      final g1807 = GameTitle.byId('1807')!;
      expect(g1807.market.kind, MarketKind.row);
      // tobymao's 500 between 540 and 660 is taken for the 600 it must be.
      expect(rightFrom(g1807, 540, 2), [540, 600, 660]);
      expect(rightFrom(g1807, 800, 1), [800, 800]);
    });

    test("1844's regionals stop short of the cells marked t", () {
      final g1844 = GameTitle.byId('1844')!;
      expect(rightFrom(g1844, 200, 1, kind: 'historical'), [200, 220]);
      // At the top, with no row above, a regional stays where it is.
      expect(rightFrom(g1844, 200, 1, kind: 'regional'), [200, 200]);
    });
  });

  group('how a payout moves a share price', () {
    test("tobymao's default: anything paid, a space right; nothing, left",
        () {
      const rules = MarketRules();
      expect(rules.movesFor(10, 100), 1);
      expect(rules.movesFor(1000, 100), 1);
      expect(rules.movesFor(0, 100), -1);
    });

    test("1807's: a payout of at least the share price, or no move", () {
      final rules = GameTitle.byId('1807')!.marketRules;
      expect(rules.movesFor(90, 100), 0);
      expect(rules.movesFor(100, 100), 1);
      expect(rules.movesFor(0, 100), -1);
    });

    test('a title can jump two, three or four spaces for larger payouts', () {
      // As 1846 and others do: under half the price, left; a whole price, a
      // space right; twice, two; and so on.
      const rules = MarketRules(payoutMoves: [
        (0.0, -1),
        (0.5, 0),
        (1.0, 1),
        (2.0, 2),
        (3.0, 3),
        (4.0, 4),
      ]);
      expect(rules.movesFor(40, 100), -1);
      expect(rules.movesFor(50, 100), 0);
      expect(rules.movesFor(150, 100), 1);
      expect(rules.movesFor(250, 100), 2);
      expect(rules.movesFor(300, 100), 3);
      expect(rules.movesFor(450, 100), 4);
      final g1889 = GameTitle.byId('1889')!;
      final market = g1889.market;
      final moved = rules.move(market, market.find(100)!, paid: 450, price: 100);
      expect(market.at(moved)!.price, 155);
    });
  });
}
