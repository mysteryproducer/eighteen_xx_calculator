import 'dart:math' as math;
import 'dart:ui';

import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/models/tile_definition.dart';
import 'package:eighteen_scanner/processing/hex_patch.dart';
import 'package:eighteen_scanner/processing/tile_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

final title = GameTitle.byId('1844')!;

/// Where stop [index] of [def] sits, in a hex of circumradius 1 centred on
/// the origin.
Offset stop(TileDefinition def, int index) =>
    TileRenderer.stationPosition(def, index, Offset.zero, 1);

/// The middle of side [edge] of that hex.
Offset side(int edge) => HexGeometry.edgeMidpoint(Offset.zero, 1, edge);

void main() {
  group('stops sit where tiles print them', () {
    test('a city on its own is in the middle', () {
      expect(stop(title.tiles['57']!, 0), Offset.zero);
      expect(stop(title.tiles['619']!.rotated(2), 0), Offset.zero);
    });

    test('a town on a gentle curve sits on the curve, not in the middle', () {
      // Tile 58: a town between sides 0 and 2. The curve's centre is the
      // next hex's, across side 1, and it passes a quarter of a radius from
      // the middle.
      final at = stop(title.tiles['58']!, 0);
      final nextHex = HexGeometry.edgeNormal(1) * math.sqrt(3);
      expect((at - nextHex).distance, closeTo(1.5, 0.01));
      expect(at.distance, closeTo(math.sqrt(3) - 1.5, 0.01));
    });

    test('a town on a tight turn sits on the turn, round the corner', () {
      // Tile 3: sides 0 and 1. The turn's centre is the corner they share.
      final at = stop(title.tiles['3']!, 0);
      final corner = HexGeometry.vertex(Offset.zero, 1, 1);
      expect((at - corner).distance, closeTo(0.5, 0.01));
      expect(at.distance, closeTo(0.5, 0.01));
    });

    test("tile 67, as laid at Fribourg, has a city on each of its runs", () {
      // Photographed on the board: one city on the straight from south-west
      // to north-east, a little way towards the north-east; the other on the
      // gentle curve from west to south-east, towards the south-east -- the
      // two stacked on the east side of the hex.
      final def = title.tiles['67']!.rotated(3);
      final straight = stop(def, 0);
      final curve = stop(def, 1);
      expect(straight.distance, closeTo(0.4, 0.05));
      // On the line through the middle towards side 3 (north-east).
      final northEast = HexGeometry.edgeNormal(3);
      expect(straight.dx * northEast.dy - straight.dy * northEast.dx,
          closeTo(0, 0.01));
      expect(straight.dx * northEast.dx + straight.dy * northEast.dy,
          greaterThan(0));
      // On the curve round the next hex across side 0, at its south-east end.
      final nextHex = HexGeometry.edgeNormal(0) * math.sqrt(3);
      expect((curve - nextHex).distance, closeTo(1.5, 0.01));
      expect(curve.dx, greaterThan(0));
      expect(curve.dy, greaterThan(0));
    });

    test('no two cities on a tile overlap, however it is turned', () {
      for (final id in ['59', '64', '65', '66', '67', '68']) {
        for (int turn = 0; turn < 6; turn++) {
          final def = title.tiles[id]!.rotated(turn);
          final cities = [
            for (final s in def.stations)
              if (s.kind == StationKind.city) s,
          ];
          for (int i = 0; i < cities.length; i++) {
            for (int j = i + 1; j < cities.length; j++) {
              final apart =
                  (stop(def, cities[i].index) - stop(def, cities[j].index))
                      .distance;
              expect(
                  apart,
                  greaterThanOrEqualTo(TileRenderer.slotRadiusFor(cities[i]) +
                      TileRenderer.slotRadiusFor(cities[j])),
                  reason: 'tile $id turned $turn');
            }
          }
        }
      }
    });

    test("1889's tile 5 has its city out in the corner between its sides",
        () {
      // Photographed at J11: the city half a radius out towards the corner
      // its two tracks share, the revenue in the middle.
      final g1889 = GameTitle.byId('1889')!;
      final city = stop(g1889.tiles['5']!, 0);
      final corner = HexGeometry.vertex(Offset.zero, 1, 1);
      expect(city.distance, closeTo(0.5, 0.01));
      expect((city / city.distance - corner).distance, lessThan(0.01));
    });

    test("1889's cities of two or three have smaller circles, closer", () {
      // 448 and 465 photographed: white discs about a quarter of the hex
      // across, touching.
      final g1889 = GameTitle.byId('1889')!;
      final two = g1889.tiles['448']!;
      final station = two.stations.firstWhere((s) => s.slots == 2);
      expect(TileRenderer.slotRadiusFor(station), 0.34);
      expect(TileRenderer.slotRadiusFor(station, style: g1889.tileStyle),
          closeTo(0.27, 0.001));
      final circles = TileRenderer.slotPositions(
          two, station.index, Offset.zero, 1,
          style: g1889.tileStyle);
      expect((circles[0] - circles[1]).distance, closeTo(0.54, 0.01));
      // A single circle is the same size as 1844's.
      final one = g1889.tiles['57']!.stations.single;
      expect(TileRenderer.slotRadiusFor(one, style: g1889.tileStyle), 0.33);
    });

    test('the printed OO hexes are laid out as the board prints them', () {
      // Romont & Fribourg one above the other; Winterthur & Frauenfeld on a
      // line rising to the right.
      final fribourg = title.map.byId('G8')!.printed;
      final upper = stop(fribourg, 0), lower = stop(fribourg, 1);
      expect(upper.dx, closeTo(0, 0.01));
      expect(lower.dx, closeTo(0, 0.01));
      expect(upper.dy, lessThan(-0.4));
      expect(lower.dy, greaterThan(0.4));
      final winterthur = title.map.byId('C20')!.printed;
      final right = stop(winterthur, 0), left = stop(winterthur, 1);
      expect(right.dx, greaterThan(0.3));
      expect(right.dy, lessThan(-0.2));
      expect(left.dx, lessThan(-0.3));
      expect(left.dy, greaterThan(0.2));
    });
  });

  group('drawn as the board prints them', () {
    // A 200-pixel drawing, and how dark it is where board point [at] falls
    // (circumradius 1, centred on the origin): 0 white, 1 black.
    Future<double Function(Offset)> drawn(TileDefinition def) async {
      final image = await TileRenderer.rasterize(def, size: 200);
      const scale = HexPatch.radiusShare * 200;
      return (at) {
        final p = image.getPixel(
            (100 + at.dx * scale).round(), (100 + at.dy * scale).round());
        return 1 - (p.r + p.g + p.b) / (3 * 255);
      };
    }

    test('track into a mountain railway only points into the hex', () async {
      // Pilatus (G14): five lines to the middle read as a junction to run
      // through; a route can only end there.
      final dark = await drawn(title.map.byId('G14')!.printed);
      expect(dark(side(3) * 0.9), greaterThan(0.8));
      expect(dark(Offset.zero), lessThan(0.4));
    });

    test('track into an off-board area only points into it', () async {
      final dark = await drawn(title.map.byId('L1')!.printed); // Lyon
      expect(dark(side(3) * 0.9), greaterThan(0.8));
      expect(dark(Offset.zero), lessThan(0.6));
    });

    test("1889's port tile shows its town as a disc, not 58's bar", () async {
      // The two are the same track; the port's town is a black disc with an
      // anchor in it. Away from the track, beside the town, the disc is dark
      // and the bar isn't there.
      final g1889 = GameTitle.byId('1889')!;
      final port = g1889.tiles['437']!, plain = g1889.tiles['58']!;
      expect(port.icons, contains('port'));
      final town = stop(port, 0);
      final along = (side(0) - town) / (side(0) - town).distance;
      final beside = town + Offset(-along.dy, along.dx) * 0.1 + along * 0.11;
      expect((await drawn(port))(beside), greaterThan(0.6));
      expect((await drawn(plain))(beside), lessThan(0.4));
    });

    test('a town where lines meet is a dot ringed in white', () async {
      // Brig (J13): six lines meeting at a town, which a plain dot was lost
      // in.
      final dark = await drawn(title.map.byId('J13')!.printed);
      expect(dark(Offset.zero), greaterThan(0.8));
      final between = HexGeometry.vertex(Offset.zero, 1, 0);
      expect(dark(between * 0.17), lessThan(0.1));
    });
  });

  group('the path a track is drawn along, which routes follow too', () {
    // The point a share of the way along [path].
    Offset along(Path path, double share) {
      final metric = path.computeMetrics().single;
      return metric.getTangentForOffset(metric.length * share)!.position;
    }

    Path track(TileDefinition def, int segment, {bool reversed = false}) =>
        TileRenderer.trackPath(def, def.segments[segment], Offset.zero, 1,
            reversed: reversed);

    test('a gentle curve runs round the next hex, not through the middle', () {
      // Tile 8: sides 0 and 2, round the hex across side 1, passing a
      // quarter of a radius from the middle.
      final path = track(title.tiles['8']!, 0);
      expect((along(path, 0) - side(0)).distance, lessThan(1e-6));
      expect((along(path, 1) - side(2)).distance, lessThan(1e-6));
      final nextHex = HexGeometry.edgeNormal(1) * math.sqrt(3);
      for (final share in [0.25, 0.5, 0.75]) {
        expect((along(path, share) - nextHex).distance, closeTo(1.5, 1e-3));
      }
      expect(along(path, 0.5).distance, closeTo(math.sqrt(3) - 1.5, 1e-3));
    });

    test('the other way, it runs back along the same curve', () {
      final def = title.tiles['8']!;
      final forward = track(def, 0), back = track(def, 0, reversed: true);
      for (final share in [0.0, 0.3, 0.5, 1.0]) {
        expect((along(back, share) - along(forward, 1 - share)).distance,
            lessThan(1e-3));
      }
    });

    test('to a town on a curve, it follows the curve to the town', () {
      // Tile 58: a town halfway along the curve tile 8 draws.
      final def = title.tiles['58']!;
      final town = stop(def, 0);
      final nextHex = HexGeometry.edgeNormal(1) * math.sqrt(3);
      final toTown = track(def, 0), fromTown = track(def, 1);
      expect((along(toTown, 0) - side(0)).distance, lessThan(1e-6));
      expect((along(toTown, 1) - town).distance, lessThan(1e-6));
      expect((along(fromTown, 0) - town).distance, lessThan(1e-6));
      expect((along(fromTown, 1) - side(2)).distance, lessThan(1e-6));
      for (final path in [toTown, fromTown]) {
        expect((along(path, 0.5) - nextHex).distance, closeTo(1.5, 1e-3));
      }
    });

    test("to a city on an OO tile's curve, it follows the curve", () {
      // Tile 67 as laid at Fribourg: its second city on the gentle curve
      // round the hex across side 0 (see above).
      final def = title.tiles['67']!.rotated(3);
      final city = stop(def, 1);
      final nextHex = HexGeometry.edgeNormal(0) * math.sqrt(3);
      for (int i = 0; i < def.segments.length; i++) {
        final ends = [def.segments[i].a, def.segments[i].b];
        if (!ends.contains(const StationEndpoint(1))) continue;
        final path = track(def, i);
        final cityEnd = ends.first == const StationEndpoint(1) ? 0.0 : 1.0;
        expect((along(path, cityEnd) - city).distance, lessThan(1e-6));
        for (final share in [0.0, 0.5, 1.0]) {
          expect((along(path, share) - nextHex).distance, closeTo(1.5, 1e-3));
        }
      }
    });

    test('to a city in the middle, it runs straight', () {
      final path = track(title.tiles['57']!, 0);
      expect((along(path, 0) - side(0)).distance, lessThan(1e-6));
      expect(along(path, 1).distance, lessThan(1e-6));
      expect((along(path, 0.5) - side(0) / 2).distance, lessThan(1e-6));
    });
  });
}
