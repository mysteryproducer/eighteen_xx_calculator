import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../processing/grid_detector.dart';
import '../processing/guide_follower.dart' as follower;
import '../processing/market_reader.dart';
import '../processing/play_area_reader.dart';
import '../processing/revenue_ocr.dart';

/// The heavy per-photo work, kept off the UI thread.
///
/// Decoding a camera photo and searching it for the hex grid take a second or
/// two each, so both run in a background isolate. Recognition itself stays on
/// the main isolate because it draws its reference tiles with the graphics
/// engine, which only the main isolate has.
///
/// Every `Isolate.run` in the app belongs here, and for a reason: a closure
/// written inside a `State` method shares its captured context with the
/// other closures around it, so a nearby `setState` drags the whole widget
/// tree -- and the framework's zone -- into the message, and sending it
/// fails with "object is unsendable". The closures below capture nothing but
/// their arguments.
class PhotoPipeline {
  const PhotoPipeline();

  /// Reads the photo at [path], turning it the right way up if the camera
  /// recorded an orientation, and returns it with a JPEG for display.
  Future<(img.Image, Uint8List)> load(String path) async {
    final bytes = await File(path).readAsBytes();
    return Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw const FormatException('That file is not an image the app can read.');
      }
      // Phones record which way up the camera was rather than rotating the
      // pixels; everything downstream assumes the picture is the right way up.
      final photo = img.bakeOrientation(decoded);
      final preview = img.encodeJpg(
        photo.width > 1600
            ? img.copyResize(photo, width: 1600, interpolation: img.Interpolation.average)
            : photo,
        quality: 85,
      );
      return (photo, preview);
    });
  }

  /// Finds the whole map in a photo of the board, helped by what the game
  /// already knows.
  Future<GridFit?> fitBoard(MapLayout map, img.Image photo,
          {BoardHints? hints}) =>
      Isolate.run(() => GridDetector(map).fitBoard(photo, hints: hints));

  /// Tightens a hand-made alignment onto the printed lines.
  Future<GridFit> snap(MapLayout map, img.Image photo, Homography guess) =>
      Isolate.run(() => GridDetector(map).snap(photo, guess));

  /// How a close-up guide drawn at [guide] (board to the frame's pixels)
  /// should move to follow the board in a preview frame of four bytes a
  /// pixel; see [followGuide].
  Future<follower.GuideAdjustment?> followGuide(
    MapLayout map, {
    required Uint8List bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    required Homography guide,
    required HexCoord target,
  }) =>
      Isolate.run(() => follower.followGuide(map,
          follower.GrayFrame.fromFourBytes(bytes, width, height, bytesPerRow),
          guide, target));

  /// Where a close-up guide locked onto the board at [current] (board to
  /// the frame's pixels) has moved to in a preview frame, perspective and
  /// all; see [follower.trackGuide].
  Future<Homography?> trackGuide(
    MapLayout map, {
    required Uint8List bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    required Homography current,
    required HexCoord target,
  }) =>
      Isolate.run(() => follower.trackGuide(map,
          follower.GrayFrame.fromFourBytes(bytes, width, height, bytesPerRow),
          current, target));

  /// Finds the grid in a close-up framed with a guide, helped by what the
  /// game already knows.
  Future<GridFit?> fitCloseUp(
    MapLayout map,
    img.Image photo,
    Homography guess,
    HexCoord target, {
    BoardHints? hints,
  }) =>
      Isolate.run(() =>
          GridDetector(map).fitCloseUp(photo, guess, target, hints: hints));

  /// Reads a photo of a player's area: the charters, trains, tokens and
  /// certificates in it. Text recognition runs natively, behind a platform
  /// channel the main isolate holds, so only the encoding goes to the
  /// background. Throws [TextRecognitionUnavailable] where the platform
  /// can't place lines of text.
  Future<PlayAreaReading> readPlayArea(GameTitle title, img.Image photo) async {
    Future<Uint8List> encoded(img.Image image, int turn) => Isolate.run(() {
          // Big enough for a card's small print; a phone's full size would
          // only slow the encoding down.
          final longest = math.max(image.width, image.height);
          var sized = longest <= 2400
              ? image
              : img.copyResize(image,
                  width: image.width * 2400 ~/ longest,
                  interpolation: img.Interpolation.average);
          if (turn != 0) sized = img.copyRotate(sized, angle: turn);
          return img.encodeJpg(sized, quality: 92);
        });
    var lines = await RevenueOcr.recognizeLines(await encoded(photo, 0));
    var reading = PlayAreaReader(title).read(lines, photo: photo);
    // A charter photographed sideways -- a portrait photo of a card lying
    // landscape -- is read anyway, but its large train figures often
    // aren't, and where a token's place lies, above its cost, is beside it.
    // Turned upright it reads properly; which way is upright is whichever
    // reads better.
    if (_sideways(lines, photo)) {
      for (final turn in [90, 270]) {
        final turned = await Isolate.run(() => img.copyRotate(photo, angle: turn));
        final turnedLines = await RevenueOcr.recognizeLines(await encoded(turned, 0));
        final turnedReading = PlayAreaReader(title).read(turnedLines, photo: turned);
        if (_score(turnedReading) > _score(reading)) {
          reading = turnedReading;
          lines = turnedLines;
        }
      }
    }
    if (reading.isEmpty) {
      // What the recognizer made of it, for working out why (on Android,
      // `adb logcat -s flutter`).
      debugPrint('Nothing found in a player\'s area. ${lines.length} lines '
          'read: ${lines.map((l) => '"${l.text}" '
              '(${l.left.toStringAsFixed(3)}, ${l.top.toStringAsFixed(3)}, '
              '${l.right.toStringAsFixed(3)}, ${l.bottom.toStringAsFixed(3)})').join(', ')}');
    }
    return reading;
  }

  /// Reads a photo of the stock market (see [MarketReader]): turned a
  /// quarter each way as well where it was taken sideways, keeping
  /// whichever finds more.
  Future<MarketReading> readMarket(GameTitle title, img.Image photo) async {
    Future<List<RecognizedWord>> linesOf(img.Image image) async =>
        RevenueOcr.recognizeLines(await Isolate.run(() {
          final longest = math.max(image.width, image.height);
          final sized = longest <= 2400
              ? image
              : img.copyResize(image,
                  width: image.width * 2400 ~/ longest,
                  interpolation: img.Interpolation.average);
          return img.encodeJpg(sized, quality: 92);
        }));
    int found(MarketReading reading) =>
        10 * reading.prices.length +
        reading.rows.fold(0, (total, row) => total + row.length);
    final lines = await linesOf(photo);
    var reading = MarketReader(title).read(lines, photo);
    if (_sideways(lines, photo)) {
      for (final turn in [90, 270]) {
        final turned = await Isolate.run(() => img.copyRotate(photo, angle: turn));
        final turnedReading =
            MarketReader(title).read(await linesOf(turned), turned);
        if (found(turnedReading) > found(reading)) reading = turnedReading;
      }
    }
    return reading;
  }

  /// Whether most of the text read in [photo] runs up and down the frame:
  /// the cards are lying sideways in it.
  static bool _sideways(List<RecognizedWord> lines, img.Image photo) {
    final long = [
      for (final l in lines)
        if (l.text.trim().length >= 4) l,
    ];
    if (long.length < 3) return false;
    final tall = long.where((l) =>
        (l.bottom - l.top) * photo.height > 1.5 * (l.right - l.left) * photo.width);
    return tall.length * 2 > long.length;
  }

  /// How much a reading found, and above all whether it read the charters
  /// the right way up: what decides which way a sideways photo is turned.
  static int _score(PlayAreaReading reading) =>
      10 * reading.upright +
      reading.charters.fold<int>(
          0,
          (t, c) =>
              t +
              2 * c.trains.length +
              c.slots.length +
              2 * c.slots.where((s) => s.filled != null).length) +
      reading.certificates.fold<int>(0, (t, c) => t + c.percents.length);
}
