import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../processing/grid_detector.dart';
import '../processing/guide_follower.dart' as follower;
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
    final bytes = await Isolate.run(() {
      // Big enough for a card's small print; a phone's full size would only
      // slow the encoding down.
      final longest = math.max(photo.width, photo.height);
      final sized = longest <= 2400
          ? photo
          : img.copyResize(photo,
              width: photo.width * 2400 ~/ longest,
              interpolation: img.Interpolation.average);
      return img.encodeJpg(sized, quality: 92);
    });
    final lines = await RevenueOcr.recognizeLines(bytes);
    return PlayAreaReader(title).read(lines, photo: photo);
  }
}
