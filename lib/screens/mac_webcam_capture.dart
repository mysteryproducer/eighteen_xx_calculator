import 'dart:io';

import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import 'capture.dart';

/// Photographs the board with a Mac's webcam, for trying the app on a
/// development machine, and returns the file path.
///
/// The `camera` plugin used on phones has no macOS implementation, so this
/// screen uses `camera_macos` instead. `capturePhoto` chooses between them.
class MacWebcamCapture extends StatefulWidget {
  final CaptureGuide? guide;

  const MacWebcamCapture({super.key, this.guide});

  @override
  State<MacWebcamCapture> createState() => _MacWebcamCaptureState();
}

class _MacWebcamCaptureState extends State<MacWebcamCapture> {
  final GlobalKey _cameraKey = GlobalKey(debugLabel: 'mac-webcam');
  CameraMacOSController? _controller;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    AppSettings.shared.load();
  }

  @override
  void dispose() {
    // The preview widget doesn't release the camera itself.
    _controller?.destroy();
    super.dispose();
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      final picture = await controller.takePicture();
      final bytes = picture?.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The webcam returned no image.');
      }
      final file = File(
        '${Directory.systemTemp.path}/'
        'board_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _capturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not take a picture: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final guide = widget.guide;
    return Scaffold(
      appBar: AppBar(
        title: Text(guide == null
            ? 'Photograph the board (webcam)'
            : 'Close-up (webcam)'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraMacOSView(
                  key: _cameraKey,
                  fit: BoxFit.contain,
                  cameraMode: CameraMacOSMode.photo,
                  // Photos come from the video feed, which is mirrored by
                  // default. A mirrored board can't be matched: a flipped
                  // tile isn't any rotation of the real one.
                  isVideoMirrored: false,
                  enableAudio: false,
                  pictureFormat: PictureFormat.png,
                  onCameraInizialized: (controller) {
                    setState(() => _controller = controller);
                  },
                  onCameraLoading: (error) {
                    if (error != null) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Could not start the webcam: $error\n'
                            'Check the app is allowed to use the camera in '
                            'System Settings > Privacy & Security > Camera.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return const Center(child: CircularProgressIndicator());
                  },
                ),
                if (guide != null && _controller != null)
                  IgnorePointer(child: _guideOverlay(guide)),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CaptureInstructions(guide?.instruction ??
                    'Fit the whole board in the frame, as square-on as you can.'),
                if (guide != null && guide.tiles.isNotEmpty)
                  const OverlayOpacityControl(),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed:
                        _controller == null || _capturing ? null : _takePicture,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(_capturing ? 'Capturing...' : 'Capture'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The preview is letterboxed inside the view, so the guide has to be drawn
  /// over the video itself rather than the whole widget, or it wouldn't match
  /// the photo that comes out.
  Widget _guideOverlay(CaptureGuide guide) {
    final size = _controller?.args.size;
    if (size == null || size.width <= 0 || size.height <= 0) {
      return const SizedBox.shrink();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: size.width / size.height,
        child: CaptureGuideOverlay(guide),
      ),
    );
  }
}
