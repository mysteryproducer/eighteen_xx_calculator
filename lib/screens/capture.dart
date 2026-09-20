import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/map_layout.dart';
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

  final String instruction;

  const CaptureGuide({
    required this.target,
    required this.hexes,
    required this.instruction,
  });

  /// The target hex's circumradius as a share of the frame's shorter side.
  /// A hex and its six neighbours span five radii, so this leaves a margin
  /// for the user's aim.
  static const double hexShare = 0.14;

  /// Board to frame coordinates for a frame of [size]. The same relative
  /// placement is used on the preview and on the photo that comes out of it.
  Homography homographyFor(Size size) {
    final scale = hexShare * math.min(size.width, size.height);
    final centre = Offset(size.width / 2, size.height / 2);
    return Homography.similarity(
      scale: scale,
      translation: centre - target.boardCenter * scale,
    );
  }
}

/// Photographs the board, returning the file path, or null if the user backed
/// out. Phones use the camera; macOS uses the Mac's webcam, so the app can be
/// tried on a development machine.
Future<String?> capturePhoto(BuildContext context, {CaptureGuide? guide}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? MacWebcamCapture(guide: guide)
          : CameraCapture(guide: guide),
    ));

/// Draws a [CaptureGuide]'s hexes over the camera preview.
class CaptureGuidePainter extends CustomPainter {
  final CaptureGuide guide;

  const CaptureGuidePainter(this.guide);

  @override
  void paint(Canvas canvas, Size size) {
    final h = guide.homographyFor(size);
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
      oldDelegate.guide != guide;
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
