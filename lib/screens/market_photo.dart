import 'package:flutter/material.dart';

import '../models/game_session.dart';
import '../models/game_title.dart';
import '../processing/revenue_ocr.dart';
import '../services/photo_pipeline.dart';
import 'capture.dart';

/// Photographs the stock market and reads each company's share value off it
/// into [session] (see `MarketReader`) -- and, for a title whose market the
/// app doesn't know, the market itself. What to tell the user, or null if
/// no photo was taken. A marker under another's isn't seen; the share values
/// are a start to put right.
Future<String?> photographMarket(
  BuildContext context, {
  required GameTitle title,
  required GameSession session,
  required PhotoPipeline pipeline,
  required VoidCallback onBusy,
}) async {
  final path = (await capturePhoto(context))?.path;
  if (path == null) return null;
  onBusy();
  try {
    final (photo, _) = await pipeline.load(path);
    final reading = await pipeline.readMarket(title, photo);
    session.sharePrices.addAll(reading.prices);
    if (title.market.isEmpty && reading.rows.isNotEmpty) {
      session.photographedMarket
        ..clear()
        ..addAll(reading.rows);
    }
    return reading.prices.isEmpty
        ? 'No markers found on the market. Enter the share values by hand.'
        : 'Read ${reading.prices.length} share '
            '${reading.prices.length == 1 ? 'value' : 'values'} off the '
            'market. Check them, and add any marker hidden under another.';
  } on TextRecognitionUnavailable catch (e) {
    return '${e.message} Enter the share values by hand.';
  }
}
