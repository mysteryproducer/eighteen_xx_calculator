// Runs every company's trains on a saved game's board and prints what they
// would earn and how long the search took, for checking the route search
// against real boards.
//
//   ROUTE_SESSION=/path/to/session.json ROUTE_TRAINS=5,5 \
//     flutter test test/session_routes_test.dart
//
// ROUTE_TRAINS defaults to each company's trains as the session has them.
// Skipped when ROUTE_SESSION isn't set.
import 'dart:convert';
import 'dart:io';

import 'package:eighteen_xx_calculator/models/game_session.dart';
import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/train_routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final saved = Platform.environment['ROUTE_SESSION'];
  test('runs every company on a saved board', () {
    final session = GameSession.fromJson(
        jsonDecode(File(saved!).readAsStringSync()) as Map<String, Object?>);
    final title = GameTitle.byId(session.titleId)!;
    final graph = session.graph(title);
    final given = Platform.environment['ROUTE_TRAINS']?.split(',');
    for (final company in title.companies) {
      final trains = given ?? session.companyTrains[company.id] ?? const [];
      if (trains.isEmpty ||
          !graph.stations.any((s) => s.holds(company.id))) {
        continue;
      }
      final watch = Stopwatch()..start();
      final runs = TrainRouter(title, graph, company.id).best(trains);
      // ignore: avoid_print
      print('${company.label} ${trains.join('+')}: ${runs.revenue} in '
          '${watch.elapsedMilliseconds} ms${runs.complete ? '' : ' (cut short)'}');
      for (final run in runs.runs) {
        // ignore: avoid_print
        print('  ${run.train}: ${run.stops.map((s) => '${title.map.at(s.hex)?.id}'
            '(${s.revenue})').join(' - ')} = ${run.revenue}'
            '${run.bonus == 0 ? '' : ' incl. ${run.bonus} bonus'}');
      }
    }
  }, skip: saved == null ? 'Set ROUTE_SESSION to a saved session' : false);
}
