import 'dart:typed_data';

import 'package:eighteen_xx_calculator/geometry/homography.dart';
import 'package:eighteen_xx_calculator/models/board.dart';
import 'package:eighteen_xx_calculator/models/map_layout.dart';
import 'package:eighteen_xx_calculator/processing/grid_detector.dart';
import 'package:eighteen_xx_calculator/processing/guide_follower.dart';
import 'package:eighteen_xx_calculator/services/photo_pipeline.dart';
import 'package:image/image.dart' as img;

/// Stands in for the real photo work so screens can be tested without
/// running detection in a background isolate.
class FakePhotoPipeline implements PhotoPipeline {
  /// What detection should return; null means "no grid found".
  GridFit? fit;

  /// When set, every call throws this instead, to exercise the paths that
  /// have to survive something going wrong deep in the detector.
  Object? failure;

  int fitBoardCalls = 0;
  int snapCalls = 0;
  int closeUpCalls = 0;

  FakePhotoPipeline({this.fit, this.failure});

  /// A fit that places [map] on a photo at [scale] pixels per hex.
  static GridFit fitFor(MapLayout map, {double scale = 30, double coverage = 0.9}) {
    final bounds = map.boardBounds;
    final h = Homography.similarity(
      scale: scale,
      translation: -bounds.topLeft * scale,
    );
    return GridFit(
      boardToImage: h,
      visible: map.coords.toSet(),
      coverage: coverage,
      hexCoverage: {for (final c in map.coords) c: coverage},
      placementMargin: 0.4,
    );
  }

  @override
  Future<(img.Image, Uint8List)> load(String path) async {
    if (failure != null) throw failure!;
    final photo = img.Image(width: 400, height: 300);
    img.fill(photo, color: img.ColorRgb8(210, 200, 180));
    return (photo, Uint8List.fromList(img.encodeJpg(photo)));
  }

  /// The hints the screen passed with its latest fit.
  BoardHints? lastHints;

  @override
  Future<GridFit?> fitBoard(MapLayout map, img.Image photo,
      {BoardHints? hints}) async {
    fitBoardCalls++;
    lastHints = hints;
    if (failure != null) throw failure!;
    return fit;
  }

  @override
  Future<GuideAdjustment?> followGuide(
    MapLayout map, {
    required Uint8List bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    required Homography guide,
    required HexCoord target,
  }) async =>
      null;

  @override
  Future<GridFit> snap(MapLayout map, img.Image photo, Homography guess) async {
    snapCalls++;
    if (failure != null) throw failure!;
    return fit ?? fitFor(map);
  }

  @override
  Future<GridFit?> fitCloseUp(
    MapLayout map,
    img.Image photo,
    Homography guess,
    HexCoord target, {
    BoardHints? hints,
  }) async {
    closeUpCalls++;
    lastHints = hints;
    if (failure != null) throw failure!;
    return fit;
  }
}
