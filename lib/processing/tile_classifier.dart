import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/tile_definition.dart';
import '../models/tile_rules.dart';
import 'hex_patch.dart';
import 'tile_renderer.dart';

/// What recognition made of one hex.
class TileReading {
  /// The most likely option.
  final TileOption option;

  /// 0..1: how far the best option stood clear of the next best. Low means
  /// "take a closer look".
  final double confidence;

  /// Every option considered, best first, with its score (higher is better).
  final List<(TileOption, double)> ranked;

  const TileReading({
    required this.option,
    required this.confidence,
    required this.ranked,
  });

  /// Confidence at or above which a reading is trusted without the user
  /// checking it. A starting guess, to be tuned against real photos.
  static const double reliableConfidence = 0.6;

  bool get isReliable => confidence >= reliableConfidence;

  @override
  String toString() =>
      'TileReading($option, ${(confidence * 100).toStringAsFixed(0)}%)';
}

/// The background colours to expect in one photo, relative to the plain map
/// colour around each hex (see `BoardReader`).
class ColourModel {
  final Map<TileColor, Offset> centroids;

  /// Typical scatter of a colour class about its centroid.
  final double spread;

  const ColourModel(this.centroids, {this.spread = 0.02});

  /// Rough expectations from one warm-lit webcam photo of a printed 1844
  /// board. Colour differences in photos are much smaller than in the tile
  /// artwork; `BoardReader` replaces these with what it measures when the
  /// photo has enough hexes of a colour it already knows.
  static const ColourModel defaults = ColourModel({
    TileColor.plain: Offset(0, 0),
    TileColor.red: Offset(0.047, 0.056),
    TileColor.yellow: Offset(-0.021, 0.02),
    TileColor.green: Offset(-0.04, 0.018),
    TileColor.brown: Offset(0.033, 0.045),
    TileColor.grey: Offset(0, -0.03),
    TileColor.purple: Offset(-0.011, -0.04),
    TileColor.blue: Offset(-0.01, -0.02),
  });

  Offset expected(TileColor color) => centroids[color] ?? Offset.zero;

  ColourModel withCentroids(Map<TileColor, Offset> measured) =>
      ColourModel({...centroids, ...measured}, spread: spread);
}

/// Picks which of a hex's possible contents a photo of it shows.
///
/// Each option is drawn by `TileRenderer` from the same tile data the route
/// graph uses, and compared with the photographed hex on where the dark
/// printing (track, city rings, town bars) lies. Background colour then
/// separates a yellow tile from a green one or from bare map, and a small
/// penalty per upgrade step reflects that most hexes don't change between
/// photos. When the hex has been photographed before, the "unchanged" option
/// is also compared with that earlier picture, which catches printed map art
/// (mountains, place names) the renderer doesn't draw.
///
/// The options come from `TileRules`, so a hex is only ever matched against
/// what could legally be there.
class TileClassifier {
  /// Each option's drawings: one, or for a tile with a city of several
  /// slots in its middle, one for each way its row of slots could run.
  final Map<String, List<HexPatch>> _templates = {};
  final Map<String, Future<void>> _rendering = {};

  int get templateCount => _templates.length;

  /// Draws and stores templates for any of [contents] (keyed by a stable
  /// name) not already drawn.
  Future<void> prepare(Map<String, TileDefinition> contents) async {
    final pending = <Future<void>>[];
    contents.forEach((key, def) {
      if (_templates.containsKey(key)) return;
      pending.add(_rendering[key] ??= () async {
        _templates[key] = [
          for (int turn = 0; turn < (TileRenderer.hasSlotRow(def) ? 3 : 1); turn++)
            HexPatch.fromTileImage(await TileRenderer.rasterize(def,
                size: HexPatch.size, slotTurn: turn)),
        ];
        _rendering.remove(key);
      }());
    });
    await Future.wait(pending);
  }

  HexPatch? template(String key) => _templates[key]?.first;

  /// Scores each of [options] against [patch]. [keyOf] names the template
  /// for an option (as passed to [prepare]), [colourOf] gives its
  /// background colour, and [exitsOf] how strongly its printing should run
  /// off each side (see `TileDefinition.exitStrengths`). [colourWeight]
  /// scales how much background colour counts: less where glare has washed
  /// it out. [relativeChroma] is the patch's colour relative to
  /// the plain map nearby. [reference] is how the hex looked when it last
  /// held the first option, if known.
  TileReading classify({
    required HexPatch patch,
    required Offset relativeChroma,
    required List<TileOption> options,
    required String Function(TileOption) keyOf,
    required TileColor Function(TileOption) colourOf,
    required Map<int, double> Function(TileOption) exitsOf,
    ColourModel colours = ColourModel.defaults,
    HexPatch? reference,
    double stepPenalty = _stepPenalty,
    double colourWeight = 1,
  }) {
    assert(options.isNotEmpty);
    final scored = <(TileOption, double)>[];
    for (int i = 0; i < options.length; i++) {
      final option = options[i];
      final drawings = _templates[keyOf(option)];
      var shape = drawings == null
          ? 1.0
          : drawings.map(patch.distanceTo).reduce(math.min);
      if (i == 0 && reference != null) {
        shape = math.min(shape, patch.distanceTo(reference));
      }
      final colourMiss =
          (relativeChroma - colours.expected(colourOf(option))).distanceSquared /
              (2 * colours.spread * colours.spread);
      // Which sides the printing runs off, against which sides this option's
      // track reaches. A hex whose track leaves by three sides looks quite
      // unlike a bare one however similar the two are pixel for pixel.
      final exits = exitsOf(option);
      double exitMiss = 0;
      for (int e = 0; e < 6; e++) {
        final measured = patch.exits[e].clamp(0.0, 1.0);
        final expected = exits[e] ?? 0.0;
        final miss = measured - expected;
        exitMiss += miss * miss;
      }
      final score = -shape / _shapeScale -
          0.5 * colourWeight * math.min(colourMiss, 4.0) -
          _exitWeight * exitMiss -
          stepPenalty * option.steps;
      scored.add((option, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final margin = scored.length < 2 ? 4.0 : scored[0].$2 - scored[1].$2;
    return TileReading(
      option: scored.first.$1,
      confidence: confidenceFor(margin),
      ranked: scored,
    );
  }

  /// How sure a lead of [margin] (in units of evidence) makes a reading.
  static double confidenceFor(double margin) =>
      1 - math.exp(-margin / _marginScale);

  /// A difference in mean squared darkness of this much counts as one unit
  /// of evidence. Track covering a tenth of a hex that is there in one
  /// picture and not the other makes a difference of about 0.1.
  static const double _shapeScale = 0.02;

  /// Evidence against each upgrade step, since most hexes are unchanged
  /// between one photo and the next. `BoardReader` softens this for a hex it
  /// has never seen, where there is no "unchanged" to speak of.
  static const double _stepPenalty = 1.0;

  /// Weight on each side's track agreeing with the photo.
  static const double _exitWeight = 2.0;

  /// How big a lead one option needs over the next before the reading counts
  /// as settled. Printed map art the renderer doesn't draw -- lakes, hill
  /// shading, place names -- can give a wrong option a small lead, so a small
  /// lead is reported as "worth a closer look" rather than as an answer.
  static const double _marginScale = 2.0;
}
