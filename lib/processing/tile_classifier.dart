import 'package:image/image.dart' as img;

import '../models/tile_definition.dart';
import '../models/tile_seed_data.dart';
import 'tile_renderer.dart';

/// What the classifier thinks is sitting on one hex.
class TileMatch {
  final String tileId;
  final int rotation; // 0..5
  final double score; // mean squared error, lower is better
  final double confidence; // 0..1, how far clear of the runner-up

  const TileMatch({
    required this.tileId,
    required this.rotation,
    required this.score,
    required this.confidence,
  });

  @override
  String toString() =>
      'TileMatch($tileId r$rotation, score ${score.toStringAsFixed(1)}, '
      'confidence ${(confidence * 100).toStringAsFixed(0)}%)';
}

/// Matches a cropped hex from the board photo against reference tiles.
///
/// Reference images are rendered at runtime from [TileSeedData] via
/// [TileRenderer] -- one per tile design per 60-degree rotation -- so the
/// recognized tile id and rotation map straight onto the same definitions the
/// route graph is built from.
///
/// The matching itself is deliberately simple: brightness-normalized mean
/// squared error over a downscaled greyscale image. It is a starting point,
/// not a finished recognizer, and the UI is expected to let the user correct
/// what it gets wrong -- [TileMatch.confidence] exists to flag which hexes are
/// worth checking.
class TileClassifier {
  static const int templateSize = 64;

  final Map<String, TileDefinition> definitions;
  final Map<String, img.Image> _templates = {}; // "id@rotation" -> greyscale
  bool _loaded = false;
  Future<void>? _loading;

  TileClassifier({Map<String, TileDefinition>? definitions})
      : definitions = definitions ?? TileSeedData.all;

  bool get isLoaded => _loaded;
  int get templateCount => _templates.length;

  /// Renders the reference images. Safe to call again while a previous call is
  /// still running -- callers share the one in-flight render rather than
  /// starting a second.
  Future<void> loadTemplates() {
    if (_loaded) return Future.value();
    return _loading ??= _renderTemplates();
  }

  Future<void> _renderTemplates() async {
    for (final def in definitions.values) {
      // A tile with no track looks the same whichever way round it is.
      final rotations = def.segments.isEmpty ? 1 : 6;
      for (int rotation = 0; rotation < rotations; rotation++) {
        final rotated = def.rotated(rotation);
        final raster =
            await TileRenderer.rasterize(rotated, size: templateSize);
        _templates['${def.id}@$rotation'] = _normalize(img.grayscale(raster));
      }
    }
    _loaded = true;
    _loading = null;
  }

  /// Best tile + rotation for [patch], or null if templates aren't loaded.
  TileMatch? matchTile(img.Image patch) {
    if (_templates.isEmpty) return null;

    final prepared = _normalize(img.grayscale(
      img.copyResize(patch, width: templateSize, height: templateSize),
    ));

    String? bestKey;
    double bestScore = double.infinity;
    final scoresById = <String, double>{};

    for (final entry in _templates.entries) {
      final score = _meanSquaredError(prepared, entry.value);
      final id = entry.key.split('@')[0];
      final existing = scoresById[id];
      if (existing == null || score < existing) scoresById[id] = score;
      if (score < bestScore) {
        bestScore = score;
        bestKey = entry.key;
      }
    }

    if (bestKey == null) return null;
    final parts = bestKey.split('@');

    // Confidence compares against the best *different* tile, so a tile whose
    // rotations look alike (a straight #9, say) isn't reported as uncertain
    // just because two of its own rotations tie.
    double runnerUp = double.infinity;
    for (final entry in scoresById.entries) {
      if (entry.key == parts[0]) continue;
      if (entry.value < runnerUp) runnerUp = entry.value;
    }
    final confidence = runnerUp.isFinite && runnerUp > 0
        ? ((runnerUp - bestScore) / runnerUp).clamp(0.0, 1.0).toDouble()
        : 0.0;

    return TileMatch(
      tileId: parts[0],
      rotation: int.parse(parts[1]),
      score: bestScore,
      confidence: confidence,
    );
  }

  /// Stretches luminance to the full 0..255 range so exposure differences
  /// between the photo and the rendered reference matter less.
  static img.Image _normalize(img.Image source) {
    int min = 255;
    int max = 0;
    for (final pixel in source) {
      final l = img.getLuminance(pixel).round();
      if (l < min) min = l;
      if (l > max) max = l;
    }
    final range = max - min;
    if (range <= 0) return source;
    for (final pixel in source) {
      final l = img.getLuminance(pixel).round();
      final scaled = ((l - min) * 255 / range).round().clamp(0, 255);
      pixel.r = scaled;
      pixel.g = scaled;
      pixel.b = scaled;
    }
    return source;
  }

  static double _meanSquaredError(img.Image a, img.Image b) {
    double total = 0;
    final width = a.width;
    final height = a.height;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final d = a.getPixel(x, y).r - b.getPixel(x, y).r;
        total += d * d;
      }
    }
    return total / (width * height);
  }
}
