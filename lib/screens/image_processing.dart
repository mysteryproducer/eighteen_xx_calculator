import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

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
  }

  void _onConfirmGrid() {
    // Placeholder: later we'll convert the grid into hex coordinates and run tile classification.
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Grid confirmed (prototype).')));
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
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _original != null
                            ? Image.memory(img.encodeJpg(_original!))
                            : const SizedBox.shrink(),
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
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
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

  _GridPainter({required this.origin, required this.hexSize, required this.rotation, required this.rows, required this.cols});

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
