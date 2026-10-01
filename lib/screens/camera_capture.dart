import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import 'capture.dart';

/// Photographs the board with the device camera and returns the file path.
///
/// With a [guide], the hexes to capture are outlined over the preview: the
/// user lines the board up with the outline, which frames the right part of
/// the board and tells the app which hexes it is looking at.
class CameraCapture extends StatefulWidget {
  final CaptureGuide? guide;

  const CameraCapture({super.key, this.guide});

  @override
  State<CameraCapture> createState() => _CameraCaptureState();
}

class _CameraCaptureState extends State<CameraCapture> {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppSettings.shared.load();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera on this device.');
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        // The board's printing is fine: the more detail the better.
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _isInitialized = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the camera: $e');
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await controller.takePicture();
      if (mounted) Navigator.of(context).pop(file.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not take the picture: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final guide = widget.guide;
    return Scaffold(
      appBar: AppBar(
        title: Text(guide == null ? 'Photograph the board' : 'Close-up'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, textAlign: TextAlign.center),
                    )
                  : _isInitialized && _controller != null
                      ? CameraPreview(
                          _controller!,
                          child: guide == null ? null : CaptureGuideOverlay(guide),
                        )
                      : const CircularProgressIndicator(),
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
                    onPressed: _isInitialized && !_busy ? _takePicture : null,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(_busy ? 'Capturing...' : 'Capture'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
