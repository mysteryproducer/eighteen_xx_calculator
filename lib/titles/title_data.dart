/// Raw per-title data as imported from tobymao/18xx by
/// `tool/import_tobymao_title.dart`: the printed map and the tile manifest,
/// both in that project's tile DSL. `GameTitle` turns this into the parsed
/// map and tile definitions the app works with.
class TitleData {
  final String id;
  final String name;
  final String? location;
  final String? designer;
  final List<MapHexData> hexes;
  final List<TileData> tiles;

  const TitleData({
    required this.id,
    required this.name,
    required this.location,
    required this.designer,
    required this.hexes,
    required this.tiles,
  });
}

/// One printed map hex. [id] is the coordinate printed on the board, a row
/// letter and a column number (`D19`); [color] is tobymao's colour name.
class MapHexData {
  final String id;
  final String color;
  final String code;
  final String? name;

  const MapHexData(this.id, this.color, this.code, {this.name});
}

/// One tile design in the title's manifest, and how many copies come in the
/// box.
class TileData {
  final String id;
  final String color;
  final String code;
  final int count;

  const TileData(this.id, this.color, this.code, {required this.count});
}
