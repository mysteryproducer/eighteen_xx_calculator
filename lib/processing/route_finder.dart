import 'dart:math' as math;

import '../models/board_graph.dart';
import '../models/tile_definition.dart';

/// One candidate route: the stations visited in order, the track run between
/// them, and what it pays.
class RouteResult {
  final List<StationNode> stops;
  final List<TrackEdge> track;
  final int revenue;

  const RouteResult({
    required this.stops,
    required this.track,
    required this.revenue,
  });

  bool get isEmpty => stops.isEmpty;

  @override
  String toString() =>
      'Route(${stops.map((s) => s.id).join(' -> ')}, revenue: $revenue)';
}

/// Finds the highest-revenue run over a [BoardGraph].
///
/// This is deliberately rules-light: a route is any simple path (no station
/// visited twice, no stretch of track traversed twice) of at most [maxStops]
/// stations, scored by summed station revenue. A company's route can't run
/// through a city whose every circle holds another company's token (see
/// [StationNode.blocks]), though it can begin or end there. `maxStops` stands
/// in for train length; the real per-train rules (E/D trains, "+" trains that
/// count towns separately, group restrictions) are a later pass, and this
/// parameter is where they plug in.
class RouteFinder {
  /// Safety valves so a dense board can't hang the UI: the search returns the
  /// best route found so far once either limit is hit.
  static const int defaultSearchBudget = 200000;
  static const int maxArms = 5000;

  /// Best route that runs through [home], which every candidate must include.
  /// The route may extend in both directions from [home], as a real 18xx route
  /// does: it is built by finding the best pair of non-overlapping "arms"
  /// leading away from the home station. Given the [company] running it, the
  /// route stops at cities full of other companies' tokens.
  static RouteResult bestRouteThrough(
    BoardGraph graph,
    StationNode home,
    int maxStops, {
    String? company,
    int searchBudget = defaultSearchBudget,
  }) {
    if (maxStops < 1) {
      return const RouteResult(stops: [], track: [], revenue: 0);
    }

    var budget = searchBudget;
    final arms = <_Arm>[];

    // Enumerate every simple path leading away from `home`. Each such path is
    // one arm of a potential route; the recursion records an arm at every
    // station it reaches, not just at dead ends.
    void walk(
      StationNode current,
      Set<String> visitedStations,
      Set<String> usedTrack,
      List<StationNode> stops,
      List<TrackEdge> track,
      int revenue,
      TrackEdge? firstEdge,
    ) {
      if (budget-- <= 0 || arms.length >= maxArms) return;
      if (firstEdge != null) {
        arms.add(_Arm(
          firstEdge: firstEdge,
          stops: List.of(stops),
          track: List.of(track),
          revenue: revenue,
          stationIds: Set.of(visitedStations),
          trackIds: Set.of(usedTrack),
        ));
      }
      if (stops.length >= maxStops) return;
      // An off-board area ends a route; trains don't run through it.
      if (current.kind == StationKind.offboard && stops.length > 1) return;
      // Nor through a city full of other companies' tokens.
      if (company != null && stops.length > 1 && current.blocks(company)) {
        return;
      }

      for (final edge in graph.edgesFrom(current)) {
        final next = edge.to;
        if (visitedStations.contains(next.id)) continue;
        // No piece of track, and no hex side, twice.
        final pieces = _piecesOf(edge);
        if (pieces.any(usedTrack.contains)) continue;
        visitedStations.add(next.id);
        usedTrack.addAll(pieces);
        stops.add(next);
        track.add(edge);
        walk(next, visitedStations, usedTrack, stops, track,
            revenue + next.revenue, firstEdge ?? edge);
        visitedStations.remove(next.id);
        usedTrack.removeAll(pieces);
        stops.removeLast();
        track.removeLast();
      }
    }

    walk(home, {home.id}, <String>{}, [home], [], home.revenue, null);

    // A route that only runs one way out of the home station.
    var best = RouteResult(stops: [home], track: const [], revenue: home.revenue);
    for (final arm in arms) {
      if (arm.revenue > best.revenue) {
        best = RouteResult(stops: arm.stops, track: arm.track, revenue: arm.revenue);
      }
    }

    // A route that runs both ways: join the best pair of arms that share
    // nothing but the home station and together fit the stop limit.
    //
    // Sorting by revenue lets the search stop early: once the best arm still
    // available can't beat what we already have, neither can anything after it.
    arms.sort((x, y) => y.revenue.compareTo(x.revenue));
    for (int i = 0; i < arms.length; i++) {
      final a = arms[i];
      if (a.revenue + arms.first.revenue - home.revenue <= best.revenue) break;
      for (int j = i + 1; j < arms.length; j++) {
        final b = arms[j];
        if (a.revenue + b.revenue - home.revenue <= best.revenue) break;
        if (a.stops.length + b.stops.length - 1 > maxStops) continue;
        if (a.firstEdge.id == b.firstEdge.id) continue;
        if (a.stationIds.intersection(b.stationIds).length > 1) continue;
        if (a.trackIds.intersection(b.trackIds).isNotEmpty) continue;
        final revenue = a.revenue + b.revenue - home.revenue;
        if (revenue > best.revenue) {
          best = RouteResult(
            stops: [...a.stops.skip(1).toList().reversed, home, ...b.stops.skip(1)],
            track: [...a.track.reversed, ...b.track],
            revenue: revenue,
          );
        }
      }
    }

    return best;
  }

  /// Best route anywhere on the board, ignoring which stations a company has
  /// tokened. Useful before token recognition is wired up, or as a sanity
  /// check on what the map is worth.
  static RouteResult bestRouteAnywhere(
    BoardGraph graph,
    int maxStops, {
    int searchBudget = defaultSearchBudget,
  }) {
    var best = const RouteResult(stops: [], track: [], revenue: 0);
    if (graph.stations.isEmpty) return best;
    final perStation =
        math.max(1000, searchBudget ~/ math.max(1, graph.stations.length));
    for (final station in graph.stations) {
      final candidate =
          bestRouteThrough(graph, station, maxStops, searchBudget: perStation);
      if (candidate.revenue > best.revenue) best = candidate;
    }
    return best;
  }
}

/// The track [edge] uses: its tile segments and the sides it crosses, or
/// for an edge built without them, the edge itself.
List<String> _piecesOf(TrackEdge edge) =>
    edge.segments.isEmpty ? [edge.id] : edge.segments;

class _Arm {
  final TrackEdge firstEdge;
  final List<StationNode> stops;
  final List<TrackEdge> track;
  final int revenue;
  final Set<String> stationIds;
  final Set<String> trackIds;

  const _Arm({
    required this.firstEdge,
    required this.stops,
    required this.track,
    required this.revenue,
    required this.stationIds,
    required this.trackIds,
  });
}
