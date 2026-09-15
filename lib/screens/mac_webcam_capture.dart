import 'dart:io';

import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';

import 'image_processing.dart';

/// Photographs the board with a Mac's webcam, for trying the app on a
/// development machine.
///
/// The `camera` plugin used on phones has no macOS implementation, so this
/// screen uses `camera_macos` instead and hands the photo to the same
/// [ImageProcessing] screen. Choose between the two with `boardCaptureScreen`.
class MacWebcamCapture extends StatefulWidget {
  final Map<String, dynamic>? game;

  const MacWebcamCapture({super.key, this.game});

  @override
  State<MacWebcamCapture> createState() => _MacWebcamCaptureState();
}

class _MacWebcamCaptureState extends State<MacWebcamCapture> {
  final GlobalKey _cameraKey = GlobalKey(debugLabel: 'mac-webcam');
  CameraMacOSController? _controller;
  bool _capturing = false;

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
      // The processing screen reads the photo from a file, as it does for the
      // phone camera.
      final file = File(
        '${Directory.systemTemp.path}/'
        'board_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ImageProcessing(
          imagePath: file.path,
          game: widget.game ?? {},
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not take a picture: $e')),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture Board (webcam)')),
      body: Column(
        children: [
          Expanded(
            child: CameraMacOSView(
              key: _cameraKey,
              fit: BoxFit.contain,
              cameraMode: CameraMacOSMode.photo,
              // Photos come from the video feed, which is mirrored by default.
              // A mirrored board can't be matched: a flipped tile isn't any
              // rotation of the real one.
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
          ),
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
    );
  }
}
