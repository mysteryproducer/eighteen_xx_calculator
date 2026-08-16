import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../processing/tile_classifier.dart';
import '../models/board.dart';

class ImageProcessing extends StatefulWidget {
  final String imagePath;
  final Map<String, dynamic> game;

  const ImageProcessing({Key? key, required this.imagePath, required this.game}) : super(key: key);

  @override
  State<ImageProcessing> createState() => _ImageProcessingState();
}

class _ImageProcessingState extends State<ImageProcessing> {
  img.Image? _original;
  img.Image? _edgeImage;
  bool _processing = true;
  final TileClassifier _classifier = TileClassifier();
  List<ClassifiedHex> _classified = [];

  // displayed image metrics (within the stack area)
  double? _displayedImageWidth;
  double? _displayedImageHeight;
  Offset _imageOffset = Offset.zero;

  // Grid parameters
  double _hexSize = 60.0;
  double _rotation = 0.0; // degrees
  Offset _origin = const Offset(100, 100);
  int _rows = 8;
  int _cols = 8;

  @override
  void initState() {
    super.initState();
    _loadAndProcess();
  }

  void _loadAndProcess() async {
    setState(() {
      _processing = true;
    });
    final bytes = await File(widget.imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;
    final grayscale = img.grayscale(decoded);
    final edges = img.sobel(grayscale);
    setState(() {
      _original = decoded;
      _edgeImage = edges;
      _processing = false;
    });
    // start loading tile templates in background
    _classifier.loadTemplates();
  }

  void _onConfirmGrid() async {
    if (_original == null) return;
    setState(() {
      _processing = true;
    });
    await _classifier.loadTemplates();

    final centers = <ClassifiedHex>[];
    final w = _hexSize * 2;
    final h = (1.7320508075688772) * _hexSize;
    final horiz = w * 3 / 4;
    final vert = h;
    final rot = _rotation * (3.141592653589793 / 180.0);

    for (int r = 0; r < _rows; r++) {
      for (int c = 0; c < _cols; c++) {
        final dx = _origin.dx + (c * horiz) + (r.isOdd ? horiz / 2 : 0);
        final dy = _origin.dy + (r * (vert * 0.5));
        final s = math.sin(rot);
        final co = math.cos(rot);
        final x = dx - _origin.dx;
        final y = dy - _origin.dy;
        final rx = x * co - y * s;
        final ry = x * s + y * co;
        final rp = Offset(rx + _origin.dx, ry + _origin.dy);

        // map display coords -> original image pixel coords
        final displayW = _displayedImageWidth ?? 1.0;
        final displayH = _displayedImageHeight ?? 1.0;
        final offsetX = _imageOffset.dx;
        final offsetY = _imageOffset.dy;
        final relX = rp.dx - offsetX;
        final relY = rp.dy - offsetY;
        final origX = (relX * (_original!.width / displayW)).round();
        final origY = (relY * (_original!.height / displayH)).round();

        final patchPxSize = (_hexSize * 1.6 * (_original!.width / displayW)).round();
        final left = (origX - patchPxSize ~/ 2).clamp(0, _original!.width - 1);
        final top = (origY - patchPxSize ~/ 2).clamp(0, _original!.height - 1);
        final width = (patchPxSize).clamp(4, _original!.width - left);
        final height = (patchPxSize).clamp(4, _original!.height - top);

        img.Image patch;
        try {
          patch = img.copyCrop(_original!, x: left, y: top, width: width, height: height);
        } catch (e) {
          patch = img.copyResize(_original!, width: 32, height: 32);
        }

        final id = _classifier.matchTile(patch);
        centers.add(ClassifiedHex(coord: HexCoord(r, c), center: rp, tileId: id));
      }
    }

    setState(() {
      _classified = centers;
      _processing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Classification complete (prototype).')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Process Image - ${widget.game['name'] ?? ''}')),
      body: _processing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(builder: (context, constraints) {
                    final containerW = constraints.maxWidth;
                    final containerH = constraints.maxHeight;
                    double displayW = containerW;
                    double displayH = containerH;
                    if (_original != null) {
                      final imgW = _original!.width.toDouble();
                      final imgH = _original!.height.toDouble();
                      final containerRatio = containerW / containerH;
                      final imgRatio = imgW / imgH;
                      if (imgRatio > containerRatio) {
                        displayW = containerW;
                        displayH = imgH * (containerW / imgW);
                      } else {
                        displayH = containerH;
                        displayW = imgW * (containerH / imgH);
                      }
                      _displayedImageWidth = displayW;
                      _displayedImageHeight = displayH;
                      _imageOffset = Offset((containerW - displayW) / 2.0, (containerH - displayH) / 2.0);
                    }

                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Center(
                            child: _original != null
                                ? SizedBox(
                                    width: displayW,
                                    height: displayH,
                                    child: Image.memory(img.encodeJpg(_original!), fit: BoxFit.contain),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _GridPainter(
                                origin: _origin,
                                hexSize: _hexSize,
                                rotation: _rotation,
                                rows: _rows,
                                cols: _cols,
                                labels: _classified,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ),
                SizedBox(
                  height: 140,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Column(
                              children: [
                                const Text('Hex size'),
                                Slider(
                                  value: _hexSize,
                                  min: 20,
                                  max: 150,
                                  onChanged: (v) => setState(() => _hexSize = v),
                                ),
                              ],
                            ),
                            Column(
                              children: [
                                const Text('Rotation'),
                                Slider(
                                  value: _rotation,
                                  min: -180,
                                  max: 180,
                                  onChanged: (v) => setState(() => _rotation = v),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Column(
                              children: [
                                const Text('Rows'),
                                Slider(
                                  value: _rows.toDouble(),
                                  min: 1,
                                  max: 40,
                                  divisions: 39,
                                  onChanged: (v) => setState(() => _rows = v.toInt()),
                                ),
                              ],
                            ),
                            Column(
                              children: [
                                const Text('Cols'),
                                Slider(
                                  value: _cols.toDouble(),
                                  min: 1,
                                  max: 40,
                                  divisions: 39,
                                  onChanged: (v) => setState(() => _cols = v.toInt()),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              ElevatedButton(
                                onPressed: _onConfirmGrid,
                                child: const Text('Confirm Grid'),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  // Show edges in a dialog
                                  showDialog(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('Edge image'),
                                      content: SizedBox(
                                        width: 300,
                                        child: _edgeImage != null
                                            ? Image.memory(img.encodePng(_edgeImage!))
                                            : const SizedBox.shrink(),
                                      ),
                                    ),
                                  );
                                },
                                child: const Text('Show Edges'),
                              ),
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
                )
              ],
            ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Offset origin;
  final double hexSize;
  final double rotation; // degrees
  final int rows;
  final int cols;
  final List<ClassifiedHex>? labels;

  _GridPainter({required this.origin, required this.hexSize, required this.rotation, required this.rows, required this.cols, this.labels});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final centerPaint = Paint()..color = Colors.blue.withOpacity(0.8);

    final rot = rotation * (math.pi / 180.0);

    // hexagon geometry (pointy-top)
    final w = hexSize * 2;
    final h = math.sqrt(3) * hexSize;
    final horiz = w * 3 / 4;
    final vert = h;

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final dx = origin.dx + (c * horiz) + (r.isOdd ? horiz / 2 : 0);
        final dy = origin.dy + (r * (vert * 0.5));
        final p = Offset(dx, dy);
        final rp = _rot(p, origin, rot);
        // draw hex center
        canvas.drawCircle(rp, 3.0, centerPaint);
        // draw hex outline
        final path = Path();
        for (int i = 0; i < 6; i++) {
          final angle = math.pi / 180 * (60 * i - 30);
          final x = rp.dx + hexSize * math.cos(angle);
          final y = rp.dy + hexSize * math.sin(angle);
          if (i == 0) path.moveTo(x, y);
          else path.lineTo(x, y);
        }
        path.close();
        canvas.drawPath(path, paint);
        // draw label if available
        if (labels != null) {
          final threshold = hexSize * 0.6;
          ClassifiedHex? found;
          for (final l in labels!) {
            if ((l.center - rp).distance <= threshold) {
              found = l;
              break;
            }
          }
          if (found != null) {
            final textPainter = TextPainter(
              text: TextSpan(text: found.tileId, style: const TextStyle(color: Colors.yellow, fontSize: 12, fontWeight: FontWeight.bold)),
              textDirection: TextDirection.ltr,
            );
            textPainter.layout();
            textPainter.paint(canvas, rp + const Offset(6, -6));
          }
        }
      }
    }
  }

  Offset _rot(Offset p, Offset center, double a) {
    final s = math.sin(a);
    final c = math.cos(a);
    final x = p.dx - center.dx;
    final y = p.dy - center.dy;
    final rx = x * c - y * s;
    final ry = x * s + y * c;
    return Offset(rx + center.dx, ry + center.dy);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
    return oldDelegate.hexSize != hexSize || oldDelegate.rotation != rotation || oldDelegate.rows != rows || oldDelegate.cols != cols || oldDelegate.origin != origin;
  }
}
