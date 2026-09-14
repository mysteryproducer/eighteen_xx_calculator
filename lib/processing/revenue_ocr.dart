import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// What text recognition made of one revenue circle.
class RevenueReading {
  final int? value;
  final String rawText;

  const RevenueReading({this.value, required this.rawText});

  bool get recognized => value != null;

  @override
  String toString() => recognized ? '$value' : 'unread("$rawText")';
}

/// Thrown when the platform has no text recognizer, such as a desktop build.
class TextRecognitionUnavailable implements Exception {
  final String message;
  const TextRecognitionUnavailable(this.message);

  @override
  String toString() => message;
}

/// Reads the printed revenue numbers next to cities and towns.
///
/// This is the fallback source of revenue, used where a tile wasn't
/// recognized confidently enough to trust its tile data (see
/// `RevenueResolver`). Recognition itself is done natively on each platform,
/// behind the [channel]: Apple's Vision framework on iOS
/// (`ios/Runner/TextRecognitionPlugin.swift`) and ML Kit on Android
/// (`TextRecognitionChannel.kt`). Neither needs a Flutter plugin, which keeps
/// the iOS build free of CocoaPods.
///
/// The channel takes PNG bytes under `image` and returns the recognized lines
/// as a single newline-separated string.
class RevenueOcr {
  static const MethodChannel channel =
      MethodChannel('eighteen_xx_calculator/text_recognition');

  const RevenueOcr();

  /// Reads a number from [region] of [source].
  ///
  /// Returns an unread [RevenueReading] if the platform recognizer fails on
  /// this crop, and throws [TextRecognitionUnavailable] if there is no
  /// recognizer at all, so a caller reading many crops can stop early.
  Future<RevenueReading> readRegion(
    img.Image source,
    math.Rectangle<int> region,
  ) async {
    final left = region.left.clamp(0, source.width - 1);
    final top = region.top.clamp(0, source.height - 1);
    final width = region.width.clamp(1, source.width - left);
    final height = region.height.clamp(1, source.height - top);

    var crop = img.copyCrop(source, x: left, y: top, width: width, height: height);
    // Small printed digits benefit from being scaled up before recognition.
    if (crop.width < 160) {
      final scale = 160 / crop.width;
      crop = img.copyResize(
        crop,
        width: 160,
        height: math.max(1, (crop.height * scale).round()),
        interpolation: img.Interpolation.cubic,
      );
    }

    try {
      final text = await channel.invokeMethod<String>(
        'recognizeText',
        {'image': img.encodePng(crop)},
      );
      return parseRecognizedText(text ?? '');
    } on MissingPluginException {
      throw const TextRecognitionUnavailable(
        'Text recognition is not available on this device.',
      );
    } on PlatformException catch (e) {
      debugPrint('Text recognition failed: ${e.code} ${e.message}');
      return const RevenueReading(value: null, rawText: '');
    }
  }

  /// Picks the revenue out of recognized text: the largest plain number found,
  /// since crops often also catch a slot number or part of a neighbouring tile.
  static RevenueReading parseRecognizedText(String text) {
    final matches = RegExp(r'\d+').allMatches(text);
    if (matches.isEmpty) {
      return RevenueReading(value: null, rawText: text.trim());
    }
    final numbers = matches
        .map((m) => int.tryParse(m.group(0)!))
        .whereType<int>()
        .where((n) => n >= 0 && n <= 999)
        .toList();
    if (numbers.isEmpty) {
      return RevenueReading(value: null, rawText: text.trim());
    }
    numbers.sort();
    return RevenueReading(value: numbers.last, rawText: text.trim());
  }
}
