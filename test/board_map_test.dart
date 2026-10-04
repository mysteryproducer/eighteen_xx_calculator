import 'dart:math' as math;
import 'dart:ui';

import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/models/board_graph.dart';
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/models/tile_definition.dart';
import 'package:eighteen_scanner/widgets/board_map.dart';
import 'package:flutter_test/flutter_test.dart';

/// [count] + 1 points evenly spaced along [path], which is one line.
List<Offset> pointsAlong(Path path, int count) {
  final metric = path.computeMetrics().single;
  return [
    for (int i = 0; i <= count; i++)
      metric.getTangentForOffset(metric.length * i / count)!.position,
  ];
}

/// A city either side of a gentle curve (tile 8, sides 0 and 2) on [curve],
/// each a tile 57 turned so its track faces the curve -- 57's ends are
/// sides 0 and 3 -- and the route graph's one run between them.
(Map<HexCoord, TileDefinition>, TrackEdge) citiesRoundACurve(
    GameTitle title, HexCoord curve) {
  final west = Board.neighborOf(curve, 0), east = Board.neighborOf(curve, 2);
  final content = {
    curve: title.tiles['8']!,
    west: title.tiles['57']!.rotated(HexGeometry.oppositeEdge(0)),
    east: title.tiles['57']!.rotated(HexGeometry.oppositeEdge(2)),
  };
  final graph = BoardGraph.fromContent(content);
  final from = graph.stations.firstWhere((s) => s.hex == west);
  return (content, graph.edgesFrom(from).single);
}

void main() {
  group('a route is drawn along the track', () {
    void followsTheCurve(GameTitle title) {
      const curve = HexCoord(4, 6);
      final (content, run) = citiesRoundACurve(title, curve);
      final geometry = BoardMapGeometry(title.map, turn: title.displayTurn);
      final path = geometry.routePath(content, run)!;
      final points = pointsAlong(path, 400);
      // From one city to the other...
      expect((points.first - geometry.stationPosition(content[run.from.hex]!, run.from))
              .distance,
          lessThan(0.01));
      expect((points.last - geometry.stationPosition(content[run.to.hex]!, run.to))
              .distance,
          lessThan(0.01));
      // ... round the curve, which passes a quarter of a radius from the
      // middle of its hex, where a line through the middle would cross it.
      final middle = geometry.centreOf(curve);
      final nearest = points
          .map((p) => (p - middle).distance)
          .reduce(math.min);
      expect(nearest / boardMapScale, closeTo(math.sqrt(3) - 1.5, 0.01));
    }

    test('round a gentle curve, not through the middle of its hex', () {
      followsTheCurve(GameTitle.byId('1844')!);
    });

    test('on a map turned to look flat-topped, as the tiles are drawn', () {
      followsTheCurve(GameTitle.byId('1889')!);
    });

    test("every run of track printed on each title's map is followed", () {
      for (final title in [
        for (final id in ['1844', '1854', '1889']) GameTitle.byId(id)!,
      ]) {
        final content = GameSession.start(
                title: title, name: 'printed', startedEmpty: true)
            .content(title);
        final graph = BoardGraph.fromContent(content);
        final geometry = BoardMapGeometry(title.map, turn: title.displayTurn);
        var runs = 0;
        for (final station in graph.stations) {
          for (final run in graph.edgesFrom(station)) {
            expect(geometry.routePath(content, run), isNotNull,
                reason: '${title.id}: ${run.id}');
            runs++;
          }
        }
        expect(runs, greaterThan(0), reason: title.id);
      }
    });

    test("a route along track the board doesn't have isn't drawn along it",
        () {
      final title = GameTitle.byId('1844')!;
      const curve = HexCoord(4, 6);
      final (content, run) = citiesRoundACurve(title, curve);
      final geometry = BoardMapGeometry(title.map);
      // The curve turned the other way since the route was found.
      expect(
          geometry.routePath(
              {...content, curve: title.tiles['8']!.rotated(3)}, run),
          isNull);
    });
  });
  group('place names', () {
    final title = GameTitle.byId('1844')!;
    final session =
        GameSession.start(title: title, name: 'test', startedEmpty: true);
    final geometry = BoardMapGeometry(title.map);
    // The whole board in a phone's window, 390 by 600.
    final fitted = math.min(
        390 / geometry.size.width, 600 / geometry.size.height);
    List<String> shownAt(double labelScale) => BoardMapPainter(
          title: title,
          session: session,
          graph: session.graph(title),
          geometry: geometry,
          labelScale: labelScale,
        ).namesShown;

    test('come in as the board is zoomed, and stay', () {
      expect(shownAt(0), isEmpty);
      final named = title.map.hexes.where((h) => h.name != null).length;
      var before = <String>{};
      for (final zoom in [1.0, 2.0, 4.0, 8.0]) {
        final shown = shownAt(fitted * zoom).toSet();
        expect(shown.containsAll(before), isTrue, reason: 'zoom $zoom');
        before = shown;
      }
      expect(shownAt(fitted * 8), hasLength(named));
    });

    test('run no further than halfway across the hexes either side', () {
      // Zoomed out, a hex is a few pixels on screen: a short name fits,
      // a long one waits.
      final whole = shownAt(fitted);
      expect(whole, contains('Lyon'));
      expect(whole, isNot(contains('Dijon/Paris')));
    });
  });
}
