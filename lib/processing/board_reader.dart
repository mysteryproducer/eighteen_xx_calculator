import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/board_graph.dart';
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

/// What one photo showed on one hex.
class HexReading {
  final MapHex hex;
  final TileReading reading;
  final HexPatch patch;

  /// The hex as photographed, squared up, as PNG.
  final Uint8List picture;

  /// Station token colours seen, by station id.
  final Map<String, TokenDetection> tokens;

  const HexReading({
    required this.hex,
    required this.reading,
    required this.patch,
    required this.picture,
    required this.tokens,
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
    this.tokenDetector = const TokenDetector(),
  })  : rules = TileRules(title),
        classifier = classifier ?? TileClassifier();

  /// Reads [hexes] from [photo], where [boardToImage] places the map.
  /// [context] is every map hex fully in the photo, used as the colour
  /// reference; it should include [hexes].
  Future<List<HexReading>> read({
    required img.Image photo,
    required Homography boardToImage,
    required Iterable<HexCoord> hexes,
    required Iterable<HexCoord> context,
    required GameSession session,
  }) async {
    final rgb = RgbImage.fromImage(photo);

    // Colour of every hex in view, and which of them are known to show the
    // plain map, as the local reference for "no tile here".
    final chroma = <HexCoord, Offset>{};
    final patches = <HexCoord, HexPatch>{};
    for (final c in {...context, ...hexes}) {
      if (title.map.at(c) == null) continue;
      final patch = HexPatch.fromPhoto(rgb, boardToImage, c);
      patches[c] = patch;
      chroma[c] = patch.chroma;
    }
    final plain = <HexCoord>[
      for (final c in chroma.keys)
        if (_knownPlain(title.map.at(c)!, session)) c,
    ];
    final reference = plain.length >= 3 ? plain : chroma.keys.toList();
    Offset localPlain(HexCoord c) {
      final near = reference.where((r) => r.distanceTo(c) <= 3 && r != c).toList();
      return _median([for (final r in near.length >= 3 ? near : reference) chroma[r]!]);
    }

    final relative = {for (final c in chroma.keys) c: chroma[c]! - localPlain(c)};
    final colours = _colourModel(relative, session);

    // Everything each hex could be, and the templates to compare with.
    final options = <HexCoord, List<TileOption>>{};
    final templates = <String, TileDefinition>{};
    for (final c in hexes) {
      final hex = title.map.at(c);
      if (hex == null || !hex.takesTiles || patches[c] == null) continue;
      final state = session.stateOf(hex);
      final list = rules.options(hex, state.basis,
          maxSteps: state.basisKnown ? 2 : 4);
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
      final reading = classifier.classify(
        patch: patches[c]!,
        relativeChroma: relative[c]!,
        options: list,
        keyOf: (o) => _key(hex, o),
        colourOf: (o) => rules.contentOf(hex, o)?.color ?? hex.printed.color,
        colours: colours,
        reference: state.reference == null
            ? null
            : HexPatch.decode(state.reference!, state.referenceChroma ?? Offset.zero),
      );
      results.add(HexReading(
        hex: hex,
        reading: reading,
        patch: patches[c]!,
        picture: img.encodePng(HexPatch.picture(rgb, boardToImage, c)),
        tokens: _tokens(photo, boardToImage, hex, rules.contentOf(hex, reading.option)),
      ));
    });
    return results;
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

  static String _key(MapHex hex, TileOption o) =>
      o.isPrinted ? 'map:${hex.id}' : 'tile:${o.tileId}@${o.rotation}';

  static bool _knownPlain(MapHex hex, GameSession session) {
    if (hex.printed.color != TileColor.plain) return false;
    final state = session.stateOf(hex);
    return state.basisKnown && state.basis == null && state.tile == null;
  }

  /// Colours measured on hexes whose content the session is sure of stand in
  /// for the defaults, where there are enough of them.
  ColourModel _colourModel(Map<HexCoord, Offset> relative, GameSession session) {
    final byColour = <TileColor, List<Offset>>{};
    relative.forEach((c, colour) {
      final hex = title.map.at(c)!;
      final state = session.stateOf(hex);
      if (state.isDoubtful || !state.basisKnown) return;
      final def = state.tile == null
          ? hex.printed
          : title.tiles[state.tile!.tileId] ?? hex.printed;
      byColour.putIfAbsent(def.color, () => []).add(colour);
    });
    return ColourModel.defaults.withCentroids({
      for (final e in byColour.entries)
        if (e.value.length >= 3) e.key: _median(e.value),
    });
  }

  Map<String, TokenDetection> _tokens(
    img.Image photo,
    Homography boardToImage,
    MapHex hex,
    TileDefinition? content,
  ) {
    final result = <String, TokenDetection>{};
    if (content == null) return result;
    final centre = hex.coord.boardCenter;
    final radius = boardToImage.localScale(centre);
    for (final station in content.stations) {
      if (station.kind != StationKind.city) continue;
      final p = boardToImage.apply(
          TileRenderer.stationPosition(content, station.index, centre, 1));
      result['${hex.coord.row}_${hex.coord.col}_${station.index}'] =
          tokenDetector.detect(photo, p.dx.round(), p.dy.round(),
              (radius * 0.16).round().clamp(2, 1000));
    }
    return result;
  }

  static Offset _median(List<Offset> values) {
    if (values.isEmpty) return Offset.zero;
    final xs = [for (final v in values) v.dx]..sort();
    final ys = [for (final v in values) v.dy]..sort();
    return Offset(xs[xs.length ~/ 2], ys[ys.length ~/ 2]);
  }

  /// Folds [readings] into [session]: tiles and confidence per hex, plus any
  /// clear token colours for city slots the session hasn't got an owner for.
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
      );
      if (!r.reading.isReliable) continue;
      r.tokens.forEach((stationId, detection) {
        if (session.tokens.containsKey(stationId)) return;
        if (detection.looksEmpty || detection.company == null) return;
        if (detection.confidence < 0.15) return;
        session.tokens[stationId] = detection.company!.id;
      });
    }
  }
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
