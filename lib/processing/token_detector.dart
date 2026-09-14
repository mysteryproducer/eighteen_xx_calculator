import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/company.dart';

/// What colour, if any, was found sitting in a city's token slot.
class TokenDetection {
  final Company? company;
  final Color sampledColor;
  final double confidence; // 0..1
  final bool looksEmpty;

  const TokenDetection({
    required this.company,
    required this.sampledColor,
    required this.confidence,
    required this.looksEmpty,
  });

  static const TokenDetection none = TokenDetection(
    company: null,
    sampledColor: Colors.transparent,
    confidence: 0,
    looksEmpty: true,
  );
}

/// Guesses which company has a station token in a city slot, by colour.
///
/// A token is a saturated disc sitting inside the city's white circle, so the
/// detector samples the middle of that circle: near-white or near-neutral means
/// an empty slot, anything else is matched to the closest company colour. This
/// is a best-effort assist for the review UI, not a source of truth -- the user
/// can always set the company by tapping the station, and low [confidence]
/// results should be shown as a suggestion rather than applied silently.
class TokenDetector {
  final List<Company> companies;

  const TokenDetector({this.companies = Company.defaults});

  /// Samples the disc of radius [radius] around ([centerX], [centerY]) in
  /// [source] and matches it against the company palette.
  TokenDetection detect(img.Image source, int centerX, int centerY, int radius) {
    final sampleRadius = math.max(2, (radius * 0.6).round());
    int count = 0;
    double rSum = 0, gSum = 0, bSum = 0;

    for (int y = centerY - sampleRadius; y <= centerY + sampleRadius; y++) {
      for (int x = centerX - sampleRadius; x <= centerX + sampleRadius; x++) {
        if (x < 0 || y < 0 || x >= source.width || y >= source.height) continue;
        final dx = x - centerX;
        final dy = y - centerY;
        if (dx * dx + dy * dy > sampleRadius * sampleRadius) continue;
        final pixel = source.getPixel(x, y);
        rSum += pixel.r;
        gSum += pixel.g;
        bSum += pixel.b;
        count++;
      }
    }

    if (count == 0) return TokenDetection.none;

    final r = rSum / count;
    final g = gSum / count;
    final b = bSum / count;
    final sampled = Color.fromARGB(255, r.round(), g.round(), b.round());

    // An empty city slot is printed white; a pale, unsaturated sample most
    // likely means no token is there.
    final maxChannel = math.max(r, math.max(g, b));
    final minChannel = math.min(r, math.min(g, b));
    final saturation = maxChannel <= 0 ? 0.0 : (maxChannel - minChannel) / maxChannel;
    final looksEmpty = saturation < 0.18 && maxChannel > 170;

    Company? best;
    double bestDistance = double.infinity;
    double runnerUp = double.infinity;
    for (final company in companies) {
      final d = _distance(r, g, b, company.color);
      if (d < bestDistance) {
        runnerUp = bestDistance;
        bestDistance = d;
        best = company;
      } else if (d < runnerUp) {
        runnerUp = d;
      }
    }

    final confidence = runnerUp.isFinite && runnerUp > 0
        ? ((runnerUp - bestDistance) / runnerUp).clamp(0.0, 1.0).toDouble()
        : 0.0;

    return TokenDetection(
      company: looksEmpty ? null : best,
      sampledColor: sampled,
      confidence: looksEmpty ? 0 : confidence,
      looksEmpty: looksEmpty,
    );
  }

  static double _distance(double r, double g, double b, Color color) {
    final dr = r - (color.r * 255);
    final dg = g - (color.g * 255);
    final db = b - (color.b * 255);
    return math.sqrt(dr * dr + dg * dg + db * db);
  }
}
