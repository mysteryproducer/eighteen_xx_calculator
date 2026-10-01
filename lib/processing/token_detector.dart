import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import '../geometry/homography.dart';
import '../models/company.dart';
import 'gray_image.dart';

/// What a photo showed in one city slot.
class TokenDetection {
  /// Whether a token seems to be in the slot, and how sure that is (0..1).
  final bool present;
  final double confidence;

  /// Whose token it most likely is, when [present], and how sure (0..1).
  /// Companies whose tokens are printed in the same colour can only be told
  /// apart by where they are, so a token away from home can be sure to be
  /// there and still unsure whose it is.
  final Company? company;
  final double companyConfidence;

  /// The colour of the slot's ring as seen, corrected for the light: white
  /// for an empty slot, the token's colour for a full one.
  final Color color;

  const TokenDetection({
    required this.present,
    required this.confidence,
    required this.color,
    this.company,
    this.companyConfidence = 0,
  });

  static const TokenDetection unseen = TokenDetection(
    present: false,
    confidence: 0,
    color: Color(0x00000000),
  );

  @override
  String toString() => present
      ? 'token ${company?.id ?? '?'} (${(confidence * 100).round()}%, '
          'whose ${(companyConfidence * 100).round()}%)'
      : 'empty (${(confidence * 100).round()}%)';
}

/// Looks for station tokens in city slots.
///
/// A slot is printed white. A token is a disc laid over it in the
/// company's colour, with the company's logo in the middle. So the ring of
/// the slot, between its middle and its edge, shows the token's colour, and
/// its middle shows the logo.
///
/// On a laid tile the slots are plain white, and either is enough -- the
/// logo is also the only way to see a token printed in a colour close to
/// white. The printed map is another matter: its cities carry art of their
/// own. 1844's glow yellow in the middle, Lucerne's holds a lake, and each
/// company's home city is printed with its logo on a white disc, which
/// looks just like a pale token. So on the map only one token is looked
/// for, the one that is usually there: the home company's, by its colour.
/// Anywhere else on the map the detector says it can't tell, rather than
/// guess.
///
/// Colours are judged against the white of the board nearby in the same
/// photo, which takes out the colour of the light: under a warm lamp an
/// empty slot is cream, and so is everything else that is white.
class TokenDetector {
  final List<Company> companies;

  const TokenDetector({this.companies = Company.defaults});

  /// The photo's white near board point [centre]: the brightest few percent
  /// of what is within [radius] board units of it, which on an 18xx board is
  /// the city slots and revenue bubbles, printed white.
  static List<double> localWhite(
    RgbImage photo,
    Homography boardToImage,
    Offset centre, {
    double radius = 1.5,
  }) {
    final samples = <List<double>>[];
    final rgb = List<double>.filled(3, 0);
    const step = 0.08;
    for (double y = -radius; y <= radius; y += step) {
      for (double x = -radius; x <= radius; x += step) {
        if (x * x + y * y > radius * radius) continue;
        final p = boardToImage.apply(centre + Offset(x, y));
        if (!photo.contains(p.dx, p.dy)) continue;
        photo.sample(p.dx, p.dy, rgb);
        samples.add(List<double>.of(rgb));
      }
    }
    if (samples.isEmpty) return const [255, 255, 255];
    samples.sort((a, b) => (b[0] + b[1] + b[2]).compareTo(a[0] + a[1] + a[2]));
    final top = samples.take(math.max(1, samples.length ~/ 33)).toList();
    return [
      for (int k = 0; k < 3; k++)
        math.max(1.0, (top.map((c) => c[k]).toList()..sort())[top.length ~/ 2]),
    ];
  }

  /// Looks at the slot of radius [slotRadius] (board units) centred on board
  /// point [slot]. [white] is [localWhite] near it. [onTile] says the slot is
  /// on a laid tile rather than printed on the map. [home] is the company
  /// whose home this slot is, if any.
  TokenDetection detect({
    required RgbImage photo,
    required Homography boardToImage,
    required Offset slot,
    required double slotRadius,
    required List<double> white,
    required bool onTile,
    Company? home,
  }) {
    final rgb = List<double>.filled(3, 0);
    List<double>? at(Offset board) {
      final p = boardToImage.apply(board);
      if (!photo.contains(p.dx, p.dy)) return null;
      photo.sample(p.dx, p.dy, rgb);
      return [for (int k = 0; k < 3; k++) 255 * rgb[k] / white[k]];
    }

    // A token is dropped on roughly, so the ring is looked at all the way
    // round and the median taken; the white edge of the slot showing on one
    // side doesn't move it.
    final ring = <List<double>>[];
    final middle = <List<double>>[];
    for (int a = 0; a < 36; a++) {
      final dir = Offset(math.cos(a * math.pi / 18), math.sin(a * math.pi / 18));
      for (final r in _ringRadii) {
        final c = at(slot + dir * (r * slotRadius));
        if (c != null) ring.add(c);
      }
      for (final r in _middleRadii) {
        final c = at(slot + dir * (r * slotRadius));
        if (c != null) middle.add(c);
      }
    }
    if (ring.length < 72 || middle.length < 54) return TokenDetection.unseen;

    final seen = [
      for (int k = 0; k < 3; k++)
        (ring.map((c) => c[k]).toList()..sort())[ring.length ~/ 2],
    ];
    final colour = Color.fromARGB(255, seen[0].round().clamp(0, 255),
        seen[1].round().clamp(0, 255), seen[2].round().clamp(0, 255));

    // How far the ring is from white: its colour, and how much darker it is.
    final lightness = (seen[0] + seen[1] + seen[2]) / 3;
    final redness = seen[0] - seen[1];
    final yellowness = (seen[0] + seen[1]) / 2 - seen[2];
    final fromWhite = math.sqrt(redness * redness +
        yellowness * yellowness +
        math.pow(math.max(0.0, 255 - lightness), 2));
    // A logo: printing much darker than the white around it.
    final logo = middle
            .where((c) => (c[0] + c[1] + c[2]) / 3 < 0.7 * 255)
            .length /
        middle.length;

    final colourEvidence = ((fromWhite - 40) / 40).clamp(0.0, 1.0);
    if (!onTile) return _homeToken(seen, colour, colourEvidence, home);
    final logoEvidence = ((logo - 0.1) / 0.2).clamp(0.0, 1.0);
    final evidence = math.max(colourEvidence, logoEvidence);
    final present = evidence >= 0.5;
    final confidence = present ? evidence : 1 - evidence;
    if (!present) {
      return TokenDetection(
          present: false, confidence: confidence, color: colour);
    }

    // Whose: the company whose token colour is nearest, with the home
    // company favoured -- most tokens are home tokens, and it is the only
    // way to tell apart companies printed in the same colour.
    final ranked = <(Company, double)>[
      for (final c in companies)
        (c, _colourDistance(seen, c.color) * (c.id == home?.id ? _homeFavour : 1)),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (ranked.isEmpty) {
      return TokenDetection(present: true, confidence: confidence, color: colour);
    }
    final best = ranked.first;
    final runnerUp = ranked.length > 1 ? ranked[1].$2 : double.infinity;
    final companyConfidence = runnerUp.isInfinite
        ? 1.0
        : ((runnerUp - best.$2) / math.max(1.0, runnerUp) * 3).clamp(0.0, 1.0);
    return TokenDetection(
      present: true,
      confidence: confidence,
      color: colour,
      company: best.$1,
      companyConfidence: companyConfidence,
    );
  }

  /// A printed city: is [home]'s token on it? Only a token that is clearly
  /// coloured can be told from the printed disc under it, and it has to look
  /// more like that company's colour than like white.
  TokenDetection _homeToken(
    List<double> seen,
    Color colour,
    double colourEvidence,
    Company? home,
  ) {
    final cantTell =
        TokenDetection(present: false, confidence: 0, color: colour);
    if (home == null || !_isColoured(home.color)) return cantTell;
    final toHome = _colourDistance(seen, home.color);
    final toWhite = _colourDistance(seen, const Color(0xFFFFFFFF));
    // 1 when the ring is right on the company's colour, 0 halfway to white.
    final likeHome =
        (1 - 2 * toHome / math.max(1.0, toHome + toWhite)).clamp(0.0, 1.0);
    final evidence = math.min(colourEvidence, likeHome * 2);
    if (evidence >= 0.5) {
      return TokenDetection(
        present: true,
        confidence: evidence.clamp(0.0, 1.0),
        color: colour,
        company: home,
        companyConfidence: 1,
      );
    }
    // A ring that is plainly white says no token; anything between is left
    // alone.
    return colourEvidence <= 0.1
        ? TokenDetection(present: false, confidence: 0.9, color: colour)
        : cantTell;
  }

  /// Whether a token printed in [c] can be told from a white disc.
  static bool _isColoured(Color c) {
    final r = c.r * 255, g = c.g * 255, b = c.b * 255;
    final chroma = math.sqrt(math.pow(r - g, 2) + math.pow((r + g) / 2 - b, 2));
    return chroma >= 40 || (r + g + b) / 3 <= 170;
  }

  /// Distance between a colour seen (white-balanced, 0..255) and a token
  /// colour, weighing hue over lightness: a token photographed under a lamp
  /// keeps its hue better than its depth.
  ///
  /// The token colours are tobymao's, chosen to read well on a screen, and
  /// deeper than printed card photographs: 1844's mustard BLS token comes
  /// out a pale yellow. Compared as they are, a pale yellow is nearer the
  /// light grey companies than the mustard ones, so each is compared as it
  /// photographs -- [_photographedShare] of the way from white to itself.
  static double _colourDistance(List<double> seen, Color token) {
    double photographed(double c) => 255 - _photographedShare * (255 - c * 255);
    final r = photographed(token.r),
        g = photographed(token.g),
        b = photographed(token.b);
    final dr = (seen[0] - seen[1]) - (r - g);
    final dy = ((seen[0] + seen[1]) / 2 - seen[2]) - ((r + g) / 2 - b);
    final dl = (seen[0] + seen[1] + seen[2]) / 3 - (r + g + b) / 3;
    return math.sqrt(dr * dr + dy * dy + 0.25 * dl * dl);
  }

  /// Where in the slot, as shares of its radius, the ring and the middle are
  /// sampled.
  static const List<double> _ringRadii = [0.5, 0.6, 0.7, 0.8];
  static const List<double> _middleRadii = [0.1, 0.2, 0.3];

  /// How much nearer the home company's colour is made to seem.
  static const double _homeFavour = 0.6;

  /// See [_colourDistance]; measured on one 1844 token under a warm lamp.
  static const double _photographedShare = 0.6;
}
