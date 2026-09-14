import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// What OCR made of one revenue circle.
class RevenueReading {
  final int? value;
  final String rawText;

  const RevenueReading({this.value, required this.rawText});

  bool get recognized => value != null;

  @override
  String toString() => recognized ? '$value' : 'unread("$rawText")';
}

/// Reads the printed revenue numbers next to cities and towns.
///
/// Each station's crop is taken from the full-resolution photo using the same
/// hex placement maths the classifier uses, then handed to ML Kit's on-device
/// text recognizer. Results are advisory: the review UI shows what was read
/// and lets the user fix it, since small printed numbers on a photographed
/// board are the least reliable part of this pipeline.
class RevenueOcr {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  /// Reads a number from [region] of [source].
  ///
  /// The crop is written to a temporary file because ML Kit reads images from
  /// disk (or a camera stream); the file is deleted once it has been read.
  Future<RevenueReading> readRegion(img.Image source, math.Rectangle<int> region) async {
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

    final file = File(
      '${Directory.systemTemp.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(img.encodePng(crop));
    try {
      final recognized =
          await _recognizer.processImage(InputImage.fromFilePath(file.path));
      return parseRecognizedText(recognized.text);
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
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

  /// Releases the recognizer. Failures here are logged rather than thrown:
  /// tearing a screen down shouldn't fail because ML Kit is unavailable.
  Future<void> dispose() async {
    try {
      await _recognizer.close();
    } catch (e) {
      debugPrint('Closing text recognizer failed: $e');
    }
  }
}
