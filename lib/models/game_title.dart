import '../titles/title_1844.dart';
import '../titles/title_1854.dart';
import '../titles/title_data.dart';
import 'board.dart';
import 'map_layout.dart';
import 'tile_definition.dart';
import 'tile_seed_data.dart';

/// An 18xx title the app knows: its printed map and the tiles in the box.
class GameTitle {
  final String id;
  final String name;
  final String description;
  final MapLayout map;

  /// Tiles players can lay, by id.
  final Map<String, TileDefinition> tiles;

  /// How many of each tile come in the box.
  final Map<String, int> tileCounts;

  const GameTitle({
    required this.id,
    required this.name,
    required this.description,
    required this.map,
    required this.tiles,
    this.tileCounts = const {},
  });

  /// Builds a title from data imported from tobymao/18xx.
  factory GameTitle.fromData(TitleData data) {
    final rowShift = MapLayout.rowShiftFor(data.hexes.first.id);
    final hexes = <MapHex>[];
    for (final h in data.hexes) {
      final printed = TileDefinition.parseDsl(
          'map:${h.id}', tileColorFromName(h.color), h.code);
      final future = RegExp(r'future_label=label:([^,;]+)').firstMatch(h.code);
      hexes.add(MapHex(
        id: h.id,
        coord: MapLayout.coordFromId(h.id, rowShift: rowShift),
        printed: printed,
        name: h.name,
        futureLabel: future?.group(1),
      ));
    }
    return GameTitle(
      id: data.id,
      name: data.name,
      description: [
        if (data.location != null) data.location!,
        if (data.designer != null) 'by ${data.designer}',
      ].join(', '),
      map: MapLayout(hexes),
      tiles: {
        for (final t in data.tiles)
          t.id: TileDefinition.parseDsl(t.id, tileColorFromName(t.color), t.code),
      },
      tileCounts: {for (final t in data.tiles) t.id: t.count},
    );
  }

  /// A plain rectangular grid with the starter tile set, for boards the app
  /// has no map for.
  factory GameTitle.genericGrid({int rows = 8, int cols = 10}) => GameTitle(
        id: 'generic',
        name: 'Other title',
        description: 'A plain $rows x $cols hex grid and a starter set of '
            'common tiles',
        map: MapLayout.rectangle(rows, cols),
        tiles: {
          for (final e in TileSeedData.all.entries)
            if (e.key != TileSeedData.blankTileId) e.key: e.value,
        },
      );

  static final List<GameTitle> all = [
    GameTitle.fromData(title1844),
    GameTitle.fromData(title1854),
  ];

  static GameTitle? byId(String id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return id == 'generic' ? GameTitle.genericGrid() : null;
  }

  /// What's on [coord] as far as track goes: [placed] if a tile is down,
  /// otherwise the printing.
  TileDefinition? contentAt(HexCoord coord, {({String tileId, int rotation})? placed}) {
    if (placed != null) return tiles[placed.tileId]?.rotated(placed.rotation);
    return map.at(coord)?.printed;
  }
}
