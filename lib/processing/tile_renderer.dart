import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/board.dart';
import '../models/tile_definition.dart';

/// Draws a [TileDefinition] as a hex tile.
///
/// The same drawing is used two ways: rasterized into reference images the
/// classifier matches camera patches against, and (via [TilePainter]) shown in
/// the UI when the user is correcting a recognized tile. Because the picture
/// comes from the same data the route graph is built from, there is no
/// separate library of tile artwork to keep in sync.
class TileRenderer {
  TileRenderer._();

  static const Color trackColor = Color(0xFF1A1A1A);

  static Color backgroundFor(TileColor color) => switch (color) {
        TileColor.plain => const Color(0xFFEDE7D9),
        TileColor.yellow => const Color(0xFFFCE94F),
        TileColor.green => const Color(0xFF73C26B),
        TileColor.brown => const Color(0xFFB97A3D),
        TileColor.grey => const Color(0xFFBDBDBD),
        TileColor.red => const Color(0xFFD9695F),
        TileColor.blue => const Color(0xFF6FA8DC),
        TileColor.purple => const Color(0xFFB39DDB),
      };

  /// The darker shade a tile of [color] prints its circles in on the
  /// textured side of 1889's tiles: ochre on yellow, deeper green and brown
  /// on the others.
  static Color shadeFor(TileColor color) => switch (color) {
        TileColor.yellow => const Color(0xFFB0782E),
        _ => Color.lerp(backgroundFor(color), Colors.black, 0.45)!,
      };

  /// Where a stop sits inside the hex.
  ///
  /// A stop with a `loc:` sits half a radius out towards that side (or
  /// towards the corner, for a half number), as tobymao/18xx (MIT licensed)
  /// draws it. A stop on its own sits in the middle -- unless it is a town
  /// on a run of track from one side to another, which sits halfway along
  /// the run with its bar across it. Where there are several stops, as on
  /// the OO tiles, each leans towards one of its sides (see [_leanings]) and
  /// sits on its own run of track, a little way out that way; the run is
  /// drawn as any other run is. That is how the tiles are printed: 1844's
  /// tile 67 has one city on its straight and the other on its gentle curve,
  /// each about 0.4 of a radius from the middle.
  static Offset stationPosition(
    TileDefinition def,
    int stationIndex,
    Offset center,
    double radius,
  ) =>
      center + (_layoutOf(def).at[stationIndex] ?? Offset.zero) * radius;

  static final Expando<_StopLayout> _layouts = Expando();

  static _StopLayout _layoutOf(TileDefinition def) =>
      _layouts[def] ??= _computeLayout(def);

  static _StopLayout _computeLayout(TileDefinition def) {
    if (def.stations.isEmpty) return const _StopLayout({}, {});
    final exits = <int, List<int>>{};
    for (final seg in def.segments) {
      for (final (x, y) in [(seg.a, seg.b), (seg.b, seg.a)]) {
        if (x case StationEndpoint(:final stationIndex)) {
          if (y case EdgeEndpoint(:final edge)) {
            (exits[stationIndex] ??= []).add(edge);
          }
        }
      }
    }
    final at = <int, Offset>{};
    final riding = <int, _Ride>{};
    void ride(TileStation stop, int a, int b, double t) {
      final (point, along) = _alongRun(a, b, t);
      at[stop.index] = point;
      riding[stop.index] = _Ride(a, b, t, along);
    }

    for (final stop in def.stations) {
      if (stop.loc case final loc?) {
        at[stop.index] = _locDirection(loc) * _locDistance;
      }
    }
    final free = [
      for (final stop in def.stations)
        if (stop.loc == null) stop,
    ];
    if (def.stations.length == 1 && free.length == 1) {
      final stop = free.single;
      final sides = exits[stop.index] ?? const <int>[];
      if (stop.kind == StationKind.town && sides.length == 2) {
        ride(stop, sides[0], sides[1], 0.5);
      } else {
        at[stop.index] = Offset.zero;
      }
      return _StopLayout(at, riding);
    }

    final leans = _leanings(def, exits);
    for (final stop in free) {
      final lean = leans[stop.index];
      if (lean == null) continue;
      final sides = exits[stop.index]!;
      if (sides.length != 2) {
        at[stop.index] = HexGeometry.edgeNormal(lean) * _offCentre;
        continue;
      }
      // Out along the run until clear of the other stops: cities on a tile
      // don't overlap.
      for (double out = _offCentre; ; out += 0.02) {
        ride(stop, sides[0], sides[1], _towards(sides[0], sides[1], lean, out));
        final clear = def.stations.every((other) =>
            other.index == stop.index ||
            at[other.index] == null ||
            (at[other.index]! - at[stop.index]!).distance >=
                _apart(stop) + _apart(other));
        if (clear || out >= 0.6) break;
      }
    }
    // Stops with no track at all, printed on the map: spread round the hex
    // as tobymao spreads them, or opposite the other stop if there are two.
    final unplaced = [
      for (final stop in free)
        if (!at.containsKey(stop.index)) stop,
    ];
    final turn = def.stations.first.turn;
    for (int i = 0; i < unplaced.length; i++) {
      final stop = unplaced[i];
      final others = [
        for (final other in def.stations)
          if (other.index != stop.index && leans.containsKey(other.index))
            leans[other.index]!,
      ];
      final side = unplaced.length == 1 && others.length == 1
          ? (others.single + 3) % 6
          : (i * 6 ~/ unplaced.length + turn) % 6;
      at[stop.index] = HexGeometry.edgeNormal(side) * _locDistance;
    }
    return _StopLayout(at, riding);
  }

  /// The side each stop without a `loc:` leans towards, chosen as tobymao
  /// chooses it: of the stop's own sides, the least crowded by other track
  /// and stops, keeping clear of the bottom side where a name goes, stops
  /// with the lowest sides choosing first. tobymao works this out on the
  /// tile as turned; it is worked out here on the tile as printed, before it
  /// was turned, so that it turns with the tile as the printing does --
  /// which is the difference between tile 67 drawn as printed and its second
  /// city drawn on the wrong side.
  static Map<int, int> _leanings(
      TileDefinition def, Map<int, List<int>> exits) {
    final turn = def.stations.isEmpty ? 0 : def.stations.first.turn;
    // In tenths, so that ties come out as ties.
    final crowd = List<int>.filled(6, 0);
    void crowdAt(int side) {
      crowd[side] += 10;
      crowd[(side + 1) % 6] += 1;
      crowd[(side + 5) % 6] += 1;
    }

    crowd[0] += 1;
    final stops = <(TileStation, List<int>)>[];
    for (final stop in def.stations) {
      final sides = [
        for (final side in exits[stop.index] ?? const <int>[]) (side - turn) % 6,
      ]..sort();
      if (sides.isEmpty) continue;
      stops.add((stop, sides));
      sides.forEach(crowdAt);
    }
    stops.sort((a, b) {
      for (int i = 0; i < math.min(a.$2.length, b.$2.length); i++) {
        if (a.$2[i] != b.$2[i]) return a.$2[i] - b.$2[i];
      }
      return a.$2.length - b.$2.length;
    });
    final result = <int, int>{};
    for (final (stop, sides) in stops) {
      if (stop.loc != null) continue;
      var best = sides.first;
      for (final side in sides) {
        if (crowd[side] < crowd[best]) best = side;
      }
      crowdAt(best);
      result[stop.index] = (best + turn) % 6;
    }
    return result;
  }

  /// How far along the run from side [a] to side [b] -- 0 at [a], 1 at [b]
  /// -- a stop leaning towards side [lean] sits: [distance] from the middle
  /// of the hex, on that half of the run. A tight turn never comes that
  /// close to the middle; its stop sits at the middle of the turn.
  static double _towards(int a, int b, int lean, double distance) {
    if (_alongRun(a, b, 0.5).$1.distance >= distance) return 0.5;
    var best = 0.5;
    var bestMiss = double.infinity;
    for (int i = 0; i <= 50; i++) {
      final t = lean == b ? 0.5 + i / 100 : 0.5 - i / 100;
      final miss = (_alongRun(a, b, t).$1.distance - distance).abs();
      if (miss < bestMiss) {
        bestMiss = miss;
        best = t;
      }
    }
    return best;
  }

  /// The point a fraction [t] of the way along the run from side [a] to
  /// side [b], in a hex of circumradius 1 centred on the origin, and the way
  /// the track runs there.
  static (Offset, Offset) _alongRun(int a, int b, double t) {
    final arc = _arcOf(Offset.zero, 1, a, b);
    if (arc == null) {
      final from = HexGeometry.edgeMidpoint(Offset.zero, 1, a);
      final d = HexGeometry.edgeMidpoint(Offset.zero, 1, b) - from;
      return (from + d * t, d / d.distance);
    }
    final angle = arc.start + arc.sweep * t;
    final out = Offset(math.cos(angle), math.sin(angle));
    final along = Offset(-out.dy, out.dx) * (arc.sweep < 0 ? -1.0 : 1.0);
    return (arc.centre + out * arc.radius, along);
  }

  /// How far from the middle a stop that shares the hex sits on its run.
  static const double _offCentre = 0.4;

  /// How much room a stop takes, from its centre, as a share of the
  /// circumradius.
  static double _apart(TileStation stop) => stop.kind == StationKind.city
      ? slotRadiusFor(stop) + 0.02
      : _townBar;

  /// A stop's `loc:` as a direction from the middle of the hex: towards a
  /// side's middle for a whole number, towards the corner between two sides
  /// for a half.
  static Offset _locDirection(double loc) {
    final whole = loc.floor();
    if ((loc - whole).abs() < 0.01) return HexGeometry.edgeNormal(whole);
    // Side k runs between corners k and k + 1, so the corner between sides
    // k and k + 1 is corner k + 1.
    final corner = HexGeometry.vertex(Offset.zero, 1, whole + 1);
    return corner / corner.distance;
  }

  /// How far out a stop with a `loc:` sits, as a share of the circumradius.
  static const double _locDistance = 0.5;

  /// The hex's circumradius as a share of the square a tile is drawn in.
  static const double radiusShare = 0.48;

  /// Paints [def] centered in a [size] x [size] square. [slotTurn] turns
  /// the row of slots of a city in the middle further, for recognition to
  /// try each way it could be printed.
  static void paint(Canvas canvas, TileDefinition def, double size,
      {int slotTurn = 0, TileStyle style = TileStyle.plain}) {
    // What a city or town circle is filled with: white, or on the textured
    // side of 1889's tiles a darker shade of the tile.
    final fill = style.shadedStops ? shadeFor(def.color) : Colors.white;
    final center = Offset(size / 2, size / 2);
    final radius = size * radiusShare;

    // Hex body.
    final hexPath = Path();
    for (int i = 0; i < 6; i++) {
      final v = HexGeometry.vertex(center, radius, i);
      if (i == 0) {
        hexPath.moveTo(v.dx, v.dy);
      } else {
        hexPath.lineTo(v.dx, v.dy);
      }
    }
    hexPath.close();
    canvas.drawPath(hexPath, Paint()..color = backgroundFor(def.color));
    // Everything printed on the tile stays on it: track drawn with round
    // ends would otherwise poke out past the sides.
    canvas.save();
    canvas.clipPath(hexPath);

    // Impassable borders: a heavy line along the side, as printed on maps.
    final borderPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.06
      ..strokeCap = StrokeCap.round;
    for (final edge in def.impassable) {
      final inset = radius * 0.94;
      canvas.drawLine(
        HexGeometry.vertex(center, inset, edge),
        HexGeometry.vertex(center, inset, (edge + 1) % 6),
        borderPaint,
      );
    }

    // Track, along the paths [trackPath] gives, which routes are drawn along
    // too.
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.09
      ..strokeCap = StrokeCap.round;
    // Track for a line that hasn't opened yet is printed faintly on the map,
    // so it is drawn faintly here: recognition compares against what the hex
    // looks like, not what a train can use.
    final futurePaint = Paint()
      ..color = trackColor.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.05
      ..strokeCap = StrokeCap.round;
    // Narrow track -- 1844's tunnels -- is drawn as the tunnel pieces are
    // printed: a black band broken by white dashes, over whatever else is
    // on the hex.
    final tunnels = <Path>[];
    final layout = _layoutOf(def);
    final runs = <int, Paint>{};
    for (final seg in def.segments) {
      final paint = seg.future ? futurePaint : trackPaint;
      // A stop sitting on a run of track: the run is drawn whole, once.
      final rider = [seg.a, seg.b].whereType<StationEndpoint>().firstOrNull;
      if (rider != null &&
          layout.riding.containsKey(rider.stationIndex) &&
          [seg.a, seg.b].any((e) => e is EdgeEndpoint)) {
        runs[rider.stationIndex] = paint;
        continue;
      }
      if (seg.narrow && seg.a is EdgeEndpoint && seg.b is EdgeEndpoint) {
        tunnels.add(trackPath(def, seg, center, radius));
        continue;
      }
      // Track into a place a route can only end at -- an off-board area,
      // or one of 1844's mountain railways -- just points into the hex, as
      // the board prints it: drawn on to the middle, several of them read
      // as a junction to run through.
      final side = [seg.a, seg.b].whereType<EdgeEndpoint>().firstOrNull;
      final end = [seg.a, seg.b].whereType<StationEndpoint>().firstOrNull;
      if (side != null && end != null && _endsRoutes(def, end.stationIndex)) {
        _paintSpur(canvas, center, radius, side.edge,
            _positionOf(def, end, center, radius), paint.strokeWidth,
            paint.color);
        continue;
      }
      canvas.drawPath(trackPath(def, seg, center, radius), paint);
    }

    runs.forEach((stop, paint) {
      final ride = layout.riding[stop]!;
      canvas.drawPath(
          _runPart(center, radius, ride.a, ride.b, 0, 1), paint);
    });

    for (final tunnel in tunnels) {
      canvas.drawPath(
          tunnel,
          Paint()
            ..color = trackColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = size * 0.07);
      final dash = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.035;
      for (final metric in tunnel.computeMetrics()) {
        final step = size * 0.065;
        for (double d = step / 2; d < metric.length; d += 2 * step) {
          canvas.drawPath(metric.extractPath(d, d + step), dash);
        }
      }
    }

    // Revenue centres. A city is a ring per token slot; a town is a bar
    // across its track where it has one or two, and a dot otherwise, which is
    // how tiles are actually printed.
    for (final station in def.stations) {
      if (station.style == 'hidden') continue;
      final pos = stationPosition(def, station.index, center, radius);
      switch (station.kind) {
        case StationKind.city:
          _paintCity(canvas, def, station, pos, center, size, radius,
              slotTurn, fill, style);
        case StationKind.town:
          _paintTown(canvas, def, station, pos, center, size, radius,
              style: style, fill: fill);
        case StationKind.offboard:
          break; // the hex's own colour says what it is
      }
    }
    canvas.restore();
    canvas.drawPath(
      hexPath,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.015,
    );
  }

  /// A token slot's radius, as a share of the circumradius, for [station].
  /// Measured on 1844's tiles: a third of the hex for a city of one slot,
  /// and a little more for each of two sharing a city, whose capsule reaches
  /// four fifths of the way to the sides it points at (close-ups of I6's 15,
  /// Geneva and a 611); three round the middle are smaller. (tobymao draws
  /// them at a quarter, which made every city tile a poor match for its
  /// photo.) A title's [style] can print the circles of a city of several
  /// smaller (see `TileStyle.multiSlotRadius`).
  static double slotRadiusFor(TileStation station,
          {TileStyle style = TileStyle.plain}) =>
      switch (station.slots) {
        <= 1 => 0.33,
        _ when style.multiSlotRadius != null => style.multiSlotRadius!,
        2 => 0.34,
        _ => 0.36,
      };

  /// Which way the row of slots of a city in the middle of a tile runs when
  /// the tile isn't turned, in degrees clockwise from east, as the tiles are
  /// printed. Measured on 1844's: 15, 619 and 611 one way, 14 another.
  /// Recognition doesn't rely on it -- it tries every way -- but the board
  /// and the editor draw tiles the way they look.
  static const Map<String, double> _slotRows = {'14': 0};
  static const double _defaultSlotRow = 120;

  /// Whether [def] has a city of several slots in its middle, whose row of
  /// slots can run three ways.
  static bool hasSlotRow(TileDefinition def) => def.stations.any((s) =>
      s.kind == StationKind.city && s.slots > 1 && s.loc == null &&
      def.stations.where((t) => t.loc == null).length == 1);

  /// Where each token slot of city [stationIndex] sits, for a hex of
  /// circumradius [radius] centred on [center]. A city in the middle has its
  /// slots in a row that turns with the tile (see [_slotRows]), turned a
  /// further [extraTurn] sixths; a city off to one side has them across the
  /// direction it faces.
  static List<Offset> slotPositions(
    TileDefinition def,
    int stationIndex,
    Offset center,
    double radius, {
    int extraTurn = 0,
    TileStyle style = TileStyle.plain,
  }) {
    final station = def.stations.firstWhere((s) => s.index == stationIndex,
        orElse: () => def.stations.first);
    final pos = stationPosition(def, stationIndex, center, radius);
    final slots = math.max(1, station.slots);
    if (slots == 1) return [pos];
    final Offset row;
    if (pos == center) {
      final degrees = (_slotRows[def.id] ?? _defaultSlotRow) +
          60.0 * (station.turn + extraTurn);
      row = Offset(math.cos(degrees * math.pi / 180),
          math.sin(degrees * math.pi / 180));
    } else {
      final outward = (pos - center) / (pos - center).distance;
      row = Offset(-outward.dy, outward.dx);
    }
    final r = radius * slotRadiusFor(station, style: style);
    if (slots == 2) return [pos - row * r, pos + row * r];
    // Three or more: round the middle, starting across the row. 1844's
    // three-slot city (909) has them just apart, centred over two fifths of
    // the way to the corners.
    final ring = r * (slots == 3 ? 1.2 : 1.42);
    final start = math.atan2(row.dy, row.dx) - math.pi / 2;
    return [
      for (int i = 0; i < slots; i++)
        pos + Offset(math.cos(start + 2 * math.pi * i / slots),
                math.sin(start + 2 * math.pi * i / slots)) *
            ring,
    ];
  }

  /// A city: one ring per token slot, in a row facing out of the hex. Two
  /// slots are printed as a capsule, the band between them white too.
  static void _paintCity(
    Canvas canvas,
    TileDefinition def,
    TileStation station,
    Offset pos,
    Offset center,
    double size,
    double radius,
    int slotTurn,
    Color fill,
    TileStyle style,
  ) {
    final ringRadius = radius * slotRadiusFor(station, style: style);
    final slots = slotPositions(def, station.index, center, radius,
        extraTurn: slotTurn, style: style);
    if (slots.length == 3) {
      // The space between three is white too.
      canvas.drawPath(
          Path()
            ..moveTo(slots[0].dx, slots[0].dy)
            ..lineTo(slots[1].dx, slots[1].dy)
            ..lineTo(slots[2].dx, slots[2].dy)
            ..close(),
          Paint()..color = fill);
    }
    if (slots.length == 2) {
      final row = slots[1] - slots[0];
      final across = Offset(-row.dy, row.dx) / row.distance * ringRadius;
      final band = Path()
        ..moveTo(slots[0].dx + across.dx, slots[0].dy + across.dy)
        ..lineTo(slots[1].dx + across.dx, slots[1].dy + across.dy)
        ..lineTo(slots[1].dx - across.dx, slots[1].dy - across.dy)
        ..lineTo(slots[0].dx - across.dx, slots[0].dy - across.dy)
        ..close();
      canvas.drawPath(band, Paint()..color = fill);
      final edge = Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.03;
      canvas
        ..drawLine(slots[0] + across, slots[1] + across, edge)
        ..drawLine(slots[0] - across, slots[1] - across, edge);
    }
    for (final at in slots) {
      canvas
        ..drawCircle(at, ringRadius, Paint()..color = fill)
        ..drawCircle(
          at,
          ringRadius,
          Paint()
            ..color = trackColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = size * 0.03,
        );
    }
  }

  /// A town: a bar laid across its track, or a dot where it has none to lie
  /// across (a junction of three or more, or a place printed on the map).
  static void _paintTown(
    Canvas canvas,
    TileDefinition def,
    TileStation station,
    Offset pos,
    Offset center,
    double size,
    double radius, {
    TileStyle style = TileStyle.plain,
    Color fill = Colors.white,
  }) {
    final sides = <int>[];
    for (final seg in def.segments) {
      final touches = [seg.a, seg.b].any((e) =>
          e is StationEndpoint && e.stationIndex == station.index);
      if (!touches) continue;
      for (final e in [seg.a, seg.b]) {
        if (e is EdgeEndpoint) sides.add(e.edge);
      }
    }
    if (def.icons.contains('port')) {
      _paintPort(canvas, pos, radius, size);
      return;
    }
    // On 1889's tiles a town is a dot on the track, or on the textured side
    // a ring in a shade of the tile.
    if (style.townDots && station.style != 'rect') {
      if (style.shadedStops) {
        canvas
          ..drawCircle(pos, radius * _townDot, Paint()..color = fill)
          ..drawCircle(
              pos,
              radius * _townDot,
              Paint()
                ..color = trackColor
                ..style = PaintingStyle.stroke
                ..strokeWidth = size * 0.02);
      } else {
        canvas.drawCircle(pos, radius * _townDot, Paint()..color = trackColor);
      }
      return;
    }
    final asBar = station.style == 'rect' ||
        (station.style == null && sides.isNotEmpty && sides.length < 3);
    if (!asBar) {
      // A black dot ringed in white, as the board prints Brig and Altdorf:
      // bigger than the track, so it shows where three or more lines meet
      // -- a plain dot there is lost in the junction, and the town looks
      // like track running through.
      canvas.drawCircle(
          pos, radius * (_townDot + _townRing), Paint()..color = Colors.white);
      canvas.drawCircle(pos, radius * _townDot, Paint()..color = trackColor);
      return;
    }
    // Across the track: perpendicular to the way the track runs through.
    final towards = HexGeometry.edgeMidpoint(center, radius, sides.first) - pos;
    final along = _layoutOf(def).riding[station.index]?.along ??
        (towards.distance < 0.01
            ? const Offset(1, 0)
            : towards / towards.distance);
    final across = Offset(-along.dy, along.dx);
    final half = radius * _townBar;
    canvas.drawLine(
      pos - across * half,
      pos + across * half,
      Paint()
        ..color = trackColor
        ..strokeWidth = size * 0.055
        ..strokeCap = StrokeCap.butt,
    );
  }

  /// A port: a black disc with an anchor in it, as 1889's port tile (437)
  /// prints its town -- drawn as a bar, the tile looked just like 58.
  static void _paintPort(Canvas canvas, Offset pos, double radius, double size) {
    canvas.drawCircle(pos, radius * 0.19, Paint()..color = trackColor);
    final anchor = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.014
      ..strokeCap = StrokeCap.round;
    final r = radius * 0.12;
    canvas
      ..drawLine(pos + Offset(0, -r), pos + Offset(0, r), anchor)
      ..drawLine(pos + Offset(-r * 0.5, -r * 0.45), pos + Offset(r * 0.5, -r * 0.45), anchor)
      ..drawArc(Rect.fromCircle(center: pos + Offset(0, r * 0.15), radius: r * 0.8),
          0.35, 2.44, false, anchor);
  }

  /// Whether a route can only end at stop [index] of [def], not run on
  /// through it.
  static bool _endsRoutes(TileDefinition def, int index) =>
      def.stations.any((s) => s.index == index && s.kind == StationKind.offboard);

  /// Track pointing in from side [edge] towards [target], as a long, narrow
  /// triangle: its base the width of the track ([width]) where the side is,
  /// its point a little under halfway to the middle.
  static void _paintSpur(Canvas canvas, Offset center, double radius, int edge,
      Offset target, double width, Color color) {
    final from = HexGeometry.edgeMidpoint(center, radius, edge);
    final towards = target - from;
    final length = towards.distance;
    if (length < 1e-6) return;
    final along = towards / length;
    final across = Offset(-along.dy, along.dx) * (width * 0.6);
    final tip = from + along * math.min(length, radius * _spurLength);
    canvas.drawPath(
        Path()
          ..moveTo(from.dx + across.dx, from.dy + across.dy)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(from.dx - across.dx, from.dy - across.dy)
          ..close(),
        Paint()..color = color);
  }

  /// How far a spur reaches in, as a share of the circumradius.
  static const double _spurLength = 0.42;

  /// A town dot's radius, the white ring round it, and half the length of
  /// a town bar, likewise.
  static const double _townDot = 0.15;
  static const double _townRing = 0.04;
  static const double _townBar = 0.22;

  /// One of [def]'s tracks, [segment], as it is drawn, in a hex of
  /// circumradius [radius] centred on [center]: from its end
  /// [TileSegment.a] to [TileSegment.b], or the other way when [reversed].
  /// Between two sides it is the run from one to the other (see [_arcOf]);
  /// between a side and a stop that sits on such a run -- a town on a
  /// curve, a city on an OO tile -- it is that part of the run; anything
  /// else is straight, as track into a city in the middle is printed. Tiles
  /// are drawn along it, and so are routes, so a route follows the track.
  static Path trackPath(
    TileDefinition def,
    TileSegment segment,
    Offset center,
    double radius, {
    bool reversed = false,
  }) {
    final (from, to) =
        reversed ? (segment.b, segment.a) : (segment.a, segment.b);
    if ((from, to)
        case (EdgeEndpoint(edge: final a), EdgeEndpoint(edge: final b))) {
      return _runPart(center, radius, a, b, 0, 1);
    }
    final side = [from, to].whereType<EdgeEndpoint>().firstOrNull;
    final stop = [from, to].whereType<StationEndpoint>().firstOrNull;
    final ride = stop == null ? null : _layoutOf(def).riding[stop.stationIndex];
    if (side != null &&
        ride != null &&
        (side.edge == ride.a || side.edge == ride.b)) {
      final atSide = side.edge == ride.a ? 0.0 : 1.0;
      return from == side
          ? _runPart(center, radius, ride.a, ride.b, atSide, ride.t)
          : _runPart(center, radius, ride.a, ride.b, ride.t, atSide);
    }
    final start = _positionOf(def, from, center, radius);
    final end = _positionOf(def, to, center, radius);
    return Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(end.dx, end.dy);
  }

  /// Where end [end] of one of [def]'s tracks is: the middle of a side, or
  /// a stop.
  static Offset _positionOf(
          TileDefinition def, TileEndpoint end, Offset center, double radius) =>
      switch (end) {
        EdgeEndpoint(:final edge) =>
          HexGeometry.edgeMidpoint(center, radius, edge),
        StationEndpoint(:final stationIndex) =>
          stationPosition(def, stationIndex, center, radius),
      };

  /// The run from side [a] to side [b] (see [_arcOf]) between fractions
  /// [from] and [to] of the way along it, 0 at [a] and 1 at [b]; backwards
  /// when [to] is the smaller.
  static Path _runPart(Offset center, double radius, int a, int b,
      double from, double to) {
    final arc = _arcOf(center, radius, a, b);
    if (arc == null) {
      final start = HexGeometry.edgeMidpoint(center, radius, a);
      final end = HexGeometry.edgeMidpoint(center, radius, b);
      final p = Offset.lerp(start, end, from)!, q = Offset.lerp(start, end, to)!;
      return Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(q.dx, q.dy);
    }
    return Path()
      ..arcTo(Rect.fromCircle(center: arc.centre, radius: arc.radius),
          arc.start + arc.sweep * from, arc.sweep * (to - from), true);
  }

  /// The circular arc that track from the middle of side [a] to the middle
  /// of side [b] follows, as tile art draws it, leaving both sides at right
  /// angles: its centre and radius, the angle at [a], and how far it turns
  /// to [b], the short way round. Null for opposite sides, straight across.
  /// A tight turn hugs the corner the two sides share and never comes near
  /// the middle of the hex; bending track through the middle instead --
  /// which this used to do -- makes every curve too wide, and a
  /// photographed curve then matches no template well.
  static ({Offset centre, double radius, double start, double sweep})? _arcOf(
      Offset center, double radius, int a, int b) {
    final centre = _arcCentre(center, radius, a, b);
    if (centre == null) return null;
    final from = HexGeometry.edgeMidpoint(center, radius, a);
    final to = HexGeometry.edgeMidpoint(center, radius, b);
    final start = math.atan2(from.dy - centre.dy, from.dx - centre.dx);
    final end = math.atan2(to.dy - centre.dy, to.dx - centre.dx);
    var sweep = end - start;
    // Go the short way round: the long way would loop outside the hex.
    while (sweep <= -math.pi) {
      sweep += 2 * math.pi;
    }
    while (sweep > math.pi) {
      sweep -= 2 * math.pi;
    }
    return (
      centre: centre,
      radius: (from - centre).distance,
      start: start,
      sweep: sweep,
    );
  }

  /// Points along the run of track from side [a] to side [b] of a hex of
  /// circumradius [radius] centred on [center], as tiles draw it, [count] +
  /// 1 of them evenly spaced from one side to the other.
  static List<Offset> runPoints(
      Offset center, double radius, int a, int b, int count) {
    final metric = _runPart(center, radius, a, b, 0, 1).computeMetrics().first;
    return [
      for (int i = 0; i <= count; i++)
        metric.getTangentForOffset(metric.length * i / count)!.position,
    ];
  }

  /// Where the arc's centre sits: on both sides' own lines, since an arc that
  /// meets a side at right angles has its centre along that side. Null when
  /// the sides are opposite and the track is straight.
  static Offset? _arcCentre(Offset center, double radius, int a, int b) {
    final da = HexGeometry.edgeNormal(a), db = HexGeometry.edgeNormal(b);
    final ma = center + da * (radius * _apothem);
    final mb = center + db * (radius * _apothem);
    final ta = Offset(-da.dy, da.dx), tb = Offset(-db.dy, db.dx);
    final cross = ta.dx * tb.dy - ta.dy * tb.dx;
    if (cross.abs() < 1e-9) return null; // opposite sides
    final diff = mb - ma;
    final s = (diff.dx * tb.dy - diff.dy * tb.dx) / cross;
    return ma + ta * s;
  }

  static const double _apothem = 0.8660254037844386;

  /// Rasterizes [def] into an [img.Image] for template matching.
  static Future<img.Image> rasterize(TileDefinition def,
      {int size = 64, int slotTurn = 0, TileStyle style = TileStyle.plain}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = Colors.white,
    );
    paint(canvas, def, size.toDouble(), slotTurn: slotTurn, style: style);
    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(size, size);
    final data = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    uiImage.dispose();
    if (data == null) {
      throw StateError('Failed to rasterize tile ${def.id}');
    }
    return img.Image.fromBytes(
      width: size,
      height: size,
      bytes: data.buffer,
      numChannels: 4,
    );
  }
}

/// Shows a tile definition as a widget, for the tile-correction UI.
class TilePainter extends CustomPainter {
  final TileDefinition definition;

  /// How far the tile is turned to look as printed (see
  /// `GameTitle.displayTurn`): a twelfth of a turn back for a flat-topped
  /// title.
  final double turn;

  const TilePainter(this.definition, {this.turn = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    canvas.save();
    canvas.translate(side / 2, side / 2);
    canvas.rotate(turn);
    canvas.translate(-side / 2, -side / 2);
    TileRenderer.paint(canvas, definition, side);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TilePainter oldDelegate) =>
      oldDelegate.definition != definition || oldDelegate.turn != turn;
}

/// Where a tile's stops sit, in a hex of circumradius 1 centred on the
/// origin, and which of them sit on a run of track from side to side.
class _StopLayout {
  final Map<int, Offset> at;
  final Map<int, _Ride> riding;

  const _StopLayout(this.at, this.riding);
}

/// A stop sitting on the run of track from side [a] to side [b]: a fraction
/// [t] of the way along it, where the track goes [along].
class _Ride {
  final int a;
  final int b;
  final double t;
  final Offset along;

  const _Ride(this.a, this.b, this.t, this.along);
}
