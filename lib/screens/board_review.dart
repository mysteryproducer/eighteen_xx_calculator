import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/board.dart';
import '../models/board_graph.dart';
import '../models/company.dart';
import '../models/image_layout.dart';
import '../models/tile_definition.dart';
import '../models/tile_seed_data.dart';
import '../processing/revenue_ocr.dart';
import '../processing/route_finder.dart';
import '../processing/tile_classifier.dart';
import '../processing/tile_renderer.dart';
import '../processing/token_detector.dart';

/// Step two: check what the scan read, fix what it got wrong, and run routes.
///
/// Recognition is treated as a first draft throughout -- every tile, revenue
/// number, and token the machine picked can be corrected by tapping it, which
/// is what makes the whole thing usable while the vision side is still rough.
/// The tappable photo area, so tests (and anything driving the screen) can
/// find the canvas without depending on the widget tree's shape.
const Key boardCanvasKey = ValueKey('board-canvas');

class BoardReview extends StatefulWidget {
  final String imagePath;
  final img.Image image;
  final Uint8List previewBytes;
  final Board calibration; // in source-image pixels
  final Map<HexCoord, PlacedTile> placedTiles;
  final Map<HexCoord, TileMatch> matches;
  final String gameName;
  final int recognizedCount;

  const BoardReview({
    super.key,
    required this.imagePath,
    required this.image,
    required this.previewBytes,
    required this.calibration,
    required this.placedTiles,
    required this.matches,
    required this.gameName,
    required this.recognizedCount,
  });

  @override
  State<BoardReview> createState() => _BoardReviewState();
}

class _BoardReviewState extends State<BoardReview> {
  late Map<HexCoord, PlacedTile> _placed;
  late BoardGraph _graph;

  final Map<String, int> _revenueOverrides = {};
  final Map<String, String?> _tokens = {};
  final Map<String, RevenueReading> _readings = {};
  final RevenueOcr _ocr = RevenueOcr();
  final TokenDetector _tokenDetector = const TokenDetector();

  ImageLayout _layout =
      const ImageLayout(imageSize: Size.zero, containerSize: Size.zero);

  Company? _company;
  int _maxStops = 3;
  RouteResult? _route;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _placed = Map.of(widget.placedTiles);
    _graph = _buildGraph();
  }

  @override
  void dispose() {
    _ocr.dispose();
    super.dispose();
  }

  BoardGraph _buildGraph() {
    final graph = BoardGraph.build(_placed, TileSeedData.all);
    for (final station in graph.stations) {
      final override = _revenueOverrides[station.id];
      if (override != null) station.revenue = override;
      station.companyId = _tokens[station.id];
    }
    return graph;
  }

  void _refresh() {
    setState(() {
      _graph = _buildGraph();
      _route = null;
    });
  }

  TileDefinition? _definitionAt(HexCoord coord) {
    final placed = _placed[coord];
    if (placed == null) return null;
    final def = TileSeedData.all[placed.tileId];
    return def?.rotated(placed.rotation);
  }

  /// Where a station sits in source-image pixels.
  Offset _stationPosition(StationNode station) {
    final center = widget.calibration.centerOf(station.hex);
    final def = _definitionAt(station.hex);
    if (def == null) return center;
    return TileRenderer.stationPosition(
      def,
      station.stationIndex,
      center,
      widget.calibration.hexSize,
    );
  }

  // --- Recognition passes -------------------------------------------------

  Future<void> _readRevenues() async {
    if (_graph.stations.isEmpty) {
      _snack('No cities or towns recognized yet.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Reading revenue numbers...';
    });

    // Revenue is printed beside the circle, so the crop takes in a good part
    // of the hex around the station rather than just the circle itself.
    final crop = (widget.calibration.hexSize * 1.1).round();
    var read = 0;
    for (final station in _graph.stations) {
      final pos = _stationPosition(station);
      final region = math.Rectangle<int>(
        (pos.dx - crop / 2).round(),
        (pos.dy - crop / 2).round(),
        crop,
        crop,
      );
      try {
        final reading = await _ocr.readRegion(widget.image, region);
        _readings[station.id] = reading;
        if (reading.value != null) {
          _revenueOverrides[station.id] = reading.value!;
          read++;
        }
      } catch (e) {
        debugPrint('OCR failed for ${station.id}: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _graph = _buildGraph();
      _busy = false;
      _status = '';
      _route = null;
    });
    _snack('Read $read of ${_graph.stations.length} revenue numbers. '
        'Tap a circle to correct one.');
  }

  Future<void> _detectTokens() async {
    final cities =
        _graph.stations.where((s) => s.kind == StationKind.city).toList();
    if (cities.isEmpty) {
      _snack('No cities recognized yet.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Looking for station tokens...';
    });

    var found = 0;
    final radius = math.max(3, (widget.calibration.hexSize * 0.16).round());
    for (final station in cities) {
      final pos = _stationPosition(station);
      final detection = _tokenDetector.detect(
        widget.image,
        pos.dx.round(),
        pos.dy.round(),
        radius,
      );
      // Only take the suggestion when it's clearly a colour, not an empty
      // white slot; everything else is left for the user to tap in.
      if (!detection.looksEmpty &&
          detection.company != null &&
          detection.confidence >= 0.15) {
        _tokens[station.id] = detection.company!.id;
        found++;
      }
    }

    if (!mounted) return;
    setState(() {
      _graph = _buildGraph();
      _busy = false;
      _status = '';
      _route = null;
    });
    _snack(found == 0
        ? 'No tokens recognized. Tap a city to set one by hand.'
        : 'Found $found token${found == 1 ? '' : 's'}. Check them by tapping.');
  }

  // --- Routing ------------------------------------------------------------

  void _findRoute() {
    if (_graph.stations.isEmpty) {
      _snack('No revenue centres to run through yet.');
      return;
    }
    final company = _company;
    final homes = company == null
        ? <StationNode>[]
        : _graph.stations.where((s) => s.companyId == company.id).toList();

    RouteResult result;
    if (homes.isEmpty) {
      result = RouteFinder.bestRouteAnywhere(_graph, _maxStops);
    } else {
      result = const RouteResult(stops: [], track: [], revenue: 0);
      for (final home in homes) {
        final candidate = RouteFinder.bestRouteThrough(_graph, home, _maxStops);
        if (candidate.revenue > result.revenue) result = candidate;
      }
    }

    setState(() => _route = result);
    if (result.isEmpty) {
      _snack('No route found. Check the tiles are connected.');
    } else if (homes.isEmpty && company != null) {
      _snack('${company.name} has no token set, so this is the best route '
          'anywhere on the board.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Tap handling -------------------------------------------------------

  void _handleTap(Offset localPosition) {
    final imagePoint = _layout.displayToImage(localPosition);

    // Stations win over hexes: they're the smaller target and the more
    // frequent thing to edit.
    StationNode? nearestStation;
    double nearestDistance = double.infinity;
    for (final station in _graph.stations) {
      final d = (_stationPosition(station) - imagePoint).distance;
      if (d < nearestDistance) {
        nearestDistance = d;
        nearestStation = station;
      }
    }
    if (nearestStation != null &&
        nearestDistance <= widget.calibration.hexSize * 0.45) {
      _editStation(nearestStation);
      return;
    }

    final hex = widget.calibration.hexAt(imagePoint);
    if (hex != null) _editTile(hex);
  }

  Future<void> _editTile(HexCoord coord) async {
    final placed = _placed[coord];
    var tileId = placed?.tileId ?? TileSeedData.blankTileId;
    var rotation = placed?.rotation ?? 0;
    final match = widget.matches[coord];
    final ids = TileSeedData.all.keys.toList()..sort(_compareTileIds);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final def = TileSeedData.all[tileId]?.rotated(rotation);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hex $coord', style: Theme.of(context).textTheme.titleMedium),
                if (match != null)
                  Text(
                    'Scanned as ${match.tileId} turned ${match.rotation}, '
                    '${(match.confidence * 100).round()}% clear of the next best.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 88,
                      height: 88,
                      child: def == null
                          ? const SizedBox.shrink()
                          : CustomPaint(painter: TilePainter(def)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButton<String>(
                            value: tileId,
                            isExpanded: true,
                            items: [
                              for (final id in ids)
                                DropdownMenuItem(
                                  value: id,
                                  child: Text(id == TileSeedData.blankTileId
                                      ? 'Empty hex'
                                      : 'Tile $id'),
                                ),
                            ],
                            onChanged: (v) =>
                                setSheetState(() => tileId = v ?? tileId),
                          ),
                          Row(
                            children: [
                              const Text('Rotation'),
                              IconButton(
                                icon: const Icon(Icons.rotate_left),
                                onPressed: () => setSheetState(
                                    () => rotation = (rotation + 5) % 6),
                              ),
                              Text('$rotation'),
                              IconButton(
                                icon: const Icon(Icons.rotate_right),
                                onPressed: () => setSheetState(
                                    () => rotation = (rotation + 1) % 6),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () {
                      _placed[coord] = PlacedTile(tileId, rotation: rotation);
                      Navigator.of(context).pop();
                      _refresh();
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _editStation(StationNode station) async {
    final controller =
        TextEditingController(text: station.revenue.toString());
    var companyId = station.companyId;
    final reading = _readings[station.id];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                station.kind == StationKind.city
                    ? 'City on hex ${station.hex}'
                    : 'Town on hex ${station.hex}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (reading != null)
                Text(
                  reading.recognized
                      ? 'Read as ${reading.value} from the photo.'
                      : 'Nothing readable here ("${reading.rawText}").',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Revenue',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Station token'),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('None'),
                    selected: companyId == null,
                    onSelected: (_) => setSheetState(() => companyId = null),
                  ),
                  for (final company in Company.defaults)
                    ChoiceChip(
                      avatar: CircleAvatar(backgroundColor: company.color),
                      label: Text(company.name),
                      selected: companyId == company.id,
                      onSelected: (_) =>
                          setSheetState(() => companyId = company.id),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    final value = int.tryParse(controller.text.trim());
                    if (value != null) _revenueOverrides[station.id] = value;
                    _tokens[station.id] = companyId;
                    Navigator.of(context).pop();
                    _refresh();
                  },
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static int _compareTileIds(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return 1; // keep 'blank' first
    if (nb != null) return -1;
    return a.compareTo(b);
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tileCount = _placed.values
        .where((p) => p.tileId != TileSeedData.blankTileId)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review board'),
        actions: [
          IconButton(
            tooltip: 'Read revenue numbers',
            onPressed: _busy ? null : _readRevenues,
            icon: const Icon(Icons.numbers),
          ),
          IconButton(
            tooltip: 'Detect station tokens',
            onPressed: _busy ? null : _detectTokens,
            icon: const Icon(Icons.circle_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              _layout = ImageLayout(
                imageSize: Size(
                  widget.image.width.toDouble(),
                  widget.image.height.toDouble(),
                ),
                containerSize: Size(constraints.maxWidth, constraints.maxHeight),
              );
              return GestureDetector(
                key: boardCanvasKey,
                // The photo and the overlay don't take hits themselves, so the
                // detector has to claim the whole area.
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _handleTap(details.localPosition),
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
                        painter: _BoardOverlayPainter(
                          layout: _layout,
                          calibration: widget.calibration,
                          placed: _placed,
                          graph: _graph,
                          stationPosition: _stationPosition,
                          route: _route,
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
                                style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
          _routePanel(tileCount),
        ],
      ),
    );
  }

  Widget _routePanel(int tileCount) {
    final route = _route;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$tileCount tiles, ${_graph.stations.length} revenue centres. '
              'Tap a hex or a circle to correct it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String?>(
                    value: _company?.id,
                    isExpanded: true,
                    hint: const Text('Company'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Any company'),
                      ),
                      for (final company in Company.defaults)
                        DropdownMenuItem<String?>(
                          value: company.id,
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 8,
                                backgroundColor: company.color,
                              ),
                              const SizedBox(width: 8),
                              Text(company.name),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _company = Company.byId(v);
                      _route = null;
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                const Text('Stops'),
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: _maxStops <= 1
                      ? null
                      : () => setState(() {
                            _maxStops--;
                            _route = null;
                          }),
                ),
                Text('$_maxStops'),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _maxStops >= 12
                      ? null
                      : () => setState(() {
                            _maxStops++;
                            _route = null;
                          }),
                ),
                FilledButton(
                  onPressed: _busy ? null : _findRoute,
                  child: const Text('Find route'),
                ),
              ],
            ),
            if (route != null && !route.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Best route pays ${route.revenue}: '
                  '${route.stops.map((s) => '${s.hex} (${s.revenue})').join(' - ')}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Draws recognized tiles, revenue centres, and the computed route over the
/// photo.
class _BoardOverlayPainter extends CustomPainter {
  final ImageLayout layout;
  final Board calibration;
  final Map<HexCoord, PlacedTile> placed;
  final BoardGraph graph;
  final Offset Function(StationNode) stationPosition;
  final RouteResult? route;

  const _BoardOverlayPainter({
    required this.layout,
    required this.calibration,
    required this.placed,
    required this.graph,
    required this.stationPosition,
    this.route,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final displayBoard = layout.boardToDisplay(calibration);
    final hexPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (final coord in displayBoard.coords) {
      final tile = placed[coord];
      if (tile == null) continue;
      final isBlank = tile.tileId == TileSeedData.blankTileId;
      final center = displayBoard.centerOf(coord);
      hexPaint.color = isBlank
          ? Colors.white24
          : Colors.lightGreenAccent.withValues(alpha: 0.9);
      final path = Path();
      for (int i = 0; i < 6; i++) {
        final v = HexGeometry.vertex(center, displayBoard.hexSize, i);
        if (i == 0) {
          path.moveTo(v.dx, v.dy);
        } else {
          path.lineTo(v.dx, v.dy);
        }
      }
      path.close();
      canvas.drawPath(path, hexPaint);

      if (!isBlank) {
        final label = TextPainter(
          text: TextSpan(
            text: tile.tileId,
            style: const TextStyle(
              color: Colors.lightGreenAccent,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(
          canvas,
          center + Offset(-label.width / 2, -displayBoard.hexSize * 0.75),
        );
      }
    }

    // Route first, so station markers sit on top of it.
    final activeRoute = route;
    if (activeRoute != null && activeRoute.track.isNotEmpty) {
      final routePaint = Paint()
        ..color = Colors.orangeAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final edge in activeRoute.track) {
        final points = <Offset>[
          layout.imageToDisplay(stationPosition(edge.from)),
          for (final hex in edge.hexPath.skip(1).take(
              edge.hexPath.length > 2 ? edge.hexPath.length - 2 : 0))
            displayBoard.centerOf(hex),
          layout.imageToDisplay(stationPosition(edge.to)),
        ];
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final p in points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, routePaint);
      }
    }

    final onRoute = {
      for (final stop in activeRoute?.stops ?? const <StationNode>[]) stop.id,
    };

    for (final station in graph.stations) {
      final center = layout.imageToDisplay(stationPosition(station));
      final radius =
          displayBoard.hexSize * (station.kind == StationKind.city ? 0.2 : 0.14);
      final company = Company.byId(station.companyId);
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = company?.color ?? Colors.white.withValues(alpha: 0.85),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = onRoute.contains(station.id)
              ? Colors.orangeAccent
              : Colors.black87
          ..style = PaintingStyle.stroke
          ..strokeWidth = onRoute.contains(station.id) ? 3 : 1.5,
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${station.revenue}',
          style: TextStyle(
            color: company == null
                ? Colors.black
                : ThemeData.estimateBrightnessForColor(company.color) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black,
            fontSize: radius,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, center + Offset(-label.width / 2, -label.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BoardOverlayPainter oldDelegate) => true;
}
