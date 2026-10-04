// Generates a title's map and tile data from tobymao/18xx
// (https://github.com/tobymao/18xx, MIT licensed), the engine behind
// 18xx.games.
//
//   dart run tool/import_tobymao_title.dart 1880
//   dart run tool/import_tobymao_title.dart 18Chesapeake
//
// finds the title's folder under lib/engine/game (g_1880, g_18_chesapeake),
// fetches its map.rb, tiles.rb, meta.rb, entities.rb, game.rb, trains.rb,
// phases.rb, market.rb, step/dividend.rb and step/route.rb, and the shared
// lib/engine/config/tile.rb, and writes lib/titles/title_1880.dart; then
// rewrites lib/titles/titles.dart, the list GameTitle.all is built from. A
// title that is a variant of another (`class Game < G18Chesapeake::Game`)
// takes whatever it doesn't define itself from that one. The Ruby files are
// plain constant hashes, so a small reader for Ruby literals is enough;
// nothing is executed.
//
// It ends with a report of what the data doesn't carry -- rules in the
// game's code, tile code the app doesn't read, things to check against the
// physical game -- each with the code to change: see
// docs/importing-a-title.md.
//
// Options:
//   --from <dir>  read the files from a local clone of tobymao/18xx, or from
//                 a folder holding one title's files (and tile.rb) as before,
//                 rather than fetching them
//   --out <dir>   write the title file into <dir> instead, leaving lib/titles
//                 alone: to see what importing again would change
//   --dry-run     write nothing; print the report
//   --list        list the titles tobymao has
//   --registry    only rewrite lib/titles/titles.dart
import 'dart:convert';
import 'dart:io';

const _usage = '''
usage: dart run tool/import_tobymao_title.dart <title> [--from <dir>] [--out <dir>] [--dry-run]
       dart run tool/import_tobymao_title.dart --list
       dart run tool/import_tobymao_title.dart --registry

<title> as 18xx.games names it (1880, 18Chesapeake, 1822MX) or as its folder
in tobymao/18xx is named (g_18_chesapeake); case, spaces and underscores
don't matter.''';

/// Where the physical boards and tiles print the cities of hexes and tiles
/// whose data gives no places for them, by hex or tile id. tobymao spreads
/// such cities by a rule of its own, but the printed pieces each have their
/// own design, and recognition compares photos against the print. Each list
/// gives a `loc` per city, in order: half numbers are corners.
const _printedCityLocs = <String, Map<String, List<String>>>{
  '1844': {
    'G8': ['2.5', '5.5'], // Romont & Fribourg: one above the other
    'C20': ['3.5', '0.5'], // Winterthur & Frauenfeld: rising to the right
    // Tile 59: the city reached from side 0 sits out by side 4, its track
    // curving round to it; the other in the corner by side 2.
    '59': ['4', '1.5'],
    // Tile 66: the city on the run from side 0 to side 3 sits out towards
    // the corner between sides 4 and 5, the run bending through it (C20,
    // 2 October); the other is in the corner by side 2, as tobymao has it.
    '66': ['4.5'],
  },
  '1889': {
    // Tile 5: the city sits out in the corner between its two sides, half a
    // radius from the middle, the revenue in the middle (J11, photographed
    // in both 3 October sessions).
    '5': ['0.5'],
  },
};

/// Cells of tobymao's stock markets that are plainly mistyped -- a price far
/// below the cells either side of it, in a row that only rises -- by title,
/// then `row:column`: the cell as tobymao has it, and as it should be.
const _marketFixes = <String, Map<String, (String, String)>>{
  // ... 210S 230S 50S 275S 300e
  '1854': {'0:16': ('50S', '250S')},
  // ... 490 540 500 660 720
  '1807': {'0:28': ('500', '600')},
};

/// [dsl] with each `city=` that has no `loc:` given the next of [locs].
String _withCityLocs(String dsl, List<String> locs) {
  var next = 0;
  return [
    for (final part in dsl.split(';'))
      part.startsWith('city=') && !part.contains('loc:') && next < locs.length
          ? '$part,loc:${locs[next++]}'
          : part,
  ].join(';');
}

/// The constants the import reads, wherever a title's files define them.
const _read = {
  'HEXES', 'TILES', 'LOCATION_NAMES', 'LAYOUT', 'CORPORATIONS', 'MINORS',
  'TRAINS', 'PHASES', 'MARKET', 'COLUMN_MARKET', 'LOCAL_NAMES',
  'LOCAL_COORDINATES', 'LOCAL_CITIES', 'TUNNEL_HEXES', 'TUNNEL_TILES',
  'MOUNTAIN_HEXES', 'MOUNTAIN_TILES',
};

/// The files of a title's folder that hold data, or rules the report looks
/// for.
const _files = [
  'map.rb',
  'tiles.rb',
  'meta.rb',
  'entities.rb',
  'game.rb',
  'trains.rb',
  'phases.rb',
  'market.rb',
  'step/dividend.rb',
  'step/route.rb',
];

Future<void> main(List<String> args) async {
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final fromDir = option('--from');
  final outDir = option('--out');
  final dryRun = args.contains('--dry-run');
  final positional = [
    for (int i = 0; i < args.length; i++)
      if (!args[i].startsWith('--') &&
          (i == 0 || (args[i - 1] != '--from' && args[i - 1] != '--out')))
        args[i],
  ];
  if (args.contains('--registry')) {
    _writeRegistry();
    return;
  }
  final upstream = fromDir == null
      ? _GitHub()
      : Directory('$fromDir/lib/engine/game').existsSync()
          ? _Clone('$fromDir/lib/engine')
          : _Flat(fromDir);
  if (args.contains('--list')) {
    final folders = await _titleFolders(upstream);
    if (folders == null) {
      stderr.writeln('Could not list the titles${upstream.why}');
      exit(1);
    }
    stdout.writeln(folders.map((f) => f.substring(2)).join('\n'));
    return;
  }
  if (positional.isEmpty) {
    stderr.writeln(_usage);
    exit(64);
  }
  final asked = positional.first;

  // The title's folder, then the folders of the titles it's a variant of.
  final folder = await _folderFor(upstream, asked);
  if (folder == null) exit(1);
  final chain = <_Source>[];
  for (String? next = folder; next != null && chain.length < 4;) {
    final source = await _Source.load(upstream, next);
    if (source.files.isEmpty) {
      stderr.writeln('Nothing found for $asked in $next${upstream.why}');
      if (chain.isEmpty) exit(1);
      break;
    }
    chain.add(source);
    final parent = source.parent;
    next = parent == null || !upstream.hasParents
        ? null
        : await _folderFor(upstream, parent);
  }
  final own = chain.first;

  // The title as 18xx.games knows it: G1880's id is 1880.
  final module = own.module ?? asked;
  final title = module;
  final stem = folder.substring(2);

  final standardSource = await upstream.read('config/tile.rb');
  if (standardSource == null) {
    stderr.writeln('Could not load the standard tile list (config/tile.rb)'
        '${upstream.why}');
    exit(1);
  }

  // Every constant the title's files define, as Ruby finds them: the
  // title's game code before the modules it includes, and the title before
  // the one it's a variant of.
  final merged = <String, Object?>{};
  final metaMerged = <String, Object?>{};
  final unread = <String, String>{};
  for (final source in chain.reversed) {
    for (final name in [
      'market.rb',
      'trains.rb',
      'phases.rb',
      'entities.rb',
      'map.rb',
      'tiles.rb',
      'game.rb',
    ]) {
      final text = source.files[name];
      if (text == null) continue;
      final parsed = RubyConstants.parse(text);
      merged.addAll(parsed.values);
      parsed.unread.forEach((constant, why) {
        if (_read.contains(constant)) unread['$constant in ${source.folder}/$name'] = why;
      });
    }
    final metaText = source.files['meta.rb'];
    if (metaText != null) metaMerged.addAll(RubyConstants.parse(metaText).values);
  }
  final all = RubyConstants(merged);
  final meta = RubyConstants(metaMerged);
  // The files the title takes from the one it's a variant of.
  final inherited = <String, List<String>>{
    for (final source in chain.skip(1))
      source.folder: [
        for (final name in _files)
          if (source.files.containsKey(name) &&
              !chain
                  .takeWhile((s) => s != source)
                  .any((s) => s.files.containsKey(name)))
            name,
      ],
  }..removeWhere((_, names) => names.isEmpty);
  final gameSources = [
    for (final source in chain) ?source.files['game.rb'],
  ];
  final gameCode = [
    for (final source in chain)
      if (source.files['game.rb'] case final text?) (source.folder, text),
  ];
  final dividendSource = [
    for (final source in chain) ?source.files['step/dividend.rb'],
  ].firstOrNull;
  final dividendFolder = [
    for (final source in chain)
      if (source.files.containsKey('step/dividend.rb')) source.folder,
  ].firstOrNull;
  final routeStep = [
    for (final source in chain)
      if (source.files['step/route.rb'] case final text?) (source.folder, text),
  ].firstOrNull;

  final report = _Report();
  final trainNotes = <String>[];

  // The trains, each variant (1844's 2H) a train of its own that keeps
  // whatever of its parent's it doesn't change.
  final trainEntries = <String>[];
  void addTrain(Map train, {Map? parent}) {
    final merged = {...?parent, ...train};
    final name = '${merged['name']}';
    final distance = merged['distance'];
    int reach;
    int? pays;
    var freeTowns = false;
    var townAllowance = 0;
    var townsPay = true;
    List<String>? visits;
    List<String>? paidAt;
    if (distance is List && distance.isNotEmpty && distance.first is Map) {
      // Parts by the kinds of stop they count: the one with cities says how
      // far the train runs -- unless it pays nothing, when the part that
      // pays does (1807's 5+5E, paid at off-board areas). One for towns
      // alone leaves them out of the count: all of them where it visits
      // any number (1854's "+" trains, 1807's), the first few otherwise
      // (1880's "2+2"); and they pay what it pays (nothing, in 1807).
      final parts = distance.whereType<Map>().toList();
      List<String> nodesOf(Map p) =>
          [for (final n in p['nodes'] as List? ?? const []) '$n'];
      int visitOf(Map p) => (p['visit'] as num?)?.toInt() ?? 99;
      int payOf(Map p) => (p['pay'] as num?)?.toInt() ?? visitOf(p);
      final main = parts.firstWhere((p) => nodesOf(p).contains('city'),
          orElse: () => parts.first);
      final paying = payOf(main) > 0
          ? main
          : parts.firstWhere((p) => payOf(p) > 0, orElse: () => main);
      if (identical(paying, main)) {
        reach = visitOf(main);
        if (payOf(main) < reach) pays = payOf(main);
      } else {
        reach = parts.map(visitOf).reduce((a, b) => a > b ? a : b);
        pays = payOf(paying);
        paidAt = nodesOf(paying);
      }
      final towns = parts
          .where((p) =>
              !identical(p, main) &&
              !identical(p, paying) &&
              nodesOf(p).every((n) => n == 'town'))
          .firstOrNull;
      if (towns != null) {
        if (visitOf(towns) >= 99) {
          freeTowns = true;
        } else {
          townAllowance = visitOf(towns);
        }
        townsPay = payOf(towns) > 0;
      }
      // The stops it may run to: those some part of it takes.
      final kinds = {for (final p in parts) ...nodesOf(p)};
      if (!kinds.containsAll(const ['city', 'town', 'offboard'])) {
        visits = kinds.toList()..sort();
      }
      final strange = kinds.difference(const {'city', 'town', 'offboard'});
      if (strange.isNotEmpty) {
        trainNotes.add('$name counts stops the app has no kind for '
            '(${strange.join(', ')}): TrainData and train_routes.dart');
      }
    } else {
      reach = (distance as num?)?.toInt() ?? 0;
    }
    final multiplier = (merged['multiplier'] as num?)?.toInt() ?? 1;
    String names(List<String> list) =>
        '[${list.map(_dartString).join(', ')}]';
    final rusts = merged['rusts_on'];
    trainEntries.add("    TrainData(${_dartString(name)}, distance: $reach"
        "${pays == null ? '' : ', pays: $pays'}"
        "${freeTowns ? ', freeTowns: true' : ''}"
        "${townAllowance > 0 ? ', townAllowance: $townAllowance' : ''}"
        "${townsPay ? '' : ', townsPay: false'}"
        "${visits == null ? '' : ', visits: ${names(visits)}'}"
        "${paidAt == null ? '' : ', paidAt: ${names(paidAt)}'}"
        "${multiplier == 1 ? '' : ', multiplier: $multiplier'}"
        "${merged['price'] == null ? '' : ', price: ${merged['price']}'}"
        "${rusts == null ? '' : ', rustsOn: ${_dartString('$rusts')}'}"
        "${parent == null ? '' : ", base: ${_dartString('${parent['name']}')}"}"
        "${merged['num'] is num ? ', count: ${merged['num']}' : ''}),");
    // How the app will run it, where that isn't plain "so many stops".
    final how = [
      if (pays != null) 'an express, paid for its best $pays stops',
      if (pays == null && reach >= 99) 'runs any distance',
      if (reach == 0) 'runs nowhere (distance 0)',
      if (freeTowns) 'towns free',
      if (townAllowance > 0) 'up to $townAllowance towns free',
      if (!townsPay) 'towns pay nothing',
      if (visits != null) 'runs to ${visits.join('/')} only',
      if (paidAt != null) 'paid at ${paidAt.join('/')} only',
      if (multiplier != 1) 'takings x$multiplier',
    ];
    if (how.isNotEmpty) trainNotes.add('$name: ${how.join('; ')}');
  }

  final trains = all['TRAINS'];
  if (trains is List) {
    for (final train in trains.whereType<Map>()) {
      addTrain(train);
      for (final variant in (train['variants'] as List? ?? const []).whereType<Map>()) {
        addTrain(variant, parent: train);
      }
    }
  }
  final phaseEntries = <String>[];
  final phases = all['PHASES'];
  if (phases is List) {
    for (final phase in phases.whereType<Map>()) {
      final limit = phase['train_limit'];
      final limits = limit is Map
          ? {for (final e in limit.entries) '${e.key}': (e.value as num).toInt()}
          : {'': (limit as num?)?.toInt() ?? 0};
      final on = phase['on'];
      final tiles = phase['tiles'];
      phaseEntries.add("    PhaseData(${_dartString('${phase['name']}')}"
          "${on == null ? '' : ', on: ${_dartString('${on is List ? on.first : on}')}'}"
          ", trainLimit: {${limits.entries.map((e) => "${_dartString(e.key)}: ${e.value}").join(', ')}}"
          "${tiles is List ? ', tiles: [${tiles.map((t) => _dartString('$t')).join(', ')}]' : ''}),");
    }
  }
  final standard = RubyConstants.parse(standardSource);

  final layout = all['LAYOUT'];
  if (layout != 'pointy' && layout != 'flat') {
    stderr.writeln('$title uses a $layout layout; only pointy-top and '
        'flat-top maps are supported.');
    exit(1);
  }

  // Standard tiles by id, with the colour of the section they're listed in.
  final standardTiles = <String, (String, String)>{};
  for (final color in ['WHITE', 'YELLOW', 'GREEN', 'BROWN', 'GRAY', 'RED', 'BLUE']) {
    final section = standard[color];
    if (section is! Map) continue;
    section.forEach((id, code) {
      if (code is String) standardTiles['$id'] = (color.toLowerCase(), code);
    });
  }

  final tileEntries = <String>[];
  // Every piece of tile code imported, for the report: hexes by id, tiles
  // as `tile <id>`.
  final codes = <String, String>{};
  // A tile printed exactly like one already listed is the same tile under
  // another name for a variant (1889's beginner game lists 6 again as Beg6,
  // and so on). Two identical drawings would always tie in recognition.
  final seen = <(String, String), String>{};
  final manifest = all['TILES'];
  if (manifest is! Map) {
    stderr.writeln('No TILES manifest found for $title');
    exit(1);
  }
  manifest.forEach((id, spec) {
    String color;
    String code;
    // How many come with the game; none for `'unlimited'` (1807's plain
    // track).
    int? countOf(Object? value) => value is num ? value.toInt() : null;
    int? count;
    bool hidden = false;
    if (spec is Map) {
      count = spec.containsKey('count') ? countOf(spec['count']) : 1;
      hidden = spec['hidden'] == true;
      final standardTile = standardTiles['$id'];
      color = (spec['color'] as String?) ?? standardTile?.$1 ?? 'yellow';
      code = (spec['code'] as String?) ?? standardTile?.$2 ?? '';
    } else {
      count = countOf(spec);
      final standardTile = standardTiles['$id'];
      if (standardTile == null) {
        stderr.writeln('warning: tile $id is not in config/tile.rb; skipped');
        report.add(_Section.tiles,
            'tile $id is not in config/tile.rb, so it was left out: give it '
            'its code in the title\'s TILES (or fix the id) and import again');
        return;
      }
      (color, code) = standardTile;
    }
    final locs = _printedCityLocs[title]?['$id'];
    if (locs != null) code = _withCityLocs(code, locs);
    final same = seen[(color, code)];
    if (same != null) {
      stderr.writeln('note: tile $id is printed exactly like $same; skipped');
      return;
    }
    seen[(color, code)] = '$id';
    codes['tile $id'] = code;
    // Tiles marked hidden are laid by the game itself rather than by a
    // player -- 1844's Gotthard tunnel opening, say -- but they do appear on
    // the board, so they are imported and marked.
    tileEntries.add("    TileData('$id', '$color', ${_dartString(code)}, "
        "count: $count${hidden ? ', laidByGame: true' : ''}),");
  });

  final names = (all['LOCATION_NAMES'] as Map?) ?? {};
  final hexEntries = <String>[];
  final hexes = all['HEXES'];
  if (hexes is! Map) {
    stderr.writeln('No HEXES found for $title');
    exit(1);
  }
  hexes.forEach((color, entries) {
    if (entries is! Map) return;
    entries.forEach((ids, code) {
      for (final id in (ids as List)) {
        final name = names[id];
        final nameArg = name == null ? '' : ', name: ${_dartString('$name')}';
        var dsl = code == 'blank' ? '' : '$code';
        final locs = _printedCityLocs[title]?[id];
        if (locs != null) dsl = _withCityLocs(dsl, locs);
        codes['$id'] = dsl;
        hexEntries.add("    MapHexData('$id', '$color', ${_dartString(dsl)}$nameArg),");
      }
    });
  });

  // The companies whose station tokens go on the board, with their token
  // colours and home cities, for recognising tokens in photos.
  final companyEntries = <String>[];
  final kinds = <String, int>{};
  final homeless = <String>[];
  void addCompany(Map company) {
    final sym = company['sym'];
    if (sym == null) return;
    var home = company['coordinates'];
    if (home is List) {
      if (home.length > 1) {
        report.add(_Section.companies,
            '$sym has ${home.length} homes (${home.join(', ')}); only the '
            'first is imported (CompanyData.home)');
      }
      home = home.isEmpty ? null : home.first;
    }
    final city = (company['city'] as num?)?.toInt();
    final text = company['text_color'] as String?;
    final kind = company['type'] as String?;
    final tokens = company['tokens'];
    final shares = company['shares'];
    kinds.update(kind ?? 'major', (n) => n + 1, ifAbsent: () => 1);
    if (home == null) homeless.add('$sym');
    companyEntries.add("    CompanyData('$sym', "
        "${_dartString('${company['name'] ?? sym}')}, "
        "${_dartString('${company['color'] ?? 'white'}')}"
        "${text == null ? '' : ', textColor: ${_dartString(text)}'}"
        "${home == null ? '' : ", home: '$home'"}"
        "${city == null ? '' : ', homeCity: $city'}"
        "${kind == null ? '' : ', kind: ${_dartString(kind)}'}"
        "${tokens is List && tokens.isNotEmpty ? ', tokens: [${tokens.join(', ')}]' : ''}"
        "${shares is List && shares.isNotEmpty ? ', shares: [${shares.join(', ')}]' : ''}),");
  }

  for (final (list, minors) in [
    (all['CORPORATIONS'], false),
    (all['MINORS'], true),
  ]) {
    if (list is! List) continue;
    for (final company in list) {
      if (company is! Map) continue;
      // A minor that doesn't say what it is is a minor (1880's foreign
      // investors): what it pays its owner goes by that.
      addCompany(minors && company['type'] == null
          ? {...company, 'type': 'minor'}
          : company);
    }
  }
  // 1854 builds its local railways in code from three parallel lists rather
  // than writing them out; the lists themselves are plain data.
  final localNames = all['LOCAL_NAMES'];
  final localHomes = all['LOCAL_COORDINATES'];
  final localCities = all['LOCAL_CITIES'];
  if (all['MINORS'] is! List &&
      localNames is List &&
      localHomes is List &&
      localNames.length == localHomes.length) {
    for (int i = 0; i < localNames.length; i++) {
      addCompany({
        'sym': '${i + 1}',
        'name': localNames[i],
        'coordinates': localHomes[i],
        if (localCities is List && i < localCities.length) 'city': localCities[i],
        'color': '#000000',
        'type': 'minor',
      });
    }
    unread.removeWhere((where, _) => where.startsWith('MINORS '));
  }

  // 1844's tunnels: the hexes a tunnel company may tunnel through, and the
  // tiles whose narrow track shows which ways a tunnel can run.
  final tunnelHexes = all['TUNNEL_HEXES'];
  final tunnelTiles = all['TUNNEL_TILES'];
  // And its mountain railways: the mountains a revenue plate can be assigned
  // to, and the plates.
  final mountainHexes = all['MOUNTAIN_HEXES'];
  final mountainTiles = all['MOUNTAIN_TILES'];
  String words(Object? list) =>
      list is List ? list.map((w) => "'$w'").join(', ') : '';

  // The stock market's cells, row by row, as tobymao writes them -- a price
  // and letters for what the cell does (`100p`, a par price; `''`, no cell).
  final marketRows = [
    for (final row in (all['MARKET'] ?? all['COLUMN_MARKET']) as List? ?? const [])
      [for (final cell in row as List) '$cell'],
  ];
  _marketFixes[title]?.forEach((at, fix) {
    final [r, c] = at.split(':').map(int.parse).toList();
    if (r < marketRows.length &&
        c < marketRows[r].length &&
        marketRows[r][c] == fix.$1) {
      marketRows[r][c] = fix.$2;
    } else {
      stderr.writeln('warning: market fix $at for $title no longer applies');
      report.add(_Section.market,
          'the fix for cell $at in _marketFixes no longer applies: tobymao '
          'may have corrected it; take it out');
    }
  });
  // How a price moves on it: along a row, with a row's end leading up (a
  // grid, as 1830's); on a hex market, diagonally (1854); or along a single
  // row (1807).
  final marketKind = gameSources.any((s) => s.contains('hex_market: true'))
      ? 'hex'
      : marketRows.length == 1
          ? 'row'
          : 'grid';

  final location = meta['GAME_LOCATION'] as String?;
  final designer = meta['GAME_DESIGNER'] as String?;
  final name = (meta['GAME_TITLE'] as String?) ?? title;
  final out = StringBuffer()
    ..writeln('// GENERATED by tool/import_tobymao_title.dart from tobymao/18xx')
    ..writeln('// (https://github.com/tobymao/18xx, MIT licensed). Do not edit by')
    ..writeln('// hand: fix the importer or the upstream data and regenerate.')
    ..writeln()
    ..writeln("import 'title_data.dart';")
    ..writeln()
    ..writeln('const TitleData title$title = TitleData(')
    ..writeln("  id: '$title',")
    ..writeln('  name: ${_dartString(name)},')
    ..writeln('  location: ${location == null ? 'null' : _dartString(location)},')
    ..writeln('  designer: ${designer == null ? 'null' : _dartString(designer)},')
    ..writeln('  hexes: [')
    ..writeAll(hexEntries.map((e) => '$e\n'))
    ..writeln('  ],')
    ..writeln('  tiles: [')
    ..writeAll(tileEntries.map((e) => '$e\n'))
    ..writeln('  ],')
    ..writeln('  companies: [')
    ..writeAll(companyEntries.map((e) => '$e\n'))
    ..writeln('  ],')
    ..writeln('  trains: [')
    ..writeAll(trainEntries.map((e) => '$e\n'))
    ..writeln('  ],')
    ..writeln('  phases: [')
    ..writeAll(phaseEntries.map((e) => '$e\n'))
    ..writeln('  ],')
    ..write(layout == 'flat' ? '  flat: true,\n' : '')
    ..writeln(tunnelHexes is List
        ? '  tunnelHexes: [${words(tunnelHexes)}],'
        : '  tunnelHexes: [],')
    ..writeln(tunnelTiles is List
        ? '  tunnelTiles: [${words(tunnelTiles)}],'
        : '  tunnelTiles: [],')
    ..writeln(mountainHexes is List
        ? '  mountainHexes: [${words(mountainHexes)}],'
        : '  mountainHexes: [],')
    ..writeln(mountainTiles is List
        ? '  mountainTiles: [${words(mountainTiles)}],'
        : '  mountainTiles: [],')
    ..writeln('  market: [')
    ..writeAll(marketRows.map((row) => '    [${words(row)}],\n'))
    ..writeln('  ],')
    ..write(marketKind == 'grid' ? '' : "  marketKind: '$marketKind',\n")
    ..writeln(');');

  // What the data doesn't carry.
  final stage = '${meta['DEV_STAGE'] ?? 'unknown'}';
  report.add(_Section.about,
      '$name (${own.folder})${location == null ? '' : ', $location'}'
      '${designer == null ? '' : ', by $designer'}');
  report.add(_Section.about,
      '${layout == 'flat' ? 'flat' : 'pointy'}-topped map: '
      '${hexEntries.length} hexes, ${tileEntries.length} tiles, '
      '${companyEntries.length} companies, ${trainEntries.length} trains, '
      '${phaseEntries.length} phases, ${marketRows.isEmpty ? 'no' : marketKind} '
      'market');
  if (stage != 'production') {
    report.add(_Section.about,
        '18xx.games has it at the `$stage` stage: its data may be unfinished '
        'or wrong');
  }
  unread.forEach((where, why) => report.add(_Section.about,
      '$where isn\'t a literal this tool can read ($why): what it holds is '
      'missing from the import -- teach RubyConstants its form, or write the '
      'missing data by hand'));
  inherited.forEach((from, files) => report.add(_Section.about,
      'a variant of ${from.substring(2)}: takes ${files.join(', ')} from it, and whatever else its own files leave out'));
  _checkTileCode(codes, report);
  _checkCityPlaces(codes, report);
  _checkMarket(marketRows, report);
  for (final note in trainNotes) {
    report.add(_Section.trains, note);
  }
  _checkGameCode(
    gameCode: gameCode,
    dividend: dividendSource,
    dividendFolder: dividendFolder,
    routeStep: routeStep,
    folder: own.folder,
    steps: own.steps,
    trains: trains is List ? trains : const [],
    minors: kinds['minor'] ?? 0,
    report: report,
  );
  if (homeless.isNotEmpty) {
    report.add(_Section.companies,
        'no home on the map, starting wherever their players put them: '
        '${homeless.join(', ')}');
  }
  report.add(_Section.companies,
      'kinds: ${kinds.entries.map((e) => '${e.value} ${e.key}').join(', ')}'
      '${kinds.containsKey('minor') ? ' (minors hold no place on the market, and pay their owner as MarketRules.minorPayout says)' : ''}');
  final privates = all['COMPANIES'];
  if (privates is List) {
    for (final company in privates.whereType<Map>()) {
      for (final ability in (company['abilities'] as List? ?? const []).whereType<Map>()) {
        final hexes = ability['hexes'], tiles = ability['tiles'];
        if ((ability['type'] == 'tile_lay' || ability['type'] == 'teleport') &&
            hexes is List &&
            hexes.isNotEmpty &&
            tiles is List &&
            tiles.isNotEmpty) {
          report.add(_Section.companies,
              '${company['sym']} (${company['name']}) lays ${tiles.join('/')} '
              'on ${hexes.join(', ')}: where no one else may lay those tiles, '
              'list them in _tilesOnlyOn');
        }
      }
    }
  }
  final handled = _handKept(title);
  if (handled.isNotEmpty) {
    report.add(_Section.about,
        'lib/models/game_title.dart already keeps rules for it in '
        '${handled.join(', ')}');
  }

  final path = outDir != null
      ? '$outDir/title_$stem.dart'
      : 'lib/titles/title_$stem.dart';
  if (!dryRun) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(out.toString());
    stdout.writeln('Wrote $path: ${hexEntries.length} hexes, '
        '${tileEntries.length} tiles, ${companyEntries.length} companies.');
    if (outDir == null) _writeRegistry();
  }
  stdout.write(report);
  stdout.writeln('\nThen check it against your copy of the game, and run '
      'flutter test test/every_title_test.dart\nand flutter analyze: see '
      'docs/importing-a-title.md.');
}

/// Rewrites lib/titles/titles.dart: every title in lib/titles, which
/// GameTitle.all is built from.
void _writeRegistry() {
  final files = [
    for (final entity in Directory('lib/titles').listSync())
      if (entity is File) entity.uri.pathSegments.last,
  ].where((f) => f.startsWith('title_') && f.endsWith('.dart') && f != 'title_data.dart').toList()
    ..sort();
  final titles = [
    for (final file in files)
      if (RegExp(r'const TitleData (\w+) =')
              .firstMatch(File('lib/titles/$file').readAsStringSync())
              ?.group(1)
          case final constant?)
        (file, constant),
  ];
  final out = StringBuffer()
    ..writeln('// GENERATED by tool/import_tobymao_title.dart: the titles in this')
    ..writeln('// folder, for GameTitle.all. Importing a title rewrites it, as does')
    ..writeln('// `dart run tool/import_tobymao_title.dart --registry`.')
    ..writeln()
    ..writeAll(titles.map((t) => "import '${t.$1}';\n"))
    ..writeln("import 'title_data.dart';")
    ..writeln()
    ..writeln('const List<TitleData> importedTitles = [')
    ..writeAll(titles.map((t) => '  ${t.$2},\n'))
    ..writeln('];');
  File('lib/titles/titles.dart').writeAsStringSync(out.toString());
  stdout.writeln('Wrote lib/titles/titles.dart: '
      '${titles.map((t) => t.$2.substring(5)).join(', ')}.');
}

/// The rules lib/models/game_title.dart keeps by hand that name [id]: the
/// maps and sets it keeps them in.
List<String> _handKept(String id) {
  final file = File('lib/models/game_title.dart');
  if (!file.existsSync()) return const [];
  final source = file.readAsStringSync();
  return [
    for (final match in RegExp(r'static (?:const|final) [^=]*\b(_\w+) = \{')
        .allMatches(source))
      if (_braced(source, match.end - 1).contains("'$id'")) match.group(1)!,
  ];
}

/// The text from the brace at [open] to the one that closes it.
String _braced(String source, int open) {
  var depth = 0;
  for (int i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  return source.substring(open);
}

/// The parts of tobymao's tile code (`lib/engine/tile.rb`) that
/// TileDefinition.parseDsl doesn't read, or reads only partly, with where
/// they appear and what that means for the app.
void _checkTileCode(Map<String, String> codes, _Report report) {
  final found = <String, List<String>>{};
  void note(String feature, String where) =>
      found.putIfAbsent(feature, () => []).add(where);
  for (final MapEntry(key: where, value: code) in codes.entries) {
    for (final raw in code.split(';')) {
      final part = raw.trim();
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final key = eq < 0 ? part : part.substring(0, eq);
      final params = <String, String>{
        if (eq >= 0)
          for (final kv in part.substring(eq + 1).split(','))
            if (kv.indexOf(':') case final colon when colon > 0)
              kv.substring(0, colon): kv.substring(colon + 1),
      };
      switch (key) {
        case 'junction' || 'halt' || 'pass':
          note(key, where);
        case 'city' || 'town' || 'offboard':
          for (final attr in const ['visit_cost', 'route', 'boom', 'to_city']) {
            if (params.containsKey(attr)) note('$key $attr', where);
          }
        case 'path':
          for (final attr in const ['lanes', 'a_lane', 'b_lane', 'ignore']) {
            if (params.containsKey(attr)) note('path $attr', where);
          }
          final track = params['track'];
          if (track != null && !const {'broad', 'narrow', 'future'}.contains(track)) {
            note('path track:$track', where);
          }
        case 'stub' || 'partition' || 'stripes' || 'frame':
          note(key, where);
        case 'label' || 'border' || 'icon' || 'upgrade' || 'future_label':
          break;
        default:
          note('$key (not in tobymao\'s tile.rb either)', where);
      }
    }
  }
  String meaning(String feature) {
    final first = feature.split(' ').first;
    if (const {'junction', 'halt', 'pass'}.contains(first)) {
      return 'a node that paths name by number (`_1`) as they do stops; the '
          'app doesn\'t count it, so track to the stops after it goes astray: '
          'TileDefinition.parseDsl must count it (lib/models/tile_definition.dart)';
    }
    if (feature.endsWith('visit_cost')) {
      return 'a stop that doesn\'t count towards a train\'s distance: '
          'train_routes.dart counts every stop';
    }
    if (feature.endsWith(' route')) {
      return 'a stop routes may not use as tobymao says: train_routes.dart '
          'doesn\'t know';
    }
    if (feature.endsWith('boom') || feature.endsWith('to_city')) {
      return 'a stop that changes as the game goes on: not modelled';
    }
    if (feature.contains('lane')) {
      return 'parallel lanes of track, read as one path: '
          'TileDefinition.parseDsl and train_routes.dart';
    }
    if (feature.endsWith('ignore')) {
      return 'track drawn but not for routes: read as track';
    }
    if (feature.startsWith('path track:')) {
      return 'a kind of track read as standard gauge: TileSegment has '
          'narrow and future only';
    }
    if (const {'stub', 'partition', 'stripes', 'frame'}.contains(first)) {
      return 'printing the app doesn\'t draw, so recognition compares the '
          'photo with a drawing that lacks it (tile_renderer.dart)';
    }
    return 'unknown: read tobymao\'s lib/engine/tile.rb';
  }

  found.forEach((feature, places) {
    final shown = places.take(8).join(', ');
    report.add(_Section.tiles,
        '$feature in ${places.length == 1 ? '' : '${places.length}: '}$shown'
        '${places.length > 8 ? ', ...' : ''} -- ${meaning(feature)}');
  });
}

/// Hexes and tiles with two or more cities that tobymao places by its own
/// rule (no `loc:`), which the print may not follow.
void _checkCityPlaces(Map<String, String> codes, _Report report) {
  final unplaced = [
    for (final MapEntry(key: where, value: code) in codes.entries)
      if (code.split(';').where((p) => p.startsWith('city=')).toList()
          case final cities
          when cities.length > 1 && cities.any((c) => !c.contains('loc:')))
        where,
  ];
  if (unplaced.isEmpty) return;
  report.add(_Section.tiles,
      '${unplaced.length} hexes and tiles have two or more cities placed by '
      'tobymao\'s rule rather than the data: ${unplaced.join(', ')} -- check '
      'each against the print; where a city sits elsewhere, give its place '
      'in _printedCityLocs (this tool) and import again');
}

/// The stock market: its letters, and cells that look mistyped.
void _checkMarket(List<List<String>> rows, _Report report) {
  if (rows.isEmpty) {
    report.add(_Section.market,
        'no stock market found (MARKET): the end of the game can\'t be worked '
        'out from share values');
    return;
  }
  final letters = <String>{};
  for (int r = 0; r < rows.length; r++) {
    int? last;
    for (int c = 0; c < rows[r].length; c++) {
      final code = rows[r][c];
      final price = int.tryParse(RegExp(r'^\d+').stringMatch(code) ?? '');
      if (price == null) continue;
      letters.addAll(code.substring('$price'.length).split('').where((l) => l.trim().isNotEmpty));
      if (last != null && price < last) {
        report.add(_Section.market,
            'cell $r:$c is $code after ${rows[r][c - 1]}, in a row that '
            'should rise: if it\'s mistyped, add the fix to _marketFixes '
            '(this tool)');
      }
      last = price;
    }
  }
  report.add(_Section.market,
      '${rows.length} row${rows.length == 1 ? '' : 's'} of up to '
      '${rows.map((r) => r.length).reduce((a, b) => a > b ? a : b)} cells; '
      'letters ${letters.isEmpty ? 'none' : (letters.toList()..sort()).join(' ')}'
      ' -- the app moves prices by the cells alone, except for letters given '
      'in MarketRules.barred (1844\'s t); the market reader tells the zones '
      'apart by them');
}

/// Rules in the title's game code that the app keeps by hand, if at all.
void _checkGameCode({
  required List<(String, String)> gameCode,
  required String? dividend,
  required String? dividendFolder,
  required (String, String)? routeStep,
  required String folder,
  required List<String>? steps,
  required List<Object?> trains,
  required int minors,
  required _Report report,
}) {
  // Each method the game code defines, and the folder whose game.rb
  // defines it first: the title's own, or one it's a variant of.
  final methods = <String, String>{};
  for (final (from, source) in gameCode) {
    for (final m in RegExp(r'^\s*def\s+(?:self\.)?([a-z_]\w*[?!]?)', multiLine: true)
        .allMatches(source)) {
      methods.putIfAbsent(m.group(1)!, () => from);
    }
  }
  List<String> defined(Set<String> names) => [
        for (final name in names)
          if (methods[name] case final from?) from == folder ? name : '$name ($from)',
      ];

  final routes = defined(const {
    'revenue_for', 'revenue_str', 'revenue_stops', 'routes_revenue',
    'check_distance', 'check_other', 'check_connected',
    'check_overlap', 'check_route_token', 'compute_stops', 'route_distance',
    'stop_type', 'express_train?',
  });
  if (routes.isNotEmpty) {
    report.add(_Section.code,
        'routes: ${routes.join(', ')} -- what a route pays or where it may go '
        'differs from the data (bonuses, costs, stops that count otherwise): '
        'read them, then add what matters to _routeRules (game_title.dart) or '
        'to train_routes.dart');
  }
  // Earnings beyond the routes: 1880's stock-market bonus, added to the run
  // in its route step.
  final extra = [
    ...defined(const {'extra_revenue', 'stock_market_bonus'}),
    if (routeStep != null && routeStep.$2.contains('extra_revenue'))
      'extra_revenue in ${routeStep.$1}/step/route.rb',
  ];
  if (extra.isNotEmpty) {
    report.add(_Section.code,
        'earnings beyond the routes: ${extra.join(', ')} -- a company earns '
        'more than its trains\' runs (a bonus): add it where the app works out '
        'what a company earns (EndGame, the route panel)');
  }
  if (methods.containsKey('hex_train?') ||
      trains.whereType<Map>().any((t) => '${t['name']}'.endsWith('H'))) {
    report.add(_Section.code,
        'trains measured in hexes (hex_train?, or names ending in H): list '
        'them in _hexTrains (game_title.dart)');
  }
  final upgrades = defined(const {
    'upgrades_to?', 'upgrades_to_correct_label?', 'upgrades_to_correct_city_town?',
    'upgrades_to_correct_color?', 'all_potential_upgrades', 'legal_tile_rotation?',
  });
  if (upgrades.isNotEmpty) {
    report.add(_Section.code,
        'tile upgrades: ${upgrades.join(', ')} -- which tile may replace which '
        'differs from the usual rule: where a printed hex takes tiles it '
        'otherwise couldn\'t, add it to _specialUpgrades (game_title.dart)');
  }
  final market = defined(const {
    'init_stock_market', 'sold_out_increase?', 'share_price_change',
    'change_share_price', 'price_movement_chart',
  });
  if (market.isNotEmpty) {
    report.add(_Section.code,
        'stock market: ${market.join(', ')} -- prices may move by rules of the '
        'game\'s own: check MarketRules in _marketRules (game_title.dart), or '
        'stock_market.dart');
  }
  final ending = defined(const {
    'player_value', 'end_game!', 'init_loans', 'take_loan', 'calculate_interest',
    'loans_due_interest',
  });
  if (ending.isNotEmpty) {
    report.add(_Section.code,
        'the end of the game: ${ending.join(', ')} -- players may be worth more '
        'or less than cash and shares (loans, bonuses): the end-of-game table '
        'counts cash and shares only');
  }
  if (dividend != null) {
    final where = '$dividendFolder/step/dividend.rb';
    if (RegExp(r'def\s+(share_price_change|change_share_price)\b').hasMatch(dividend)) {
      report.add(_Section.code,
          'payouts: $where moves share prices its own way: read '
          'share_price_change, then set MarketRules.payoutMoves and '
          'withholdMoves in _marketRules (game_title.dart)');
    }
    if (RegExp(r'\bHalfPay\b').hasMatch(dividend) ||
        RegExp(r'DIVIDEND_TYPES[^\n]*\bhalf\b').hasMatch(dividend)) {
      report.add(_Section.code,
          'payouts: a company may pay half ($where): add the title to '
          '_halfPay (game_title.dart)');
    }
    if (dividend.contains('MinorHalfPay')) {
      report.add(_Section.code,
          'minors pay their owners half ($where): '
          'MarketRules(minorPayout: 0.5) in _marketRules');
    } else if (dividend.contains('MinorWithold')) {
      report.add(_Section.code,
          'minors keep what they earn ($where): '
          'MarketRules(minorPayout: 0) in _marketRules');
    } else if (minors > 0) {
      report.add(_Section.code,
          '$minors minors: they pay their owners everything unless '
          '_marketRules says otherwise -- check the rules');
    }
  } else if (minors > 0) {
    report.add(_Section.code,
        '$minors minors: they pay their owners everything unless _marketRules '
        'says otherwise -- check the rules');
  }
  if (steps != null) {
    const ordinary = {
      'dividend.rb', 'buy_sell_par_shares.rb', 'buy_train.rb', 'track.rb',
      'token.rb', 'route.rb', 'waterfall_auction.rb', 'buy_company.rb',
      'special_track.rb', 'special_token.rb', 'bankrupt.rb', 'discard_train.rb',
      'home_token.rb', 'track_and_token.rb', 'selection_auction.rb',
    };
    final unusual = steps.where((s) => !ordinary.contains(s)).toList();
    if (unusual.isNotEmpty) {
      report.add(_Section.code,
          'steps of its own beyond the usual: ${unusual.join(', ')} in '
          '$folder/step -- mostly turn order and buying, which '
          'the app doesn\'t follow; skim them for anything about routes, '
          'payouts or share values');
    }
  }
}

/// The parts of the report, in order.
enum _Section {
  about('The title'),
  tiles('Tiles and hexes'),
  trains('Trains, as the app will run them'),
  market('Stock market'),
  code('Rules in the game\'s code (game.rb, step/), which the app keeps by hand'),
  companies('Companies');

  final String heading;
  const _Section(this.heading);
}

/// What an import found that the app may not handle by itself.
class _Report {
  final _lines = <_Section, List<String>>{};

  void add(_Section section, String line) =>
      _lines.putIfAbsent(section, () => []).add(line);

  @override
  String toString() {
    final out = StringBuffer();
    for (final section in _Section.values) {
      final lines = _lines[section];
      if (lines == null) continue;
      out.writeln('\n${section.heading}:');
      for (final line in lines) {
        out.writeln('  - $line');
      }
    }
    return out.toString();
  }
}

/// One of tobymao's title folders: the files of [_files] it has.
class _Source {
  final String folder;
  final Map<String, String> files;

  /// The files in its `step` folder, where they could be listed.
  final List<String>? steps;

  _Source(this.folder, this.files, this.steps);

  static Future<_Source> load(_Upstream upstream, String folder) async {
    final files = <String, String>{};
    for (final name in _files) {
      final text = await upstream.read('game/$folder/$name');
      if (text != null) files[name] = text;
    }
    return _Source(folder, files, await upstream.list('game/$folder/step'));
  }

  /// Its module's name without the G: 1880 for G1880.
  String? get module =>
      RegExp(r'module\s+G([0-9A-Z]\w*)').firstMatch(files['meta.rb'] ?? files['game.rb'] ?? '')?.group(1);

  /// The title it's a variant of, by module name, if any.
  String? get parent => RegExp(r'class\s+Game\s*<\s*G([0-9A-Z]\w*)::Game\b')
      .firstMatch(files['game.rb'] ?? '')
      ?.group(1);
}

/// tobymao's title folders (`g_1880`), or null if they can't be listed.
Future<List<String>?> _titleFolders(_Upstream upstream) =>
    upstream._folders ??= upstream.list('game').then((names) => names == null
        ? null
        : (names.where((n) => n.startsWith('g_') && !n.contains('.')).toList()..sort()));

/// The folder of the title called [name], or null (having said why).
Future<String?> _folderFor(_Upstream upstream, String name) async {
  String key(String s) => s
      .toLowerCase()
      .replaceFirst(RegExp(r'^g_'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  final folders = await _titleFolders(upstream);
  if (folders == null) {
    final guess = 'g_${_snakeCase(name)}';
    if (upstream is! _Flat) {
      stderr.writeln('note: could not list the titles${upstream.why}; trying '
          '$guess');
    }
    return guess;
  }
  final wanted = key(name);
  for (final folder in folders) {
    if (key(folder) == wanted) return folder;
  }
  final near = [
    for (final folder in folders)
      if (key(folder).contains(wanted) ||
          (wanted.length >= 4 && key(folder).startsWith(wanted.substring(0, 4))))
        folder.substring(2),
  ];
  stderr.writeln('tobymao/18xx has no title $name.'
      '${near.isEmpty ? '' : ' Perhaps: ${near.join(', ')}'}'
      '\nSee them all with --list.');
  return null;
}

/// [name] as tobymao names a folder, as near as can be guessed:
/// 18Chesapeake as 18_chesapeake.
String _snakeCase(String name) => name
    .replaceFirst(RegExp(r'^[gG]_'), '')
    .replaceAllMapped(RegExp(r'(?<=[0-9])(?=[A-Za-z])|(?<=[a-z])(?=[A-Z0-9])'), (_) => '_')
    .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
    .toLowerCase();

/// Where tobymao/18xx's files come from.
abstract class _Upstream {
  /// The file at [path] under lib/engine (`game/g_1880/map.rb`), or null.
  Future<String?> read(String path);

  /// The names in the folder at [path] under lib/engine, or null if it
  /// can't be listed.
  Future<List<String>?> list(String path);

  /// Whether a title's variants can be followed to the titles they're
  /// variants of.
  bool get hasParents => true;

  /// Why the last thing asked for couldn't be had, as a clause.
  String get why => '';

  /// The title folders, once listed (see [_titleFolders]).
  Future<List<String>?>? _folders;
}

/// tobymao/18xx's master branch on GitHub.
class _GitHub extends _Upstream {
  static const _raw = 'https://raw.githubusercontent.com/tobymao/18xx/master/lib/engine';
  static const _api = 'https://api.github.com/repos/tobymao/18xx/contents/lib/engine';
  int? _status;

  @override
  Future<String?> read(String path) => _get('$_raw/$path');

  @override
  Future<List<String>?> list(String path) async {
    final body = await _get('$_api/$path');
    final entries = body == null ? null : jsonDecode(body);
    return entries is List
        ? [for (final e in entries) if (e is Map) '${e['name']}']
        : null;
  }

  @override
  String get why => switch (_status) {
        null || 200 => '',
        403 || 429 => ' (GitHub is limiting requests: try again in an hour, '
            'or use --from with a clone of tobymao/18xx)',
        404 => '',
        final status => ' (GitHub answered $status)',
      };

  Future<String?> _get(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      _status = response.statusCode;
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } on SocketException catch (e) {
      stderr.writeln('Could not reach GitHub: ${e.message}');
      return null;
    } finally {
      client.close();
    }
  }
}

/// A local clone of tobymao/18xx: [root] is its lib/engine.
class _Clone extends _Upstream {
  final String root;
  _Clone(this.root);

  @override
  Future<String?> read(String path) async {
    final file = File('$root/$path');
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<List<String>?> list(String path) async {
    final dir = Directory('$root/$path');
    return dir.existsSync()
        ? [for (final e in dir.listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)]
        : null;
  }
}

/// A folder holding one title's files -- map.rb, entities.rb and so on, a
/// step folder if wanted -- and config/tile.rb's tile.rb.
class _Flat extends _Upstream {
  final String dir;
  _Flat(this.dir);

  @override
  bool get hasParents => false;

  @override
  Future<String?> read(String path) async {
    final local = path == 'config/tile.rb'
        ? 'tile.rb'
        : path.split('/').skip(2).join('/');
    final file = File('$dir/$local');
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<List<String>?> list(String path) async {
    if (!path.endsWith('/step')) return null;
    final steps = Directory('$dir/step');
    return steps.existsSync()
        ? [for (final e in steps.listSync()) e.uri.pathSegments.last]
        : null;
  }
}

String _dartString(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');
  return "'$escaped'";
}

/// The constants assigned at the top level of a Ruby file (`NAME = value`),
/// where each value is a literal: hashes, arrays, `%w[]` word lists,
/// strings, numbers, symbols, booleans and nil.
class RubyConstants {
  final Map<String, Object?> values;

  /// The constants assigned something other than a literal, or a literal
  /// this reader doesn't follow, with why.
  final Map<String, String> unread;

  RubyConstants(this.values, [this.unread = const {}]);

  Object? operator [](String name) => values[name];

  static RubyConstants parse(String source) {
    final tokens = _Tokenizer(source).tokenize();
    final values = <String, Object?>{};
    final unread = <String, String>{};
    for (int i = 0; i + 2 < tokens.length; i++) {
      final t = tokens[i];
      if (t.kind == _T.ident &&
          RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(t.text) &&
          tokens[i + 1].kind == _T.punct &&
          tokens[i + 1].text == '=') {
        final parser = _Parser(tokens, i + 2);
        try {
          values[t.text] = parser.value();
          i = parser.pos - 1;
        } on FormatException catch (e) {
          // Not a literal (a method call or expression): not data we need,
          // unless it's one of the constants the import reads.
          unread[t.text] = e.message;
        }
      }
    }
    return RubyConstants(values, unread);
  }
}

enum _T { string, words, number, ident, symbol, punct }

class _Token {
  final _T kind;
  final String text;
  final List<String>? words;
  const _Token(this.kind, this.text, [this.words]);
  @override
  String toString() => '$kind:$text';
}

class _Tokenizer {
  final String s;
  int i = 0;
  _Tokenizer(this.s);

  List<_Token> tokenize() {
    final out = <_Token>[];
    while (i < s.length) {
      final c = s[i];
      if (c == '#') {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\\') {
        // A trailing backslash continues a line; adjacent strings are joined
        // below.
        i++;
      } else if (c == "'" || c == '"') {
        final text = _quoted(c);
        if (i < s.length && s[i] == ':' && (i + 1 >= s.length || s[i + 1] != ':')) {
          // A quoted key (`'pre-sbb': 2`), as Ruby writes a symbol key that
          // isn't a plain word.
          out.add(_Token(_T.symbol, text));
          out.add(const _Token(_T.punct, '=>'));
          i++;
        } else if (out.isNotEmpty && out.last.kind == _T.string) {
          out[out.length - 1] = _Token(_T.string, out.last.text + text);
        } else {
          out.add(_Token(_T.string, text));
        }
      } else if (c == '%' && i + 2 < s.length && (s[i + 1] == 'w' || s[i + 1] == 'i')) {
        final open = s[i + 2];
        final close = switch (open) { '[' => ']', '(' => ')', '{' => '}', _ => open };
        final end = s.indexOf(close, i + 3);
        final body = s.substring(i + 3, end);
        out.add(_Token(_T.words, body,
            body.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList()));
        i = end + 1;
      } else if (RegExp(r'[0-9-]').hasMatch(c) &&
          (c != '-' || (i + 1 < s.length && RegExp(r'[0-9]').hasMatch(s[i + 1])))) {
        final start = i;
        i++;
        while (i < s.length && RegExp(r'[0-9._]').hasMatch(s[i])) {
          i++;
        }
        out.add(_Token(_T.number, s.substring(start, i).replaceAll('_', '')));
      } else if (c == ':' && i + 1 < s.length && (s[i + 1] == "'" || s[i + 1] == '"')) {
        // A quoted symbol: `color: :'#FF0000'` (1846's).
        i++;
        out.add(_Token(_T.symbol, _quoted(s[i])));
      } else if (c == ':' && i + 1 < s.length && RegExp(r'[a-zA-Z_]').hasMatch(s[i + 1])) {
        final start = ++i;
        while (i < s.length && RegExp(r'[a-zA-Z0-9_?!]').hasMatch(s[i])) {
          i++;
        }
        out.add(_Token(_T.symbol, s.substring(start, i)));
      } else if (RegExp(r'[a-zA-Z_]').hasMatch(c)) {
        final start = i;
        while (i < s.length && RegExp(r'[a-zA-Z0-9_?!]').hasMatch(s[i])) {
          i++;
        }
        final word = s.substring(start, i);
        // `key: value` hash shorthand: the colon belongs to the key.
        if (i < s.length && s[i] == ':' && (i + 1 >= s.length || s[i + 1] != ':')) {
          i++;
          out.add(_Token(_T.symbol, word));
          out.add(const _Token(_T.punct, '=>'));
        } else {
          out.add(_Token(_T.ident, word));
        }
      } else if (c == '=' && i + 1 < s.length && s[i + 1] == '>') {
        out.add(const _Token(_T.punct, '=>'));
        i += 2;
      } else {
        out.add(_Token(_T.punct, c));
        i++;
      }
    }
    return out;
  }

  String _quoted(String quote) {
    final buffer = StringBuffer();
    i++;
    while (i < s.length && s[i] != quote) {
      if (s[i] == '\\' && i + 1 < s.length) {
        buffer.write(s[i + 1]);
        i += 2;
      } else {
        buffer.write(s[i]);
        i++;
      }
    }
    i++;
    return buffer.toString();
  }
}

class _Parser {
  final List<_Token> t;
  int pos;
  _Parser(this.t, this.pos);

  _Token get _peek => t[pos];

  bool _isPunct(String p) => pos < t.length && t[pos].kind == _T.punct && t[pos].text == p;

  Object? value() {
    var v = _atom();
    while (true) {
      // Trailing `.freeze` and similar method calls on a literal.
      if (_isPunct('.') && pos + 1 < t.length && t[pos + 1].kind == _T.ident) {
        pos += 2;
        continue;
      }
      // Arrays joined: `[''] + %w[54y 57y]` (1854's stock market).
      if (_isPunct('+') && v is List) {
        pos++;
        final next = _atom();
        if (next is! List) throw const FormatException('expected an array');
        v = [...v, ...next];
        continue;
      }
      return v;
    }
  }

  Object? _atom() {
    if (pos >= t.length) throw const FormatException('end of input');
    final tok = _peek;
    switch (tok.kind) {
      case _T.string:
        pos++;
        return tok.text;
      case _T.words:
        pos++;
        return tok.words;
      case _T.number:
        pos++;
        return num.parse(tok.text);
      case _T.symbol:
        pos++;
        return tok.text;
      case _T.ident:
        pos++;
        return switch (tok.text) {
          'true' => true,
          'false' => false,
          'nil' => null,
          _ => throw FormatException('not a literal: ${tok.text}'),
        };
      case _T.punct:
        if (tok.text == '{') return _hash();
        if (tok.text == '[') return _array();
        throw FormatException('unexpected ${tok.text}');
    }
  }

  Map<Object?, Object?> _hash() {
    pos++; // {
    final result = <Object?, Object?>{};
    while (!_isPunct('}')) {
      final key = value();
      if (!_isPunct('=>')) throw const FormatException('expected =>');
      pos++;
      result[key is List ? List<Object?>.of(key) : key] = value();
      if (_isPunct(',')) pos++;
    }
    pos++; // }
    return result;
  }

  List<Object?> _array() {
    pos++; // [
    final result = <Object?>[];
    while (!_isPunct(']')) {
      result.add(value());
      if (_isPunct(',')) pos++;
    }
    pos++; // ]
    return result;
  }
}
