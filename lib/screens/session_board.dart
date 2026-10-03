import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../geometry/homography.dart';
import '../models/board.dart';
import '../models/board_graph.dart';
import '../models/company.dart';
import '../models/company_rules.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import '../models/tile_rules.dart';
import '../processing/board_reader.dart';
import '../processing/grid_detector.dart';
import '../processing/plate_reader.dart';
import '../processing/play_area_reader.dart';
import '../processing/revenue_ocr.dart';
import '../processing/revenue_resolver.dart';
import '../processing/route_finder.dart';
import '../processing/tile_renderer.dart';
import '../processing/train_routes.dart';
import '../services/photo_pipeline.dart';
import '../services/session_store.dart';
import '../services/training_log.dart';
import '../widgets/board_map.dart';
import '../widgets/company_assets.dart';
import '../widgets/tile_choices.dart';
import 'align_board.dart';
import 'capture.dart';
import 'play_area_review.dart';
import 'players_screen.dart';

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

  /// Where corrections are banked as training examples. Null turns that off.
  final TrainingLog? trainingLog;

  const SessionBoard({
    super.key,
    required this.title,
    required this.session,
    required this.store,
    this.pipeline = const PhotoPipeline(),
    this.trainingLog,
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

  /// The selected company's trains' runs, when it has trains noted.
  CompanyRuns? _runs;

  /// Which of [_runs]' trains have their bonus spelt out, by index.
  final Set<int> _bonusesShown = {};

  /// Whether the company pays out half its revenue (where the title lets
  /// it), for what each player is paid.
  bool _halfPay = false;

  /// A phase the user said not yet to (see [_offerPhase]); only a later one
  /// is offered again.
  TileColor? _phaseDeclined;
  HexCoord? _highlighted;
  bool _busy = false;
  String _status = '';

  /// Hexes holding a tile the rules don't allow there, usually because it
  /// was set by hand.
  Set<HexCoord> _misfits = {};

  /// Tokens that can't legally be where they are (see
  /// [GameSession.tokenProblems]).
  Map<String, String> _tokenProblems = {};

  /// The hexes being picked out to photograph, or null when not choosing.
  Set<HexCoord>? _choosing;

  GameSession get _session => widget.session;
  MapLayout get _map => widget.title.map;

  @override
  void initState() {
    super.initState();
    _geometry = BoardMapGeometry(_map, turn: widget.title.displayTurn);
    _reader = BoardReader(widget.title);
    _rules = TileRules(widget.title);
    // A token saved before this title had its own companies names a plain
    // colour, and was a guess by the colour-only detector: shown, but up for
    // checking, and for a later photo to put right.
    for (final e in _session.tokens.entries) {
      if (!widget.title.companies.any((c) => c.id == e.value)) {
        _session.tokenDoubts.add(e.key);
      }
    }
    _rebuild();
  }

  void _rebuild() {
    _graph = _session.graph(widget.title);
    _misfits = {
      for (final hex in _map.hexes)
        if (_session.tileAt(hex) case final tile?)
          if (!_rules.fits(hex, tile)) hex.coord,
    };
    _tokenProblems = _session.tokenProblems(widget.title);
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
    _runs = null;
  }

  Future<void> _save() async {
    await widget.store.save(_session);
  }

  void _refresh() {
    setState(_rebuild);
    _save();
  }

  (TileColor, String)? _laterPhase() =>
      CompanyRules(widget.title).laterPhase(_session);

  /// After a photo: offers to move to the phase the board or the trains
  /// show, if later than the session's.
  Future<void> _offerPhase() async {
    final later = _laterPhase();
    if (later == null || !mounted) return;
    final (colour, why) = later;
    final declined = _phaseDeclined;
    if (declined != null &&
        widget.title.phaseColours.indexOf(colour) <=
            widget.title.phaseColours.indexOf(declined)) {
      return;
    }
    final move = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move to the ${colour.name} phase?'),
        content: Text('The game is in the ${_session.phase.name} phase, but '
            '$why says it has reached ${colour.name}: off-board areas pay '
            'their ${colour.name} figures from then on.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Move to ${colour.name}'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (move == true) {
      setState(() {
        _session.phase = colour;
        _rebuild();
      });
      await _save();
    } else {
      _phaseDeclined = colour;
    }
  }

  /// After the user has set a tile or a train: moves to the phase it shows,
  /// without asking -- they have just said so.
  void _followPhase() {
    final later = _laterPhase();
    if (later == null) return;
    final (colour, why) = later;
    _refreshWith(() => _session.phase = colour);
    _snack('Moved to the ${colour.name} phase: $why.');
  }

  void _refreshWith(void Function() change) {
    setState(() {
      change();
      _rebuild();
    });
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
    final path = (await capturePhoto(context))?.path;
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
            hints: _hints,
          ),
        ),
      );
      if (boardToImage == null || !mounted) return;
      // Players photograph from where they sit: close-ups are framed, and
      // the next photo of the board looked for, the same way round.
      _session.facing = GridFit.facingOf(boardToImage, _map.boardBounds.center);
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

  /// Photographs a player's area: reads the charters, trains, tokens and
  /// certificates in it, has the user confirm them, then works out the
  /// first charter's routes.
  Future<void> _photographPlayArea() async {
    final path = (await capturePhoto(context))?.path;
    if (path == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Reading the photo...';
    });
    PlayAreaReading reading;
    Uint8List preview;
    try {
      final (photo, jpeg) = await widget.pipeline.load(path);
      preview = jpeg;
      try {
        reading = await widget.pipeline.readPlayArea(widget.title, photo);
      } on TextRecognitionUnavailable catch (e) {
        if (mounted) _snack('${e.message} Enter what the photo shows by hand.');
        reading = const PlayAreaReading();
      }
    } catch (e) {
      if (mounted) _snack('$e');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final confirmed = await Navigator.of(context).push<PlayAreaConfirmed>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PlayAreaReview(
          title: widget.title,
          session: _session,
          reading: reading,
          preview: preview,
        ),
      ),
    );
    if (confirmed == null || !mounted) return;
    confirmed.applyTo(_session);
    await _save();
    await _offerPhase();
    if (!mounted) return;
    final first = confirmed.companies.firstOrNull;
    setState(() {
      if (first != null) _company = widget.title.companyById(first);
      _route = null;
      _runs = null;
    });
    if (first != null &&
        (_session.companyTrains[first]?.isNotEmpty ?? false)) {
      _findRoute();
    }
  }

  /// What the game knows about the board, to help find it in a photo.
  BoardHints get _hints => BoardHints(
        colours: {
          for (final e in _session.content(widget.title).entries)
            e.key: e.value.color,
        },
        tiled: {
          for (final hex in _map.hexes)
            if (_session.tileAt(hex) != null) hex.coord,
        },
        facing: _session.facing,
      );

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
    // A grid fitted to faint printed outlines, or to outlines tiles cover,
    // can sit a fraction of a hex off; the hexes the game is sure of put it
    // right first.
    boardToImage = await _reader.alignToKnown(
        photo: photo,
        boardToImage: boardToImage,
        hexes: context,
        session: _session);
    final before = {
      for (final hex in _map.hexes) hex.id: _session.tileAt(hex)?.tileId,
    };
    final readings = await _reader.read(
      photo: photo,
      boardToImage: boardToImage,
      hexes: hexes,
      context: context,
      session: _session,
      // A close-up is read knowing where glare fell on the whole board.
      glarePrior: source == HexSource.overview
          ? const {}
          : {
              for (final e in _session.glare.entries)
                if (_map.byId(e.key) case final hex?) hex.coord: e.value,
            },
    );
    BoardReader.apply(_session, readings, source: source);
    if (source == HexSource.overview) {
      _session.glare
        ..clear()
        ..addAll({for (final r in readings) r.hex.id: r.glare});
    }
    BoardReader.applyTunnels(
        _session,
        _reader.readTunnels(
            photo: photo, boardToImage: boardToImage, hexes: hexes));
    // Every mountain in the photo, not just those it was taken for: glare
    // tends to sit in the middle of a close-up, so a plate is often clearest
    // at the edge of a close-up of somewhere else.
    final mountains = _reader.readMountains(
        photo: photo, boardToImage: boardToImage, hexes: context);
    // Which plate is read off its figures, where they are large enough --
    // only for plates the user hasn't already named.
    final plates = await PlateReader(widget.title).readAll(photo, boardToImage, [
      for (final m in mountains)
        if (!_session.mountains.containsKey(m.hex.id) ||
            _session.mountainDoubts.contains(m.hex.id))
          m,
    ]);
    BoardReader.applyMountains(_session, mountains, plates: plates);
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
        .where((r) => before[r.hex.id] != _session.tileAt(r.hex)?.tileId)
        .length;
    final doubtful = readings.where((r) => !r.reading.isReliable).length;
    final glared = [
      for (final r in readings)
        if (r.glare > 0.3) r.hex.id,
      // A mountain the photo was for, whose plate (if any) glare hid, unless
      // the user has already said which plate is there.
      for (final m in mountains)
        if (m.washout > 0.5 &&
            !m.present &&
            hexes.contains(m.hex.coord) &&
            (!_session.mountains.containsKey(m.hex.id) ||
                _session.mountainDoubts.contains(m.hex.id)))
          m.hex.id,
    ];
    _snack('Read ${readings.length} hexes: $changed changed, '
        '${doubtful == 0 ? 'none' : doubtful} to check.'
        '${glared.isEmpty ? '' : ' Glare over ${_listed(glared)}: close-ups of '
            'those from another angle will read better.'}');
    await _offerPhase();
  }

  /// Hex ids for a message: a few, then how many more.
  static String _listed(List<String> ids) => ids.length <= 6
      ? ids.join(', ')
      : '${ids.take(5).join(', ')} and ${ids.length - 5} more';

  /// Measures how the board's colours look under this game's light (see
  /// [ColourProfile]), from a photo of the whole board.
  Future<void> _calibrateColours() async {
    final path = (await capturePhoto(context))?.path;
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
            hints: _hints,
          ),
        ),
      );
      if (boardToImage == null || !mounted) return;
      final result = _reader.calibrate(
        photo: photo,
        boardToImage: boardToImage,
        hexes: _visibleHexes(photo, boardToImage),
        session: _session,
      );
      setState(() => _session.colourProfile = result.profile);
      await _save();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Colours measured'),
          content: Text(_describeCalibration(result)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describeCalibration(Calibration result) {
    String name(TileColor c) => c == TileColor.plain ? 'bare map' : c.name;
    final measured = [
      for (final e in result.samples.entries)
        if (result.profile.colours.containsKey(e.key))
          '${name(e.key)} (${e.value} hexes)',
    ];
    final inPlay = {
      for (final hex in _map.hexes)
        if (_session.tileAt(hex) case final t?) widget.title.tiles[t.tileId]?.color,
    }.whereType<TileColor>();
    final missing = [
      for (final c in inPlay)
        if (!result.profile.colours.containsKey(c)) name(c),
    ];
    return [
      measured.isEmpty
          ? 'Nothing on the board was certain enough to measure. Confirm a few '
              'hexes first (tap one and Apply), then calibrate again.'
          : 'This game will use these colours from now on: ${measured.join(', ')}.',
      if (missing.isNotEmpty)
        'No ${missing.join(' or ')} tiles were certain enough to measure; '
            'confirm some and calibrate again to include them.',
      if (result.glare.isNotEmpty)
        'Glare over ${_listed([for (final c in result.glare) _map.at(c)!.id])}. '
            'Tiles there wash out from this camera position, so the app asks '
            'for close-ups of them rather than guess. Moving the light or the '
            'camera helps.',
    ].join('\n\n');
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
    final content = _session.content(widget.title);
    final guide = CaptureGuide(
      target: request.target,
      map: _map,
      turn: _session.facing ?? widget.title.displayTurn,
      hexes: [for (final c in around) _map.at(c)!],
      tiles: {
        for (final c in around)
          if (_session.tileAt(_map.at(c)!) != null ||
              _session.tunnels.containsKey(_map.at(c)!.id))
            c: content[c]!,
      },
      tileStyle: widget.title.tileStyle,
      instruction: '${label == null ? '' : '$label. '}'
          'Line the outline up with ${target.displayName} and the hexes '
          'around it.',
    );
    final shot = await capturePhoto(context, guide: guide);
    if (shot == null || !mounted) return false;
    final path = shot.path;
    // Where the guide was when the photo was taken, if it moved to follow
    // the board: a much closer start for finding the grid.
    final framed = shot.guide ?? guide;

    setState(() {
      _busy = true;
      _status = 'Reading the close-up...';
    });
    try {
      final (photo, preview) = await widget.pipeline.load(path);
      final guess = framed.homographyFor(
          Size(photo.width.toDouble(), photo.height.toDouble()));
      final fit = await widget.pipeline
          .fitCloseUp(_map, photo, guess, request.target, hints: _hints);
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
      if (!hex.takesTiles &&
          _rules.tunnelPaths(hex).isEmpty &&
          _rules.mountainPlates(hex).isEmpty) {
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
      final spots = [
        _geometry.stationPosition(def, station),
        if (station.kind == StationKind.city)
          for (final circle in TileRenderer.slotPositions(
              def, station.stationIndex, station.hex.boardCenter, 1))
            _geometry.toScreen(circle),
      ];
      for (final spot in spots) {
        final d = (spot - position).distance;
        if (d < nearestDistance) {
          nearestDistance = d;
          nearest = station;
        }
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
    // Everything that could legally be here at any point in the game, not
    // just what could follow the tile there now: the editor is for putting
    // things right, and a misread yellow tile needs the other yellow tiles.
    final legal = _rules.options(hex, null, maxSteps: 4);
    final legalTiles = {for (final o in legal) if (!o.isPrinted) o.tileId};
    final line = _rules.lineOf(hex);
    final content = _session.content(widget.title);
    final tunnelPaths = _rules.tunnelPaths(hex);
    var tunnel = _session.tunnels[hex.id];
    final plates = _rules.mountainPlates(hex);
    var plate = _session.mountains[hex.id];
    int connections(TileOption option) {
      final def = _rules.contentOf(hex, option);
      if (def == null || option.isPrinted) return 0;
      var joined = 0;
      for (final e in def.routableEdges) {
        final next = content[Board.neighborOf(hex.coord, e)];
        if (next != null && next.routableEdges.contains((e + 3) % 6)) joined++;
      }
      return joined;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Tall enough for the choices on a small window; the buttons are
      // pinned below them either way.
      isScrollControlled: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (context) => StatefulBuilder(builder: (context, setSheetState) {
        final chosen = tileId == null
            ? TileOption.printed
            : TileOption(tileId, rotation);
        final options = <TileOption>[
          if (!legal.contains(TileOption.printed)) TileOption.printed,
          ...legal,
          // Every tile, every way round, when the rules here are too strict
          // for whatever is really on the board.
          if (showAll)
            for (final id in (widget.title.tiles.keys.toList()
              ..sort(_compareTileIds)))
              for (final r in _rules.distinctRotations(id))
                if (!legal.any((o) => o.tileId == id && o.rotation == r))
                  TileOption(id, r),
          if (!legal.contains(chosen) && !chosen.isPrinted) chosen,
        ];
        final definition = _rules.contentOf(hex, chosen);
        final problem = tileId == null
            ? null
            : _rules.explain(hex, PlacedTile(tileId!, rotation: rotation));
        return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // What there is to choose from scrolls; the buttons stay put,
              // so Apply is never below the bottom of a small window.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(hex.displayName,
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(_describeState(hex, state),
                          style: Theme.of(context).textTheme.bodySmall),
                      if (state.suggestion case final s?)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'The photo shows '
                                  '${s.tile == null ? 'no tile' : 'tile ${s.tile!.tileId} turned ${s.tile!.rotation}'} '
                                  '(${(s.confidence * 100).round()}% sure).',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: BoardMapPainter.suggested),
                                ),
                              ),
                              TextButton(
                                onPressed: () => setSheetState(() {
                                  tileId = s.tile?.tileId;
                                  rotation = s.tile?.rotation ?? 0;
                                }),
                                child: const Text('Use that'),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),
                      // A wrap, not a row: on a phone the turn control drops
                      // below the two pictures rather than being squeezed off
                      // the edge.
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.start,
                        children: [
                          if (picture != null)
                            Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.memory(
                                    picture,
                                    width: 96,
                                    height: 96,
                                    // A picture that won't decode shouldn't
                                    // cost the user the editor.
                                    errorBuilder: (context, _, _) =>
                                        const SizedBox(
                                      width: 96,
                                      height: 96,
                                      child: Center(
                                          child: Icon(
                                              Icons.broken_image_outlined)),
                                    ),
                                  ),
                                ),
                                Text('the photo',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall),
                              ],
                            ),
                          Column(
                            children: [
                              SizedBox(
                                width: 96,
                                height: 96,
                                child: definition == null
                                    ? const SizedBox.shrink()
                                    : CustomPaint(
                                        painter: TilePainter(definition,
                                            turn: widget.title.displayTurn)),
                              ),
                              Text(
                                  tileId == null
                                      ? 'as printed'
                                      : 'tile $tileId',
                                  style:
                                      Theme.of(context).textTheme.labelSmall),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
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
                      const SizedBox(height: 4),
                      TileChoices(
                        hex: hex,
                        rules: _rules,
                        options: options,
                        selected: chosen,
                        isAllowed: (o) => o.isPrinted || legal.contains(o),
                        connections: connections,
                        onSelected: (option) => setSheetState(() {
                          tileId = option.tileId;
                          rotation = option.rotation;
                        }),
                      ),
                      if (line.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'This line is one piece: laying it or taking it '
                            'up here does the same on all ${line.length} '
                            'of its hexes (${line.map((h) => h.id).join(', ')}).',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
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
                      if (tunnelPaths.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('Tunnel',
                            style: Theme.of(context).textTheme.labelLarge),
                        if (_session.tunnelDoubts.contains(hex.id))
                          Text(
                            'Seen in a photo, but not for certain.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: BoardMapPainter.uncertain),
                          ),
                        const SizedBox(height: 4),
                        _TunnelChoices(
                          turn: widget.title.displayTurn,
                          base: _rules.contentOf(hex, chosen) ?? hex.printed,
                          paths: tunnelPaths,
                          selected: tunnel,
                          onSelected: (path) =>
                              setSheetState(() => tunnel = path),
                        ),
                      ],
                      if (plates.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('Mountain railway',
                            style: Theme.of(context).textTheme.labelLarge),
                        if (_session.mountainDoubts.contains(hex.id))
                          Text(
                            plate == GameSession.unknownPlate
                                ? 'A plate was seen in a photo, but not which '
                                    'one. Pick it.'
                                : 'Seen in a photo; check it.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: BoardMapPainter.uncertain),
                          ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            ChoiceChip(
                              label: const Text('None'),
                              selected: plate == null,
                              onSelected: (_) =>
                                  setSheetState(() => plate = null),
                            ),
                            for (final id in plates)
                              ChoiceChip(
                                label: _PlateLabel(widget.title.tiles[id]!),
                                selected: plate == id,
                                onSelected: (_) =>
                                    setSheetState(() => plate = id),
                              ),
                          ],
                        ),
                      ],
                      if (hex.takesTiles)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: showAll,
                          onChanged: (v) =>
                              setSheetState(() => showAll = v ?? false),
                          title: Text(
                            'Show every tile, not just the '
                            '${legalTiles.length} the rules allow here',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
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
                      final tile = tileId == null
                          ? null
                          : PlacedTile(tileId!, rotation: rotation);
                      // A line that opens as one piece is laid or taken up
                      // as one: each of its hexes gets its own part of it.
                      final whole = line.length > 1 &&
                          (tile == null ||
                              widget.title.laidByGame.contains(tile.tileId));
                      for (final h in whole ? line : [hex]) {
                        final t = h == hex || tile == null
                            ? tile
                            : _rules.openingOf(h)?.placed;
                        _bankCorrection(h, t);
                        _session.setManually(h, t);
                      }
                      if (plates.isNotEmpty) {
                        final chosen = plate;
                        if (chosen == null) {
                          _session.mountains.remove(hex.id);
                        } else {
                          _session.mountains[hex.id] = chosen;
                        }
                        // Settled, unless it is still "some plate".
                        if (chosen != GameSession.unknownPlate) {
                          _session.mountainDoubts.remove(hex.id);
                        }
                      }
                      if (tunnelPaths.isNotEmpty) {
                        final path = tunnel;
                        if (path == null) {
                          _session.tunnels.remove(hex.id);
                        } else {
                          _session.tunnels[hex.id] = path;
                        }
                        _session.tunnelDoubts.remove(hex.id);
                      }
                      Navigator.of(context).pop();
                      _refresh();
                      _followPhase();
                    },
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        );
      }),
    );
    if (mounted) setState(() => _highlighted = null);
  }

  /// Keeps what the user says is on a hex, with the picture it was read
  /// from, as a labelled example. Recognition can only be tuned against real
  /// boards under real light, and this is where that evidence comes from --
  /// on the device, for copying off later, not sent anywhere.
  Future<void> _bankCorrection(MapHex hex, PlacedTile? tile) async {
    final log = widget.trainingLog;
    if (log == null) return;
    // What the photos said, taken now: the caller sets the hex as soon as
    // this yields. Where the user had already set the hex, the latest photo's
    // view is its suggestion, if it disagreed.
    final state = _session.stateOf(hex);
    final suggestion = state.suggestion;
    final readAs = suggestion == null ? state.tile : suggestion.tile;
    final readConfidence =
        suggestion == null ? state.confidence : suggestion.confidence;
    final picture = await widget.store.hexPicture(_session.id, hex.id);
    if (picture == null) return; // never photographed; nothing to learn from
    final when = DateTime.now();
    try {
      await log.record(
        LabelledHex(
          titleId: widget.title.id,
          hexId: hex.id,
          tileId: tile?.tileId,
          rotation: tile?.rotation ?? 0,
          readAsTileId: readAs?.tileId,
          readAsRotation: readAs?.rotation,
          readConfidence: readConfidence,
          when: when,
          picture: TrainingLog.pictureName(_session.id, hex.id, when),
        ),
        picture,
      );
    } catch (e) {
      debugPrint('Could not bank a training example: $e');
    }
  }

  String _describeState(MapHex hex, HexState state) {
    if (!hex.takesTiles) {
      if (_rules.mountainPlates(hex).isNotEmpty) {
        return 'No tile is laid here, but a mountain railway can put a '
            'revenue plate on it.';
      }
      return _rules.tunnelPaths(hex).isEmpty
          ? 'Printed on the map; no tile is ever laid here.'
          : 'No tile is laid here, but a tunnel can be driven through.';
    }
    final confidence = '${(state.confidence * 100).round()}% sure';
    return switch (state.source) {
      HexSource.manual => state.suggestion == null
          ? 'Set by you.'
          : 'Set by you. A photo since shows something else; see below.',
      HexSource.assumed => _session.startedEmpty
          ? 'Assumed as printed: no photo of this hex yet.'
          : 'Not photographed yet, so anything could be here.',
      HexSource.overview => 'Read from a photo of the board, $confidence.',
      HexSource.closeUp => 'Read from a close-up, $confidence.',
    };
  }

  Future<void> _editStation(StationNode station) async {
    final controller = TextEditingController(text: station.revenue.toString());
    final chosen = List<String?>.of(station.tokens);
    final hex = _map.at(station.hex);
    final reading = _revenueReadings[station.id];
    final companies = [
      ...widget.title.companies,
      // A token set before the title had its own companies still shows.
      for (final id in chosen)
        if (widget.title.companyById(id) case final c?
            when !widget.title.companies.contains(c))
          c,
    ];
    // Whose home this city is: each keeps a circle free until its home
    // token is down.
    final homes = [
      if (hex != null)
        for (final c in widget.title.companies)
          if (c.isHomeOf(hex.id, station.stationIndex)) c,
    ];
    String? blocking() {
      final waiting = [
        for (final c in homes)
          if (!chosen.contains(c.id)) c,
      ];
      final others = chosen
          .where((t) => t != null && !homes.any((c) => c.id == t))
          .length;
      if (waiting.isEmpty || others <= chosen.length - waiting.length) {
        return null;
      }
      return '${hex?.displayName ?? 'This city'} is '
          '${waiting.map((c) => c.label).join(' and ')}\'s home: '
          '${chosen.length == 1 ? 'its only circle' : 'a circle'} has to stay '
          'free until the home token is placed, so this token is not '
          'allowed here.';
    }

    // A company's first token goes on its home hex; one of its tokens here
    // with none there is out of place (see [GameSession.tokenProblems]).
    List<String> awayFromHome() => [
          for (final c in companies)
            if (c.homeHex case final home?
                when chosen.contains(c.id) &&
                    home != hex?.id &&
                    !_graph.stations.any(
                        (s) => _map.at(s.hex)?.id == home && s.holds(c.id)))
              GameSession.homeMissing(c, _map.byId(home)?.displayName),
        ];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // A city of several circles offers a row of companies for each; they
      // scroll, and Apply stays below them, on a small window too.
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
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
              if (station.kind == StationKind.city)
                for (int slot = 0; slot < chosen.length; slot++) ...[
                  const SizedBox(height: 8),
                  Text(chosen.length == 1
                      ? 'Station token'
                      : 'Station token, circle ${slot + 1} of ${chosen.length}'),
                  if (_session.tokenDoubts
                      .contains(GameSession.slotId(station.id, slot)))
                    Text(
                      'Seen in a photo, but whose it is was a guess. Pick the '
                      'right company to settle it.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: BoardMapPainter.uncertain),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: const Text('None'),
                        selected: chosen[slot] == null,
                        onSelected: (_) =>
                            setSheetState(() => chosen[slot] = null),
                      ),
                      for (final company in companies)
                        Tooltip(
                          message: company.name,
                          child: ChoiceChip(
                            avatar:
                                CircleAvatar(backgroundColor: company.color),
                            label: Text(company.label),
                            selected: chosen[slot] == company.id,
                            onSelected: (_) => setSheetState(
                                () => chosen[slot] = company.id),
                          ),
                        ),
                    ],
                  ),
                ],
              if (station.kind == StationKind.city && homes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Home of ${homes.map((c) => c.label).join(' and ')}: a '
                    'home token is taken as down until you set its circle to '
                    'None, for a company that hasn\'t started.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (station.kind == StationKind.city)
                for (final why in [?blocking(), ...awayFromHome()])
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(why,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: BoardMapPainter.wrong)),
                  ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    final value = int.tryParse(controller.text.trim());
                    if (value != null && value != station.revenue) {
                      _session.revenueOverrides[station.id] = value;
                    }
                    for (int slot = 0; slot < chosen.length; slot++) {
                      final id = GameSession.slotId(station.id, slot);
                      if (chosen[slot] case final company?) {
                        _session.tokens[id] = company;
                      } else {
                        _session.tokens.remove(id);
                      }
                      // The user has looked at it: whatever it is now is
                      // settled.
                      _session.tokenDoubts.remove(id);
                    }
                    // A home token taken off is a company that hasn't
                    // started; put back, it has.
                    for (final c in homes) {
                      if (chosen.contains(c.id)) {
                        _session.homeTokensOff.remove(c.id);
                      } else {
                        _session.homeTokensOff.add(c.id);
                      }
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
    final trains = company == null
        ? const <String>[]
        : _session.companyTrains[company.id] ?? const <String>[];
    if (company != null && trains.isNotEmpty) {
      if (!_graph.stations.any((s) => s.holds(company.id))) {
        setState(() {
          _runs = null;
          _route = null;
        });
        _snack('${company.label} has no token on the board, so its trains '
            'have nowhere to start from.');
        return;
      }
      final runs = TrainRouter(widget.title, _graph, company.id).best(trains);
      setState(() {
        _runs = runs;
        _bonusesShown.clear();
        _route = null;
      });
      if (runs.revenue == 0) {
        _snack("No route found for ${company.label}'s trains. Check the "
            'track joins up.');
      } else if (!runs.complete) {
        _snack('Too many routes to try them all: these are the best found.');
      }
      return;
    }
    final homes = company == null
        ? <StationNode>[]
        : _graph.stations.where((s) => s.holds(company.id)).toList();
    RouteResult result;
    if (homes.isEmpty) {
      result = RouteFinder.bestRouteAnywhere(_graph, _maxStops);
    } else {
      result = const RouteResult(stops: [], track: [], revenue: 0);
      for (final home in homes) {
        final candidate = RouteFinder.bestRouteThrough(
            _graph, home, _maxStops,
            company: company?.id);
        if (candidate.revenue > result.revenue) result = candidate;
      }
    }
    setState(() {
      _route = result;
      _runs = null;
    });
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
    final suggested = _session.suggestedHexes(_map);
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
              for (final phase in widget.title.phaseColours)
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
          PopupMenuButton<String>(
            tooltip: 'Take a photo',
            enabled: !_busy,
            icon: const Icon(Icons.photo_camera),
            onSelected: (choice) => choice == 'area'
                ? _photographPlayArea()
                : _photographBoard(),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'board',
                child: ListTile(
                  leading: Icon(Icons.grid_on),
                  title: Text('The whole board'),
                ),
              ),
              PopupMenuItem(
                value: 'area',
                child: ListTile(
                  leading: Icon(Icons.style),
                  title: Text("A player's area"),
                  subtitle: Text('Charters, trains, tokens, certificates'),
                ),
              ),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            enabled: !_busy,
            onSelected: (choice) {
              switch (choice) {
                case 'players':
                  _editPlayers();
                case 'calibrate':
                  _calibrateColours();
                case 'forget':
                  setState(() => _session.colourProfile = null);
                  _save();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'players',
                child: Text('Players and shares'),
              ),
              PopupMenuItem(
                value: 'calibrate',
                child: Text(_session.colourProfile == null
                    ? 'Calibrate colours'
                    : 'Recalibrate colours'),
              ),
              if (_session.colourProfile != null)
                const PopupMenuItem(
                  value: 'forget',
                  child: Text('Forget colour calibration'),
                ),
            ],
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
          else if (suggested.isNotEmpty)
            _banner(
              '${suggested.length} ${suggested.length == 1 ? 'photo shows' : 'photos show'} '
              'something other than what you set. Yours stands until you '
              'say otherwise.',
              'Review',
              () {
                final next = _map.hexes
                    .firstWhere((h) => suggested.contains(h.coord));
                _editHex(next);
              },
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
                  minScale: 0.8,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(100),
                  child: Center(
                    // The map is laid out at its own size and scaled to fit,
                    // so what takes taps is exactly what is drawn. Left to
                    // the window's constraints, the map was cut down to the
                    // window's size for hit testing while still being
                    // painted in full, and hexes beyond the window's edge --
                    // most of 1844 in a Mac's default window -- ignored taps
                    // however far the board was panned or zoomed.
                    child: FittedBox(
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
                            routes: [
                              if (_runs case final runs?)
                                for (final run in runs.runs) run.route
                              else
                                ?_route,
                            ],
                            highlighted: _highlighted,
                            misfits: _misfits,
                            tokenProblems: _tokenProblems,
                            selected: _choosing ?? const {},
                          ),
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
    final company = _company;
    final trains = company == null
        ? const <String>[]
        : _session.companyTrains[company.id] ?? const <String>[];
    final tiles = _session.hexes.values.where((s) => s.tile != null).length;
    String? count(Iterable<String> doubts, Map<String, Object> layer,
        String one, String many) {
      final n = doubts.where(layer.containsKey).length;
      return n == 0 ? null : '$n ${n == 1 ? one : many}';
    }

    final toCheck = [
      count(_session.tokenDoubts, _session.tokens, 'token', 'tokens'),
      count(_session.tunnelDoubts, _session.tunnels, 'tunnel', 'tunnels'),
      count(_session.mountainDoubts, _session.mountains, 'mountain railway',
          'mountain railways'),
    ].nonNulls;
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
              '${toCheck.isEmpty ? '' : '${toCheck.join(', ')} to check (ringed). '}'
              '${_misfits.isEmpty && _tokenProblems.isEmpty ? 'Tap a hex or a circle to correct it.' : '${[
                  if (_misfits.isNotEmpty) '${_misfits.length} ${_misfits.length == 1 ? 'tile' : 'tiles'}',
                  if (_tokenProblems.isNotEmpty) '${_tokenProblems.length} ${_tokenProblems.length == 1 ? 'token' : 'tokens'}',
                ].join(' and ')} in red ${_misfits.length + _tokenProblems.length == 1 ? "isn't" : "aren't"} allowed there -- tap to see why.'}',
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
                      for (final company in widget.title.companies)
                        DropdownMenuItem<String?>(
                          value: company.id,
                          child: Row(
                            children: [
                              CircleAvatar(
                                  radius: 8, backgroundColor: company.color),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  company.label == company.name
                                      ? company.name
                                      : '${company.label}  ${company.name}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _company = widget.title.companyById(v);
                      _route = null;
                      _runs = null;
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                // Without trains noted, a single run of so many stops.
                if (trains.isEmpty) ...[
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
                ],
                FilledButton(
                  onPressed: _busy ? null : _findRoute,
                  child: Text(trains.isEmpty ? 'Find route' : 'Find routes'),
                ),
              ],
            ),
            if (company != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      trains.isEmpty
                          ? 'No trains noted for ${company.label}.'
                          : '${company.label} runs ${trains.join(', ')}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _editAssets(company),
                    icon: const Icon(Icons.train, size: 18),
                    label: const Text('Trains and tokens'),
                  ),
                ],
              ),
            // Routes from tokens that can't all be right.
            if (company?.homeHex case final home?
                when _session
                    .awayFromHome(widget.title, _graph.stations)
                    .containsKey(company!.id))
              Text(
                GameSession.homeMissing(company, _map.byId(home)?.displayName),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: BoardMapPainter.wrong),
              ),
            if (_runs case final runs? when company != null)
              ..._runLines(runs, company),
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

  // --- Players and companies ---------------------------------------------

  /// Each train's run, what the company earns, and what each player
  /// holding its certificates is paid.
  List<Widget> _runLines(CompanyRuns runs, Company company) {
    final theme = Theme.of(context).textTheme;
    String stop(StationNode s) => _map.at(s.hex)?.id ?? '${s.hex}';
    final rules = CompanyRules(widget.title);
    final holders = [
      for (final p in _session.players)
        if (_session.percentHeld(p, company.id) > 0) p,
    ];
    return [
      for (int i = 0; i < runs.runs.length; i++) ...[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                color: BoardMapPainter.routeColours[
                    i % BoardMapPainter.routeColours.length],
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: theme.bodyMedium,
                    children: [
                      TextSpan(
                        text: runs.runs[i].runs
                            ? '${runs.runs[i].train}: '
                                '${runs.runs[i].stops.map(stop).join(' - ')} '
                                'pays ${runs.runs[i].revenue}'
                            : '${runs.runs[i].train}: nowhere left to run',
                      ),
                      // How the bonus adds up, a tap away.
                      if (runs.runs[i].bonus != 0)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: InkWell(
                            onTap: () => setState(() {
                              if (!_bonusesShown.remove(i)) {
                                _bonusesShown.add(i);
                              }
                            }),
                            child: Text(
                              ' (${runs.runs[i].bonus} of it bonus'
                              '${_bonusesShown.contains(i) ? ' ▾' : ' ▸'})',
                              style: theme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_bonusesShown.contains(i))
          for (final line in [
            for (final b in runs.runs[i].bonuses) '${b.reason}: ${b.amount}',
            if (runs.runs[i].unpaid.isNotEmpty)
              'Paid for the best ${runs.runs[i].paid.length} of its '
                  '${runs.runs[i].stops.length} stops, not '
                  '${runs.runs[i].unpaid.map((s) => '${stop(s)} (${s.revenue})').join(', ')}',
          ])
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 1),
              child: Text(line, style: theme.bodySmall),
            ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${company.label} earns ${runs.revenue}'
                '${_halfPay ? ', and pays out half: ${runs.revenue ~/ 2}' : ''}.',
                style: theme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            if (widget.title.halfPay)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Full')),
                  ButtonSegment(value: true, label: Text('Half')),
                ],
                selected: {_halfPay},
                onSelectionChanged: (s) => setState(() => _halfPay = s.first),
              ),
          ],
        ),
      ),
      Text(
        holders.isEmpty
            ? _session.players.isEmpty
                ? 'Add the players (More, then Players and shares) to see '
                    'what each is paid.'
                : 'No player holds ${company.label} certificates yet.'
            : holders
                .map((p) => '$p ${rules.dividend(_session, p, company.id, runs.revenue, half: _halfPay)} '
                    '(${_session.percentHeld(p, company.id)}%)')
                .join('   '),
        style: theme.bodySmall,
      ),
    ];
  }

  /// Opens the game's players and their certificates.
  Future<void> _editPlayers() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayersScreen(
        title: widget.title,
        session: _session,
        onChanged: _save,
      ),
    ));
    if (mounted) setState(() {});
  }

  /// Sets [company]'s trains and the tokens left on its charter.
  Future<void> _editAssets(Company company) async {
    final edited = await editCompanyAssets(context,
        title: widget.title, session: _session, company: company);
    if (edited == null || !mounted) return;
    setState(() {
      if (edited.trains.isEmpty) {
        _session.companyTrains.remove(company.id);
      } else {
        _session.companyTrains[company.id] = edited.trains;
      }
      if (edited.tokens case final tokens?) {
        _session.charterTokens[company.id] = tokens;
      }
      _runs = null;
    });
    await _save();
    _followPhase();
  }
}

enum _CloseUpFallback { retry, byHand, skip, stop }


/// A mountain railway's revenue plate as printed: a box per phase, in the
/// phase's colour, with what it pays.
class _PlateLabel extends StatelessWidget {
  final TileDefinition plate;

  const _PlateLabel(this.plate);

  @override
  Widget build(BuildContext context) {
    final station = plate.stations.firstWhere(
        (s) => s.kind == StationKind.offboard,
        orElse: () => plate.stations.first);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final phase in tilePhases)
          if (station.phaseRevenue[phase] case final pays?)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: TileRenderer.backgroundFor(phase),
                border: Border.all(color: Colors.black54, width: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text('$pays',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
      ],
    );
  }
}

/// The ways a tunnel can run through a hex, drawn through what is on it.
class _TunnelChoices extends StatelessWidget {
  final TileDefinition base;
  final List<(int, int)> paths;
  final (int, int)? selected;
  final ValueChanged<(int, int)?> onSelected;

  /// How far tiles are turned to look as printed.
  final double turn;

  const _TunnelChoices({
    this.turn = 0,
    required this.base,
    required this.paths,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    Widget choice((int, int)? path) {
      final chosen = path == selected;
      final drawn = path == null
          ? base
          : base.withSegments([
              TileSegment(EdgeEndpoint(path.$1), EdgeEndpoint(path.$2),
                  narrow: true),
            ]);
      return InkWell(
        onTap: () => onSelected(path),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  width: chosen ? 3 : 1,
                  color: chosen
                      ? Theme.of(context).colorScheme.primary
                      : Colors.black26,
                ),
              ),
              child: CustomPaint(
                  painter: TilePainter(drawn, turn: turn)),
            ),
            Text(path == null ? 'no tunnel' : 'tunnel',
                style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      );
    }

    return SizedBox(
      height: 80,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final path in [null, ...paths])
            Padding(padding: const EdgeInsets.only(right: 8), child: choice(path)),
        ],
      ),
    );
  }
}
