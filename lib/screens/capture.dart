import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import '../processing/guide_follower.dart';
import '../processing/tile_renderer.dart';
import '../services/app_settings.dart';
import 'camera_capture.dart';
import 'mac_webcam_capture.dart';

/// The outline drawn over the camera preview for a close-up, and the rough
/// placement it implies.
///
/// Lining the board up with an outline on screen does two jobs at once: it
/// gets the right hexes in frame at a workable size, and it tells the app
/// which hex is which, which a close-up of a repeating grid can't otherwise
/// say. The fit is then corrected against the printed lines, so the framing
/// only has to be good to within about half a hex.
class CaptureGuide {
  /// The hex to put in the middle of the frame.
  final HexCoord target;

  /// The hexes drawn, usually [target] and its neighbours.
  final List<MapHex> hexes;

  /// The tiles the game already has on those hexes, drawn faintly inside the
  /// outline: something to line up with besides a grid that looks the same
  /// everywhere.
  final Map<HexCoord, TileDefinition> tiles;

  final String instruction;

  /// Which way the board faces in the frame, in radians as
  /// `GridFit.facing`: the way it faced in the game's last photo of the
  /// whole board, since players take their close-ups from where they sit.
  final double turn;

  /// The title's map, for following the board in the camera's preview (see
  /// `followGuide`); without it the guide stays where it is drawn.
  final MapLayout? map;

  /// How the guide has been moved to follow the board the camera sees.
  final GuideAdjustment adjustment;

  const CaptureGuide({
    required this.target,
    required this.hexes,
    required this.instruction,
    this.tiles = const {},
    this.turn = 0,
    this.map,
    this.adjustment = GuideAdjustment.none,
  });

  /// This guide, moved by [adjustment].
  CaptureGuide adjusted(GuideAdjustment adjustment) => CaptureGuide(
        target: target,
        hexes: hexes,
        instruction: instruction,
        tiles: tiles,
        turn: turn,
        map: map,
        adjustment: adjustment,
      );

  /// The target hex's circumradius as a share of the frame's shorter side.
  /// A hex and its six neighbours span five radii, so this leaves a margin
  /// for the user's aim.
  static const double hexShare = 0.14;

  /// Board to frame coordinates for a frame of [size]. The same relative
  /// placement is used on the preview and on the photo that comes out of it.
  Homography homographyFor(Size size) {
    final drawn = unadjustedFor(size);
    return adjustment.isNone ? drawn : drawn.then(adjustment.inFrame(size));
  }

  /// Where the guide is first drawn, before following the board.
  Homography unadjustedFor(Size size) {
    final scale = hexShare * math.min(size.width, size.height);
    final centre = Offset(size.width / 2, size.height / 2);
    final c = math.cos(turn) * scale, s = math.sin(turn) * scale;
    final at = target.boardCenter;
    return Homography.similarity(
      scale: scale,
      radians: turn,
      translation: centre - Offset(c * at.dx - s * at.dy, s * at.dx + c * at.dy),
    );
  }
}

/// Photographs the board, returning the file path, or null if the user backed
/// out. Phones use the camera; macOS uses the Mac's webcam, so the app can be
/// tried on a development machine.
Future<CapturedPhoto?> capturePhoto(BuildContext context,
        {CaptureGuide? guide}) =>
    Navigator.of(context).push<CapturedPhoto>(MaterialPageRoute(
      builder: (_) => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? MacWebcamCapture(guide: guide)
          : CameraCapture(guide: guide),
    ));

/// A photo taken, and the guide as it was when it was taken: moved to
/// follow the board in the preview, if it was.
class CapturedPhoto {
  final String path;
  final CaptureGuide? guide;

  const CapturedPhoto(this.path, {this.guide});
}

/// Draws a [CaptureGuide]'s hexes over the camera preview, with the tiles
/// already on them at [tileOpacity].
class CaptureGuidePainter extends CustomPainter {
  final CaptureGuide guide;
  final double tileOpacity;

  const CaptureGuidePainter(this.guide,
      {this.tileOpacity = AppSettings.defaultOverlayOpacity});

  @override
  void paint(Canvas canvas, Size size) {
    final h = guide.homographyFor(size);
    if (tileOpacity > 0 && guide.tiles.isNotEmpty) {
      // The guide is a plain scale and shift, so each tile is drawn the way
      // the board map draws it, just smaller or larger.
      final radius = h.localScale(guide.target.boardCenter);
      final tileSize = radius / TileRenderer.radiusShare;
      canvas.saveLayer(Offset.zero & size,
          Paint()..color = Colors.black.withValues(alpha: tileOpacity));
      guide.tiles.forEach((coord, tile) {
        final centre = h.apply(coord.boardCenter);
        canvas.save();
        canvas.translate(centre.dx, centre.dy);
        canvas.rotate(guide.turn + guide.adjustment.turn);
        canvas.translate(-tileSize / 2, -tileSize / 2);
        TileRenderer.paint(canvas, tile, tileSize);
        canvas.restore();
      });
      canvas.restore();
    }
    for (final hex in guide.hexes) {
      final isTarget = hex.coord == guide.target;
      final path = Path();
      for (int i = 0; i < 6; i++) {
        final v = h.apply(HexGeometry.vertex(hex.coord.boardCenter, 1, i));
        i == 0 ? path.moveTo(v.dx, v.dy) : path.lineTo(v.dx, v.dy);
      }
      path.close();
      canvas
        ..drawPath(
          path,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isTarget ? 6 : 4,
        )
        ..drawPath(
          path,
          Paint()
            ..color = (isTarget ? Colors.amberAccent : Colors.white)
                .withValues(alpha: isTarget ? 1 : 0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isTarget ? 3 : 1.5,
        );

      final label = TextPainter(
        text: TextSpan(
          text: hex.id,
          style: TextStyle(
            color: isTarget ? Colors.amberAccent : Colors.white70,
            fontSize: isTarget ? 16 : 12,
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final centre = h.apply(hex.coord.boardCenter);
      label.paint(canvas, centre - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CaptureGuidePainter oldDelegate) =>
      oldDelegate.guide != guide || oldDelegate.tileOpacity != tileOpacity;
}

/// The guide over a camera preview, following the overlay setting.
class CaptureGuideOverlay extends StatelessWidget {
  final CaptureGuide guide;

  const CaptureGuideOverlay(this.guide, {super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: AppSettings.shared.overlayOpacity,
        builder: (context, opacity, _) => CustomPaint(
          painter: CaptureGuidePainter(guide, tileOpacity: opacity),
        ),
      );
}

/// How strongly the tiles already laid show over the preview, remembered
/// from one close-up to the next.
class OverlayOpacityControl extends StatelessWidget {
  const OverlayOpacityControl({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: AppSettings.shared.overlayOpacity,
        builder: (context, opacity, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text('Tiles shown', style: Theme.of(context).textTheme.bodySmall),
              Expanded(
                child: Slider(
                  value: opacity,
                  divisions: 10,
                  label: '${(opacity * 100).round()}%',
                  onChanged: (v) => AppSettings.shared.setOverlayOpacity(v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${(opacity * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
      );
}

/// The instruction bar shown under a guided preview.
class CaptureInstructions extends StatelessWidget {
  final String text;

  const CaptureInstructions(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
}
