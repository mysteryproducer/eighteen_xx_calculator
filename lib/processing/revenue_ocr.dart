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

/// A word (or a line) the platform's text recognizer read, and where it
/// lies in the image: from 0 at the left edge to 1 at the right, and from 0
/// at the top to 1 at the bottom.
class RecognizedWord {
  final String text;
  final double left;
  final double right;
  final double top;
  final double bottom;

  const RecognizedWord(this.text, this.left, this.right,
      {this.top = 0, this.bottom = 1});

  double get width => right - left;
  double get height => bottom - top;

  @override
  String toString() =>
      '$text@${left.toStringAsFixed(2)}-${right.toStringAsFixed(2)}';
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
/// behind the [channel]: Apple's Vision framework on iOS and macOS
/// (`TextRecognitionPlugin.swift` in each runner) and ML Kit on Android
/// (`TextRecognitionChannel.kt`). None needs a Flutter plugin, which keeps
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

    return parseRecognizedText(await recognize(crop));
  }

  /// The text the platform recognizer finds in [image], a line at a time;
  /// empty if it fails on this image. Throws [TextRecognitionUnavailable]
  /// if there is no recognizer at all.
  static Future<String> recognize(img.Image image) async {
    try {
      final text = await channel.invokeMethod<String>(
        'recognizeText',
        {'image': img.encodePng(image)},
      );
      return text ?? '';
    } on MissingPluginException {
      throw const TextRecognitionUnavailable(
        'Text recognition is not available on this device.',
      );
    } on PlatformException catch (e) {
      debugPrint('Text recognition failed: ${e.code} ${e.message}');
      return '';
    }
  }

  /// The words the platform recognizer finds in [image], with where each
  /// lies across it; empty if it fails on this image. Throws
  /// [TextRecognitionUnavailable] if the platform can't say where words are
  /// (Android's recognizer answers only [recognize]).
  static Future<List<RecognizedWord>> recognizeWords(img.Image image) async {
    try {
      final words = await channel.invokeListMethod<Map<Object?, Object?>>(
        'recognizeTextWords',
        {'image': img.encodePng(image)},
      );
      return [
        for (final word in words ?? const <Map<Object?, Object?>>[])
          RecognizedWord(
            word['text'] as String,
            (word['left'] as num).toDouble(),
            (word['right'] as num).toDouble(),
            top: (word['top'] as num?)?.toDouble() ?? 0,
            bottom: (word['bottom'] as num?)?.toDouble() ?? 1,
          ),
      ];
    } on MissingPluginException {
      throw const TextRecognitionUnavailable(
        'Word positions are not available on this device.',
      );
    } on PlatformException catch (e) {
      debugPrint('Text recognition failed: ${e.code} ${e.message}');
      return const [];
    }
  }

  /// The lines of text the platform recognizer finds in [image] -- PNG or
  /// JPEG bytes -- with where each lies; empty if it fails on this image.
  /// Throws [TextRecognitionUnavailable] if there is no recognizer.
  static Future<List<RecognizedWord>> recognizeLines(Uint8List image) async {
    try {
      final lines = await channel.invokeListMethod<Map<Object?, Object?>>(
        'recognizeTextLines',
        {'image': image},
      );
      return [
        for (final line in lines ?? const <Map<Object?, Object?>>[])
          RecognizedWord(
            line['text'] as String,
            (line['left'] as num).toDouble(),
            (line['right'] as num).toDouble(),
            top: (line['top'] as num).toDouble(),
            bottom: (line['bottom'] as num).toDouble(),
          ),
      ];
    } on MissingPluginException {
      throw const TextRecognitionUnavailable(
        'Text recognition is not available on this device.',
      );
    } on PlatformException catch (e) {
      debugPrint('Text recognition failed: ${e.code} ${e.message}');
      return const [];
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
