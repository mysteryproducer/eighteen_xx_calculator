import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/board.dart';
import '../models/board_graph.dart';
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
  final Rect bounds;

  BoardMapGeometry(this.map) : bounds = map.boardBounds.inflate(0.3);

  Size get size => Size(bounds.width * boardMapScale, bounds.height * boardMapScale);

  Offset toScreen(Offset board) => (board - bounds.topLeft) * boardMapScale;

  Offset toBoard(Offset screen) => screen / boardMapScale + bounds.topLeft;

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
  final RouteResult? route;
  final HexCoord? highlighted;

  /// Hexes holding a tile that doesn't belong there by the rules.
  final Set<HexCoord> misfits;

  /// Hexes the user has picked out to photograph.
  final Set<HexCoord> selected;

  /// Marks anything the user should check.
  static const Color uncertain = Color(0xFFFFB300);

  /// Marks a tile that can't be right.
  static const Color wrong = Color(0xFFE53935);

  /// Marks a hex the user set where a photo since shows something else.
  static const Color suggested = Color(0xFF8E24AA);

  BoardMapPainter({
    required this.title,
    required this.session,
    required this.graph,
    required this.geometry,
    this.route,
    this.highlighted,
    this.misfits = const {},
    this.selected = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    final content = session.content(title);
    final tileSize = boardMapScale / TileRendererFraming.radiusShare;

    for (final hex in title.map.hexes) {
      final def = content[hex.coord] ?? hex.printed;
      final centre = geometry.centreOf(hex.coord);
      canvas.save();
      canvas.translate(centre.dx - tileSize / 2, centre.dy - tileSize / 2);
      TileRenderer.paint(canvas, def, tileSize);
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
    final active = route;
    if (active == null || active.track.isEmpty) return;
    final paint = Paint()
      ..color = Colors.deepOrange.withValues(alpha: 0.85)
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
    final onRoute = {for (final s in route?.stops ?? const <StationNode>[]) s.id};
    for (final station in graph.stations) {
      final def = content[station.hex];
      if (def == null) continue;
      final centre = geometry.stationPosition(def, station);
      final radius = boardMapScale *
          (station.kind == StationKind.city ? 0.2 : 0.16);
      final company = title.companyById(station.companyId);
      if (company != null) {
        canvas.drawCircle(centre, radius * 0.85, Paint()..color = company.color);
      }
      // Whose token this is was guessed from a photo, or the revenue is.
      final flagged = station.revenueSource == RevenueSource.unverified ||
          (company != null && session.tokenDoubts.contains(station.id));
      if (onRoute.contains(station.id) || flagged) {
        canvas.drawCircle(
          centre,
          radius + 2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = onRoute.contains(station.id) ? Colors.deepOrange : uncertain,
        );
      }
      // A city printed with no value yet (1844 prints `revenue:0`) has
      // nothing worth showing until a tile gives it one.
      if (station.revenue == 0) continue;
      final text = TextPainter(
        text: TextSpan(
          text: '${station.revenue}',
          style: TextStyle(
            fontSize: math.max(7, radius * 0.8),
            fontWeight: FontWeight.bold,
            color: company != null &&
                    ThemeData.estimateBrightnessForColor(company.color) ==
                        Brightness.dark
                ? Colors.white
                : Colors.black,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final offset = station.kind == StationKind.offboard
          ? Offset(0, -radius * 1.4)
          : Offset.zero;
      if (station.kind == StationKind.offboard) {
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

  static Path _outline(Offset centre, double radius) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final v = HexGeometry.vertex(centre, radius, i);
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
