import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/board_graph.dart';
import '../models/company.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import '../models/tile_rules.dart';
import 'gray_image.dart';
import 'hex_patch.dart';
import 'tile_classifier.dart';
import 'tile_renderer.dart';
import 'token_detector.dart';
import 'mountain_detector.dart';
import 'plate_reader.dart';
import 'tunnel_detector.dart';

/// What one photo showed on one hex.
class HexReading {
  final MapHex hex;
  final TileReading reading;
  final HexPatch patch;

  /// The hex as photographed, squared up, as PNG.
  final Uint8List picture;

  /// What each city circle showed, by circle (see `GameSession.slotId`).
  final Map<String, TokenDetection> tokens;

  /// Whether what was read is an upgrade of what the session last knew was
  /// there: a later colour of tile, keeping its track. Only an upgrade
  /// replaces a tile the user set by hand.
  final bool isUpgrade;

  /// How washed out by glare the hex was, 0..1 (see
  /// `BoardReader.measureGlare`).
  final double glare;

  const HexReading({
    required this.hex,
    required this.reading,
    required this.patch,
    required this.picture,
    required this.tokens,
    this.isUpgrade = false,
    this.glare = 0,
  });

  PlacedTile? get tile => reading.option.placed;
}

/// Reads hexes out of a photo whose grid has been found.
///
/// For each hex it asks [TileRules] what could be there given what the
/// session last knew, and has [TileClassifier] pick among those. Colours are
/// judged against the plain map nearby in the same photo, which cancels out
/// most of the lighting.
class BoardReader {
  final GameTitle title;
  final TileRules rules;
  final TileClassifier classifier;
  final TokenDetector tokenDetector;

  BoardReader(
    this.title, {
    TileClassifier? classifier,
    TokenDetector? tokenDetector,
  })  : rules = TileRules(title),
        classifier = classifier ?? TileClassifier(),
        tokenDetector =
            tokenDetector ?? TokenDetector(companies: title.companies);

  /// Lines [boardToImage] up with what the game already knows is on the
  /// board, and returns the better fit (or [boardToImage] itself, if what
  /// is known says nothing clear).
  ///
  /// A grid fitted to the printed outlines can sit a fraction of a hex off
  /// where they are faint, or covered by tiles. So each hex in [hexes] whose
  /// printing the game knows -- a tile it is sure of, or a printed city or
  /// town -- is looked for a little way around where the grid puts it, by
  /// matching its drawing against the photo; and the shifts they agree on
  /// move the grid: all of it the same way when only one or two hexes say,
  /// turned and scaled as well when more do, and in perspective when there
  /// are plenty.
  Future<Homography> alignToKnown({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
    required GameSession session,
    void Function(String)? log,
  }) async {
    final anchors = <HexCoord, String>{};
    final drawings = <String, TileDefinition>{};
    for (final c in hexes) {
      final hex = title.map.at(c);
      if (hex == null || !hex.takesTiles) continue;
      final state = session.stateOf(hex);
      final tile = session.tileAt(hex);
      if (tile != null) {
        if (state.source != HexSource.manual && state.confidence < _sureEnough) {
          continue;
        }
        final def = title.tiles[tile.tileId];
        if (def == null) continue;
        final key = _key(hex, TileOption(tile.tileId, tile.rotation));
        anchors[c] = key;
        drawings[key] = def.rotated(tile.rotation);
      } else if (hex.printed.stations.isNotEmpty) {
        final key = _key(hex, TileOption.printed);
        anchors[c] = key;
        drawings[key] = hex.printed;
      }
    }
    if (anchors.isEmpty) return boardToImage;
    await classifier.prepare(drawings);
    final rgb = RgbImage.fromImage(photo);

    double like(HexCoord c, Offset shift) =>
        classifier.shapeLikeness(anchors[c]!,
            HexPatch.coarseFromPhoto(rgb, boardToImage, c, shift: shift)) ??
        0;
    final still = {for (final c in anchors.keys) c: like(c, Offset.zero)};
    // Spread over the photo, and not so many that this takes long.
    final ordered = anchors.keys.toList()
      ..sort((a, b) => a.row != b.row ? a.row - b.row : a.col - b.col);
    List<HexCoord> spread(int most) => ordered.length <= most
        ? ordered
        : [
            for (int i = 0; i < most; i++)
              ordered[i * ordered.length ~/ most],
          ];
    final judges = spread(16);

    // First the whole grid moved together, judged on the known hexes at
    // once: one hex alone can match by chance a little way off, but not all
    // of them the same way.
    double together(Offset shift) {
      double total = 0;
      for (final c in judges) {
        total += like(c, shift);
      }
      return total / judges.length;
    }

    final start = together(Offset.zero);
    var shift = Offset.zero;
    var best = start;
    void consider(Offset candidate) {
      final score = together(candidate);
      if (score > best) {
        best = score;
        shift = candidate;
      }
    }

    for (double y = -_reach; y <= _reach + 1e-9; y += 0.1) {
      for (double x = -_reach; x <= _reach + 1e-9; x += 0.1) {
        consider(Offset(x, y));
      }
    }
    final coarse = shift;
    for (double y = -0.075; y <= 0.076; y += 0.025) {
      for (double x = -0.075; x <= 0.076; x += 0.025) {
        consider(coarse + Offset(x, y));
      }
    }
    log?.call('known hexes: ${anchors.length}, alike '
        '${start.toStringAsFixed(3)} where the grid put them, '
        '${best.toStringAsFixed(3)} at (${shift.dx.toStringAsFixed(3)}, '
        '${shift.dy.toStringAsFixed(3)})');
    if (best < start + _clearGain) return boardToImage;
    // A best match at the edge of where the grid was looked for may only be
    // the nearest the search came to something further off -- or a hex
    // matching a neighbour's drawing. Either way it isn't to be trusted.
    if (shift.dx.abs() > _reach - 0.1 || shift.dy.abs() > _reach - 0.1) {
      log?.call('the best match is at the edge of the search; left as it is');
      return boardToImage;
    }

    // Then each hex a little way around that, for any turn, scaling or
    // perspective the grid is out by as well.
    final from = <Offset>[], to = <Offset>[], weights = <double>[];
    for (final c in spread(30)) {
      var own = shift;
      var ownBest = like(c, shift);
      for (double y = -0.1; y <= 0.101; y += 0.025) {
        for (double x = -0.1; x <= 0.101; x += 0.025) {
          final likeness = like(c, shift + Offset(x, y));
          if (likeness > ownBest) {
            ownBest = likeness;
            own = shift + Offset(x, y);
          }
        }
      }
      log?.call('  ${title.map.at(c)!.id} (${anchors[c]}): '
          '${still[c]!.toStringAsFixed(3)} -> ${ownBest.toStringAsFixed(3)} at '
          '(${own.dx.toStringAsFixed(3)}, ${own.dy.toStringAsFixed(3)})');
      // A hex that doesn't look like its drawing anywhere near says nothing.
      if (ownBest < _alike) continue;
      from.add(c.boardCenter);
      to.add(c.boardCenter + own);
      weights.add(ownBest);
    }
    if (from.isEmpty) {
      return Homography.similarity(translation: shift).then(boardToImage);
    }
    return _correction(from, to, weights).then(boardToImage);
  }

  /// The board-space correction taking [from] to [to] as closely as they
  /// can say: a plain shift where they are close together, since a turn or
  /// scaling fitted to a cluster is mostly its noise; a shift, a slight turn
  /// and a slight scaling where they spread over a few hexes; and
  /// perspective as well where there are plenty spread wide.
  static Homography _correction(
      List<Offset> from, List<Offset> to, List<double> weights) {
    double total = 0;
    var shift = Offset.zero;
    var mf = Offset.zero, mt = Offset.zero;
    var bounds = Rect.fromPoints(from.first, from.first);
    for (int i = 0; i < from.length; i++) {
      shift += (to[i] - from[i]) * weights[i];
      mf += from[i] * weights[i];
      mt += to[i] * weights[i];
      total += weights[i];
      bounds = bounds.expandToInclude(Rect.fromPoints(from[i], from[i]));
    }
    shift /= total;
    mf /= total;
    mt /= total;
    final plain = Homography.similarity(translation: shift);
    if (from.length < 3 || bounds.longestSide < _spreadForTurn) return plain;
    if (from.length >= 6 && bounds.shortestSide >= _spreadForPerspective) {
      final fitted = Homography.fit(from, to, weights: weights);
      // Taken only if it agrees with the anchors' plain shift to within a
      // fraction of a hex across them: it is correcting a fit, not
      // replacing it.
      if (fitted != null &&
          [bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight]
              .every((p) => (fitted.apply(p) - p - shift).distance < 0.5)) {
        return fitted;
      }
    }
    // Weighted Procrustes: the scale, turn and shift taking one set of
    // points onto the other most closely.
    double a = 0, b = 0, norm = 0;
    for (int i = 0; i < from.length; i++) {
      final p = from[i] - mf, q = to[i] - mt;
      a += weights[i] * (p.dx * q.dx + p.dy * q.dy);
      b += weights[i] * (p.dx * q.dy - p.dy * q.dx);
      norm += weights[i] * (p.dx * p.dx + p.dy * p.dy);
    }
    if (norm <= 0) return plain;
    final scale = math.sqrt(a * a + b * b) / norm;
    final turn = math.atan2(b, a);
    if ((scale - 1).abs() > 0.03 || turn.abs() > 3 * math.pi / 180) {
      return plain;
    }
    final cs = math.cos(turn) * scale, sn = math.sin(turn) * scale;
    final turned = Offset(cs * mf.dx - sn * mf.dy, sn * mf.dx + cs * mf.dy);
    return Homography.similarity(
        scale: scale, radians: turn, translation: mt - turned);
  }

  /// How far apart, in board units, known hexes have to be before they can
  /// say how the grid is turned, and before they can say how it is in
  /// perspective. Neighbouring hexes are 1.7 apart.
  static const double _spreadForTurn = 3.4;
  static const double _spreadForPerspective = 6;

  /// How far either way, in hex radii, the grid is looked for.
  static const double _reach = 0.8;

  /// How much more alike their drawings (see [HexPatch.correlationWith])
  /// the known hexes have to be, on the whole, to say the grid is out.
  static const double _clearGain = 0.05;

  /// How alike its drawing a known hex has to look to steer the grid.
  static const double _alike = 0.3;

  /// How sure of a tile the game has to be for it to steer the grid.
  static const double _sureEnough = 0.8;

  /// Reads [hexes] from [photo], where [boardToImage] places the map.
  /// [context] is every map hex fully in the photo, used as the colour
  /// reference; it should include [hexes].
  Future<List<HexReading>> read({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
    required Iterable<HexCoord> context,
    required GameSession session,
    Map<HexCoord, double> glarePrior = const {},
  }) async {
    final rgb = RgbImage.fromImage(photo);
    final inView = {...context, ...hexes}.where(title.map.contains).toSet();
    // Glare measured here, or remembered from the board under the same
    // light (see [GameSession.glare]), whichever is stronger.
    final measured = measureGlare(rgb, boardToImage, inView);
    final glare = {
      for (final c in inView)
        c: math.max(measured[c] ?? 0, _priorWeight * (glarePrior[c] ?? 0)),
    };

    // Colour of every hex in view, and which of them are known to show the
    // plain map, as the local reference for "no tile here".
    final chroma = <HexCoord, Offset>{};
    final patches = <HexCoord, HexPatch>{};
    for (final c in inView) {
      final patch = HexPatch.fromPhoto(rgb, boardToImage, c);
      patches[c] = patch;
      chroma[c] = patch.chroma;
    }
    final relative = _relativeToPlain(chroma, session);
    final colours = _colourModel(relative, session, glare);

    // Everything each hex could be, and the templates to compare with.
    final options = <HexCoord, List<TileOption>>{};
    final templates = <String, TileDefinition>{};
    for (final c in hexes) {
      final hex = title.map.at(c);
      if (hex == null || !hex.takesTiles || patches[c] == null) continue;
      final state = session.stateOf(hex);
      // Three lays ahead of what was last known: bare map to brown is three,
      // and a game photographed now and then skips rounds. Each lay costs a
      // little evidence, so a long jump needs a clear picture.
      final list = rules.options(hex, state.basis,
          maxSteps: state.basisKnown ? 3 : 4);
      // Tiles are never taken up in play, so the rules only look forward
      // from what was there -- which makes a tile the app misread
      // permanent. Where the app read the tile itself (never where the user
      // set it), bare map stays on offer, at a price only clear evidence
      // pays.
      if (state.basis != null &&
          state.source != HexSource.manual &&
          !list.any((o) => o.isPrinted)) {
        list.add(const TileOption(null, 0, steps: _misreadSteps));
      }
      options[c] = list;
      for (final o in list) {
        final def = rules.contentOf(hex, o);
        if (def != null) templates[_key(hex, o)] = def;
      }
    }
    await classifier.prepare(templates);

    final results = <HexReading>[];
    options.forEach((c, list) {
      final hex = title.map.at(c)!;
      final state = session.stateOf(hex);
      final washedOut = glare[c] ?? 0;
      final classified = classifier.classify(
        patch: patches[c]!,
        relativeChroma: relative[c]!,
        options: list,
        keyOf: (o) => _key(hex, o),
        colourOf: (o) => rules.contentOf(hex, o)?.color ?? hex.printed.color,
        exitsOf: (o) => rules.contentOf(hex, o)?.exitStrengths ?? const {},
        colours: colours,
        // "It probably hasn't changed" only counts for a hex the app has
        // actually seen; on one it has never read, a tile is no less likely
        // than bare map.
        stepPenalty: state.basisKnown ? 1.0 : 0.25,
        reference: state.reference == null
            ? null
            : HexPatch.decode(state.reference!, state.referenceChroma ?? Offset.zero),
        // Glare washes colour out before it hides track.
        colourWeight: 1 - 0.75 * washedOut,
      );
      // Glare can hide a tile, but it can't put track where there is none.
      // So under it, "nothing here" is never taken as read where it would
      // be news -- where the app didn't already know the hex was bare.
      final knownBare = state.basisKnown && state.basis == null;
      final reading = classified.option.isPrinted && !knownBare && washedOut > 0
          ? TileReading(
              option: classified.option,
              confidence: classified.confidence * (1 - 0.6 * washedOut),
              ranked: classified.ranked,
            )
          : classified;
      results.add(HexReading(
        hex: hex,
        reading: reading,
        patch: patches[c]!,
        picture: img.encodePng(HexPatch.picture(rgb, boardToImage, c)),
        tokens: (glare[c] ?? 0) > 0.5
            ? const {}
            : _tokens(rgb, boardToImage, hex, reading.option),
        isUpgrade: _isUpgrade(state.basis, reading.option),
        glare: washedOut,
      ));
    });
    return _openLinesTogether(results);
  }

  /// A line printed for later opening opens all at once -- 1844's Gotthard
  /// line is one piece laid over five hexes -- so its hexes are decided
  /// together: the evidence from every hex of the line in view is added up,
  /// and they all read as opened or all as printed. Each hex alone is a
  /// close call (the piece reprints most of what is under it), and one hex
  /// in shadow shouldn't split the line.
  List<HexReading> _openLinesTogether(List<HexReading> results) {
    final byCoord = {
      for (final r in results)
        if (r.hex.opensLater) r.hex.coord: r,
    };
    final seen = <HexCoord>{};
    final decided = <HexCoord, HexReading>{};
    for (final start in byCoord.keys) {
      if (!seen.add(start)) continue;
      // The hexes of this line in view: those joined to [start].
      final line = <HexReading>[];
      final queue = [start];
      while (queue.isNotEmpty) {
        final c = queue.removeLast();
        line.add(byCoord[c]!);
        for (final n in c.neighbors) {
          if (byCoord.containsKey(n) && seen.add(n)) queue.add(n);
        }
      }
      double lead = 0; // for opening, over staying as printed
      for (final r in line) {
        double? printed, opened;
        for (final (o, score) in r.reading.ranked) {
          if (o.isPrinted) {
            printed ??= score;
          } else {
            opened ??= score;
          }
        }
        if (printed == null || opened == null) continue;
        lead += opened - printed;
      }
      final confidence = TileClassifier.confidenceFor(lead.abs());
      for (final r in line) {
        final option = r.reading.ranked
            .map((e) => e.$1)
            .firstWhere((o) => o.isPrinted == (lead <= 0),
                orElse: () => r.reading.option);
        decided[r.hex.coord] = HexReading(
          hex: r.hex,
          reading: TileReading(
              option: option, confidence: confidence, ranked: r.reading.ranked),
          patch: r.patch,
          picture: r.picture,
          tokens: r.tokens,
          isUpgrade: r.isUpgrade && option == r.reading.option,
          glare: r.glare,
        );
      }
    }
    return [for (final r in results) decided[r.hex.coord] ?? r];
  }

  /// Looks for tunnels on the hexes of [hexes] that can take one.
  List<TunnelReading> readTunnels({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
  }) {
    final tunnelHexes = [
      for (final c in hexes)
        if (title.map.at(c) case final hex? when rules.tunnelPaths(hex).isNotEmpty)
          hex,
    ];
    if (tunnelHexes.isEmpty) return const [];
    final rgb = RgbImage.fromImage(photo);
    return [
      for (final hex in tunnelHexes)
        const TunnelDetector()
            .detect(rgb, boardToImage, hex, rules.tunnelPaths(hex)),
    ];
  }

  /// Folds [readings] into [session], as tokens are: a tunnel the user set
  /// stays as it is; one the app placed without being sure is replaced by
  /// what a later photo shows, or taken away if that photo clearly shows
  /// none. Tunnels aren't removed in play, so a sure one is kept.
  static void applyTunnels(GameSession session, List<TunnelReading> readings) {
    for (final r in readings) {
      final id = r.hex.id;
      final current = session.tunnels[id];
      final open = current == null || session.tunnelDoubts.contains(id);
      if (!open || r.confidence < _tokenConfidence) continue;
      final path = r.path;
      if (path != null) {
        session.tunnels[id] = path;
        if (r.confidence >= _sureTunnel) {
          session.tunnelDoubts.remove(id);
        } else {
          session.tunnelDoubts.add(id);
        }
      } else if (current != null) {
        session.tunnels.remove(id);
        session.tunnelDoubts.remove(id);
      }
    }
  }

  static const double _sureTunnel = 0.8;

  /// Looks for mountain railway plates on the mountains among [hexes]. A
  /// mountain cut off by the edge of the photo is left unread.
  List<MountainReading> readMountains({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
  }) {
    final mountains = [
      for (final c in hexes)
        if (title.map.at(c) case final hex? when rules.mountainPlates(hex).isNotEmpty)
          hex,
    ];
    if (mountains.isEmpty) return const [];
    final rgb = RgbImage.fromImage(photo);
    return [
      for (final hex in mountains)
        const MountainDetector().detect(rgb, boardToImage, hex),
    ];
  }

  /// Folds [readings] into [session], as tunnels are. A photo can tell that
  /// a plate is there, but only its figures say which one: where [plates]
  /// has them read (by hex id, see `PlateReader`) that plate is recorded --
  /// settled if every figure was read, flagged if only some were -- and
  /// otherwise [GameSession.unknownPlate], flagged for the user to name.
  static void applyMountains(
    GameSession session,
    List<MountainReading> readings, {
    Map<String, PlateIdentity> plates = const {},
  }) {
    for (final r in readings) {
      final id = r.hex.id;
      final current = session.mountains[id];
      final open = current == null || session.mountainDoubts.contains(id);
      if (!open || r.confidence < _tokenConfidence) continue;
      if (r.present) {
        final read = plates[id];
        final named = read?.plate;
        session.mountains[id] = named ?? current ?? GameSession.unknownPlate;
        if (named != null && read!.sure) {
          session.mountainDoubts.remove(id);
        } else {
          session.mountainDoubts.add(id);
        }
      } else if (current != null) {
        session.mountains.remove(id);
        session.mountainDoubts.remove(id);
      }
    }
  }

  /// Takes a photo as showing the board exactly as printed and remembers how
  /// each hex looks, without trying to recognize anything.
  ///
  /// Photographed before the first tile goes down, this teaches the app the
  /// map's own artwork -- lakes, hill shading, place names, the board's
  /// lighting -- which is the thing most likely to be mistaken for track.
  /// Later photos are compared against these pictures, so "nothing has
  /// changed here" becomes an easy call.
  Future<List<HexReading>> readAsPrinted({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
    required GameSession session,
  }) async {
    final rgb = RgbImage.fromImage(photo);
    final results = <HexReading>[];
    for (final c in hexes) {
      final hex = title.map.at(c);
      if (hex == null) continue;
      final patch = HexPatch.fromPhoto(rgb, boardToImage, c);
      final reading = TileReading(
        option: TileOption.printed,
        confidence: 1,
        ranked: const [(TileOption.printed, 0.0)],
      );
      session.recordReading(
        hex,
        tile: null,
        confidence: 1,
        source: HexSource.overview,
        reference: patch.encodeDarkness(),
        referenceChroma: patch.chroma,
      );
      results.add(HexReading(
        hex: hex,
        reading: reading,
        patch: patch,
        picture: img.encodePng(HexPatch.picture(rgb, boardToImage, c)),
        tokens: const {},
      ));
    }
    return results;
  }

  /// A later colour of tile than [from], reached by the upgrade rules.
  bool _isUpgrade(PlacedTile? from, TileOption to) {
    if (from == null || to.isPrinted || to.steps < 1) return false;
    final before = tilePhases.indexOf(title.tiles[from.tileId]?.color ?? TileColor.plain);
    final after = tilePhases.indexOf(title.tiles[to.tileId]?.color ?? TileColor.plain);
    return before >= 0 && after > before;
  }

  /// How washed out by glare each hex of [hexes] is in [photo], 0..1.
  ///
  /// Glare off a board under a lamp lifts everything towards white in a
  /// broad patch, and the tiles, which are glossier than the board, worst of
  /// all: a yellow tile under it photographs nearly white and its track a
  /// faint grey. Being white light added on top, it lifts every colour
  /// channel, the weakest included; a lamp that is merely brighter in one
  /// place lifts the colours it already has and leaves the weakest -- blue,
  /// under a warm lamp -- low. So what is measured is the weakest channel of
  /// each beige or yellow hex's background, against the photo's middle
  /// value, smoothed over neighbours since glare is broad and one hex's
  /// printing shouldn't decide it.
  Map<HexCoord, double> measureGlare(
    RgbImage photo,
    Homography boardToImage,
    Set<HexCoord> hexes,
  ) {
    final light = <HexCoord, double>{};
    final rgb = List<double>.filled(3, 0);
    for (final c in hexes) {
      final colour = title.map.at(c)!.printed.color;
      if (colour != TileColor.plain && colour != TileColor.yellow) continue;
      final samples = <double>[];
      for (double y = -0.6; y <= 0.61; y += 0.06) {
        for (double x = -0.6; x <= 0.61; x += 0.06) {
          final p = boardToImage.apply(c.boardCenter + Offset(x, y));
          if (!photo.contains(p.dx, p.dy)) continue;
          photo.sample(p.dx, p.dy, rgb);
          samples.add(math.min(rgb[0], math.min(rgb[1], rgb[2])));
        }
      }
      if (samples.length < 100) continue;
      samples.sort();
      // The background: brighter than the printing, short of the white
      // city circles.
      light[c] = samples[samples.length * 6 ~/ 10];
    }
    if (light.isEmpty) return const {};
    final sorted = light.values.toList()..sort();
    final middle = sorted[sorted.length ~/ 2];
    final raw = {
      for (final e in light.entries)
        e.key: math.max(
          // Brighter than the rest of the photo -- where there is enough of
          // it to say what the rest looks like.
          light.length >= 7
              ? ((e.value - middle - _glareMargin) / _glareSpan).clamp(0.0, 1.0)
              : 0.0,
          // Or washed out outright: even the weakest colour near the top of
          // the range. A close-up holds few hexes, and when glare covers
          // most of them the photo's middle value is glare too.
          ((e.value - _clippedFrom) / _clippedSpan).clamp(0.0, 1.0),
        ),
    };
    return {
      for (final c in hexes)
        c: () {
          final near = [
            for (final e in raw.entries)
              if (e.key.distanceTo(c) <= 1) e.value,
          ]..sort();
          return near.isEmpty ? 0.0 : near[near.length ~/ 2];
        }(),
    };
  }

  /// How much brighter than the photo's middle a background has to be
  /// before it counts as glare, and over how much more it becomes total.
  /// Yellow tiles are a little brighter than the beige map in any light.
  static const double _glareMargin = 15;
  static const double _glareSpan = 30;

  /// Where a background's weakest colour channel starts to count as washed
  /// out whatever the rest of the photo does, and where it is wholly so.
  static const double _clippedFrom = 215;
  static const double _clippedSpan = 30;

  static String _key(MapHex hex, TileOption o) =>
      o.isPrinted ? 'map:${hex.id}' : 'tile:${o.tileId}@${o.rotation}';

  static bool _knownPlain(MapHex hex, GameSession session) {
    if (hex.printed.color != TileColor.plain) return false;
    final state = session.stateOf(hex);
    return state.basisKnown && state.basis == null && state.tile == null;
  }

  /// Colours measured on hexes whose content the session is sure of stand in
  /// for the defaults, where there are enough of them.
  /// Each hex's background colour against the bare map near it, which
  /// takes out most of the light's own colour.
  Map<HexCoord, Offset> _relativeToPlain(
      Map<HexCoord, Offset> chroma, GameSession session) {
    final plain = <HexCoord>[
      for (final c in chroma.keys)
        if (_knownPlain(title.map.at(c)!, session)) c,
    ];
    final reference = plain.length >= 3 ? plain : chroma.keys.toList();
    Offset localPlain(HexCoord c) {
      final near = reference.where((r) => r.distanceTo(c) <= 3 && r != c).toList();
      return _median([for (final r in near.length >= 3 ? near : reference) chroma[r]!]);
    }

    return {for (final c in chroma.keys) c: chroma[c]! - localPlain(c)};
  }

  /// The colours of the hexes whose content the session is sure of, by the
  /// colour they should be, leaving out any washed out by glare.
  Map<TileColor, List<Offset>> _knownColours(Map<HexCoord, Offset> relative,
      GameSession session, Map<HexCoord, double> glare) {
    final byColour = <TileColor, List<Offset>>{};
    relative.forEach((c, colour) {
      if ((glare[c] ?? 0) > _glaredOut) return;
      final hex = title.map.at(c)!;
      final state = session.stateOf(hex);
      if (state.isDoubtful || !state.basisKnown) return;
      final def = state.tile == null
          ? hex.printed
          : title.tiles[state.tile!.tileId] ?? hex.printed;
      byColour.putIfAbsent(def.color, () => []).add(colour);
    });
    return byColour;
  }

  /// The colours to expect: the defaults, then the session's own profile if
  /// it has one, then whatever this photo shows clearly enough of.
  ColourModel _colourModel(Map<HexCoord, Offset> relative, GameSession session,
      Map<HexCoord, double> glare) {
    final byColour = _knownColours(relative, session, glare);
    return ColourModel.defaults
        .withCentroids(session.colourProfile?.colours ?? const {})
        .withCentroids({
      for (final e in byColour.entries)
        if (e.value.length >= 3) e.key: _median(e.value),
    });
  }

  /// How much remembered glare counts against what a photo shows itself:
  /// the light is the same, but a close-up is taken from somewhere else.
  static const double _priorWeight = 0.8;

  /// Glare above which a hex's colours aren't trusted as a sample.
  static const double _glaredOut = 0.3;

  /// Measures how the board's colours look in [photo], for a session's
  /// [ColourProfile]: each colour from the hexes [session] is sure of,
  /// leaving out any under glare, which is reported instead.
  Calibration calibrate({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
    required GameSession session,
  }) {
    final rgb = RgbImage.fromImage(photo);
    final inView = hexes.where(title.map.contains).toSet();
    final glare = measureGlare(rgb, boardToImage, inView);
    final chroma = {
      for (final c in inView)
        c: HexPatch.fromPhoto(rgb, boardToImage, c).chroma,
    };
    final byColour =
        _knownColours(_relativeToPlain(chroma, session), session, glare);
    final colours = {
      for (final e in byColour.entries)
        if (e.value.length >= 2) e.key: _median(e.value),
    };
    return Calibration(
      profile: ColourProfile(colours: colours, measured: DateTime.now()),
      samples: {for (final e in byColour.entries) e.key: e.value.length},
      glare: {
        for (final e in glare.entries)
          if (e.value > _glaredOut) e.key,
      },
    );
  }

  /// What each circle of each city on [hex] holds, read as [option], by
  /// circle (see `GameSession.slotId`).
  Map<String, TokenDetection> _tokens(
    RgbImage photo,
    Homography boardToImage,
    MapHex hex,
    TileOption option,
  ) {
    final result = <String, TokenDetection>{};
    final content = rules.contentOf(hex, option);
    if (content == null || content.cityCount == 0) return result;
    final centre = hex.coord.boardCenter;
    final white = TokenDetector.localWhite(photo, boardToImage, centre);
    for (final station in content.stations) {
      if (station.kind != StationKind.city) continue;
      Company? home;
      for (final c in title.companies) {
        if (c.isHomeOf(hex.id, station.index)) home = c;
      }
      final circles =
          TileRenderer.slotPositions(content, station.index, centre, 1);
      for (int slot = 0; slot < circles.length; slot++) {
        result[GameSession.slotId(
            '${hex.coord.row}_${hex.coord.col}_${station.index}', slot)] =
            tokenDetector.detect(
          photo: photo,
          boardToImage: boardToImage,
          slot: circles[slot],
          slotRadius: TileRenderer.slotRadiusFor(station),
          white: white,
          onTile: !option.isPrinted,
          home: home,
        );
      }
    }
    return result;
  }

  static Offset _median(List<Offset> values) {
    if (values.isEmpty) return Offset.zero;
    final xs = [for (final v in values) v.dx]..sort();
    final ys = [for (final v in values) v.dy]..sort();
    return Offset(xs[xs.length ~/ 2], ys[ys.length ~/ 2]);
  }

  /// Folds [readings] into [session]: tiles and confidence per hex, and the
  /// station tokens seen.
  ///
  /// A token the user has set or confirmed stays as it is. One the app put
  /// there itself without being sure whose it is (see
  /// `GameSession.tokenDoubts`) is replaced by what a later photo shows, or
  /// taken away if that photo clearly shows the slot empty. Tokens are only
  /// read where the tile was read confidently: where it wasn't, the app
  /// doesn't know where the cities are.
  static void apply(
    GameSession session,
    List<HexReading> readings, {
    required HexSource source,
  }) {
    for (final r in readings) {
      session.recordReading(
        r.hex,
        tile: r.tile,
        confidence: r.reading.confidence,
        source: source,
        reference: r.patch.encodeDarkness(),
        referenceChroma: r.patch.chroma,
        upgrade: r.isUpgrade,
      );
      if (!r.reading.isReliable) continue;
      r.tokens.forEach((circle, detection) {
        final current = session.tokens[circle];
        final open = current == null || session.tokenDoubts.contains(circle);
        if (!open || detection.confidence < _tokenConfidence) return;
        final company = detection.company;
        if (detection.present && company != null) {
          session.tokens[circle] = company.id;
          if (detection.companyConfidence >= _tokenConfidence) {
            session.tokenDoubts.remove(circle);
          } else {
            session.tokenDoubts.add(circle);
          }
        } else if (!detection.present && current != null) {
          session.tokens.remove(circle);
          session.tokenDoubts.remove(circle);
        }
      });
    }
  }

  /// What taking back a tile the app read costs, in upgrade steps.
  static const int _misreadSteps = 3;

  /// How sure a token reading has to be to change the session.
  static const double _tokenConfidence = 0.5;
}

/// What [BoardReader.calibrate] found.
class Calibration {
  final ColourProfile profile;

  /// How many hexes each colour was measured from.
  final Map<TileColor, int> samples;

  /// Hexes under glare, left out of the measurement.
  final Set<HexCoord> glare;

  const Calibration({
    required this.profile,
    required this.samples,
    required this.glare,
  });
}

/// A close-up for the user to take: [target] in the middle of the frame,
/// which also takes in the hexes in [covers].
class CloseUpRequest {
  final HexCoord target;
  final Set<HexCoord> covers;

  const CloseUpRequest(this.target, this.covers);
}

/// Groups hexes into as few close-ups as possible. Each close-up is framed on
/// one hex and reads it and its six neighbours, so the planner repeatedly
/// picks the hex whose neighbourhood holds the most hexes still uncovered.
///
/// Off-board areas and other hexes that never take tiles make poor targets:
/// they are printed as part-hexes running off the edge of the board, so there
/// is less for the grid to lock onto, and they are never what the photo is
/// really for.
List<CloseUpRequest> planCloseUps(MapLayout map, Set<HexCoord> wanted) {
  final remaining = Set<HexCoord>.of(wanted);
  final requests = <CloseUpRequest>[];
  while (remaining.isNotEmpty) {
    HexCoord? best;
    var bestScore = -1.0;
    for (final candidate in map.around(remaining, 1)) {
      final covered =
          map.around([candidate], 1).where(remaining.contains).length;
      if (covered == 0) continue;
      var score = covered.toDouble();
      if (map.at(candidate)?.takesTiles ?? false) score += 0.5;
      // All else equal, aim at a hex that wants photographing itself.
      if (remaining.contains(candidate)) score += 0.25;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    if (best == null) break;
    final covers = map.around([best], 1).where(remaining.contains).toSet();
    requests.add(CloseUpRequest(best, covers));
    remaining.removeAll(covers);
  }
  return requests;
}
