import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

class TileClassifier {
  final Map<String, img.Image> _templates = {};
  bool _loaded = false;

  Future<void> loadTemplates() async {
    if (_loaded) return;
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);
      for (final key in manifestMap.keys) {
        if (key.startsWith('assets/tiles/')) {
          try {
            final bytes = await rootBundle.load(key);
            final list = bytes.buffer.asUint8List();
            final decoded = img.decodeImage(list);
            if (decoded != null) {
              _templates[key] = decoded;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  String matchTile(img.Image patch) {
    if (_templates.isEmpty) return 'unknown';

    // Convert patch to grayscale and resize to template size for comparison
    String bestKey = 'unknown';
    double? bestScore;

    for (final entry in _templates.entries) {
      final tpl = entry.value;
      final tw = tpl.width;
      final th = tpl.height;

      final resizedPatch = img.copyResize(patch, width: tw, height: th);
      final gp = img.grayscale(resizedPatch);
      final gt = img.grayscale(tpl);

      // Mean squared error
      double mse = 0.0;
      final len = tw * th;
      for (int y = 0; y < th; y++) {
        for (int x = 0; x < tw; x++) {
          final pPix = gp.getPixelSafe(x, y);
          final tPix = gt.getPixelSafe(x, y);
          final pL = img.getLuminance(pPix).toDouble();
          final tL = img.getLuminance(tPix).toDouble();
          final d = pL - tL;
          mse += d * d;
        }
      }
      mse = mse / len;
      if (bestScore == null || mse < bestScore) {
        bestScore = mse;
        bestKey = entry.key;
      }
    }

    // return filename without path and extension
    final name = bestKey.split('/').last.split('.').first;
    return name;
  }
}
