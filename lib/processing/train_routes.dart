import 'dart:math' as math;
import 'dart:typed_data';

import '../models/board_graph.dart';
import '../models/game_title.dart';
import '../models/tile_definition.dart';
import 'route_finder.dart';

/// One part of what a route earns besides its stops, and why.
class RouteBonus {
  final String reason;
  final int amount;

  const RouteBonus(this.reason, this.amount);

  @override
  String toString() => '$reason: $amount';
}

/// One train's run.
class TrainRun {
  /// The train's name, as the title has it.
  final String train;

  /// The stops in the order the train runs them, and the track between:
  /// empty when it has nowhere to run.
  final List<StationNode> stops;
  final List<TrackEdge> track;

  /// The stops it is paid for: all of them, except for an express, which
  /// is paid for its best few.
  final List<StationNode> paid;

  /// What the route earns besides its stops: running over tunnel track,
  /// joining two off-board groups. [bonuses] says how it adds up.
  final int bonus;
  final List<RouteBonus> bonuses;

  final int revenue;

  const TrainRun({
    required this.train,
    required this.stops,
    required this.track,
    required this.paid,
    required this.bonus,
    required this.revenue,
    this.bonuses = const [],
  });

  const TrainRun.idle(this.train)
      : stops = const [],
        track = const [],
        paid = const [],
        bonus = 0,
        bonuses = const [],
        revenue = 0;

  /// The stops it visits but isn't paid for: an express's beyond its best
  /// few.
  List<StationNode> get unpaid => [
        for (final s in stops)
          if (!paid.contains(s)) s,
      ];

  bool get runs => stops.isNotEmpty;

  RouteResult get route =>
      RouteResult(stops: stops, track: track, revenue: revenue);

  @override
  String toString() =>
      '$train: ${stops.map((s) => s.id).join(' -> ')} = $revenue';
}

/// What a company's trains earn between them, and how: a run for each
/// train, in the order the trains were given.
class CompanyRuns {
  final List<TrainRun> runs;

  /// False when the search reached its limits and settled for the best it
  /// had found.
  final bool complete;

  const CompanyRuns(this.runs, {this.complete = true});

  int get revenue => runs.fold(0, (t, r) => t + r.revenue);
}

/// Finds the best runs for a company's trains together: each train its own
/// route, no two sharing any track, every route through a city holding one
/// of the company's tokens.
///
/// Trains run as their title says (see [TrainType]): so many stops (towns
/// left out of the count for 1854's "+" trains), so many hexes (1844's H
/// trains, which can't reach red off-board areas), or any number of stops
/// paid for the best few (an express, one of them a city the company has a
/// token in). Routes earn the title's bonuses ([RouteRules]). As with
/// [RouteFinder], a route can't run through a city full of other
/// companies' tokens, or through an off-board area, though either can end
/// it.
class TrainRouter {
  final GameTitle title;
  final BoardGraph graph;
  final String company;

  TrainRouter(this.title, this.graph, this.company) {
    for (int i = 0; i < graph.stations.length; i++) {
      _stationIndex[graph.stations[i].id] = i;
      _hexIds[graph.stations[i].id] = title.map.at(graph.stations[i].hex)?.id;
    }
    final segmentIndex = <String, int>{};
    for (final edges in graph.adjacency.values) {
      for (final edge in edges) {
        for (final s in edge.segments) {
          segmentIndex.putIfAbsent(s, () => segmentIndex.length);
        }
      }
    }
    _stationWords = (graph.stations.length + 31) >> 5;
    _segmentWords = (segmentIndex.length + 31) >> 5;
    for (final edges in graph.adjacency.values) {
      for (final edge in edges) {
        final bits = Uint32List(_segmentWords);
        for (final s in edge.segments) {
          _set(bits, segmentIndex[s]!);
        }
        _edgeBits[edge] = bits;
      }
    }
  }

  /// How much searching one train's routes may take -- steps along track
  /// and pairs of half-routes tried -- before settling for the best found.
  static const int defaultBudget = 1500000;

  /// How many of each train's best routes are kept to fit together.
  static const int _keep = 300;

  /// The most half-routes kept out of one city.
  static const int _maxArms = 6000;

  /// The most combinations of routes tried.
  static const int _maxCombinations = 2000000;

  final Map<String, int> _stationIndex = {};
  final Map<String, String?> _hexIds = {};
  final Map<TrackEdge, Uint32List> _edgeBits = Map.identity();
  final Map<String, List<TrackEdge>> _sortedEdges = {};
  late final int _stationWords;
  late final int _segmentWords;
  bool _cutShort = false;

  /// The best the company can do with [trains] (names from the title), a
  /// run for each.
  CompanyRuns best(List<String> trains, {int budget = defaultBudget}) {
    _cutShort = false;
    final homes = graph.stations.where((s) => s.holds(company)).toList();
    final specs = [for (final t in trains) _Spec.of(title, t)];
    if (homes.isEmpty || specs.every((s) => s == null)) {
      return CompanyRuns([for (final t in trains) TrainRun.idle(t)]);
    }
    final pools = <String, List<_Candidate>>{};
    for (final spec in specs.nonNulls) {
      pools[spec.name] ??=
          _candidates(spec, homes, keep: _keep, budget: _Budget(budget));
    }
    List<_Candidate> poolOf(int i) =>
        specs[i] == null ? const [] : pools[specs[i]!.name]!;

    // Trains with the best routes first, so the bound bites early; the
    // same trains side by side, so each pair of their routes is tried
    // only one way round.
    final order = [for (int i = 0; i < trains.length; i++) i]
      ..sort((a, b) {
        final pa = poolOf(a), pb = poolOf(b);
        final by = (pb.isEmpty ? 0 : pb.first.revenue)
            .compareTo(pa.isEmpty ? 0 : pa.first.revenue);
        return by != 0 ? by : trains[a].compareTo(trains[b]);
      });
    var picked = _combine([for (final i in order) poolOf(i)]);
    var total = picked.fold(0, (t, c) => t + (c?.revenue ?? 0));

    // Each train's best few hundred routes can all lean on the same busy
    // stretch of track, leaving nothing apart for the next. So also let
    // the trains choose in turn, each from whatever track the others have
    // left it.
    for (final turn in _turns(order, trains)) {
      final excluded = Uint32List(_segmentWords);
      final chosen = List<_Candidate?>.filled(order.length, null);
      var sum = 0;
      for (final i in turn) {
        final spec = specs[i];
        if (spec == null) continue;
        final found = _candidates(spec, homes,
            keep: 1, budget: _Budget(budget), excluded: excluded);
        if (found.isEmpty) continue;
        chosen[order.indexOf(i)] = found.first;
        sum += found.first.revenue;
        _orInto(excluded, found.first.segments);
      }
      if (sum > total) {
        total = sum;
        picked = chosen;
      }
    }

    final runs = List<TrainRun>.generate(
        trains.length, (i) => TrainRun.idle(trains[i]));
    for (int k = 0; k < order.length; k++) {
      final c = picked[k];
      if (c != null) {
        runs[order[k]] = c.run(trains[order[k]], _bonusesOf(c.paid, c.track));
      }
    }
    return CompanyRuns(runs, complete: !_cutShort);
  }

  /// The orders the trains take turns choosing in: every one for up to
  /// three trains, otherwise longest first and shortest first.
  List<List<int>> _turns(List<int> order, List<String> trains) {
    if (order.length < 2) return const [];
    final seen = <String>{};
    final turns = <List<int>>[];
    void add(List<int> turn) {
      if (seen.add(turn.map((i) => trains[i]).join(','))) turns.add(turn);
    }

    if (order.length <= 3) {
      void permute(List<int> done, List<int> left) {
        if (left.isEmpty) return add(done);
        for (int i = 0; i < left.length; i++) {
          permute([...done, left[i]], [...left]..removeAt(i));
        }
      }

      permute([], order);
    } else {
      add(order);
      add(order.reversed.toList());
    }
    return turns;
  }

  /// The best pick of one route (or none) from each pool, no two sharing
  /// track: branch and bound over the pools, best routes first.
  List<_Candidate?> _combine(List<List<_Candidate>> pools) {
    final n = pools.length;
    final rest = List<int>.filled(n + 1, 0);
    for (int k = n - 1; k >= 0; k--) {
      rest[k] = rest[k + 1] + (pools[k].isEmpty ? 0 : pools[k].first.revenue);
    }
    var bestTotal = -1;
    var best = List<_Candidate?>.filled(n, null);
    final pick = List<_Candidate?>.filled(n, null);
    final picked = List<int>.filled(n, -1);
    var steps = 0;

    void search(int k, Uint32List used, int total) {
      if (++steps > _maxCombinations) {
        _cutShort = true;
        return;
      }
      if (k == n) {
        if (total > bestTotal) {
          bestTotal = total;
          best = List.of(pick);
        }
        return;
      }
      if (total + rest[k] <= bestTotal) return;
      // A train the same as the one before picks a later route than it
      // did, and runs only if it ran.
      final same = k > 0 && identical(pools[k], pools[k - 1]);
      if (!same || picked[k - 1] >= 0) {
        final pool = pools[k];
        for (int c = same ? picked[k - 1] + 1 : 0; c < pool.length; c++) {
          final candidate = pool[c];
          if (total + candidate.revenue + rest[k + 1] <= bestTotal) break;
          if (_overlap(candidate.segments, used)) continue;
          pick[k] = candidate;
          picked[k] = c;
          final now = Uint32List.fromList(used);
          _orInto(now, candidate.segments);
          search(k + 1, now, total + candidate.revenue);
        }
      }
      pick[k] = null;
      picked[k] = -1;
      search(k + 1, used, total);
    }

    search(0, Uint32List(_segmentWords), 0);
    return best;
  }

  /// [spec]'s best routes -- up to [keep] of them, best first, each through
  /// one of [homes] -- that keep off [excluded] track.
  List<_Candidate> _candidates(
    _Spec spec,
    List<StationNode> homes, {
    required int keep,
    required _Budget budget,
    Uint32List? excluded,
  }) {
    final found = <_Candidate>[];
    final seen = <String>{};
    // Once [keep] are found, what a route has to beat to be worth keeping.
    var threshold = -1;
    void offer(_Candidate c) {
      if (c.revenue <= threshold || !seen.add(c.key)) return;
      found.add(c);
      if (found.length >= keep * 2) {
        found.sort((a, b) => b.revenue.compareTo(a.revenue));
        found.length = keep;
        threshold = found.last.revenue;
      }
    }

    final cap = _bonusCap(spec);
    for (final home in homes) {
      if (!_canVisit(spec, home)) continue;
      final homeCounts = _counts(spec, home) ? 1 : 0;
      final arms = _armsFrom(home, spec, excluded, budget)
        ..sort((a, b) => b.best.compareTo(a.best));
      for (final a in arms) {
        offer(_score(spec, home, a, null));
      }
      // Two half-routes out of the city make a route through it.
      outer:
      for (int i = 0; i + 1 < arms.length; i++) {
        final a = arms[i];
        if (a.best + arms[i + 1].best + spec.earns(home) + cap <= threshold) {
          break;
        }
        for (int j = i + 1; j < arms.length; j++) {
          final b = arms[j];
          if (a.best + b.best + spec.earns(home) + cap <= threshold) break;
          if (!budget.take()) {
            _cutShort = true;
            break outer;
          }
          final fits = spec.kind == TrainKind.hexes
              ? 1 + a.hexes + b.hexes <= spec.distance
              : homeCounts + a.counted + b.counted <= spec.distance;
          if (!fits ||
              _overlap(a.stations, b.stations) ||
              _overlap(a.segments, b.segments)) {
            continue;
          }
          offer(_score(spec, home, a, b));
        }
      }
    }
    found.sort((a, b) => b.revenue.compareTo(a.revenue));
    if (found.length > keep) found.length = keep;
    return found;
  }

  /// Every way out of [home] a route through it could run on one side:
  /// stops along track not already used, within the train's reach.
  List<_Arm> _armsFrom(
    StationNode home,
    _Spec spec,
    Uint32List? excluded,
    _Budget budget,
  ) {
    final arms = <_Arm>[];
    final stops = <StationNode>[];
    final track = <TrackEdge>[];
    final stations = Uint32List(_stationWords);
    final segments = Uint32List(_segmentWords);
    final homeCounts = _counts(spec, home) ? 1 : 0;

    void walk(StationNode current, int counted, int hexes, bool narrow) {
      if (stops.isNotEmpty) {
        arms.add(_Arm(
          stops: List.of(stops),
          track: List.of(track),
          best: _armBest(spec, stops),
          counted: counted,
          hexes: hexes,
          stations: Uint32List.fromList(stations),
          segments: Uint32List.fromList(segments),
          narrow: narrow,
        ));
        // Off-board areas and full cities end a route.
        if (current.kind == StationKind.offboard || current.blocks(company)) {
          return;
        }
      }
      for (final edge in _edgesFrom(current)) {
        if (arms.length >= _maxArms) {
          _cutShort = true;
          return;
        }
        if (!budget.take()) {
          _cutShort = true;
          return;
        }
        final next = edge.to;
        final n = _stationIndex[next.id]!;
        if (identical(next, home) || _has(stations, n)) continue;
        if (!_canVisit(spec, next)) continue;
        final bits = _edgeBits[edge]!;
        if (_overlap(bits, segments) ||
            (excluded != null && _overlap(bits, excluded))) {
          continue;
        }
        final nowCounted = counted + (_counts(spec, next) ? 1 : 0);
        final nowHexes = hexes + edge.hexSteps;
        final within = spec.kind == TrainKind.hexes
            ? 1 + nowHexes <= spec.distance
            : homeCounts + nowCounted <= spec.distance;
        if (!within) continue;
        _set(stations, n);
        _orInto(segments, bits);
        stops.add(next);
        track.add(edge);
        walk(next, nowCounted, nowHexes, narrow || edge.narrow);
        stops.removeLast();
        track.removeLast();
        _clear(stations, n);
        _clearFrom(segments, bits);
      }
    }

    walk(home, 0, 0, false);
    return arms;
  }

  /// The most a half-route can add to a route's stops: everything it
  /// visits, except for an express, which is paid for no more than its best
  /// few (and its red off-boards).
  int _armBest(_Spec spec, List<StationNode> stops) {
    var sum = 0;
    if (spec.kind != TrainKind.express) {
      for (final s in stops) {
        sum += spec.earns(s);
      }
      return sum;
    }
    final others = <int>[];
    for (final s in stops) {
      if (s.color == TileColor.red) {
        sum += spec.earns(s);
      } else {
        others.add(spec.earns(s));
      }
    }
    others.sort((a, b) => b.compareTo(a));
    for (final r in others.take(spec.pays!)) {
      sum += r;
    }
    return sum;
  }

  /// The route through [home] along [a], and [b] if given, and what it pays.
  _Candidate _score(_Spec spec, StationNode home, _Arm a, _Arm? b) {
    final stops = b == null
        ? [home, ...a.stops]
        : [...a.stops.reversed, home, ...b.stops];
    final track = b == null ? a.track : [...a.track.reversed, ...b.track];
    final paid =
        spec.kind == TrainKind.express ? _expressPaid(spec, stops) : stops;
    var revenue = 0;
    for (final s in paid) {
      revenue += spec.earns(s);
    }
    var bonus = _pairBonus(paid);
    if (a.narrow || (b?.narrow ?? false)) {
      bonus += title.routeRules.narrowBonus * paid.length;
    }
    final segments = Uint32List.fromList(a.segments);
    if (b != null) _orInto(segments, b.segments);
    return _Candidate(
      stops: stops,
      track: track,
      paid: paid,
      bonus: bonus,
      revenue: revenue + bonus,
      segments: segments,
    );
  }

  /// The stops an express is paid for, as tobymao picks them: its best
  /// few, one of them a city the company has a token in, and then any red
  /// off-board areas left over.
  List<StationNode> _expressPaid(_Spec spec, List<StationNode> stops) {
    final pays = spec.pays!;
    if (stops.length <= pays) return stops;
    final byRevenue = [...stops]
      ..sort((a, b) => spec.earns(b).compareTo(spec.earns(a)));
    final paid = byRevenue.sublist(0, pays);
    final rest = byRevenue.sublist(pays);
    if (!paid.any((s) => s.holds(company))) {
      paid.removeLast();
      final tokened = rest.where((s) => s.holds(company)).firstOrNull;
      if (tokened != null) paid.add(tokened);
    }
    paid.addAll(rest.where((s) => s.color == TileColor.red));
    return paid;
  }

  /// How a route's bonus adds up, for the user to see: tunnel track at so
  /// much a stop, and each pair of off-board groups it joins, with what
  /// each area pays.
  List<RouteBonus> _bonusesOf(
      List<StationNode> paid, List<TrackEdge> track) {
    final rules = title.routeRules;
    final bonuses = <RouteBonus>[];
    if (rules.narrowBonus > 0 && track.any((e) => e.narrow)) {
      bonuses.add(RouteBonus(
          'Tunnel track: ${rules.narrowBonus} for each of the '
          '${paid.length} stops paid for',
          rules.narrowBonus * paid.length));
    }
    final groups = {
      for (final s in paid) ...?title.stopGroups[_hexIds[s.id]],
    };
    String nameOf(StationNode s) {
      final hex = title.map.at(s.hex);
      return hex?.name ?? hex?.id ?? '${s.hex}';
    }

    for (final (one, other) in rules.bonusPairs) {
      if (!groups.contains(one) || !groups.contains(other)) continue;
      final paying = [
        for (final s in paid)
          if ((title.groupBonus[_hexIds[s.id]] ?? 0) > 0) s,
      ];
      bonuses.add(RouteBonus(
          '${_groupWord(one)} to ${_groupWord(other).toLowerCase()}: '
          '${paying.map((s) => '${nameOf(s)} ${title.groupBonus[_hexIds[s.id]]}').join(' + ')}',
          paying.fold(0, (t, s) => t + title.groupBonus[_hexIds[s.id]]!)));
    }
    return bonuses;
  }

  static String _groupWord(String group) => switch (group) {
        'E' => 'East',
        'W' => 'West',
        'N' => 'North',
        'S' => 'South',
        _ => group,
      };

  /// What joining two off-board groups earns (1844's east-west and
  /// north-south runs): every bonus the route's stops pay, for each pair
  /// of groups it joins.
  int _pairBonus(List<StationNode> paid) {
    final pairs = title.routeRules.bonusPairs;
    if (pairs.isEmpty) return 0;
    final groups = {
      for (final s in paid) ...?title.stopGroups[_hexIds[s.id]],
    };
    var bonus = 0;
    for (final (one, other) in pairs) {
      if (!groups.contains(one) || !groups.contains(other)) continue;
      for (final s in paid) {
        bonus += title.groupBonus[_hexIds[s.id]] ?? 0;
      }
    }
    return bonus;
  }

  /// The most bonuses could add to any route of [spec]'s, for the bound
  /// that stops the search trying routes that can't make the cut.
  int _bonusCap(_Spec spec) {
    final rules = title.routeRules;
    var cap = 0;
    if (rules.narrowBonus > 0) {
      final reds =
          graph.stations.where((s) => s.color == TileColor.red).length;
      final most = switch (spec.kind) {
        TrainKind.express => spec.pays! + reds,
        TrainKind.hexes => 2 * spec.distance,
        TrainKind.stops => spec.freeTowns ? graph.stations.length : spec.distance,
      };
      cap += rules.narrowBonus * math.min(most, graph.stations.length);
    }
    int mostIn(String group) {
      var most = 0;
      title.stopGroups.forEach((hex, groups) {
        if (groups.contains(group)) {
          most = math.max(most, title.groupBonus[hex] ?? 0);
        }
      });
      return most;
    }

    for (final (one, other) in rules.bonusPairs) {
      cap += mostIn(one) + mostIn(other);
    }
    return cap;
  }

  /// Whether a train of [spec]'s may stop at [station] at all.
  bool _canVisit(_Spec spec, StationNode station) {
    if (title.routeRules.noEmptyStops && spec.earns(station) <= 0) {
      return false;
    }
    if (spec.kind == TrainKind.hexes && station.color == TileColor.red) {
      return false;
    }
    return true;
  }

  /// Whether [station] counts towards [spec]'s reach in stops.
  bool _counts(_Spec spec, StationNode station) =>
      !(spec.freeTowns && station.kind == StationKind.town);

  /// The track out of [station], richest stop first, so a search cut short
  /// has tried the likeliest routes.
  List<TrackEdge> _edgesFrom(StationNode station) => _sortedEdges.putIfAbsent(
      station.id,
      () => [...graph.edgesFrom(station)]
        ..sort((a, b) => b.to.revenue.compareTo(a.to.revenue)));

  static bool _has(Uint32List bits, int i) => bits[i >> 5] & (1 << (i & 31)) != 0;

  static void _set(Uint32List bits, int i) => bits[i >> 5] |= 1 << (i & 31);

  static void _clear(Uint32List bits, int i) =>
      bits[i >> 5] &= ~(1 << (i & 31));

  static bool _overlap(Uint32List a, Uint32List b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i] & b[i] != 0) return true;
    }
    return false;
  }

  static void _orInto(Uint32List into, Uint32List bits) {
    for (int i = 0; i < into.length; i++) {
      into[i] |= bits[i];
    }
  }

  static void _clearFrom(Uint32List from, Uint32List bits) {
    for (int i = 0; i < from.length; i++) {
      from[i] &= ~bits[i];
    }
  }
}

/// How a train runs, from its title's description of it.
class _Spec {
  final String name;
  final TrainKind kind;
  final int distance;
  final int? pays;
  final bool freeTowns;

  /// A D train, which some stops pay more (see `StationNode.revenueFor`).
  final bool diesel;

  _Spec(this.name, this.kind, this.distance,
      {this.pays, this.freeTowns = false})
      : diesel = name.toUpperCase() == 'D';

  /// What a stop pays this train.
  int earns(StationNode s) => diesel ? s.revenueFor(name) : s.revenue;

  /// The train called [name], or for a title that doesn't list it, a train
  /// of as many stops as the number it starts with.
  static _Spec? of(GameTitle title, String name) {
    final type = title.trainNamed(name);
    if (type != null) {
      return _Spec(name, type.kind, type.distance,
          pays: type.pays, freeTowns: type.freeTowns);
    }
    final number = int.tryParse(RegExp(r'^\d+').stringMatch(name) ?? '');
    if (number != null) {
      return _Spec(name, TrainKind.stops, number,
          freeTowns: name.endsWith('+'));
    }
    if (name == 'D') return _Spec(name, TrainKind.stops, 999);
    return null;
  }
}

/// Half a route: the stops out of a city one way, and what they could be
/// worth.
class _Arm {
  final List<StationNode> stops;
  final List<TrackEdge> track;
  final int best;
  final int counted;
  final int hexes;
  final Uint32List stations;
  final Uint32List segments;
  final bool narrow;

  const _Arm({
    required this.stops,
    required this.track,
    required this.best,
    required this.counted,
    required this.hexes,
    required this.stations,
    required this.segments,
    required this.narrow,
  });
}

/// A whole route for one train, and what it pays.
class _Candidate {
  final List<StationNode> stops;
  final List<TrackEdge> track;
  final List<StationNode> paid;
  final int bonus;
  final int revenue;
  final Uint32List segments;

  _Candidate({
    required this.stops,
    required this.track,
    required this.paid,
    required this.bonus,
    required this.revenue,
    required this.segments,
  });

  /// The same track makes the same route, whichever way round it was
  /// found.
  late final String key = segments.join(',');

  TrainRun run(String train, [List<RouteBonus> bonuses = const []]) =>
      TrainRun(
        train: train,
        stops: stops,
        track: track,
        paid: paid,
        bonus: bonus,
        revenue: revenue,
        bonuses: bonuses,
      );
}

class _Budget {
  int _left;

  _Budget(this._left);

  bool take() => --_left >= 0;
}
