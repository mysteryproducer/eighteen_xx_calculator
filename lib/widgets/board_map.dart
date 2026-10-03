import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/board.dart';
import '../models/board_graph.dart';
import '../models/company.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import '../processing/route_finder.dart';
import '../processing/tile_renderer.dart';

/// Scale of the drawn map: screen pixels per hex circumradius, before the
/// user zooms.
const double boardMapScale = 36;

/// Where things are on the drawn map, shared by the painter and by tap
/// handling so they agree.
class BoardMapGeometry {
  final MapLayout map;

  /// How far the map is turned, in radians clockwise, to look as the board
  /// is printed (see `GameTitle.displayTurn`).
  final double turn;

  /// The drawn map's extent, turned, in hex radii.
  final Rect bounds;

  BoardMapGeometry(this.map, {this.turn = 0})
      : bounds = _turnedBounds(map, turn).inflate(0.3);

  static Rect _turnedBounds(MapLayout map, double turn) {
    if (turn == 0) return map.boardBounds;
    Rect? bounds;
    for (final c in map.coords) {
      final hex = Rect.fromCircle(center: _turned(c.boardCenter, turn), radius: 1);
      bounds = bounds == null ? hex : bounds.expandToInclude(hex);
    }
    return bounds ?? Rect.zero;
  }

  static Offset _turned(Offset p, double turn) {
    final c = math.cos(turn), s = math.sin(turn);
    return Offset(c * p.dx - s * p.dy, s * p.dx + c * p.dy);
  }

  Size get size => Size(bounds.width * boardMapScale, bounds.height * boardMapScale);

  Offset toScreen(Offset board) =>
      (_turned(board, turn) - bounds.topLeft) * boardMapScale;

  Offset toBoard(Offset screen) =>
      _turned(screen / boardMapScale + bounds.topLeft, -turn);

  Offset centreOf(HexCoord hex) => toScreen(hex.boardCenter);

  /// Where a station sits on the drawn map.
  Offset stationPosition(TileDefinition content, StationNode station) =>
      toScreen(TileRenderer.stationPosition(
          content, station.stationIndex, station.hex.boardCenter, 1));

  /// The map hex under [screen], if any.
  MapHex? hexAt(Offset screen) => map.at(HexCoord.nearestTo(toBoard(screen)));
}

/// Draws the board as the session understands it: the printed map, the
/// tiles laid on it, station tokens and revenue, and a route if one has been
/// found. Hexes the app isn't sure of are outlined in amber.
class BoardMapPainter extends CustomPainter {
  final GameTitle title;
  final GameSession session;
  final BoardGraph graph;
  final BoardMapGeometry geometry;
  /// Routes to draw, each in its own colour (see [routeColours]): one per
  /// train.
  final List<RouteResult> routes;
  final HexCoord? highlighted;

  /// Hexes holding a tile that doesn't belong there by the rules.
  final Set<HexCoord> misfits;

  /// Hexes the user has picked out to photograph.
  final Set<HexCoord> selected;

  /// Tokens that can't legally be where they are, by circle (see
  /// `GameSession.tokenProblems`): ringed in red.
  final Map<String, String> tokenProblems;

  /// Marks anything the user should check.
  static const Color uncertain = Color(0xFFFFB300);

  /// Marks a tile that can't be right.
  static const Color wrong = Color(0xFFE53935);

  /// Marks a hex the user set where a photo since shows something else.
  static const Color suggested = Color(0xFF8E24AA);

  /// The colours routes are drawn in, a train each.
  static const List<Color> routeColours = [
    Colors.deepOrange,
    Color(0xFF1E88E5),
    Color(0xFF43A047),
    Color(0xFFD81B60),
    Color(0xFF6D4C41),
  ];

  BoardMapPainter({
    required this.title,
    required this.session,
    required this.graph,
    required this.geometry,
    this.routes = const [],
    this.highlighted,
    this.misfits = const {},
    this.selected = const {},
    this.tokenProblems = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    final content = session.content(title);
    final tileSize = boardMapScale / TileRendererFraming.radiusShare;

    for (final hex in title.map.hexes) {
      final def = content[hex.coord] ?? hex.printed;
      final centre = geometry.centreOf(hex.coord);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(geometry.turn);
      canvas.translate(-tileSize / 2, -tileSize / 2);
      TileRenderer.paint(canvas, def, tileSize, style: title.tileStyle);
      canvas.restore();

      final label = TextPainter(
        text: TextSpan(
          text: hex.id,
          style: const TextStyle(fontSize: 7, color: Color(0x99000000)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas,
          centre + Offset(-label.width / 2, -boardMapScale * 0.82));

      final tile = session.tileAt(hex);
      if (tile != null) {
        final number = TextPainter(
          text: TextSpan(
            text: tile.tileId,
            style: const TextStyle(fontSize: 7, color: Color(0xCC000000)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        number.paint(canvas,
            centre + Offset(boardMapScale * 0.35, boardMapScale * 0.45));
      }

      if (selected.contains(hex.coord)) {
        canvas.drawPath(
          _outline(centre, boardMapScale * 0.97),
          Paint()..color = Colors.blueAccent.withValues(alpha: 0.3),
        );
      }
      final doubtful = (hex.takesTiles && session.stateOf(hex).isDoubtful) ||
          session.tunnelDoubts.contains(hex.id) ||
          session.mountainDoubts.contains(hex.id);
      final disputed = session.stateOf(hex).suggestion != null;
      final misfit = misfits.contains(hex.coord);
      if (doubtful || disputed || misfit || hex.coord == highlighted ||
          selected.contains(hex.coord)) {
        canvas.drawPath(
          _outline(centre, boardMapScale * 0.97),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = hex.coord == highlighted ? 4 : 3
            ..color = hex.coord == highlighted || selected.contains(hex.coord)
                ? Colors.blueAccent
                : misfit
                    ? wrong
                    : disputed
                        ? suggested
                        : uncertain,
        );
      }
    }

    _paintRoute(canvas, content);
    _paintStations(canvas, content);
  }

  void _paintRoute(Canvas canvas, Map<HexCoord, TileDefinition> content) {
    for (int i = 0; i < routes.length; i++) {
      _paintOneRoute(canvas, content, routes[i],
          routeColours[i % routeColours.length]);
    }
  }

  void _paintOneRoute(Canvas canvas, Map<HexCoord, TileDefinition> content,
      RouteResult active, Color colour) {
    if (active.track.isEmpty) return;
    final paint = Paint()
      ..color = colour.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset at(StationNode s) => geometry.stationPosition(content[s.hex]!, s);
    for (final edge in active.track) {
      final points = <Offset>[
        at(edge.from),
        for (final hex in edge.hexPath.skip(1).take(
            edge.hexPath.length > 2 ? edge.hexPath.length - 2 : 0))
          geometry.centreOf(hex),
        at(edge.to),
      ];
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  void _paintStations(Canvas canvas, Map<HexCoord, TileDefinition> content) {
    // Each stop ringed in the colour of the first route through it.
    final onRoute = <String, Color>{};
    for (int i = routes.length - 1; i >= 0; i--) {
      for (final s in routes[i].stops) {
        onRoute[s.id] = routeColours[i % routeColours.length];
      }
    }
    void ring(Offset at, double radius, Color colour) => canvas.drawCircle(
        at,
        radius + 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = colour);

    for (final station in graph.stations) {
      final def = content[station.hex];
      if (def == null) continue;
      final centre = geometry.stationPosition(def, station);
      final printed = def.stations.firstWhere(
          (s) => s.index == station.stationIndex,
          orElse: () => def.stations.first);
      final radius = boardMapScale *
          (station.kind == StationKind.city ? 0.2 : 0.16);
      final routeColour = onRoute[station.id];
      final route = routeColour != null;
      Company? only;
      if (station.kind == StationKind.city) {
        // Each token in its own circle, where the tile prints the circle.
        final circles = TileRenderer.slotPositions(
            def, station.stationIndex, station.hex.boardCenter, 1);
        final size = TileRenderer.slotRadiusFor(printed) * boardMapScale;
        for (int slot = 0; slot < circles.length; slot++) {
          final at = geometry.toScreen(circles[slot]);
          final id = GameSession.slotId(station.id, slot);
          final company = title.companyById(
              slot < station.tokens.length ? station.tokens[slot] : null);
          if (circles.length == 1) only = company;
          if (company != null) {
            canvas.drawCircle(at, size * 0.85, Paint()..color = company.color);
          }
          if (tokenProblems.containsKey(id)) {
            ring(at, size, wrong);
          } else if (company != null && session.tokenDoubts.contains(id)) {
            ring(at, size, uncertain);
          } else if (route) {
            ring(at, size, routeColour);
          }
        }
        if (station.revenueSource == RevenueSource.unverified) {
          ring(centre, radius * 2.2, uncertain);
        }
      } else if (route || station.revenueSource == RevenueSource.unverified) {
        ring(centre, radius, routeColour ?? uncertain);
      }

      // A city printed with no value yet (1844 prints `revenue:0`) has
      // nothing worth showing until a tile gives it one.
      if (station.revenue == 0) continue;
      final boxed = station.kind != StationKind.city || station.tokens.length > 1;
      final text = TextPainter(
        text: TextSpan(
          text: '${station.revenue}',
          style: TextStyle(
            fontSize: math.max(7, radius * 0.8),
            fontWeight: FontWeight.bold,
            color: !boxed &&
                    only != null &&
                    ThemeData.estimateBrightnessForColor(only.color) ==
                        Brightness.dark
                ? Colors.white
                : Colors.black,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // Above an off-board area; beside a town, whose dot or bar shows it is
      // a town to run through -- under its figure, Brig looked just like the
      // mountain railways' dead ends; between a city's circles, on a label.
      final offset = switch (station.kind) {
        StationKind.offboard => Offset(0, -radius * 1.4),
        StationKind.town => Offset(radius * 1.9, -radius * 1.9),
        StationKind.city => Offset.zero,
      };
      if (boxed) {
        final box = Rect.fromCenter(
          center: centre + offset,
          width: text.width + 6,
          height: text.height + 2,
        );
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)),
            Paint()..color = Colors.white.withValues(alpha: 0.9));
      }
      text.paint(canvas, centre + offset - Offset(text.width / 2, text.height / 2));
    }
  }

  Path _outline(Offset centre, double radius) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final v = centre +
          BoardMapGeometry._turned(
              HexGeometry.vertex(Offset.zero, radius, i), geometry.turn);
      i == 0 ? path.moveTo(v.dx, v.dy) : path.lineTo(v.dx, v.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant BoardMapPainter oldDelegate) => true;
}

/// How `TileRenderer.paint` frames a tile: the hex's circumradius as a share
/// of the square it is drawn in.
class TileRendererFraming {
  static const double radiusShare = 0.48;
}
