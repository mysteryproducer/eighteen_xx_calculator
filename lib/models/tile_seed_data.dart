import 'tile_definition.dart';

/// A small starter set of common 18xx tile designs, enough to prove out
/// recognition + route tracing end-to-end. Track/city layout strings are
/// ported verbatim from tobymao/18xx's `lib/engine/config/tile.rb`
/// (https://github.com/tobymao/18xx, MIT licensed) -- these tile numbers and
/// their track geometry are standard notation shared across the 18xx hobby,
/// not specific to any one title. Only plain-track, city, and town tiles are
/// included; offboards, junctions (Lawson tiles), labels, and multi-lane
/// track are left for a later pass (see docs/plans/recognition-and-route-plotting.md).
///
/// Extend this map to grow the recognized tile set -- nothing else needs to
/// change to support a new tile beyond adding its DSL string here.
class TileSeedData {
  TileSeedData._();

  /// Id of the bare map hex (no tile laid). Hexes recognized as this are left
  /// out of the route graph.
  static const String blankTileId = 'blank';

  static const Map<String, String> _yellow = {
    // Plain track
    '7': 'path=a:0,b:1',
    '8': 'path=a:0,b:2',
    '9': 'path=a:0,b:3',
    // Towns
    '3': 'town=revenue:10;path=a:0,b:_0;path=a:_0,b:1',
    '4': 'town=revenue:10;path=a:0,b:_0;path=a:_0,b:3',
    '58': 'town=revenue:10;path=a:0,b:_0;path=a:_0,b:2',
    '1': 'town=revenue:10;town=revenue:10;path=a:1,b:_0;path=a:_0,b:3;'
        'path=a:0,b:_1;path=a:_1,b:4',
    '2': 'town=revenue:10;town=revenue:10;path=a:0,b:_0;path=a:_0,b:3;'
        'path=a:1,b:_1;path=a:_1,b:2',
    // Cities
    '5': 'city=revenue:20;path=a:0,b:_0;path=a:1,b:_0',
    '6': 'city=revenue:20;path=a:0,b:_0;path=a:2,b:_0',
    '57': 'city=revenue:20;path=a:0,b:_0;path=a:_0,b:3',
  };

  static const Map<String, String> _green = {
    // Plain track (curves/straights)
    '16': 'path=a:0,b:2;path=a:1,b:3',
    '19': 'path=a:0,b:3;path=a:2,b:4',
    '20': 'path=a:0,b:3;path=a:1,b:4',
    '23': 'path=a:0,b:3;path=a:0,b:4',
    '24': 'path=a:0,b:3;path=a:0,b:2',
    // Towns
    '87': 'town=revenue:10;path=a:0,b:_0;path=a:1,b:_0;path=a:2,b:_0;path=a:3,b:_0',
    '88': 'town=revenue:10;path=a:0,b:_0;path=a:1,b:_0;path=a:3,b:_0;path=a:4,b:_0',
    // Cities
    '14': 'city=revenue:30,slots:2;path=a:0,b:_0;path=a:1,b:_0;path=a:3,b:_0;path=a:4,b:_0',
    '15': 'city=revenue:30,slots:2;path=a:0,b:_0;path=a:1,b:_0;path=a:2,b:_0;path=a:3,b:_0',
  };

  /// All seed tiles, parsed once, keyed by tile id.
  static final Map<String, TileDefinition> all = {
    blankTileId:
        TileDefinition.parseDsl(blankTileId, TileColor.plain, ''),
    for (final e in _yellow.entries)
      e.key: TileDefinition.parseDsl(e.key, TileColor.yellow, e.value),
    for (final e in _green.entries)
      e.key: TileDefinition.parseDsl(e.key, TileColor.green, e.value),
  };
}
