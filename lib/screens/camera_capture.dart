import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'image_processing.dart';

class CameraCapture extends StatefulWidget {
  final Map<String, dynamic>? game;

  const CameraCapture({super.key, this.game});

  @override
  State<CameraCapture> createState() => _CameraCaptureState();
}

class _CameraCaptureState extends State<CameraCapture> {
  CameraController? _controller;
  XFile? _capturedFile;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (!mounted) return;
      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      // ignore errors for now
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final file = await _controller!.takePicture();
      setState(() {
        _capturedFile = file;
      });
      // navigate to processing screen with captured image and chosen game
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) {
          return ImageProcessing(
            imagePath: file.path,
            game: widget.game ?? {},
          );
        }));
      }
    } catch (e) {
      debugPrint('Take picture error: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capture Board'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _isInitialized && _controller != null
                  ? CameraPreview(_controller!)
                  : const Text('Initializing camera...'),
            ),
          ),
          if (_capturedFile != null)
            SizedBox(
              height: 200,
              child: Image.file(File(_capturedFile!.path)),
            ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _takePicture,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Capture'),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _capturedFile = null;
                    });
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Clear'),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
