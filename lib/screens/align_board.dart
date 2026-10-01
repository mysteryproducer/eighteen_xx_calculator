import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../processing/grid_detector.dart';
import '../services/photo_pipeline.dart';

/// The photo area, so tests can find it without depending on the widget tree.
const Key alignCanvasKey = ValueKey('align-canvas');

/// [hexes] laid over the middle of a photo of [size], as large as fits: where
/// the grid starts when detection has nothing to offer, and where "Fit to
/// the photo" puts it back. From here every handle is on screen, which a
/// wrong detection -- a few huge hexes spilling far past the photo -- can't
/// promise.
Homography placeOverPhoto(Size size, Iterable<HexCoord> hexes) {
  var bounds = Rect.zero;
  var first = true;
  for (final c in hexes) {
    final hex = Rect.fromCenter(
        center: c.boardCenter, width: math.sqrt(3), height: 2);
    bounds = first ? hex : bounds.expandToInclude(hex);
    first = false;
  }
  if (first) return Homography.identity;
  final scale = 0.9 *
      math.min(size.width / bounds.width, size.height / bounds.height);
  return Homography.similarity(
    scale: scale,
    translation: size.center(Offset.zero) - bounds.center * scale,
  );
}

/// Finds where the board is in a photo, and lets the user correct it.
///
/// The app looks for the hex grid itself: the repeat of the printed outlines
/// gives the hex size and angle, fitting them accounts for the camera's
/// angle, and the shape of the title's map says which hex is which. When that
/// doesn't work -- an awkward angle, deep shadow, half the board out of frame
/// -- the user drags four named hexes onto their places instead, and the fit
/// is tightened against the printed lines from there.
class AlignBoard extends StatefulWidget {
  final GameTitle title;
  final img.Image photo;
  final Uint8List previewBytes;

  /// A starting placement, for a close-up whose guide already says roughly
  /// where the hexes are. Null for a photo of the whole board, which is
  /// worked out from scratch.
  final Homography? initial;

  /// The hexes this photo is meant to cover; the anchors to drag are chosen
  /// from these. Null means the whole map.
  final Set<HexCoord>? focus;

  final PhotoPipeline pipeline;

  const AlignBoard({
    super.key,
    required this.title,
    required this.photo,
    required this.previewBytes,
    this.initial,
    this.focus,
    this.pipeline = const PhotoPipeline(),
  });

  @override
  State<AlignBoard> createState() => _AlignBoardState();
}

class _AlignBoardState extends State<AlignBoard> {
  Homography? _boardToImage;
  GridFit? _fit;
  bool _busy = true;
  String _status = 'Looking for the hex grid...';
  bool _adjusting = false;
  int? _draggingAnchor;

  /// The gesture so far, for turning its running totals into steps.
  Offset? _lastFocal;
  double _lastScale = 1;
  double _lastRotation = 0;

  /// The hexes the user drags, and where they have been dragged to.
  late List<MapHex> _anchors;
  List<Offset> _handles = [];

  Size _displaySize = Size.zero;
  Offset _displayOrigin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _anchors = _chooseAnchors();
    _detect();
  }

  List<MapHex> _chooseAnchors() {
    final focus = widget.focus;
    if (focus == null || focus.length < 4) return widget.title.map.anchors;
    // For a close-up, spread the handles over the hexes in frame.
    final hexes = [
      for (final c in focus)
        if (widget.title.map.at(c) != null) widget.title.map.at(c)!,
    ];
    final subMap = MapLayout(hexes);
    return subMap.anchors;
  }

  Future<void> _detect() async {
    final initial = widget.initial;
    try {
      final fit = initial == null
          ? await widget.pipeline.fitBoard(widget.title.map, widget.photo)
          : await widget.pipeline
              .snap(widget.title.map, widget.photo, initial);
      if (!mounted) return;
      final usable = fit != null && (fit.isConvincing || _onPhoto(fit.boardToImage));
      setState(() {
        _busy = false;
        _fit = usable ? fit : null;
        _boardToImage = usable ? fit.boardToImage : initial ?? _overPhoto;
        _adjusting = !usable || !fit.isConvincing;
        _status = usable || fit == null
            ? _describe(fit)
            : 'The grid found in this photo doesn\'t fit it, so the map has '
                'been laid over the photo to start from. Drag the marked '
                'hexes onto their places, then snap.';
        _syncHandles();
      });
    } catch (e, stack) {
      debugPrint('Grid detection failed: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _boardToImage = initial ?? _overPhoto;
        _adjusting = true;
        _status = 'Something went wrong reading that photo. Place the marked '
            'hexes by hand, or go back and take another.';
        _syncHandles();
      });
    }
  }

  /// The hexes this photo is meant to show.
  Iterable<HexCoord> get _hexes => widget.focus ?? widget.title.map.coords;

  /// The map laid over the photo; see [placeOverPhoto].
  Homography get _overPhoto => placeOverPhoto(
      Size(widget.photo.width.toDouble(), widget.photo.height.toDouble()),
      _hexes);

  /// Whether [h] puts the map somewhere the user can work with it: over the
  /// photo, and not so large that the handles are out of reach.
  bool _onPhoto(Homography h) {
    final width = widget.photo.width.toDouble();
    final height = widget.photo.height.toDouble();
    var bounds = Rect.zero;
    var first = true;
    for (final c in _hexes) {
      final p = h.apply(c.boardCenter);
      if (!p.dx.isFinite || !p.dy.isFinite) return false;
      bounds = first ? Rect.fromLTWH(p.dx, p.dy, 0, 0) : bounds.expandToInclude(
          Rect.fromLTWH(p.dx, p.dy, 0, 0));
      first = false;
    }
    return bounds.width <= 3 * width &&
        bounds.height <= 3 * height &&
        bounds.overlaps(Rect.fromLTWH(0, 0, width, height));
  }

  String _describe(GridFit? fit) {
    if (fit == null) {
      return 'No hex grid found in this photo. Drag the four marked hexes '
          'onto their places on the board, then snap.';
    }
    final hexes = '${fit.visible.length} '
        '${fit.visible.length == 1 ? 'hex' : 'hexes'} in frame';
    if (fit.isConvincing) {
      return 'Found the board: $hexes. Check the outlines sit on the printed '
          'hexes before reading it.';
    }
    return 'Not sure about this one ($hexes). Check the outlines, and drag '
        'the marked hexes onto their places if they are off.';
  }

  Future<void> _snap() async {
    final current = _boardToImage;
    if (current == null) return;
    setState(() {
      _busy = true;
      _status = 'Lining the grid up with the printed hexes...';
    });
    try {
      final fit =
          await widget.pipeline.snap(widget.title.map, widget.photo, current);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fit = fit;
        _boardToImage = fit.boardToImage;
        _status = _describe(fit);
        _syncHandles();
      });
    } catch (e, stack) {
      debugPrint('Snap failed: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Could not line that up. Try moving the marked hexes closer '
            'to where they sit on the board.';
      });
    }
  }

  void _syncHandles() {
    final h = _boardToImage;
    if (h == null) return;
    _handles = [for (final a in _anchors) h.apply(a.coord.boardCenter)];
  }

  /// Recomputes the placement from the four dragged handles.
  void _handlesMoved() {
    final fitted = Homography.fit(
      [for (final a in _anchors) a.coord.boardCenter],
      _handles,
    );
    if (fitted != null) _boardToImage = fitted;
  }

  Offset _toDisplay(Offset image) =>
      Offset(image.dx * _scale, image.dy * _scale) + _displayOrigin;

  Offset _toImage(Offset display) => (display - _displayOrigin) / _scale;

  double get _scale => _displaySize.width <= 0
      ? 1
      : _displaySize.width / widget.photo.width;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Align the board' : 'Align close-up'),
        actions: [
          IconButton(
            tooltip: 'Adjust by hand',
            onPressed: _busy ? null : () => setState(() => _adjusting = !_adjusting),
            icon: Icon(_adjusting ? Icons.pan_tool : Icons.pan_tool_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              final photo = widget.photo;
              final scale = (constraints.maxWidth / photo.width)
                  .clamp(0.0, constraints.maxHeight / photo.height);
              _displaySize = Size(photo.width * scale, photo.height * scale);
              _displayOrigin = Offset(
                (constraints.maxWidth - _displaySize.width) / 2,
                (constraints.maxHeight - _displaySize.height) / 2,
              );
              return Listener(
                onPointerSignal: _pointerSignal,
                child: GestureDetector(
                  key: alignCanvasKey,
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: !_adjusting ? null : _startGesture,
                  onScaleUpdate: !_adjusting ? null : _updateGesture,
                  onScaleEnd: !_adjusting ? null : (_) => setState(() {
                        _draggingAnchor = null;
                        _lastFocal = null;
                      }),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: Image.memory(
                          widget.previewBytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _AlignPainter(
                            title: widget.title,
                            boardToImage: _boardToImage,
                            fit: _fit,
                            toDisplay: _toDisplay,
                            anchors: _adjusting ? _anchors : const [],
                            handles: _adjusting ? _handles : const [],
                            focus: widget.focus,
                          ),
                        ),
                      ),
                      if (_busy)
                        Container(
                          color: Colors.black54,
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(_status,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }),
          ),
          _controls(),
        ],
      ),
    );
  }

  void _startGesture(ScaleStartDetails details) {
    _lastFocal = details.localFocalPoint;
    _lastScale = 1;
    _lastRotation = 0;
    int? index;
    if (details.pointerCount <= 1) {
      final point = details.localFocalPoint;
      double best = double.infinity;
      for (int i = 0; i < _handles.length; i++) {
        final d = (_toDisplay(_handles[i]) - point).distance;
        if (d < best) {
          best = d;
          index = i;
        }
      }
      if (best > 44) index = null;
    }
    setState(() => _draggingAnchor = index);
  }

  void _updateGesture(ScaleUpdateDetails details) {
    setState(() {
      final index = _draggingAnchor;
      if (index != null && details.pointerCount <= 1) {
        _handles[index] = _toImage(details.localFocalPoint);
      } else {
        // Anywhere else moves the whole grid; two fingers (or a trackpad
        // pinch) also size and turn it, about the point between them.
        _draggingAnchor = null;
        final focal = _toImage(details.localFocalPoint);
        _transformGrid(
          about: focal,
          shift: focal - _toImage(_lastFocal ?? details.localFocalPoint),
          scale: details.scale / _lastScale,
          radians: details.rotation - _lastRotation,
        );
      }
      _lastFocal = details.localFocalPoint;
      _lastScale = details.scale;
      _lastRotation = details.rotation;
      _handlesMoved();
    });
  }

  /// A mouse wheel sizes the grid about the pointer.
  void _pointerSignal(PointerSignalEvent event) {
    if (!_adjusting || _busy || event is! PointerScrollEvent) return;
    setState(() {
      _transformGrid(
        about: _toImage(event.localPosition),
        scale: math.exp(-event.scrollDelta.dy / 400),
      );
      _handlesMoved();
    });
  }

  /// Moves every handle by [shift], then scales by [scale] and turns by
  /// [radians] about [about] (photo pixels): the grid moves as one piece.
  void _transformGrid({
    required Offset about,
    Offset shift = Offset.zero,
    double scale = 1,
    double radians = 0,
  }) {
    final c = math.cos(radians) * scale, s = math.sin(radians) * scale;
    for (int i = 0; i < _handles.length; i++) {
      final v = _handles[i] + shift - about;
      _handles[i] = about + Offset(c * v.dx - s * v.dy, s * v.dx + c * v.dy);
    }
  }

  /// The buttons' version of a pinch or a twist, about the middle of the
  /// photo.
  void _stepGrid({double scale = 1, double radians = 0}) {
    setState(() {
      _transformGrid(
        about: Offset(widget.photo.width / 2, widget.photo.height / 2),
        scale: scale,
        radians: radians,
      );
      _handlesMoved();
    });
  }

  void _resetToPhoto() {
    setState(() {
      _boardToImage = _overPhoto;
      _syncHandles();
    });
  }

  Widget _controls() {
    final fit = _fit;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _status,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_adjusting)
              Text(
                'Drag each labelled circle onto that hex on the board; drag '
                'anywhere else to move the whole grid, and pinch, scroll or '
                'use the buttons to size and turn it.',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 4),
            if (_adjusting)
              Row(
                children: [
                  IconButton(
                    tooltip: 'Smaller',
                    onPressed: _busy ? null : () => _stepGrid(scale: 1 / 1.1),
                    icon: const Icon(Icons.zoom_out),
                  ),
                  IconButton(
                    tooltip: 'Bigger',
                    onPressed: _busy ? null : () => _stepGrid(scale: 1.1),
                    icon: const Icon(Icons.zoom_in),
                  ),
                  IconButton(
                    tooltip: 'Turn a quarter',
                    onPressed:
                        _busy ? null : () => _stepGrid(radians: math.pi / 2),
                    icon: const Icon(Icons.rotate_90_degrees_cw),
                  ),
                  IconButton(
                    tooltip: 'Fit to the photo',
                    onPressed: _busy ? null : _resetToPhoto,
                    icon: const Icon(Icons.fit_screen),
                  ),
                ],
              ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy || _boardToImage == null ? null : _snap,
                  icon: const Icon(Icons.grid_goldenratio),
                  label: const Text('Snap to lines'),
                ),
                const Spacer(),
                if (fit != null)
                  Text('fit ${(fit.coverage * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _busy || _boardToImage == null
                      ? null
                      : () => Navigator.of(context).pop(_boardToImage),
                  child: const Text('Read board'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AlignPainter extends CustomPainter {
  final GameTitle title;
  final Homography? boardToImage;
  final GridFit? fit;
  final Offset Function(Offset) toDisplay;
  final List<MapHex> anchors;
  final List<Offset> handles;
  final Set<HexCoord>? focus;

  const _AlignPainter({
    required this.title,
    required this.boardToImage,
    required this.fit,
    required this.toDisplay,
    required this.anchors,
    required this.handles,
    this.focus,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final h = boardToImage;
    if (h == null) return;
    final hexes = focus ?? title.map.coords.toSet();
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final coord in hexes) {
      final centre = coord.boardCenter;
      final path = Path();
      for (int i = 0; i < 6; i++) {
        final v = toDisplay(h.apply(HexGeometry.vertex(centre, 1, i)));
        i == 0 ? path.moveTo(v.dx, v.dy) : path.lineTo(v.dx, v.dy);
      }
      path.close();
      final coverage = fit?.hexCoverage[coord];
      outline.color = coverage == null
          ? Colors.lightBlueAccent.withValues(alpha: 0.5)
          : Color.lerp(Colors.redAccent, Colors.lightGreenAccent,
              coverage.clamp(0.0, 1.0))!;
      canvas.drawPath(path, outline);
    }

    for (int i = 0; i < anchors.length && i < handles.length; i++) {
      final p = toDisplay(handles[i]);
      canvas
        ..drawCircle(p, 16, Paint()..color = Colors.black54)
        ..drawCircle(
          p,
          16,
          Paint()
            ..color = Colors.amberAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      final label = TextPainter(
        text: TextSpan(
          text: anchors[i].id,
          style: const TextStyle(
            color: Colors.amberAccent,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, p + Offset(-label.width / 2, 18));
    }
  }

  @override
  bool shouldRepaint(covariant _AlignPainter oldDelegate) => true;
}
