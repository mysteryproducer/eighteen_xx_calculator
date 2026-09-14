import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/board.dart';
import '../models/board_graph.dart';
import '../models/image_layout.dart';
import '../models/tile_seed_data.dart';
import '../processing/tile_classifier.dart';
import 'board_review.dart';

/// Step one: line the hex grid up with the photographed board, then read each
/// hex. Alignment is manual (drag to move the grid, sliders for size and
/// rotation) -- automatic hex detection is a later exercise.
class ImageProcessing extends StatefulWidget {
  final String imagePath;
  final Map<String, dynamic> game;

  const ImageProcessing({super.key, required this.imagePath, required this.game});

  @override
  State<ImageProcessing> createState() => _ImageProcessingState();
}

class _ImageProcessingState extends State<ImageProcessing> {
  img.Image? _original;
  Uint8List? _preview;
  bool _busy = true;
  String _status = 'Loading photo...';

  final TileClassifier _classifier = TileClassifier();

  /// Grid calibration in display coordinates while the user is adjusting it.
  Board _board = const Board(
    rows: 5,
    cols: 5,
    hexSize: 60,
    origin: Offset(120, 120),
  );

  ImageLayout _layout = const ImageLayout(imageSize: Size.zero, containerSize: Size.zero);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (!mounted) return;
    if (decoded == null) {
      setState(() {
        _busy = false;
        _status = 'Could not read that image.';
      });
      return;
    }
    setState(() {
      _original = decoded;
      _preview = img.encodeJpg(decoded, quality: 85);
      _busy = false;
      _status = '';
    });
    // Reference tiles take a moment to render; start now so "Scan board" is
    // responsive later.
    unawaited(_classifier.loadTemplates());
  }

  Future<void> _scanBoard() async {
    final original = _original;
    if (original == null) return;
    setState(() {
      _busy = true;
      _status = 'Rendering reference tiles...';
    });
    await _classifier.loadTemplates();
    if (!mounted) return;
    setState(() => _status = 'Reading hexes...');

    final imageBoard = _layout.boardToImage(_board);
    final placed = <HexCoord, PlacedTile>{};
    final matches = <HexCoord, TileMatch>{};

    // A patch a little wider than the hex so the whole tile is in frame.
    final patchSize = (imageBoard.hexSize * 1.8).round().clamp(8, original.width);

    for (final coord in imageBoard.coords) {
      final center = imageBoard.centerOf(coord);
      final left = (center.dx - patchSize / 2).round();
      final top = (center.dy - patchSize / 2).round();
      if (left < 0 ||
          top < 0 ||
          left + patchSize > original.width ||
          top + patchSize > original.height) {
        continue; // hex falls outside the photo
      }
      final patch = img.copyCrop(
        original,
        x: left,
        y: top,
        width: patchSize,
        height: patchSize,
      );
      final match = _classifier.matchTile(patch);
      if (match == null) continue;
      matches[coord] = match;
      placed[coord] = PlacedTile(match.tileId, rotation: match.rotation);
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
    });

    final recognized =
        placed.values.where((p) => p.tileId != TileSeedData.blankTileId).length;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BoardReview(
        imagePath: widget.imagePath,
        image: original,
        previewBytes: _preview!,
        calibration: imageBoard,
        placedTiles: placed,
        matches: matches,
        gameName: widget.game['name'] as String? ?? '',
        recognizedCount: recognized,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Align grid - ${widget.game['name'] ?? ''}')),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              final original = _original;
              if (original == null) {
                return Center(
                  child: _busy
                      ? const CircularProgressIndicator()
                      : Text(_status),
                );
              }
              _layout = ImageLayout(
                imageSize:
                    Size(original.width.toDouble(), original.height.toDouble()),
                containerSize: Size(constraints.maxWidth, constraints.maxHeight),
              );
              return GestureDetector(
                // Neither the photo nor the overlay takes hits, so the
                // detector has to claim the whole area to be draggable.
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) => setState(() {
                  _board = _board.copyWith(origin: _board.origin + details.delta);
                }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: Image.memory(
                        _preview!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _GridPainter(board: _board),
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
                            Text(
                              _status,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
          _controls(),
        ],
      ),
    );
  }

  Widget _controls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Drag the photo to move the grid, then match it to the board.',
              style: TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
            Row(
              children: [
                Expanded(
                  child: _slider('Size', _board.hexSize, 20, 200,
                      (v) => _board = _board.copyWith(hexSize: v)),
                ),
                Expanded(
                  child: _slider('Rotation', _board.rotation, -30, 30,
                      (v) => _board = _board.copyWith(rotation: v)),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: _slider('Rows', _board.rows.toDouble(), 1, 20,
                      (v) => _board = _board.copyWith(rows: v.round()),
                      divisions: 19),
                ),
                Expanded(
                  child: _slider('Cols', _board.cols.toDouble(), 1, 20,
                      (v) => _board = _board.copyWith(cols: v.round()),
                      divisions: 19),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.icon(
                onPressed: _busy || _original == null ? null : _scanBoard,
                icon: const Icon(Icons.grid_on),
                label: const Text('Scan board'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) apply, {
    int? divisions,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ${divisions != null ? value.round() : value.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 12)),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) => setState(() => apply(v)),
        ),
      ],
    );
  }
}

/// Simple alignment overlay: hex outlines and centers, no tile labels.
class _GridPainter extends CustomPainter {
  final Board board;

  const _GridPainter({required this.board});

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = Colors.red.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final centerDot = Paint()..color = Colors.blue.withValues(alpha: 0.85);

    for (final coord in board.coords) {
      final center = board.centerOf(coord);
      canvas.drawCircle(center, 2.5, centerDot);
      final path = Path();
      for (int i = 0; i < 6; i++) {
        final v = HexGeometry.vertex(center, board.hexSize, i);
        if (i == 0) {
          path.moveTo(v.dx, v.dy);
        } else {
          path.lineTo(v.dx, v.dy);
        }
      }
      path.close();
      canvas.drawPath(
        _rotatedPath(path, center, board.rotation * math.pi / 180),
        outline,
      );
    }
  }

  Path _rotatedPath(Path path, Offset center, double radians) {
    if (radians == 0) return path;
    final matrix = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..rotateZ(radians)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    return path.transform(matrix.storage);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.board != board;
}

