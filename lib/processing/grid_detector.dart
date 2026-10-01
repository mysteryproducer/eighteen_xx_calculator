import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import 'fft.dart';
import 'gray_image.dart';

/// Where a title's map sits in a photo, as found by [GridDetector].
class GridFit {
  /// Flat board (see [HexCoord.boardCenter]) to photo pixels.
  final Homography boardToImage;

  /// Map hexes wholly inside the photo.
  final Set<HexCoord> visible;

  /// Of the outline points checked on visible hexes, the share that sit on a
  /// printed line. Near 1 is a good fit; below about 0.5 the grid is likely
  /// off by some fraction of a hex somewhere.
  final double coverage;

  /// [coverage] per visible hex.
  final Map<HexCoord, double> hexCoverage;

  /// For a whole-board photo: how clearly the chosen placement of the map
  /// beat the next best one (0 = a tie, 1 = no contest). Null for close-ups
  /// and snaps, where the placement comes from the user.
  final double? placementMargin;

  const GridFit({
    required this.boardToImage,
    required this.visible,
    required this.coverage,
    required this.hexCoverage,
    this.placementMargin,
  });

  /// Good enough to scan from without the user checking it first.
  bool get isConvincing =>
      coverage >= 0.6 && (placementMargin == null || placementMargin! >= 0.15);
}

/// Finds a title's hex grid in a photo and works out the perspective
/// transform between the photo and the flat board.
///
/// There are three entry points, for the three ways a photo arrives:
///
/// * [fitBoard] -- a photo of the whole board with no other help. The hex
///   pattern's repeat distance and direction come from the autocorrelation of
///   the photo's thin dark lines; the grid is then pulled into line with the
///   printed hex outlines outward from the middle of the photo, which lets it
///   bend with the perspective; finally the title's map shape is slid over
///   the grid to find which hex is which, since only one placement makes the
///   map's ragged edge match where outlines stop.
/// * [fitCloseUp] -- a close-up taken with an on-screen guide, which already
///   says roughly which hexes are in frame and where.
/// * [snap] -- tightening a rough alignment the user made by hand.
///
/// All of it works on a copy of the photo about [workingSize] pixels across.
/// Everything here is plain Dart on typed arrays so it can run in a
/// background isolate.
class GridDetector {
  final MapLayout map;

  /// Longest side of the working copy of the photo, in pixels.
  final int workingSize;

  /// Receives a line per detection stage, for tuning.
  final void Function(String message)? log;

  GridDetector(this.map, {this.workingSize = 1024, this.log});

  // --- Entry points --------------------------------------------------------

  /// Finds the map in a photo of the whole board, or returns null if no hex
  /// grid could be found at all.
  GridFit? fitBoard(img.Image photo) {
    var work = _Working.of(photo, workingSize);
    log?.call('working ${work.lines.width}x${work.lines.height}, '
        'line threshold ${work.threshold.toStringAsFixed(3)}');
    final maxSpacing = _largestSpacing(work.lines.width, work.lines.height);
    final minSpacing = _smallestSpacing(work.lines.width, work.lines.height);
    var lattice = _estimateLattice(work.lines,
        log: log, maxSpacing: maxSpacing, minSpacing: minSpacing);
    if (lattice == null) {
      // A photo taken at a steep angle repeats at one spacing on the near
      // side of the board and two thirds of it on the far side, and over
      // the whole photo the repeat smears out. The middle of the photo
      // varies much less.
      log?.call('no repeat found; looking in the middle of the photo');
      final w = work.lines.width, h = work.lines.height;
      lattice = _estimateLattice(
          work.lines.cropped(w ~/ 5, h ~/ 5, w * 3 ~/ 5, h * 3 ~/ 5),
          log: log,
          maxSpacing: maxSpacing,
          minSpacing: minSpacing);
    }
    if (lattice == null) {
      // Perhaps the board fills the frame and its outlines are thick; look
      // again with a filter for wider lines.
      log?.call('no repeat found; trying again for thicker lines');
      work = _Working.of(photo, workingSize,
          hexSpacing: work.lines.width / 6);
      lattice = _estimateLattice(work.lines,
          log: log, maxSpacing: maxSpacing, minSpacing: minSpacing);
    }
    if (lattice == null) return null;
    log?.call('lattice east ${lattice.east} south-east ${lattice.southEast} '
        'strength ${lattice.strength.toStringAsFixed(2)}');
    work = work.normalized(lattice.east.distance);
    log?.call('normalized line threshold ${work.threshold.toStringAsFixed(3)}');

    final centre = Offset(work.lines.width / 2, work.lines.height / 2);
    final phase = _estimatePhase(work.lines, lattice, centre,
        radius: 4 * lattice.east.distance);
    log?.call('phase $phase');
    var h = lattice.homography(phase);
    h = _growLattice(work, h, log: log);
    log?.call('grown lattice $h');

    final placement = _placeMap(work, h, log: log);
    if (placement == null) return null;
    log?.call('placement turn ${placement.rotation} shift '
        '(${placement.dx}, ${placement.dz}) score '
        '${placement.score.toStringAsFixed(1)} margin '
        '${placement.margin.toStringAsFixed(2)}');
    h = placement.homography.then(h);

    final visible = _visibleHexes(work.lines, h, map.coords);
    h = _refine(work, h, visible, searchFractions: const [0.2, 0.12, 0.08]);
    return _result(work, h, placementMargin: placement.margin);
  }

  /// Fits a close-up whose rough placement [guess] (board to photo pixels)
  /// came from the capture guide. [target] is the hex the user was asked to
  /// centre, and anchors which lattice cell is which: the fit is trusted as
  /// long as the photo was framed to within about half a hex.
  GridFit? fitCloseUp(img.Image photo, Homography guess, HexCoord target) {
    var work = _Working.of(photo, workingSize,
        hexSpacing: _expectedSpacing(photo, guess, target.boardCenter));
    final guessWork = guess.then(work.toWorking);
    final targetInPhoto = guessWork.apply(target.boardCenter);
    final nearby = map.around([target], 3);

    Homography h;
    final lattice = _estimateLattice(work.lines,
        log: log, expected: _latticeOf(guessWork, target.boardCenter));
    log?.call('close-up lattice: ${lattice == null ? 'none' : 'east ${lattice.east} '
        'strength ${lattice.strength.toStringAsFixed(2)}'}');
    if (lattice != null) {
      work = work.normalized(lattice.east.distance);
      log?.call('rebuilt lines, threshold ${work.threshold.toStringAsFixed(2)}');
      final phase = _estimatePhase(work.lines, lattice, targetInPhoto,
          radius: 2.5 * lattice.east.distance);
      final latticeH = lattice.homography(phase);
      h = _alignToGuess(latticeH, guessWork, target);
      h = _grow(work, h, nearby, target);
    } else {
      h = _refine(work, guessWork, _visibleHexes(work.lines, guessWork, nearby),
          searchFractions: const [0.45, 0.3, 0.2, 0.12, 0.08]);
    }
    h = _settleShift(work, h, target);
    return _result(work, h, restrictTo: nearby);
  }

  /// A close-up framed a whole hex off looks just like one framed right:
  /// the grid is the same everywhere, so the guide is all that says which
  /// hex is which, and lining an outline of seven hexes up on the wrong
  /// seven is an easy slip. What does differ is what is printed where --
  /// grey mountain railways, purple tunnels, red off-board areas and blue
  /// lakes never move -- so the placements one hex each way are tried
  /// against the colours in the photo, and one is taken only if it matches
  /// them clearly better than where the guide put the grid. In the middle
  /// of a plain stretch of map there is nothing to tell them apart, and the
  /// guide stands.
  Homography _settleShift(_Working work, Homography h, HexCoord target) {
    final cells = <HexCoord>[];
    const reach = 4;
    for (int dz = -reach; dz <= reach; dz++) {
      for (int dx = -reach; dx <= reach; dx++) {
        if ((dx + dz).abs() > reach) continue;
        final c = HexCoord.fromCube(target.cubeX + dx, target.cubeZ + dz);
        // A close-up holds few whole hexes; the colour of a part-hex at the
        // edge of the frame counts as well.
        if (_inside(work.lines, h.apply(c.boardCenter), 0)) cells.add(c);
      }
    }
    final colours = _cellColours(work, h, cells);
    final hexes = map.around([target], 3);
    // Only yellow against blue: that is what sets the beige map and its
    // tiles apart from grey and purple hexes and lakes. Red against green
    // varies with the light and the printing more than it tells hexes apart.
    double agreement(int dx, int dz) {
      final expected = <double>[];
      final measured = <double>[];
      for (final c in hexes) {
        final seen = colours[(c.cubeX + dx, c.cubeZ + dz)];
        if (seen == null) continue;
        expected.add(_printedChroma(map.at(c)!.printed.color).dy);
        measured.add(seen.dy);
      }
      return _correlation(expected, measured);
    }

    final guided = agreement(0, 0);
    var best = (0, 0);
    var bestScore = guided;
    for (final (dx, dz) in const [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]) {
      final score = agreement(dx, dz);
      if (score > bestScore) {
        best = (dx, dz);
        bestScore = score;
      }
    }
    log?.call('close-up colours: as guided ${guided.toStringAsFixed(2)}, '
        'best step $best ${bestScore.toStringAsFixed(2)}');
    if (best == (0, 0) || bestScore < 0.4 || bestScore - guided < 0.3) return h;
    // Map hex c goes where the grid had c + step.
    final step = HexCoord.fromCube(target.cubeX + best.$1, target.cubeZ + best.$2)
            .boardCenter -
        target.boardCenter;
    return Homography.similarity(translation: step).then(h);
  }

  /// Pulls a hand-made alignment [guess] (board to photo pixels) onto the
  /// printed hex outlines nearby.
  GridFit snap(img.Image photo, Homography guess) {
    var work = _Working.of(photo, workingSize,
        hexSpacing: _expectedSpacing(photo, guess, map.boardBounds.center));
    final guessWork = guess.then(work.toWorking);
    final centre = Offset(work.lines.width / 2, work.lines.height / 2);

    // Take the hand-made placement as right in the middle of the photo, and
    // the printed grid as the authority on hex size and angle: dragging four
    // corners about gets the scale a percent or two out, which is half a hex
    // by the far side of the board.
    HexCoord? target;
    double best = double.infinity;
    for (final hex in _visibleHexes(work.lines, guessWork, map.coords)) {
      final d = (guessWork.apply(hex.boardCenter) - centre).distance;
      if (d < best) {
        best = d;
        target = hex;
      }
    }

    var h = guessWork;
    final lattice = target == null
        ? null
        : _estimateLattice(work.lines,
            expected: _latticeOf(guessWork, target.boardCenter));
    if (lattice != null && target != null) {
      work = work.normalized(lattice.east.distance);
      final phase = _estimatePhase(
          work.lines, lattice, guessWork.apply(target.boardCenter),
          radius: 2.5 * lattice.east.distance);
      h = _alignToGuess(lattice.homography(phase), guessWork, target);
    }
    h = _grow(work, h, map.coords, target ?? const HexCoord(0, 0));
    return _result(work, h);
  }

  /// The longest hex repeat, in pixels, a photo of the whole board can have:
  /// the one at which the map would be two and a half times the size of a
  /// [width] x [height] frame, whichever way round it is. A photo that cuts
  /// off the edges of the board still fits well inside that; a lattice of
  /// every fourth hex, which also repeats, doesn't.
  double _largestSpacing(int width, int height) {
    final bounds = map.boardBounds;
    double fit(double w, double h) =>
        math.min(w / bounds.width, h / bounds.height);
    final scale = math.max(fit(width.toDouble(), height.toDouble()),
        fit(height.toDouble(), width.toDouble()));
    return 2.5 * scale * math.sqrt(3);
  }

  /// The shortest hex repeat, in pixels, a photo of the whole board can have:
  /// the one at which the map would span only half of a [width] x [height]
  /// frame. A photo taken at an angle blurs the real repeat -- the far side
  /// of the board repeats at two thirds the spacing of the near side -- and
  /// then a pattern at half the spacing, or structure close around every
  /// hex, can repeat more strongly, putting a tiny grid in one corner.
  double _smallestSpacing(int width, int height) {
    final bounds = map.boardBounds;
    final scale = 0.5 *
        math.max(width, height) /
        math.max(bounds.width, bounds.height);
    return scale * math.sqrt(3);
  }

  /// The hex repeat [h] implies around [at]: where a step to the eastern and
  /// south-eastern neighbours lands.
  static _Lattice _latticeOf(Homography h, Offset at) {
    final centre = h.apply(at);
    const east = Offset(1.7320508075688772, 0);
    const southEast = Offset(0.8660254037844386, 1.5);
    return _Lattice(
      east: h.apply(at + east) - centre,
      southEast: h.apply(at + southEast) - centre,
      strength: 0,
    );
  }

  /// How far apart hex centres should be, in working pixels, if [guess] is
  /// about right.
  double _expectedSpacing(img.Image photo, Homography guess, Offset at) {
    final scale = GrayImage.scaleFor(photo.width, photo.height, workingSize);
    return guess.localScale(at) * math.sqrt(3) * scale;
  }

  /// Fits outward from [centre] in widening rings, so the parts of the photo
  /// the placement is already close on pull the rest into line, rather than
  /// a far corner that is a hex out dragging everything with it.
  static Homography _grow(
    _Working work,
    Homography h,
    Iterable<HexCoord> hexes,
    HexCoord centre, {
    List<double> searchFractions = const [0.3, 0.2, 0.12, 0.08],
  }) {
    final byDistance = [
      for (final hex in hexes)
        (hex, (hex.boardCenter - centre.boardCenter).distance),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (byDistance.isEmpty) return h;
    final furthest = byDistance.last.$2;
    var previous = 0;
    for (final radius in [4.0, 8.0, 14.0, 22.0, 32.0, furthest + 1]) {
      final within = [
        for (final (hex, d) in byDistance)
          if (d <= radius) hex,
      ];
      final visible = _visibleHexes(work.lines, h, within);
      if (visible.length == previous && radius > 8) continue;
      previous = visible.length;
      h = _refine(work, h, visible,
          searchFractions: const [0.3, 0.2], minCorrespondences: 24);
      if (radius > furthest) break;
    }
    return _refine(work, h, _visibleHexes(work.lines, h, hexes),
        searchFractions: searchFractions);
  }

  // --- Lattice: the repeating pattern, before it is tied to the map --------

  /// Finds the hex repeat from the autocorrelation of the line image: the
  /// photo shifted by exactly one hex lines up with itself, so the strongest
  /// peaks away from zero shift sit at the six neighbour offsets, 60 degrees
  /// apart.
  /// Finds the hex repeat in [lines]. [expected] is what the repeat should be
  /// if a guide or hand-made placement is roughly right, which turns a blind
  /// search into a look in the right place -- worth a lot on a close-up,
  /// where only a few hexes are in frame and the repeat away from the
  /// horizontal is weak. [maxSpacing] and [minSpacing] (pixels of [lines])
  /// rule out repeats too long or too short to be neighbouring hexes.
  static _Lattice? _estimateLattice(
    GrayImage lines, {
    void Function(String)? log,
    _Lattice? expected,
    double? maxSpacing,
    double? minSpacing,
  }) {
    const n = 512;
    const fitSide = 256;
    final scale = math.min(1.0, fitSide / math.max(lines.width, lines.height));
    final small = lines.scaled(scale);
    final w = small.width, h = small.height;

    final values = Float64List(n * n);
    final window = Float64List(n * n);
    final mean = small.mean;
    for (int y = 0; y < h; y++) {
      final wy = 0.5 - 0.5 * math.cos(2 * math.pi * (y + 0.5) / h);
      for (int x = 0; x < w; x++) {
        final wx = 0.5 - 0.5 * math.cos(2 * math.pi * (x + 0.5) / w);
        final win = wx * wy;
        values[y * n + x] = (small.data[y * w + x] - mean) * win;
        window[y * n + x] = win;
      }
    }
    final ac = Fft.autocorrelation(values, n);
    final wac = Fft.autocorrelation(window, n);
    if (ac[0] <= 0 || wac[0] <= 0) return null;

    // Correct for the shrinking overlap at larger shifts, so a peak far out
    // isn't penalised just for having less photo to compare.
    double at(int dx, int dy) {
      final i = ((dy % n + n) % n) * n + ((dx % n + n) % n);
      final overlap = wac[i] / wac[0];
      if (overlap < 0.2) return 0;
      return (ac[i] / wac[i]) / (ac[0] / wac[0]);
    }

    final rMin = 4;
    final rMax = math.min(w, h) ~/ 2;

    double atF(Offset d) {
      final x0 = d.dx.floor(), y0 = d.dy.floor();
      final ax = d.dx - x0, ay = d.dy - y0;
      return at(x0, y0) * (1 - ax) * (1 - ay) +
          at(x0 + 1, y0) * ax * (1 - ay) +
          at(x0, y0 + 1) * (1 - ax) * ay +
          at(x0 + 1, y0 + 1) * ax * ay;
    }


    /// Whether the photo really repeats at [d], rather than [d] just sitting
    /// on the slope of the central peak, where every short shift scores well.
    bool isPeak(Offset d) {
      final v = atF(d);
      if (v <= 0.02) return false;
      if (v <= atF(d * 0.75) || v <= atF(d * 1.3)) return false;
      for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
          if (ox == 0 && oy == 0) continue;
          if (atF(d + Offset(ox.toDouble(), oy.toDouble())) > v) return false;
        }
      }
      return true;
    }

    bool peakWithinPixel(Offset d) {
      for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
          if (isPeak(d + Offset(ox.toDouble(), oy.toDouble()))) return true;
        }
      }
      return false;
    }

    /// The strongest genuine repeat within [spread] of [v] in length and
    /// [degrees] of its direction.
    Offset? peakNear(Offset v, {double spread = 0.35, double degrees = 20}) {
      final length = v.distance;
      if (length < rMin) return null;
      final cosLimit = math.cos(degrees * math.pi / 180);
      Offset? best;
      double bestValue = 0;
      final limit = math.min(rMax.toDouble(), length * (1 + spread)).ceil();
      for (int dy = -limit; dy <= limit; dy++) {
        for (int dx = -limit; dx <= limit; dx++) {
          final d = Offset(dx.toDouble(), dy.toDouble());
          final ratio = d.distance / length;
          if (ratio < 1 - spread || ratio > 1 + spread) continue;
          if ((d.dx * v.dx + d.dy * v.dy) / (d.distance * length) < cosLimit) {
            continue;
          }
          final value = at(dx, dy);
          if (value > bestValue && isPeak(d)) {
            bestValue = value;
            best = d;
          }
        }
      }
      return best;
    }

    if (expected != null && log != null) {
      final e = expected.east * scale;
      log('expected east ${e.dx.toStringAsFixed(1)},${e.dy.toStringAsFixed(1)} '
          '(len ${e.distance.toStringAsFixed(1)})');
      final profile = <String>[];
      for (int k = 6; k <= 60; k += 2) {
        final d = e / e.distance * k.toDouble();
        profile.add('$k:${atF(d).toStringAsFixed(2)}');
      }
      log('along east: ${profile.join(' ')}');
      final se = expected.southEast * scale;
      final profile2 = <String>[];
      for (int k = 6; k <= 60; k += 2) {
        final d = se / se.distance * k.toDouble();
        profile2.add('$k:${atF(d).toStringAsFixed(2)}');
      }
      log('along south-east: ${profile2.join(' ')}');
    }

    if (expected != null) {
      Offset turn60(Offset v) => Offset(
            v.dx * 0.5 - v.dy * 0.8660254037844386,
            v.dx * 0.8660254037844386 + v.dy * 0.5,
          );

      // Look along each axis in turn. Either one alone pins the hex size and
      // the angle, which is what matters: a photo taken at a low angle keeps
      // the repeat along the rows but loses it across them, because
      // perspective squeezes the far rows closer together than the near ones.
      for (final (name, axis) in [
        ('east', expected.east * scale),
        ('south-east', expected.southEast * scale),
      ]) {
        final found = peakNear(axis);
        if (found == null) continue;
        final partner = peakNear(turn60(found), spread: 0.2, degrees: 12);
        final consistent = partner != null && isPeak(partner - found);
        final east = name == 'east' ? found : turn60(turn60(turn60(turn60(found))));
        final southEast = consistent && name == 'east' ? partner : turn60(east);
        log?.call('lattice from the $name repeat $found'
            '${consistent ? ' with its partner $partner' : ' alone'}');
        return _Lattice(
          east: east / scale,
          southEast: southEast / scale,
          strength: atF(found),
        );
      }
      log?.call('nothing at the expected repeat; searching the photo instead');
    }

    final peaks = <_Peak>[];
    for (int dy = 0; dy <= rMax; dy++) {
      for (int dx = -rMax; dx <= rMax; dx++) {
        if (dy == 0 && dx <= 0) continue;
        final r2 = dx * dx + dy * dy;
        if (r2 < rMin * rMin || r2 > rMax * rMax) continue;
        final v = at(dx, dy);
        if (v <= 0) continue;
        var isMax = true;
        for (int oy = -1; oy <= 1 && isMax; oy++) {
          for (int ox = -1; ox <= 1; ox++) {
            if (ox == 0 && oy == 0) continue;
            if (at(dx + ox, dy + oy) > v) {
              isMax = false;
              break;
            }
          }
        }
        if (isMax) peaks.add(_Peak(dx, dy, v));
      }
    }
    if (peaks.length < 2) return null;
    peaks.sort((a, b) => b.value.compareTo(a.value));
    final top = peaks.take(24).toList();
    log?.call('small ${w}x$h, ${peaks.length} peaks: '
        '${top.take(10).map((p) => '(${p.dx},${p.dy}) ${p.value.toStringAsFixed(2)}').join('  ')}');
    final candidates = [
      for (final p in top) ...[p, _Peak(-p.dx, -p.dy, p.value)],
    ];

    Offset refine(int dx, int dy) {
      double axis(double m, double c, double p) {
        final denom = m - 2 * c + p;
        if (denom.abs() < 1e-12) return 0;
        return (0.5 * (m - p) / denom).clamp(-0.5, 0.5);
      }

      final c = at(dx, dy);
      return Offset(
        dx + axis(at(dx - 1, dy), c, at(dx + 1, dy)),
        dy + axis(at(dx, dy - 1), c, at(dx, dy + 1)),
      );
    }

    final longest = maxSpacing == null ? double.infinity : maxSpacing * scale;
    final shortest = minSpacing == null ? 0.0 : minSpacing * scale;
    final triples = <_Triple>[];
    for (final p in candidates) {
      for (final q in candidates) {
        final pv = Offset(p.dx.toDouble(), p.dy.toDouble());
        final qv = Offset(q.dx.toDouble(), q.dy.toDouble());
        final cross = pv.dx * qv.dy - pv.dy * qv.dx;
        if (cross <= 0) continue;
        if (pv.distance > longest || qv.distance > longest) continue;
        if (pv.distance < shortest || qv.distance < shortest) continue;
        final ratio = qv.distance / pv.distance;
        if (ratio < 0.8 || ratio > 1.25) continue;
        final angle = math.acos(
            ((pv.dx * qv.dx + pv.dy * qv.dy) / (pv.distance * qv.distance))
                .clamp(-1.0, 1.0));
        if (angle < 45 * math.pi / 180 || angle > 75 * math.pi / 180) continue;
        final r = at(q.dx - p.dx, q.dy - p.dy);
        final score = math.min(p.value, math.min(q.value, r));
        // Short shifts along the slope of the central peak are local maxima
        // too; only a real repeat is worth preferring for being fine. The
        // third side is the difference of two rounded peaks, so its own
        // peak may be a pixel away.
        if (!isPeak(pv) || !isPeak(qv) || !peakWithinPixel(qv - pv)) continue;
        triples.add(_Triple(p, q, score));
      }
    }
    _Triple? best;
    for (final t in triples) {
      if (best == null || t.score > best.score) best = t;
    }
    log?.call('best triple: ${best == null ? 'none' : '${best.p.dx},${best.p.dy} / '
        '${best.q.dx},${best.q.dy} score ${best.score.toStringAsFixed(3)}'}');
    if (best == null || best.score < 0.05) return null;

    var p = refine(best.p.dx, best.p.dy);
    var q = refine(best.q.dx, best.q.dy);
    var r = refine(best.q.dx - best.p.dx, best.q.dy - best.p.dy);
    // Least-squares basis from the three measured neighbour offsets.
    var a = (p * 2 + q - r) / 3;
    var b = (p + q * 2 + r) / 3;
    var strength = best.score;

    // Every other hex, or every third along a diagonal, repeats too. If the
    // strongest repeat is one of those coarser grids of a finer one that is
    // nearly as strong, the finer one is the real hex grid.
    for (var guard = 0; guard < 3; guard++) {
      final finer = [
        (a / 2, b / 2), // every other hex
        ((a * 2 - b) / 3, (a + b) / 3), // the sqrt(3) diagonal grid
      ];
      var changed = false;
      for (final (fa, fb) in finer) {
        if (fa.distance < rMin) continue;
        if (!isPeak(fa) || !isPeak(fb) || !isPeak(fb - fa)) continue;
        final score = math.min(atF(fa), math.min(atF(fb), atF(fb - fa)));
        if (score >= strength * 0.6) {
          a = fa;
          b = fb;
          strength = score;
          changed = true;
          break;
        }
      }
      if (!changed) break;
    }
    log?.call('lattice from ${best.p.dx},${best.p.dy} / ${best.q.dx},${best.q.dy} '
        'score ${best.score.toStringAsFixed(2)} -> a $a b $b');

    // Of the six neighbour directions, call the one nearest the photo's +x
    // "east"; the next one clockwise is south-east. Which way round the map
    // really is gets settled when it is placed on the grid.
    final dirs = [a, b, b - a, -a, -b, a - b];
    dirs.sort((u, v) => _angleFromX(u).abs().compareTo(_angleFromX(v).abs()));
    final east = dirs.first;
    final wanted = _angleFromX(east) + math.pi / 3;
    dirs.sort((u, v) => _angleDiff(_angleFromX(u), wanted)
        .compareTo(_angleDiff(_angleFromX(v), wanted)));
    final southEast = dirs.first;

    return _Lattice(
      east: east / scale,
      southEast: southEast / scale,
      strength: strength,
    );
  }

  static double _angleFromX(Offset v) => math.atan2(v.dy, v.dx);

  static double _angleDiff(double a, double b) {
    var d = (a - b) % (2 * math.pi);
    if (d > math.pi) d -= 2 * math.pi;
    if (d < -math.pi) d += 2 * math.pi;
    return d.abs();
  }

  /// Where a hex centre falls, near [centre]: the line image is folded onto
  /// one repeat of the lattice (averaging every hex in the area together) and
  /// matched against an ideal hex outline.
  static Offset _estimatePhase(
    GrayImage lines,
    _Lattice lattice,
    Offset centre, {
    required double radius,
  }) {
    const bins = 32;
    final fold = Float64List(bins * bins);
    final count = Int32List(bins * bins);
    final e = lattice.east, s = lattice.southEast;
    final det = e.dx * s.dy - e.dy * s.dx;
    final x0 = math.max(0, (centre.dx - radius).floor());
    final x1 = math.min(lines.width - 1, (centre.dx + radius).ceil());
    final y0 = math.max(0, (centre.dy - radius).floor());
    final y1 = math.min(lines.height - 1, (centre.dy + radius).ceil());
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        final px = x - centre.dx, py = y - centre.dy;
        if (px * px + py * py > radius * radius) continue;
        final u = (px * s.dy - py * s.dx) / det;
        final v = (e.dx * py - e.dy * px) / det;
        final bu = ((u - u.floorToDouble()) * bins).floor() % bins;
        final bv = ((v - v.floorToDouble()) * bins).floor() % bins;
        fold[bv * bins + bu] += lines.data[y * lines.width + x];
        count[bv * bins + bu]++;
      }
    }
    for (int i = 0; i < fold.length; i++) {
      if (count[i] > 0) fold[i] /= count[i];
    }

    // The ideal pattern: bright on the hex outline, dark inside.
    final template = Float64List(bins * bins);
    const eb = Offset(1.7320508075688772, 0); // east neighbour, board units
    const sb = Offset(0.8660254037844386, 1.5); // south-east neighbour
    for (int j = 0; j < bins; j++) {
      for (int i = 0; i < bins; i++) {
        final u = (i + 0.5) / bins, v = (j + 0.5) / bins;
        final p = eb * u + sb * v;
        final c = HexCoord.nearestTo(p).boardCenter;
        final d = _apothem - _hexNorm(p - c);
        template[j * bins + i] = math.exp(-(d * d) / (0.12 * 0.12));
      }
    }
    double bestScore = -double.infinity;
    int bestI = 0, bestJ = 0;
    for (int sj = 0; sj < bins; sj++) {
      for (int si = 0; si < bins; si++) {
        double score = 0;
        for (int j = 0; j < bins; j++) {
          final fj = ((j + sj) % bins) * bins;
          for (int i = 0; i < bins; i++) {
            score += fold[fj + (i + si) % bins] * template[j * bins + i];
          }
        }
        if (score > bestScore) {
          bestScore = score;
          bestI = si;
          bestJ = sj;
        }
      }
    }
    return centre + e * ((bestI + 0.5) / bins) + s * ((bestJ + 0.5) / bins);
  }

  static const double _apothem = 0.8660254037844386;

  /// Distance from the centre of a pointy-top hex of circumradius 1 in the
  /// hex's own metric: [_apothem] on the outline, less inside.
  static double _hexNorm(Offset v) {
    final a = v.dx.abs();
    final b = (0.5 * v.dx + 0.8660254037844386 * v.dy).abs();
    final c = (-0.5 * v.dx + 0.8660254037844386 * v.dy).abs();
    return math.max(a, math.max(b, c));
  }

  /// Fits the lattice outward from its origin, a ring at a time, so the
  /// perspective across the photo is picked up gradually and the grid never
  /// has to jump more than a fraction of a hex to find the outlines.
  static Homography _growLattice(
    _Working work,
    Homography h, {
    void Function(String)? log,
  }) {
    final lines = work.lines;
    var previous = -1;
    for (final radius in [2.0, 3.5, 5.0, 7.0, 9.5, 12.5, 16.0, 20.0, 25.0, 31.0, 38.0]) {
      final cells = <HexCoord>[];
      final steps = (radius / math.sqrt(3)).ceil() + 1;
      for (int dz = -steps; dz <= steps; dz++) {
        for (int dx = -steps; dx <= steps; dx++) {
          final c = HexCoord.fromCube(dx, dz);
          if (c.boardCenter.distance > radius) continue;
          cells.add(c);
        }
      }
      final visible = _visibleHexes(lines, h, cells);
      if (visible.length == previous && radius > 5) break;
      previous = visible.length;
      h = _refine(work, h, visible,
          searchFractions: const [0.25, 0.18], minCorrespondences: 24);
      log?.call('grow r=$radius: ${visible.length} cells, '
          'hex size ${h.localScale(Offset.zero).toStringAsFixed(1)} px at origin');
    }
    return h;
  }

  // --- Placing the map on the lattice --------------------------------------

  /// Slides (and turns, in 60 degree steps) the map over the lattice to where
  /// the most map hexes land on printed outlines and the fewest outlines are
  /// left uncovered. Returns the board-to-lattice transform.
  _Placement? _placeMap(
    _Working work,
    Homography latticeH, {
    void Function(String)? log,
  }) {
    // Score every lattice cell in the photo by how much outline it shows.
    final cells = <HexCoord, double>{};
    final steps = 60;
    for (int dz = -steps; dz <= steps; dz++) {
      for (int dx = -steps; dx <= steps; dx++) {
        final c = HexCoord.fromCube(dx, dz);
        final centre = latticeH.apply(c.boardCenter);
        if (!_inside(work.lines, centre, 0)) continue;
        if (!_hexInside(work.lines, latticeH, c)) continue;
        cells[c] = _outlineStrength(work, latticeH, c);
      }
    }
    if (cells.length < 4) return null;
    final threshold = _otsu(cells.values.toList());
    log?.call('${cells.length} cells in view, outline threshold '
        '${threshold.toStringAsFixed(2)}, '
        '${cells.values.where((v) => v > threshold).length} above');
    // A covered cell scores its excess over the threshold; an outlined cell
    // the map leaves uncovered costs its excess.
    final gain = <(int, int), double>{
      for (final e in cells.entries)
        (e.key.cubeX, e.key.cubeZ): e.value - threshold > 0
            ? 2 * (e.value - threshold)
            : e.value - threshold,
    };

    int minX = 1 << 30, maxX = -(1 << 30), minZ = 1 << 30, maxZ = -(1 << 30);
    for (final c in cells.keys) {
      minX = math.min(minX, c.cubeX);
      maxX = math.max(maxX, c.cubeX);
      minZ = math.min(minZ, c.cubeZ);
      maxZ = math.max(maxZ, c.cubeZ);
    }

    final scores = <_Placement>[];
    const origin = HexCoord(0, 0);
    for (int k = 0; k < 6; k++) {
      final rotated = [
        for (final c in map.coords) c.rotatedAbout(origin, k),
      ];
      int rMinX = 1 << 30, rMaxX = -(1 << 30), rMinZ = 1 << 30, rMaxZ = -(1 << 30);
      for (final c in rotated) {
        rMinX = math.min(rMinX, c.cubeX);
        rMaxX = math.max(rMaxX, c.cubeX);
        rMinZ = math.min(rMinZ, c.cubeZ);
        rMaxZ = math.max(rMaxZ, c.cubeZ);
      }
      for (int tz = minZ - rMaxZ; tz <= maxZ - rMinZ; tz++) {
        for (int tx = minX - rMaxX; tx <= maxX - rMinX; tx++) {
          double score = 0;
          for (final c in rotated) {
            score += gain[(c.cubeX + tx, c.cubeZ + tz)] ?? 0;
          }
          scores.add(_Placement(k, tx, tz, score));
        }
      }
    }
    scores.sort((a, b) => b.score.compareTo(a.score));
    final bestOutline = scores.first.score;
    if (bestOutline <= 0) return null;

    // The map's outline alone can fit nearly as well turned round or shifted
    // along a straight edge, so among the placements that fit the outlines
    // about as well as the best, prefer the one whose printed colours --
    // red off-board areas, yellow and grey pre-printed hexes -- match the
    // photo.
    final colours = _cellColours(work, latticeH, cells.keys);
    final shortlist = [
      for (final p in scores.take(400))
        if (p.score >= bestOutline * 0.8) p,
    ];
    final ranked = <(_Placement, double)>[];
    for (final p in shortlist) {
      final agreement = _colourAgreement(p, colours);
      ranked.add((p, p.score / bestOutline + agreement));
    }
    ranked.sort((a, b) => b.$2.compareTo(a.$2));
    log?.call('top placements: ${ranked.take(6).map((r) => 'k${r.$1.rotation}(${r.$1.dx},${r.$1.dz}) '
        'outline ${r.$1.score.toStringAsFixed(1)} total ${r.$2.toStringAsFixed(2)}').join('  ')}');
    final best = ranked.first;
    final runnerUp = ranked.length > 1 ? ranked[1].$2 : 0.0;
    return _Placement(best.$1.rotation, best.$1.dx, best.$1.dz, best.$1.score,
        margin: ((best.$2 - runnerUp) / best.$2).clamp(0.0, 1.0));
  }

  /// Chromaticity of each cell's interior: (red - green, yellow - blue), in
  /// shares of total brightness so lighting level drops out.
  static Map<(int, int), Offset> _cellColours(
    _Working work,
    Homography latticeH,
    Iterable<HexCoord> cells,
  ) {
    final result = <(int, int), Offset>{};
    final rgb = List<double>.filled(3, 0);
    for (final cell in cells) {
      final c = cell.boardCenter;
      double r = 0, g = 0, b = 0;
      int n = 0;
      for (double y = -0.6; y <= 0.61; y += 0.2) {
        for (double x = -0.6; x <= 0.61; x += 0.2) {
          final p = latticeH.apply(c + Offset(x, y));
          if (!work.color.contains(p.dx, p.dy)) continue;
          work.color.sample(p.dx, p.dy, rgb);
          r += rgb[0];
          g += rgb[1];
          b += rgb[2];
          n++;
        }
      }
      final sum = r + g + b;
      if (n == 0 || sum <= 0) continue;
      result[(cell.cubeX, cell.cubeZ)] =
          Offset((r - g) / sum, ((r + g) / 2 - b) / sum);
    }
    // Light falling unevenly across the board shifts every colour in an area
    // together, by more than the difference between a beige and a grey hex.
    // Measuring each cell against the median of its neighbours leaves only
    // what is printed.
    final relative = <(int, int), Offset>{};
    result.forEach((key, colour) {
      final xs = <double>[], ys = <double>[];
      for (int dz = -2; dz <= 2; dz++) {
        for (int dx = -2; dx <= 2; dx++) {
          if ((dx + dz).abs() > 2 || (dx == 0 && dz == 0)) continue;
          final n = result[(key.$1 + dx, key.$2 + dz)];
          if (n == null) continue;
          xs.add(n.dx);
          ys.add(n.dy);
        }
      }
      if (xs.length < 4) return;
      xs.sort();
      ys.sort();
      relative[key] = colour - Offset(xs[xs.length ~/ 2], ys[ys.length ~/ 2]);
    });
    return relative;
  }

  /// Correlation (-1..1) between the colours [placement] says the covered
  /// cells should be printed in and the colours they are in the photo.
  double _colourAgreement(_Placement placement, Map<(int, int), Offset> colours) {
    final expected = <Offset>[];
    final measured = <Offset>[];
    for (final hex in map.hexes) {
      final c = hex.coord.rotatedAbout(const HexCoord(0, 0), placement.rotation);
      final seen = colours[(c.cubeX + placement.dx, c.cubeZ + placement.dz)];
      if (seen == null) continue;
      expected.add(_printedChroma(hex.printed.color));
      measured.add(seen);
    }
    return (_correlation([for (final e in expected) e.dx],
                [for (final m in measured) m.dx]) +
            _correlation([for (final e in expected) e.dy],
                [for (final m in measured) m.dy])) /
        2;
  }

  /// Correlation (-1..1) between [expected] and [measured]. Zero when there
  /// are too few to say, or nothing varies.
  static double _correlation(List<double> expected, List<double> measured) {
    final n = expected.length;
    if (n < 6) return 0;
    double mx = 0, my = 0;
    for (int i = 0; i < n; i++) {
      mx += expected[i];
      my += measured[i];
    }
    mx /= n;
    my /= n;
    double sxy = 0, sxx = 0, syy = 0;
    for (int i = 0; i < n; i++) {
      final dx = expected[i] - mx, dy = measured[i] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
    }
    if (sxx <= 1e-12 || syy <= 1e-12) return 0;
    return sxy / math.sqrt(sxx * syy);
  }

  /// The chromaticity a hex printed in [color] is expected to have, on the
  /// same scale as [_cellColours].
  static Offset _printedChroma(TileColor color) => switch (color) {
        TileColor.red => const Offset(0.27, 0.16),
        TileColor.yellow => const Offset(0.035, 0.29),
        TileColor.green => const Offset(-0.1, 0.05),
        TileColor.brown => const Offset(0.15, 0.12),
        TileColor.grey || TileColor.purple => const Offset(0, 0),
        TileColor.blue => const Offset(-0.11, -0.16),
        TileColor.plain => const Offset(0.01, 0.03),
      };

  /// Otsu's threshold: the split of [values] into two groups that are each
  /// as tight as possible.
  static double _otsu(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final n = sorted.length;
    final total = sorted.fold<double>(0, (a, b) => a + b);
    double bestVariance = -1, bestThreshold = sorted[n ~/ 2];
    double sumLow = 0;
    for (int i = 0; i < n - 1; i++) {
      sumLow += sorted[i];
      final wLow = (i + 1) / n, wHigh = 1 - wLow;
      final meanLow = sumLow / (i + 1);
      final meanHigh = (total - sumLow) / (n - i - 1);
      final between = wLow * wHigh * (meanLow - meanHigh) * (meanLow - meanHigh);
      if (between > bestVariance) {
        bestVariance = between;
        bestThreshold = (sorted[i] + sorted[i + 1]) / 2;
      }
    }
    return bestThreshold;
  }

  /// Turns [latticeH] (lattice board to photo) and a guide's [guess] (map
  /// board to photo) into a map-board-to-photo transform that follows the
  /// lattice: same orientation as the guess to the nearest 60 degrees, and
  /// [target] on the lattice cell nearest where the guess put it.
  static Homography _alignToGuess(
    Homography latticeH,
    Homography guess,
    HexCoord target,
  ) {
    final t = target.boardCenter;
    final guessCentre = guess.apply(t);
    final guessEast = guess.apply(t + const Offset(1, 0)) - guessCentre;
    final wanted = _angleFromX(guessEast);

    // Direction of board east through the lattice at the target, for each
    // 60 degree turn of the map.
    final latticeTarget =
        HexCoord.nearestTo(latticeH.inverse.apply(guessCentre));
    final latticeCentre = latticeH.apply(latticeTarget.boardCenter);
    int bestK = 0;
    double bestDiff = double.infinity;
    for (int k = 0; k < 6; k++) {
      final dir = Offset(math.cos(k * math.pi / 3), math.sin(k * math.pi / 3));
      final east =
          latticeH.apply(latticeTarget.boardCenter + dir) - latticeCentre;
      final diff = _angleDiff(_angleFromX(east), wanted);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestK = k;
      }
    }
    final rotatedTarget = target.rotatedAbout(const HexCoord(0, 0), bestK);
    final dx = latticeTarget.cubeX - rotatedTarget.cubeX;
    final dz = latticeTarget.cubeZ - rotatedTarget.cubeZ;
    return _Placement(bestK, dx, dz, 0).homography.then(latticeH);
  }

  // --- Refinement ----------------------------------------------------------

  /// Iteratively pulls the grid onto the printed outlines: every sample point
  /// on each hex's predicted outline looks along the outline's normal for
  /// the darkest line within a search distance (a fraction of the local hex
  /// size), and a new perspective transform is fitted to the matches, with
  /// outliers down-weighted. Each entry of [searchFractions] is one pass,
  /// usually shrinking.
  static Homography _refine(
    _Working work,
    Homography h,
    Iterable<HexCoord> hexes, {
    required List<double> searchFractions,
    int minCorrespondences = 40,
  }) {
    final lines = work.lines;
    final hexList = hexes.toList();
    final hexSet = hexList.toSet();
    if (hexList.isEmpty) return h;
    for (final fraction in searchFractions) {
      final from = <Offset>[];
      final to = <Offset>[];
      final weights = <double>[];
      final limits = <double>[];
      for (final hex in hexList) {
        final c = hex.boardCenter;
        final radiusPx = h.localScale(c);
        final search = math.max(1.5, fraction * radiusPx);
        for (int k = 0; k < 6; k++) {
          // Each shared side is visited from both hexes; only count it once.
          if (k >= 3 && hexSet.contains(Board.neighborOf(hex, k))) continue;
          final v1 = HexGeometry.vertex(c, 1, k);
          final v2 = HexGeometry.vertex(c, 1, (k + 1) % 6);
          final normal = HexGeometry.edgeNormal(k);
          for (final t in _edgeSamples) {
            final b = v1 + (v2 - v1) * t;
            final match = _searchLine(lines, h, b, normal, search, work.threshold);
            if (match == null) continue;
            from.add(b);
            to.add(match.$1);
            weights.add(match.$2);
            limits.add(search);
          }
        }
      }
      if (from.length < minCorrespondences) continue;
      var fitted = Homography.fit(from, to, weights: weights);
      if (fitted == null) continue;
      // Down-weight matches that disagree with the consensus (Huber).
      for (int pass = 0; pass < 2; pass++) {
        final robust = <double>[];
        for (int i = 0; i < from.length; i++) {
          final residual = (fitted!.apply(from[i]) - to[i]).distance;
          final k = limits[i] * 0.3;
          robust.add(weights[i] * (residual <= k ? 1 : k / residual));
        }
        final again = Homography.fit(from, to, weights: robust);
        if (again == null) break;
        fitted = again;
      }
      h = fitted!;
    }
    return h;
  }

  static const List<double> _edgeSamples = [0.2, 0.35, 0.5, 0.65, 0.8];

  /// Looks along [normal] (board units) from board point [b] for the
  /// strongest dark line within [search] photo pixels. Returns where it is in
  /// the photo and how strong, or null if nothing clears [threshold].
  static (Offset, double)? _searchLine(
    GrayImage lines,
    Homography h,
    Offset b,
    Offset normal,
    double search,
    double threshold,
  ) {
    final p = h.apply(b);
    if (!_inside(lines, p, search + 1)) return null;
    final q = h.apply(b + normal * 0.05);
    var n = q - p;
    final len = n.distance;
    if (len < 1e-9) return null;
    n = n / len;
    const step = 0.5;
    final count = (search / step).ceil();
    double best = -1;
    int bestI = 0;
    final values = Float64List(2 * count + 1);
    for (int i = -count; i <= count; i++) {
      final s = p + n * (i * step);
      final v = lines.sample(s.dx, s.dy);
      values[i + count] = v;
      if (v > best) {
        best = v;
        bestI = i;
      }
    }
    if (best < threshold) return null;
    // A maximum at the very end of the search is just the slope of something
    // further away.
    if (bestI == -count || bestI == count) return null;
    final m = values[bestI + count - 1], c = values[bestI + count], pl = values[bestI + count + 1];
    final denom = m - 2 * c + pl;
    final offset = denom.abs() < 1e-12 ? 0.0 : (0.5 * (m - pl) / denom).clamp(-0.5, 0.5);
    return (p + n * ((bestI + offset) * step), best);
  }

  // --- Measuring a fit -------------------------------------------------------

  static bool _inside(GrayImage image, Offset p, double margin) =>
      p.dx >= margin &&
      p.dy >= margin &&
      p.dx <= image.width - 1 - margin &&
      p.dy <= image.height - 1 - margin;

  static bool _hexInside(GrayImage image, Homography h, HexCoord c) {
    for (int i = 0; i < 6; i++) {
      if (!_inside(image, h.apply(HexGeometry.vertex(c.boardCenter, 1, i)), 1)) {
        return false;
      }
    }
    return true;
  }

  static Set<HexCoord> _visibleHexes(
    GrayImage image,
    Homography h,
    Iterable<HexCoord> hexes,
  ) =>
      {
        for (final c in hexes)
          if (_hexInside(image, h, c)) c,
      };

  /// Share of a hex's outline sample points that sit on a line, allowing for
  /// the line's own width and a little slack -- more of it on a close-up,
  /// where a printed line is many pixels across.
  static double _outlineStrength(_Working work, Homography h, HexCoord hex) {
    final c = hex.boardCenter;
    final slack = math.max(2.5, h.localScale(c) * 0.03);
    int hits = 0, total = 0;
    for (int k = 0; k < 6; k++) {
      final v1 = HexGeometry.vertex(c, 1, k);
      final v2 = HexGeometry.vertex(c, 1, (k + 1) % 6);
      final normal = HexGeometry.edgeNormal(k);
      for (final t in _edgeSamples) {
        total++;
        final match = _searchLine(
            work.lines, h, v1 + (v2 - v1) * t, normal, slack, work.threshold);
        if (match != null) hits++;
      }
    }
    return total == 0 ? 0 : hits / total;
  }

  GridFit _result(
    _Working work,
    Homography h, {
    double? placementMargin,
    Set<HexCoord>? restrictTo,
  }) {
    final visible = _visibleHexes(work.lines, h, restrictTo ?? map.coords);
    final perHex = <HexCoord, double>{};
    for (final hex in visible) {
      perHex[hex] = _outlineStrength(work, h, hex);
    }
    // Off-board areas and the hexes at the edge of the map are printed as
    // part-hexes running off the board, so their outlines are missing however
    // well the grid is placed. Judge the fit on the hexes that are drawn in
    // full -- the ones tiles go on -- and only fall back to all of them when
    // a photo holds none.
    var judged = [
      for (final hex in visible)
        if (map.at(hex)?.takesTiles ?? false) perHex[hex]!,
    ];
    if (judged.isEmpty) judged = perHex.values.toList();
    double sum = 0;
    for (final s in judged) {
      sum += s;
    }
    final toPhoto = h.then(work.toWorking.inverse);
    return GridFit(
      boardToImage: toPhoto,
      visible: visible,
      coverage: judged.isEmpty ? 0 : sum / judged.length,
      hexCoverage: perHex,
      placementMargin: placementMargin,
    );
  }
}

/// The photo prepared for detection: shrunk to working size, and turned into
/// a map of how strongly each pixel lies on a thin dark line.
class _Working {
  final GrayImage lines;

  /// The photo in grey at working size, to build [lines] from again once the
  /// hex size is known.
  final GrayImage gray;

  /// The photo in colour at working size, for matching printed colours.
  final RgbImage color;

  /// Photo pixels to working pixels.
  final Homography toWorking;

  /// Line strength that counts as "on a printed line".
  final double threshold;

  _Working(this.lines, this.gray, this.color, this.toWorking, this.threshold);

  /// [hexSpacing], in working pixels, tunes the line filter to how wide the
  /// printed outlines will be. Without it the filter looks for the thinnest
  /// lines worth finding, which is right for a photo of a whole board.
  factory _Working.of(img.Image photo, int workingSize, {double? hexSpacing}) {
    final gray = GrayImage.fromImage(photo, maxSide: workingSize);
    final scale = gray.width / photo.width;
    final color = RgbImage.fromImage(img.copyResize(photo,
        width: gray.width,
        height: gray.height,
        interpolation: img.Interpolation.average));
    final lines = _lineMap(gray, hexSpacing);
    return _Working(lines, gray, color, Homography.similarity(scale: scale),
        _thresholdFor(lines));
  }

  /// How strongly each pixel lies on a printed hex outline. An outline is a
  /// fixed fraction of a hex wide, so it is a hair's breadth in a photo of a
  /// whole board and several pixels across in a close-up, and a filter
  /// looking for one-pixel lines barely sees the latter.
  static GrayImage _lineMap(GrayImage gray, double? hexSpacing) {
    if (hexSpacing == null) {
      return gray.darkLines(lineRadius: 1, surroundRadius: 4).boxBlur(1);
    }
    return gray
        .darkLines(
          lineRadius: math.max(1, (hexSpacing * 0.012).round()),
          surroundRadius: math.max(3, (hexSpacing * 0.05).round()),
        )
        .boxBlur(math.max(1, (hexSpacing * 0.008).round()));
  }

  /// What counts as a line depends on the photo's sharpness and contrast:
  /// take a fraction of the strong end of the distribution.
  static double _thresholdFor(GrayImage lines) {
    final sorted = Float32List.fromList(lines.data)..sort();
    final strong = sorted[(sorted.length * 0.97).floor()];
    return math.max(0.01, strong * 0.3);
  }

  /// Redoes the line map now that the hex size is known, and evens out its
  /// strength across the photo.
  ///
  /// Both parts matter. A printed hex outline is a fixed fraction of a hex
  /// wide, so it is a hair's breadth in a photo of the whole board and
  /// several pixels across in a close-up; a filter looking for one-pixel
  /// lines barely sees the latter, and the grid then settles a fraction of a
  /// hex out -- close enough to look plausible, far enough that every hex is
  /// cut half from its neighbour. Glare or shade then weakens every line in
  /// an area by about the same factor, so dividing by the local average makes
  /// a faint but regular outline under glare count the same as a crisp one.
  /// The floor keeps blank areas, which have no lines to average, from having
  /// their noise blown up.
  _Working normalized(double hexSpacing) {
    final rebuilt = _lineMap(gray, hexSpacing);
    final radius = math.max(4, (hexSpacing * 0.6).round());
    final local = rebuilt.boxBlur(radius);
    final floor = rebuilt.mean * 0.5;
    final out = GrayImage(rebuilt.width, rebuilt.height);
    for (int i = 0; i < out.data.length; i++) {
      out.data[i] = rebuilt.data[i] / (local.data[i] + floor);
    }
    return _Working(out, gray, color, toWorking, _thresholdFor(out));
  }
}

class _Lattice {
  /// Photo offset from a hex centre to its east and south-east neighbours.
  final Offset east;
  final Offset southEast;
  final double strength;

  const _Lattice({
    required this.east,
    required this.southEast,
    required this.strength,
  });

  /// The affine board-to-photo map putting hex (0, 0) at [origin].
  Homography homography(Offset origin) => Homography.affine(
        origin: origin,
        // Board east (sqrt 3, 0) -> east; board south-east (sqrt 3 / 2, 3/2)
        // -> southEast. Solving for the images of the unit axes:
        xAxis: east / math.sqrt(3),
        yAxis: (southEast * 2 - east) / 3,
      );
}

class _Peak {
  final int dx;
  final int dy;
  final double value;
  const _Peak(this.dx, this.dy, this.value);
}

class _Triple {
  final _Peak p;
  final _Peak q;
  final double score;
  const _Triple(this.p, this.q, this.score);
}

/// A way of laying the map on the lattice: turned [rotation] x 60 degrees
/// about hex (0, 0), then shifted by the cube offset ([dx], [dz]).
class _Placement {
  final int rotation;
  final int dx;
  final int dz;
  final double score;
  final double margin;

  const _Placement(this.rotation, this.dx, this.dz, this.score, {this.margin = 0});

  /// Map board space to lattice board space.
  Homography get homography => Homography.similarity(
        radians: rotation * math.pi / 3,
        translation: Offset(math.sqrt(3) * (dx + dz / 2), 1.5 * dz),
      );
}
