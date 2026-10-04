import 'company.dart';
import 'game_title.dart';
import 'stock_market.dart';

/// One end game OR set: the last operating rounds of a game, up to three, run
/// by themselves on a board that won't change any more. Each company runs its
/// trains for what they earn and pays it all out, every round -- unless it is
/// set to withhold -- its share value moving as the title's market says, or
/// as the user corrects it. A set starts from the game as it stands (cash,
/// share values, who holds what), kept with it; once kept, its results carry
/// on into the game, so stock rounds can be played before the next.
class EndGameSet {
  final DateTime created;

  /// Each player's cash as the set starts.
  final Map<String, int> cash;

  /// Each company's share value as the set starts.
  final Map<String, int> prices;

  /// The certificates each player holds as the set starts (see
  /// `GameSession.holdings`).
  final Map<String, Map<String, List<int>>> holdings;

  /// How many operating rounds the set runs, 1 to [maxRounds].
  int rounds;

  /// What each company earns in a round, paid out in full.
  final Map<String, int> revenue;

  /// Companies that withhold rather than pay out, their share values falling.
  final Set<String> withheld;

  /// Share values the user has put right, after each round (by round, from
  /// 0, then company): what follows is worked out from them.
  final List<Map<String, int>> corrected;

  static const int maxRounds = 3;

  EndGameSet({
    DateTime? created,
    Map<String, int>? cash,
    Map<String, int>? prices,
    Map<String, Map<String, List<int>>>? holdings,
    this.rounds = 1,
    Map<String, int>? revenue,
    Set<String>? withheld,
    List<Map<String, int>>? corrected,
  })  : created = created ?? DateTime.now(),
        cash = cash ?? {},
        prices = prices ?? {},
        holdings = holdings ?? {},
        revenue = revenue ?? {},
        withheld = withheld ?? {},
        corrected = corrected ?? [];

  /// The share value the user set for [company] after round [round] (from
  /// 0), if they did.
  int? correction(int round, String company) =>
      round < corrected.length ? corrected[round][company] : null;

  /// Puts right [company]'s share value after round [round]; null takes the
  /// correction back.
  void correct(int round, String company, int? value) {
    while (corrected.length <= round) {
      corrected.add({});
    }
    if (value == null) {
      corrected[round].remove(company);
    } else {
      corrected[round][company] = value;
    }
  }

  Map<String, Object?> toJson() => {
        'created': created.toIso8601String(),
        'cash': cash,
        'prices': prices,
        'holdings': holdings,
        'rounds': rounds,
        'revenue': revenue,
        if (withheld.isNotEmpty) 'withheld': withheld.toList()..sort(),
        if (corrected.any((c) => c.isNotEmpty)) 'corrected': corrected,
      };

  static Map<String, int> _ints(Object? json) => {
        for (final e in (json as Map? ?? {}).entries)
          '${e.key}': (e.value as num).toInt(),
      };

  factory EndGameSet.fromJson(Map<String, Object?> json) => EndGameSet(
        created: DateTime.tryParse(json['created'] as String? ?? ''),
        cash: _ints(json['cash']),
        prices: _ints(json['prices']),
        holdings: {
          for (final e in (json['holdings'] as Map? ?? {}).entries)
            '${e.key}': {
              for (final h in (e.value as Map).entries)
                '${h.key}': [for (final p in h.value as List) (p as num).toInt()],
            },
        },
        rounds: ((json['rounds'] as num?)?.toInt() ?? 1).clamp(1, maxRounds),
        revenue: _ints(json['revenue']),
        withheld: {for (final c in json['withheld'] as List? ?? const []) '$c'},
        corrected: [for (final c in json['corrected'] as List? ?? const []) _ints(c)],
      );
}

/// An end game OR set worked through: each company's share value after each
/// round, and what each player is paid.
class EndGameResult {
  /// Each company's share value as the set starts and after each round.
  final Map<String, List<int>> values;

  /// Rounds (from 1; 0 is the start) where the user put a company's value
  /// right rather than it being worked out.
  final Map<String, Set<int>> correctedAt;

  /// What each player is paid in each round.
  final Map<String, List<int>> dividends;

  /// Companies whose share value the market can't move: it isn't on it, or
  /// there is no market to move it on.
  final Set<String> stuck;

  const EndGameResult({
    required this.values,
    required this.correctedAt,
    required this.dividends,
    required this.stuck,
  });

  /// What [player] has been paid over the set.
  int paid(String player) =>
      (dividends[player] ?? const []).fold(0, (total, d) => total + d);

  /// Each company's share value at the end of the set.
  Map<String, int> get finalValues => {
        for (final e in values.entries) e.key: e.value.last,
      };
}

/// What players are worth, and end game OR sets worked out, for a title.
class EndGame {
  final GameTitle title;

  /// The share certificates each player holds: by player, by company id, the
  /// percentage on each certificate (see `GameSession.holdings`).
  final Map<String, Map<String, List<int>>> holdings;

  /// The market as a photo of it read, row by row, for a title whose market
  /// the app doesn't know (see `GameSession.photographedMarket`).
  final List<List<int>> photographedMarket;

  /// The percentage a share of a company is, by company id, where it isn't
  /// the company's smallest certificate (see `GameSession.shareStakes`).
  final Map<String, int> stakes;

  const EndGame(this.title, this.holdings,
      {this.photographedMarket = const [], this.stakes = const {}});

  Company? _company(String id) => title.companyById(id);

  /// The share of [company] that [player] holds, in percent.
  int percentHeld(String player, String company) =>
      (holdings[player]?[company] ?? const <int>[])
          .fold(0, (total, share) => total + share);

  /// How many shares [percent] of [company] is: in shares of its stake, the
  /// smallest certificate unless [stakes] says otherwise (10% for most, 25%
  /// for 1844's pre-SBB companies).
  double shares(String company, int percent) =>
      percent / (stakes[company] ?? _company(company)?.shareUnit ?? 10);

  /// What [player]'s shares are worth at [values], each at its company's
  /// share value.
  int sharesWorth(String player, Map<String, int> values) {
    var total = 0.0;
    for (final e in (holdings[player] ?? const <String, List<int>>{}).entries) {
      final value = values[e.key];
      if (value == null) continue;
      total += shares(e.key, percentHeld(player, e.key)) * value;
    }
    return total.round();
  }

  /// What [player] is worth with [cash] and their shares at [values].
  int worth(String player, {required int cash, required Map<String, int> values}) =>
      cash + sharesWorth(player, values);

  /// What [player] is paid when [company] pays out [revenue]: their share of
  /// it, rounded up, as tobymao pays each holder -- of what a minor pays its
  /// owner, where it is a minor (see `MarketRules.minorPayout`).
  int dividend(String player, String company, int revenue) {
    final percent = percentHeld(player, company);
    if (percent <= 0 || revenue <= 0) return 0;
    final paid = _company(company)?.kind == 'minor'
        ? (revenue * title.marketRules.minorPayout).floor()
        : revenue;
    return (paid * percent + 99) ~/ 100;
  }

  /// The market share values move on: the title's, or failing that the one
  /// a photo of it gave.
  StockMarket get market => !title.market.isEmpty
      ? title.market
      : StockMarket([
          for (final row in photographedMarket)
            [for (final price in row) MarketCell(price)],
        ]);

  /// Works [set] through, round by round, with the certificates [holdings]
  /// says. A company pays out unless it withholds: one whose takings aren't
  /// known yet still moves up as a payout does -- a space, by default --
  /// though what it pays its holders can't be worked out.
  EndGameResult run(EndGameSet set) {
    final market = this.market;
    final companies = {...set.prices.keys, ...set.revenue.keys};
    final values = {
      for (final c in companies)
        if (set.prices[c] case final price?) c: [price],
    };
    final correctedAt = <String, Set<int>>{};
    final stuck = <String>{};
    final players = holdings.keys.toList();
    final dividends = {for (final p in players) p: <int>[]};
    int paidOut(String c) =>
        set.withheld.contains(c) ? 0 : set.revenue[c] ?? 0;
    for (int round = 0; round < set.rounds; round++) {
      for (final p in players) {
        dividends[p]!.add([
          for (final c in companies) dividend(p, c, paidOut(c)),
        ].fold(0, (total, d) => total + d));
      }
      for (final c in values.keys) {
        final path = values[c]!;
        final now = path.last;
        final fixed = set.correction(round, c);
        if (fixed != null) {
          path.add(fixed);
          (correctedAt[c] ??= {}).add(round + 1);
          continue;
        }
        final company = _company(c);
        final spot = market.find(now);
        // A minor has no share value to move; nor has a price off the
        // market, or a market the app doesn't know.
        if (spot == null || company?.kind == 'minor') {
          if (company?.kind != 'minor') stuck.add(c);
          path.add(now);
          continue;
        }
        final paid = set.withheld.contains(c)
            ? 0
            : (set.revenue[c] ?? 0) > 0
                ? set.revenue[c]!
                : now;
        final next = title.marketRules
            .move(market, spot, paid: paid, price: now, kind: company?.kind);
        path.add(market.at(next)?.price ?? now);
      }
    }
    return EndGameResult(
      values: values,
      correctedAt: correctedAt,
      dividends: dividends,
      stuck: stuck,
    );
  }
}
