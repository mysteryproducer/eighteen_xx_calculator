import 'company.dart';
import 'game_session.dart';
import 'game_title.dart';
import 'tile_definition.dart';

/// How many of a company's station tokens are where.
class TokenCount {
  /// How many the company has in all.
  final int total;
  final int onBoard;

  /// On its charter, if they have been counted.
  final int? onCharter;

  const TokenCount(
      {required this.total, required this.onBoard, this.onCharter});

  /// Tokens neither on the board nor on the charter: negative for more seen
  /// than the company has. Null until the charter has been counted.
  int? get missing => onCharter == null ? null : total - onBoard - onCharter!;
}

/// What a title's rules say about the companies' trains and tokens: the
/// checks behind the warnings when they are set or photographed.
class CompanyRules {
  final GameTitle title;

  const CompanyRules(this.title);

  /// The phase the game has reached, as far as the session can tell: the
  /// latest whose train any company is known to hold -- with [alsoSeen],
  /// trains just photographed, and leaving out what was noted for
  /// [except] -- or whose tiles are being laid.
  GamePhase? phase(
    GameSession session, {
    Iterable<String> alsoSeen = const [],
    String? except,
  }) {
    if (title.phases.isEmpty) return null;
    final bases = {
      for (final t in [
        for (final e in session.companyTrains.entries)
          if (e.key != except) ...e.value,
        ...alsoSeen,
      ])
        title.trainNamed(t)?.base ?? t,
    };
    var at = 0;
    for (int i = 0; i < title.phases.length; i++) {
      final phase = title.phases[i];
      if (phase.on != null && bases.contains(phase.on)) at = i;
      // Tiles of a colour no earlier phase allowed.
      if (session.phase != TileColor.yellow &&
          phase.tiles.contains(session.phase) &&
          (i == 0 || !title.phases[i - 1].tiles.contains(session.phase)) &&
          i > at) {
        at = i;
      }
    }
    return title.phases[at];
  }

  /// What is wrong with [company] owning [trains], in sentences: a train
  /// the title doesn't have, more than the phase allows, or one that a
  /// train seen with it -- its own, others in the same photo ([alsoSeen]),
  /// or another company's -- would already have scrapped.
  List<String> trainProblems(
    GameSession session,
    Company company,
    List<String> trains, {
    Iterable<String> alsoSeen = const [],
  }) {
    final problems = <String>[
      for (final name in trains.toSet())
        if (title.trains.isNotEmpty && title.trainNamed(name) == null)
          "There's no $name train in ${title.name}.",
    ];
    final phase = this.phase(session,
        alsoSeen: [...trains, ...alsoSeen], except: company.id);
    final limit = phase?.limitFor(company.kind);
    if (limit != null && trains.length > limit) {
      problems.add('${company.label} can own at most $limit '
          '${limit == 1 ? 'train' : 'trains'} in phase ${phase!.name}, not '
          '${trains.length}.');
    }
    for (final name in trains.toSet()) {
      final rustsOn = title.trainNamed(name)?.rustsOn;
      if (rustsOn == null) continue;
      bool scraps(String t) => (title.trainNamed(t)?.base ?? t) == rustsOn;
      final here = [...trains, ...alsoSeen].where(scraps).firstOrNull;
      final owner = session.companyTrains.entries
          .where((e) => e.key != company.id && e.value.any(scraps))
          .firstOrNull;
      if (here == null && owner == null) continue;
      final where = here != null
          ? 'alongside a $here'
          : 'now that ${title.companyById(owner!.key)?.label ?? owner.key} '
              'has a ${owner.value.firstWhere(scraps)}';
      problems.add('A $name train is scrapped when the first $rustsOn is '
          "bought, so it can't still be running $where.");
    }
    return problems;
  }

  /// Where [company]'s station tokens are: on the board (from the
  /// session's tokens) and, once counted, on its charter.
  TokenCount tokens(GameSession session, Company company) => TokenCount(
        total: company.tokenCount,
        onBoard: session.tokens.values.where((c) => c == company.id).length,
        onCharter: session.charterTokens[company.id],
      );

  /// What is wrong with [company] having [onCharter] tokens left on its
  /// charter, given the tokens the session has on the board: more than it
  /// has, or some unaccounted for.
  List<String> tokenCountProblems(
      GameSession session, Company company, int onCharter) {
    if (company.tokenCount == 0) return const [];
    final count = TokenCount(
      total: company.tokenCount,
      onBoard: tokens(session, company).onBoard,
      onCharter: onCharter,
    );
    final missing = count.missing!;
    final where = '${count.onBoard} on the board and $onCharter on its charter';
    if (missing > 0) {
      return [
        '${company.label} has ${count.total} tokens: $where leaves $missing '
            'unaccounted for. Is ${missing == 1 ? 'one' : 'one or more'} '
            'missing from the board?',
      ];
    }
    if (missing < 0) {
      return [
        '${company.label} has only ${count.total} tokens, not $where. Check '
            "the board's tokens.",
      ];
    }
    return const [];
  }

  /// What is wrong with [player] holding certificates of [percents] in
  /// [company]: a size the company doesn't print, more of one than it has,
  /// or more than all of it with what the other players hold.
  List<String> certificateProblems(GameSession session, Company company,
      String? player, List<int> percents) {
    final problems = <String>[];
    if (company.shares.isNotEmpty) {
      final printed = <int, int>{};
      for (final s in company.shares) {
        printed[s] = (printed[s] ?? 0) + 1;
      }
      final held = <int, int>{};
      for (final p in percents) {
        held[p] = (held[p] ?? 0) + 1;
      }
      for (final e in held.entries) {
        final have = printed[e.key] ?? 0;
        if (have == 0) {
          problems.add('${company.label} has no ${e.key}% certificate.');
        } else if (e.value > have) {
          problems.add('${company.label} has only $have ${e.key}% '
              '${have == 1 ? 'certificate' : 'certificates'}.');
        }
      }
    }
    final others = session.players
        .where((p) => p != player)
        .fold(0, (t, p) => t + session.percentHeld(p, company.id));
    final total = others + percents.fold(0, (t, p) => t + p);
    if (total > 100) {
      problems.add('With what the other players hold, that makes $total% of '
          '${company.label}.');
    }
    return problems;
  }

  /// What a player is paid when [company] pays out [revenue]: their share of
  /// it, rounded down. Half of it with [half], where the title allows that.
  int dividend(GameSession session, String player, String company,
      int revenue, {bool half = false}) {
    final paid = half ? revenue ~/ 2 : revenue;
    return paid * session.percentHeld(player, company) ~/ 100;
  }
}
