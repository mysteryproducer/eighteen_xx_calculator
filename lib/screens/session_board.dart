import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/board_graph.dart';
import '../models/company.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import '../models/tile_rules.dart';
import '../processing/board_reader.dart';
import '../processing/grid_detector.dart';
import '../processing/revenue_ocr.dart';
import '../processing/revenue_resolver.dart';
import '../processing/route_finder.dart';
import '../processing/tile_renderer.dart';
import '../services/photo_pipeline.dart';
import '../services/session_store.dart';
import '../widgets/board_map.dart';
import 'align_board.dart';
import 'capture.dart';

/// The drawn board, so tests can find it without depending on the tree.
const Key sessionBoardKey = ValueKey('session-board');

/// A game in progress: the board as the app understands it, and everything
/// you can do to it.
///
/// The board here is drawn from data, not from a photo, so it stays legible
/// between photos and carries what the app is unsure about. Photos are how
/// the state gets updated: one of the whole board to start, then close-ups of
/// the few hexes that changed or that recognition wasn't sure of.
class SessionBoard extends StatefulWidget {
  final GameTitle title;
  final GameSession session;
  final SessionStore store;
  final PhotoPipeline pipeline;

  const SessionBoard({
    super.key,
    required this.title,
    required this.session,
    required this.store,
    this.pipeline = const PhotoPipeline(),
  });

  @override
  State<SessionBoard> createState() => _SessionBoardState();
}

class _SessionBoardState extends State<SessionBoard> {
  late BoardMapGeometry _geometry;
  late BoardGraph _graph;
  late BoardReader _reader;
  late TileRules _rules;

  final Map<String, RevenueReading> _revenueReadings = {};
  final RevenueOcr _ocr = const RevenueOcr();

  Company? _company;
  int _maxStops = 4;
  RouteResult? _route;
  HexCoord? _highlighted;
  bool _busy = false;
  String _status = '';

  /// Hexes holding a tile the rules don't allow there, usually because it
  /// was set by hand.
  Set<HexCoord> _misfits = {};

  /// The hexes being picked out to photograph, or null when not choosing.
  Set<HexCoord>? _choosing;

  GameSession get _session => widget.session;
  MapLayout get _map => widget.title.map;

  @override
  void initState() {
    super.initState();
    _geometry = BoardMapGeometry(_map);
    _reader = BoardReader(widget.title);
    _rules = TileRules(widget.title);
    _rebuild();
  }

  void _rebuild() {
    _graph = _session.graph(widget.title);
    _misfits = {
      for (final hex in _map.hexes)
        if (_session.tileAt(hex) case final tile?)
          if (!_rules.fits(hex, tile)) hex.coord,
    };
    RevenueResolver.apply(
      _graph,
      isTileTrusted: (hex) {
        final mapHex = _map.at(hex);
        return mapHex == null || !_session.stateOf(mapHex).isDoubtful;
      },
      manual: _session.revenueOverrides,
      readings: _revenueReadings,
    );
    _route = null;
  }

  Future<void> _save() async {
    await widget.store.save(_session);
  }

  void _refresh() {
    setState(_rebuild);
    _save();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Photographing ------------------------------------------------------

  /// Photographs the whole board: align, then read every hex in frame.
  Future<void> _photographBoard({bool asPrinted = false}) async {
    final path = await capturePhoto(context);
    if (path == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Reading the photo...';
    });
    try {
      final (photo, preview) = await widget.pipeline.load(path);
      if (!mounted) return;
      setState(() => _busy = false);
      final boardToImage = await Navigator.of(context).push<Homography>(
        MaterialPageRoute(
          builder: (_) => AlignBoard(
            title: widget.title,
            photo: photo,
            previewBytes: preview,
          ),
        ),
      );
      if (boardToImage == null || !mounted) return;
      final visible = _visibleHexes(photo, boardToImage);
      if (asPrinted) {
        await _recordAsPrinted(photo, boardToImage, visible);
      } else {
        await _readHexes(
          photo: photo,
          boardToImage: boardToImage,
          hexes: visible,
          context: visible,
          source: HexSource.overview,
        );
      }
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Set<HexCoord> _visibleHexes(img.Image photo, Homography boardToImage) {
    bool inside(Offset p) =>
        p.dx >= 0 && p.dy >= 0 && p.dx < photo.width && p.dy < photo.height;
    return {
      for (final hex in _map.hexes)
        if (List.generate(
                6, (i) => boardToImage.apply(HexGeometry.vertex(hex.coord.boardCenter, 1, i)))
            .every(inside))
          hex.coord,
    };
  }

  /// Takes the photo as showing the board exactly as printed, and remembers
  /// how each hex looks, which is what later photos are compared against.
  Future<void> _recordAsPrinted(
    img.Image photo,
    Homography boardToImage,
    Set<HexCoord> visible,
  ) async {
    setState(() {
      _busy = true;
      _status = 'Learning what the empty board looks like...';
    });
    final readings = await _reader.readAsPrinted(
      photo: photo,
      boardToImage: boardToImage,
      hexes: visible,
      session: _session,
    );
    for (final r in readings) {
      await widget.store.saveHexPicture(_session.id, r.hex.id, r.picture);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
      _rebuild();
    });
    await _save();
    _snack('Remembered ${readings.length} hexes as printed. Photograph or '
        'take close-ups after each tile lay to keep up.');
  }

  Future<void> _readHexes({
    required img.Image photo,
    required Homography boardToImage,
    required Set<HexCoord> hexes,
    required Set<HexCoord> context,
    required HexSource source,
  }) async {
    setState(() {
      _busy = true;
      _status = 'Reading ${hexes.length} hexes...';
    });
    final before = {
      for (final hex in _map.hexes) hex.id: _session.tileAt(hex)?.tileId,
    };
    final readings = await _reader.read(
      photo: photo,
      boardToImage: boardToImage,
      hexes: hexes,
      context: context,
      session: _session,
    );
    BoardReader.apply(_session, readings, source: source);
    for (final r in readings) {
      await widget.store.saveHexPicture(_session.id, r.hex.id, r.picture);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
      _rebuild();
    });
    await _save();

    final changed = readings
        .where((r) => before[r.hex.id] != r.tile?.tileId)
        .length;
    final doubtful = readings.where((r) => !r.reading.isReliable).length;
    _snack('Read ${readings.length} hexes: $changed changed, '
        '${doubtful == 0 ? 'none' : doubtful} to check.');
  }

  /// Walks through close-ups of [hexes].
  Future<void> _takeCloseUps(Set<HexCoord> hexes) async {
    setState(() => _choosing = null);
    final requests = planCloseUps(_map, hexes);
    if (requests.isEmpty) {
      _snack('Nothing to photograph.');
      return;
    }
    for (int i = 0; i < requests.length; i++) {
      final more = await _closeUp(requests[i],
          label: 'Close-up ${i + 1} of ${requests.length}');
      if (!more || !mounted) break;
    }
  }

  /// One close-up. Returns false if the user backed out of the sequence.
  Future<bool> _closeUp(CloseUpRequest request, {String? label}) async {
    final target = _map.at(request.target);
    if (target == null) return true;
    final around = _map.around([request.target], 1);
    final guide = CaptureGuide(
      target: request.target,
      hexes: [for (final c in around) _map.at(c)!],
      instruction: '${label == null ? '' : '$label. '}'
          'Line the outline up with ${target.displayName} and the hexes '
          'around it.',
    );
    final path = await capturePhoto(context, guide: guide);
    if (path == null || !mounted) return false;

    setState(() {
      _busy = true;
      _status = 'Reading the close-up...';
    });
    try {
      final (photo, preview) = await widget.pipeline.load(path);
      final guess = guide.homographyFor(
          Size(photo.width.toDouble(), photo.height.toDouble()));
      final fit = await widget.pipeline
          .fitCloseUp(_map, photo, guess, request.target);
      if (!mounted) return false;
      setState(() => _busy = false);

      // A close-up only has to be good enough on the hexes it is for. Hexes
      // at the edge of the map are printed as part-hexes, so a photo of that
      // corner never scores highly however well it is placed, and a fit that
      // is off is caught later anyway: recognition reports it as doubtful.
      final target = fit?.hexCoverage[request.target] ?? 0;
      if (fit == null || (fit.coverage < 0.3 && target < 0.4)) {
        if (!mounted) return false;
        final choice = await _closeUpFailed(fit);
        if (choice == _CloseUpFallback.retry) {
          return _closeUp(request, label: label);
        }
        if (choice == _CloseUpFallback.byHand) {
          if (!mounted) return false;
          final boardToImage = await Navigator.of(context).push<Homography>(
            MaterialPageRoute(
              builder: (_) => AlignBoard(
                title: widget.title,
                photo: photo,
                previewBytes: preview,
                initial: guess,
                focus: _map.around([request.target], 2),
              ),
            ),
          );
          if (boardToImage == null || !mounted) return true;
          await _readHexes(
            photo: photo,
            boardToImage: boardToImage,
            hexes: around.intersection(_visibleHexes(photo, boardToImage)),
            context: _visibleHexes(photo, boardToImage),
            source: HexSource.closeUp,
          );
          return true;
        }
        return choice != _CloseUpFallback.stop;
      }

      await _readHexes(
        photo: photo,
        boardToImage: fit.boardToImage,
        hexes: around.intersection(fit.visible),
        context: fit.visible,
        source: HexSource.closeUp,
      );
      return true;
    } catch (e) {
      if (mounted) _snack('$e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_CloseUpFallback?> _closeUpFailed(GridFit? fit) => showDialog<_CloseUpFallback>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not line that up'),
          content: Text(fit == null
              ? 'No hex grid showed up in that photo. Get closer, keep the '
                  'whole outlined area in frame, and try to avoid shadows.'
              : 'The grid only half matched the printed hexes '
                  '(${(fit.coverage * 100).round()}%). Try again, or place it '
                  'by hand.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseUpFallback.stop),
              child: const Text('Stop'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseUpFallback.skip),
              child: const Text('Skip'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseUpFallback.byHand),
              child: const Text('Place by hand'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _CloseUpFallback.retry),
              child: const Text('Retake'),
            ),
          ],
        ),
      );

  // --- Editing ------------------------------------------------------------

  void _handleTap(Offset position) {
    final choosing = _choosing;
    if (choosing != null) {
      final hex = _geometry.hexAt(position);
      if (hex == null) return;
      if (!hex.takesTiles) {
        _snack('${hex.displayName} never changes, so there is nothing to '
            'photograph there.');
        return;
      }
      setState(() {
        choosing.contains(hex.coord)
            ? choosing.remove(hex.coord)
            : choosing.add(hex.coord);
      });
      return;
    }
    // A station is the smaller target and the more common thing to fix.
    StationNode? nearest;
    double nearestDistance = double.infinity;
    final content = _session.content(widget.title);
    for (final station in _graph.stations) {
      final def = content[station.hex];
      if (def == null) continue;
      final d = (_geometry.stationPosition(def, station) - position).distance;
      if (d < nearestDistance) {
        nearestDistance = d;
        nearest = station;
      }
    }
    if (nearest != null && nearestDistance <= boardMapScale * 0.3) {
      _editStation(nearest);
      return;
    }
    final hex = _geometry.hexAt(position);
    if (hex != null) _editHex(hex);
  }

  Future<void> _editHex(MapHex hex) async {
    setState(() => _highlighted = hex.coord);
    final state = _session.stateOf(hex);
    var tileId = state.tile?.tileId;
    var rotation = state.tile?.rotation ?? 0;
    var showAll = false;
    final picture = await widget.store.hexPicture(_session.id, hex.id);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheetState) {
        final legal = _rules
            .options(hex, state.basis, maxSteps: state.basisKnown ? 3 : 4)
            .map((o) => o.tileId)
            .whereType<String>()
            .toSet();
        final ids = {
          ...showAll ? widget.title.tiles.keys : legal,
          // Whatever is on the hex now stays on the list, even if the rules
          // wouldn't allow it -- it may be there because the user said so.
          if (tileId != null) tileId!,
        }.toList()
          ..sort(_compareTileIds);
        final definition = tileId == null
            ? hex.printed
            : widget.title.tiles[tileId]?.rotated(rotation);
        final problem = tileId == null
            ? null
            : _rules.explain(hex, PlacedTile(tileId!, rotation: rotation));
        return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hex.displayName,
                    style: Theme.of(context).textTheme.titleMedium),
                Text(_describeState(hex, state),
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (picture != null) ...[
                      Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(picture, width: 88, height: 88),
                          ),
                          Text('photo',
                              style: Theme.of(context).textTheme.labelSmall),
                        ],
                      ),
                      const SizedBox(width: 12),
                    ],
                    Column(
                      children: [
                        SizedBox(
                          width: 88,
                          height: 88,
                          child: definition == null
                              ? const SizedBox.shrink()
                              : CustomPaint(painter: TilePainter(definition)),
                        ),
                        Text(tileId == null ? 'as printed' : 'tile $tileId',
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButton<String?>(
                            value: ids.contains(tileId) ? tileId : null,
                            isExpanded: true,
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('Nothing laid'),
                              ),
                              for (final id in ids)
                                DropdownMenuItem<String?>(
                                  value: id,
                                  child: Text('Tile $id'),
                                ),
                            ],
                            onChanged: (v) => setSheetState(() => tileId = v),
                          ),
                          Row(
                            children: [
                              const Text('Turn'),
                              IconButton(
                                icon: const Icon(Icons.rotate_left),
                                onPressed: tileId == null
                                    ? null
                                    : () => setSheetState(
                                        () => rotation = (rotation + 5) % 6),
                              ),
                              Text('$rotation'),
                              IconButton(
                                icon: const Icon(Icons.rotate_right),
                                onPressed: tileId == null
                                    ? null
                                    : () => setSheetState(
                                        () => rotation = (rotation + 1) % 6),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber,
                            size: 18, color: BoardMapPainter.wrong),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            problem,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: BoardMapPainter.wrong),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (hex.takesTiles)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: showAll,
                    onChanged: (v) => setSheetState(() => showAll = v ?? false),
                    title: Text(
                      'Show every tile, not just the ${legal.length} the rules '
                      'allow here',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _closeUp(CloseUpRequest(hex.coord, {hex.coord}));
                      },
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Close-up'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () {
                        _session.setManually(hex,
                            tileId == null ? null : PlacedTile(tileId!, rotation: rotation));
                        Navigator.of(context).pop();
                        _refresh();
                      },
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }),
    );
    if (mounted) setState(() => _highlighted = null);
  }

  String _describeState(MapHex hex, HexState state) {
    if (!hex.takesTiles) {
      return 'Printed on the map; no tile is ever laid here.';
    }
    final confidence = '${(state.confidence * 100).round()}% sure';
    return switch (state.source) {
      HexSource.manual => 'Set by you.',
      HexSource.assumed => _session.startedEmpty
          ? 'Assumed as printed: no photo of this hex yet.'
          : 'Not photographed yet, so anything could be here.',
      HexSource.overview => 'Read from a photo of the board, $confidence.',
      HexSource.closeUp => 'Read from a close-up, $confidence.',
    };
  }

  Future<void> _editStation(StationNode station) async {
    final controller = TextEditingController(text: station.revenue.toString());
    var companyId = station.companyId;
    final hex = _map.at(station.hex);
    final reading = _revenueReadings[station.id];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${switch (station.kind) {
                  StationKind.city => 'City',
                  StationKind.town => 'Town',
                  StationKind.offboard => 'Off-board area',
                }} on ${hex?.displayName ?? station.hex}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(_describeRevenue(station, reading),
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Revenue',
                  border: OutlineInputBorder(),
                ),
              ),
              if (hex != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final value = await _readRevenueFromPhoto(hex, station);
                      if (value != null) {
                        setSheetState(() => controller.text = '$value');
                      }
                    },
                    icon: const Icon(Icons.numbers),
                    label: const Text('Read the figure off the photo'),
                  ),
                ),
              if (station.kind == StationKind.city) ...[
                const SizedBox(height: 8),
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
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    final value = int.tryParse(controller.text.trim());
                    if (value != null && value != station.revenue) {
                      _session.revenueOverrides[station.id] = value;
                    }
                    if (companyId == null) {
                      _session.tokens.remove(station.id);
                    } else {
                      _session.tokens[station.id] = companyId!;
                    }
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

  String _describeRevenue(StationNode station, RevenueReading? reading) =>
      switch (station.revenueSource) {
        RevenueSource.manual => 'Set by you.',
        RevenueSource.tile => 'From the tile or the printed map.',
        RevenueSource.photo => 'Read off the photo, because the tile here is '
            'uncertain.',
        RevenueSource.unverified =>
          'The tile here is uncertain, so check this figure.',
      };

  /// Reads the printed figure off the hex's stored picture.
  Future<int?> _readRevenueFromPhoto(MapHex hex, StationNode station) async {
    final picture = await widget.store.hexPicture(_session.id, hex.id);
    if (picture == null) {
      _snack('No photo of this hex yet.');
      return null;
    }
    final image = img.decodePng(picture);
    if (image == null) return null;
    try {
      final reading = await _ocr.readRegion(
        image,
        math.Rectangle<int>(0, 0, image.width, image.height),
      );
      _revenueReadings[station.id] = reading;
      if (!reading.recognized) {
        _snack('Could not make out a number on that hex.');
        return null;
      }
      return reading.value;
    } on TextRecognitionUnavailable catch (e) {
      _snack('${e.message} Type the figure in instead.');
      return null;
    }
  }

  // --- Routes -------------------------------------------------------------

  void _findRoute() {
    if (_graph.stations.isEmpty) {
      _snack('No revenue centres on the board yet.');
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
      _snack('No route found. Check the track joins up.');
    } else if (homes.isEmpty && company != null) {
      _snack('${company.name} has no token on the board, so this is the best '
          'route anywhere.');
    }
  }

  static int _compareTileIds(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final doubtful = _session.doubtfulHexes(_map);
    final neverSeen = _session.hexes.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(_session.name),
        actions: [
          PopupMenuButton<TileColor>(
            tooltip: 'Phase',
            initialValue: _session.phase,
            onSelected: (phase) {
              setState(() {
                _session.phase = phase;
                _rebuild();
              });
              _save();
            },
            itemBuilder: (context) => [
              for (final phase in tilePhases)
                PopupMenuItem(value: phase, child: Text('${phase.name} phase')),
            ],
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(_session.phase.name),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close-ups of hexes you choose',
            onPressed: _busy ? null : () => setState(() => _choosing = {}),
            icon: const Icon(Icons.center_focus_strong),
          ),
          IconButton(
            tooltip: 'Photograph the whole board',
            onPressed: _busy ? null : () => _photographBoard(),
            icon: const Icon(Icons.photo_camera),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_choosing != null)
            _choosingBar(_choosing!, doubtful)
          else if (neverSeen && _session.startedEmpty)
            _banner(
              'Photograph the board before anyone lays a tile, so the app '
              'knows what the bare map looks like here.',
              'Photograph empty board',
              () => _photographBoard(asPrinted: true),
            )
          else if (doubtful.isNotEmpty)
            _banner(
              '${doubtful.length} ${doubtful.length == 1 ? 'hex needs' : 'hexes need'} '
              'a closer look '
              '(${planCloseUps(_map, doubtful).length} photos).',
              'Choose',
              // Nothing starts chosen: after an operating round the player
              // knows which few hexes changed, and the bar's "All" button is
              // there when the answer really is "check the lot".
              () => setState(() => _choosing = {}),
            ),
          Expanded(
            child: Stack(
              children: [
                InteractiveViewer(
                  minScale: 0.4,
                  maxScale: 6,
                  boundaryMargin: const EdgeInsets.all(200),
                  child: Center(
                    child: GestureDetector(
                      key: sessionBoardKey,
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) => _handleTap(details.localPosition),
                      child: CustomPaint(
                        size: _geometry.size,
                        painter: BoardMapPainter(
                          title: widget.title,
                          session: _session,
                          graph: _graph,
                          geometry: _geometry,
                          route: _route,
                          highlighted: _highlighted,
                          misfits: _misfits,
                          selected: _choosing ?? const {},
                        ),
                      ),
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
          ),
          _routePanel(),
        ],
      ),
    );
  }

  Widget _banner(
    String message,
    String action,
    VoidCallback onPressed, {
    (String, VoidCallback)? extra,
  }) =>
      Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(message,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              if (extra != null)
                TextButton(
                  onPressed: _busy ? null : extra.$2,
                  child: Text(extra.$1),
                ),
              TextButton(
                onPressed: _busy ? null : onPressed,
                child: Text(action),
              ),
            ],
          ),
        ),
      );

  /// The bar shown while picking hexes to photograph. One close-up covers a
  /// hex and its neighbours, so a few hexes near each other cost one photo.
  Widget _choosingBar(Set<HexCoord> chosen, Set<HexCoord> doubtful) {
    final photos = planCloseUps(_map, chosen).length;
    final all = doubtful.difference(chosen).isEmpty;
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                chosen.isEmpty
                    ? 'Tap the hexes to photograph -- the ones where tiles '
                        'went down.'
                    : '${chosen.length} chosen, '
                        '$photos ${photos == 1 ? 'photo' : 'photos'} to take.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (doubtful.isNotEmpty)
              TextButton(
                // Everything the app is unsure of, to then toggle off what
                // doesn't need looking at.
                onPressed: all ? null : () => setState(() => chosen.addAll(doubtful)),
                child: Text('All ${doubtful.length}'),
              ),
            TextButton(
              onPressed: () => setState(() => _choosing = null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty || _busy
                  ? null
                  : () => _takeCloseUps({...chosen}),
              child: const Text('Close-ups'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _routePanel() {
    final route = _route;
    final tiles = _session.hexes.values.where((s) => s.tile != null).length;
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
              '$tiles ${tiles == 1 ? 'tile' : 'tiles'} laid, '
              '${_graph.stations.length} revenue centres. '
              '${_misfits.isEmpty ? 'Tap a hex or a circle to correct it.' : '${_misfits.length} in red '
                  '${_misfits.length == 1 ? "doesn't fit" : "don't fit"} the map -- tap to see why.'}',
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
                                  radius: 8, backgroundColor: company.color),
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
                  '${route.stops.map((s) => '${_map.at(s.hex)?.id ?? s.hex} (${s.revenue})').join(' - ')}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _CloseUpFallback { retry, byHand, skip, stop }
