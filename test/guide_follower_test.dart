import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eighteen_scanner/geometry/homography.dart';
import 'package:eighteen_scanner/models/board.dart';
import 'package:eighteen_scanner/processing/guide_follower.dart';
import 'package:eighteen_scanner/screens/capture.dart';
import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/synthetic_board.dart';

/// [photo]'s brightness, as a camera's preview frame gives it.
GrayFrame frameOf(img.Image photo) {
  final bytes = Uint8List(photo.width * photo.height * 4);
  for (final p in photo) {
    final i = (p.y * photo.width + p.x) * 4;
    bytes[i] = p.b.toInt();
    bytes[i + 1] = p.g.toInt();
    bytes[i + 2] = p.r.toInt();
    bytes[i + 3] = 255;
  }
  return GrayFrame.fromFourBytes(
      bytes, photo.width, photo.height, photo.width * 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('an adjustment', () {
    test('turns and scales about the middle of the frame, then shifts', () {
      const size = Size(800, 600);
      const adjustment =
          GuideAdjustment(turn: 0.3, scale: 1.2, shift: Offset(0.1, 0));
      final h = adjustment.inFrame(size);
      // The middle moves only by the shift, in units of the shorter side.
      final middle = h.apply(const Offset(400, 300));
      expect(middle.dx, closeTo(460, 1e-6));
      expect(middle.dy, closeTo(300, 1e-6));
      expect(GuideAdjustment.none.isNone, isTrue);
      final halfway = GuideAdjustment.none.toward(adjustment, 0.5);
      expect(halfway.turn, closeTo(0.15, 1e-9));
      expect(halfway.scale, closeTo(1.1, 1e-9));
    });
  });

  group('following the board', () {
    final target = title.map.byId('F11')!.coord; // Bern
    const closeRadius = 90.0;
    const size = 900;
    final guide = CaptureGuide(
      target: target,
      hexes: [for (final c in title.map.around([target], 1)) title.map.at(c)!],
      instruction: '',
      map: title.map,
    );
    final drawnAt = guide.unadjustedFor(const Size(size + 0.0, size + 0.0));

    /// A preview frame of the board turned [degrees] and shifted [shift] (in
    /// hex radii) from where the guide is drawn.
    Future<(img.Image, Homography)> preview(double degrees, Offset shift) async {
      final close = await drawBoard(title.map, hexRadius: closeRadius);
      final truth = boardToDrawn(title.map, closeRadius);
      // Board to frame as the guide draws it, then turned about the middle of
      // the frame and shifted.
      final wanted = drawnAt.then(GuideAdjustment(
              turn: degrees * math.pi / 180,
              shift: shift * (drawnAt.localScale(target.boardCenter) / size))
          .inFrame(const Size(size + 0.0, size + 0.0)));
      // Drawing to frame: undo the drawing's own placement, then that.
      final toFrame = truth.inverse.then(wanted);
      return (warp(close, toFrame, width: size, height: size), wanted);
    }

    test('a board turned and a little off is followed', () async {
      final (photo, wanted) = await preview(15, const Offset(0.3, -0.2));
      final found =
          followGuide(title.map, frameOf(photo), drawnAt, target);
      expect(found, isNotNull);
      expect(found!.turn * 180 / math.pi, closeTo(15, 3));
      // The guide, so moved, puts Bern where the board has it.
      final moved = guide.adjusted(found);
      final at = moved
          .homographyFor(const Size(size + 0.0, size + 0.0))
          .apply(target.boardCenter);
      final really = wanted.apply(target.boardCenter);
      expect((at - really).distance / drawnAt.localScale(target.boardCenter),
          lessThan(0.2));
    });

    test('a frame without the board leaves the guide where it is', () {
      final blank = img.Image(width: size, height: size);
      img.fill(blank, color: img.ColorRgb8(120, 110, 100));
      expect(followGuide(title.map, frameOf(blank), drawnAt, target), isNull);
    });

    group('locked on', () {
      /// The frame as a camera tilted forward sees it: the far rows (the
      /// top of the frame) narrower than the near ones by [squeeze].
      Homography tilted(double squeeze) => Homography.fromFourPoints(const [
            Offset(0, 0),
            Offset(size + 0.0, 0),
            Offset(size + 0.0, size + 0.0),
            Offset(0, size + 0.0),
          ], [
            Offset(size * squeeze / 2, size * squeeze / 4),
            Offset(size * (1 - squeeze / 2), size * squeeze / 4),
            const Offset(size + 0.0, size + 0.0),
            const Offset(0, size + 0.0),
          ])!;

      Future<(img.Image, Homography)> tiltedPreview(double squeeze) async {
        final close = await drawBoard(title.map, hexRadius: closeRadius);
        final truth = boardToDrawn(title.map, closeRadius);
        final wanted = drawnAt.then(tilted(squeeze));
        return (
          warp(close, truth.inverse.then(wanted), width: size, height: size),
          wanted
        );
      }

      test('the outline follows a camera tilted to dodge glare', () async {
        final (photo, wanted) = await tiltedPreview(0.3);
        // Locked on a look or two ago, part of the way into the tilt.
        final current = drawnAt.then(tilted(0.15));
        final found = trackGuide(title.map, frameOf(photo), current, target);
        expect(found, isNotNull);
        final hex = drawnAt.localScale(target.boardCenter);
        for (final c in title.map.around([target], 1)) {
          for (int i = 0; i < 6; i++) {
            final corner = HexGeometry.vertex(c.boardCenter, 1, i);
            expect((found!.apply(corner) - wanted.apply(corner)).distance / hex,
                lessThan(0.15),
                reason: 'corner $i of ${title.map.at(c)?.id}');
          }
        }
        // Stepping part of the way there moves it smoothly.
        final step = stepToward(current, found!, target.boardCenter, 0.5);
        final half = (step.apply(target.boardCenter) -
                current.apply(target.boardCenter)) +
            (step.apply(target.boardCenter) - found.apply(target.boardCenter));
        expect(half.distance / hex, lessThan(0.05));
      });

      test('a frame without the board leaves it where it is', () {
        final blank = img.Image(width: size, height: size);
        img.fill(blank, color: img.ColorRgb8(120, 110, 100));
        expect(
            trackGuide(title.map, frameOf(blank), drawnAt.then(tilted(0.2)),
                target),
            isNull);
      });
    });

    test('a board turned too far for a small correction is left alone',
        () async {
      final (photo, _) = await preview(40, Offset.zero);
      final found = followGuide(title.map, frameOf(photo), drawnAt, target);
      // Turned 40 degrees is the same grid turned 20 the other way; either
      // way the guide must not swing round to another set of hexes.
      if (found != null) {
        expect(found.turn.abs(), lessThanOrEqualTo(25 * math.pi / 180));
      }
    });
  });
}
