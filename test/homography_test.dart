import 'dart:math' as math;

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:flutter_test/flutter_test.dart';

/// A photo of a flat board taken from an angle: the transform the grid
/// detector has to recover.
final perspective = Homography([
  1.2, 0.1, 30, //
  0.05, 1.1, 20, //
  0.0004, 0.0002, 1,
]);

void main() {
  group('apply', () {
    test('a similarity moves, scales and turns', () {
      final h = Homography.similarity(
        scale: 2,
        radians: math.pi / 2,
        translation: const Offset(10, 5),
      );
      final p = h.apply(const Offset(1, 0));
      expect(p.dx, closeTo(10, 1e-9));
      expect(p.dy, closeTo(7, 1e-9));
    });

    test('an affine map sends the unit axes where told', () {
      final h = Homography.affine(
        origin: const Offset(3, 4),
        xAxis: const Offset(0, 2),
        yAxis: const Offset(-1, 0),
      );
      expect(h.apply(Offset.zero), const Offset(3, 4));
      expect(h.apply(const Offset(1, 0)), const Offset(3, 6));
      expect(h.apply(const Offset(0, 1)), const Offset(2, 4));
    });

    test('perspective brings distant points closer together', () {
      final near = perspective.apply(const Offset(0, 0));
      final far = perspective.apply(const Offset(1000, 0));
      final middle = perspective.apply(const Offset(500, 0));
      // Equal steps on the board are unequal in the photo.
      expect((middle - near).distance, greaterThan((far - middle).distance));
    });
  });

  group('inverse and composition', () {
    test('inverse undoes the transform', () {
      final back = perspective.inverse;
      for (final p in [const Offset(0, 0), const Offset(120, -40), const Offset(900, 600)]) {
        final round = back.apply(perspective.apply(p));
        expect(round.dx, closeTo(p.dx, 1e-6));
        expect(round.dy, closeTo(p.dy, 1e-6));
      }
    });

    test('then applies this transform first', () {
      final move = Homography.similarity(translation: const Offset(5, 0));
      final scale = Homography.similarity(scale: 2);
      expect(move.then(scale).apply(Offset.zero), const Offset(10, 0));
      expect(scale.then(move).apply(Offset.zero), const Offset(5, 0));
    });

    test('a non-invertible transform is reported, not silently wrong', () {
      expect(() => const Homography([1, 2, 3, 2, 4, 6, 0, 0, 1]).inverse,
          throwsStateError);
    });
  });

  group('fit', () {
    List<Offset> board() => const [
          Offset(0, 0),
          Offset(100, 0),
          Offset(100, 80),
          Offset(0, 80),
          Offset(50, 40),
        ];

    test('four points pin a perspective transform exactly', () {
      final from = board().take(4).toList();
      final to = [for (final p in from) perspective.apply(p)];
      final fitted = Homography.fromFourPoints(from, to)!;
      for (final p in board()) {
        final expected = perspective.apply(p);
        final actual = fitted.apply(p);
        expect((actual - expected).distance, lessThan(1e-6));
      }
    });

    test('more points than needed are fitted by least squares', () {
      final from = board();
      final to = [for (final p in from) perspective.apply(p)];
      // One badly placed point, as a shaky finger would make.
      to[2] += const Offset(3, -2);
      final fitted = Homography.fit(from, to)!;
      final middle = fitted.apply(const Offset(50, 40));
      expect((middle - perspective.apply(const Offset(50, 40))).distance,
          lessThan(4));
    });

    test('weights let a confident match pull harder', () {
      final from = board();
      final to = [for (final p in from) perspective.apply(p)];
      to[2] += const Offset(30, -20); // a wild outlier
      final weights = [1.0, 1.0, 0.001, 1.0, 1.0];
      final fitted = Homography.fit(from, to, weights: weights)!;
      final check = fitted.apply(const Offset(100, 0));
      expect((check - perspective.apply(const Offset(100, 0))).distance,
          lessThan(1));
    });

    test('three points in a line fit nothing', () {
      expect(
        Homography.fit(
          const [Offset(0, 0), Offset(1, 1), Offset(2, 2), Offset(3, 3)],
          const [Offset(0, 0), Offset(1, 1), Offset(2, 2), Offset(3, 3)],
        ),
        isNull,
      );
      expect(Homography.fit(const [Offset(0, 0)], const [Offset(1, 1)]), isNull);
    });
  });

  test('localScale reports how big a board unit is in the photo', () {
    final h = Homography.similarity(scale: 3);
    expect(h.localScale(const Offset(10, 10)), closeTo(3, 1e-6));
    // Under perspective the same board unit covers fewer pixels further away.
    expect(perspective.localScale(const Offset(1000, 0)),
        lessThan(perspective.localScale(const Offset(0, 0))));
  });

  test('survives a round trip through JSON', () {
    final restored = Homography.fromJson(perspective.toJson());
    expect(restored, perspective);
    expect(restored.hashCode, perspective.hashCode);
  });
}
