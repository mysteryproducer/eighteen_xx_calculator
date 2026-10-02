import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';

import '../processing/guide_follower.dart';
import '../services/app_settings.dart';
import '../services/photo_pipeline.dart';
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

  /// How the guide has moved to follow the board in the preview (see
  /// [followGuide]), and how many looks in a row haven't found it.
  GuideAdjustment _adjustment = GuideAdjustment.none;
  int _misses = 0;
  bool _looking = false;
  Timer? _follow;

  @override
  void initState() {
    super.initState();
    AppSettings.shared.load();
  }

  @override
  void dispose() {
    _follow?.cancel();
    // The preview widget doesn't release the camera itself.
    _controller?.destroy();
    super.dispose();
  }

  /// Starts looking at the preview now and then to keep a close-up's guide
  /// on the board.
  void _startFollowing() {
    if (widget.guide?.map == null || _follow != null) return;
    _follow = Timer.periodic(
        const Duration(milliseconds: 900), (_) => _followOnce());
  }

  Future<void> _followOnce() async {
    final controller = _controller;
    final guide = widget.guide;
    final map = guide?.map;
    if (controller == null || guide == null || map == null) return;
    if (_looking || _capturing) return;
    _looking = true;
    try {
      final frame = await _oneFrame(controller);
      if (frame == null || !mounted || _capturing) return;
      final size = Size(frame.width.toDouble(), frame.height.toDouble());
      final found = await const PhotoPipeline().followGuide(
        map,
        bytes: frame.bytes,
        width: frame.width,
        height: frame.height,
        bytesPerRow: frame.bytesPerRow,
        // From where the guide was first drawn, every time.
        guide: guide.unadjustedFor(size),
        target: guide.target,
      );
      if (!mounted || _capturing) return;
      setState(() {
        if (found != null) {
          _misses = 0;
          _adjustment = _adjustment.toward(found, 0.6);
        } else if (++_misses >= 3) {
          // Lost the board: drift back to where the guide was drawn.
          _adjustment = _adjustment.toward(GuideAdjustment.none, 0.4);
        }
      });
    } catch (e) {
      debugPrint('Following the board: $e');
    } finally {
      _looking = false;
    }
  }

  /// One frame of the preview: the stream runs only long enough for it.
  Future<CameraImageData?> _oneFrame(CameraMacOSController controller) {
    final frame = Completer<CameraImageData?>();
    controller.startImageStream((image) {
      if (frame.isCompleted || image == null) return;
      frame.complete(image);
      controller.stopImageStream();
    });
    return frame.future.timeout(const Duration(seconds: 2), onTimeout: () {
      controller.stopImageStream();
      return null;
    });
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;
    _follow?.cancel();
    setState(() => _capturing = true);
    try {
      await controller.stopImageStream();
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
      Navigator.of(context).pop(CapturedPhoto(file.path,
          guide: widget.guide?.adjusted(_adjustment)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _capturing = false);
      _follow = null;
      _startFollowing();
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
                    _startFollowing();
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
                if (guide?.map != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(_followingText,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
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
        child: CaptureGuideOverlay(guide.adjusted(_adjustment)),
      ),
    );
  }

  String get _followingText {
    if (_misses > 0 || _adjustment.isNone) {
      return 'Get the outline roughly over the hexes, and it will follow '
          'the board from there.';
    }
    final degrees = (_adjustment.turn * 180 / math.pi).round();
    return 'The outline is following the board'
        '${degrees.abs() < 2 ? '' : ', turned ${degrees.abs()} degrees '
            '${degrees > 0 ? 'clockwise' : 'anticlockwise'}'}.';
  }
}
