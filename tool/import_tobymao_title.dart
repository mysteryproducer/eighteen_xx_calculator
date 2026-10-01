// Generates a title's map and tile data from tobymao/18xx
// (https://github.com/tobymao/18xx, MIT licensed), the engine behind
// 18xx.games.
//
//   dart run tool/import_tobymao_title.dart 1844
//
// fetches lib/engine/game/g_1844/{map,tiles,meta,entities}.rb and the shared
// lib/engine/config/tile.rb, and writes lib/titles/title_1844.dart. The Ruby
// files are plain constant hashes, so a small reader for Ruby literals is
// enough; nothing is executed.
//
// Pass `--from <dir>` to read map.rb, tiles.rb, meta.rb, entities.rb and
// tile.rb from a local directory instead of fetching them.
import 'dart:convert';
import 'dart:io';

const _base = 'https://raw.githubusercontent.com/tobymao/18xx/master/lib/engine';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/import_tobymao_title.dart <title> '
        '[--from <dir>]');
    exit(64);
  }
  final title = args.first;
  final fromIndex = args.indexOf('--from');
  final fromDir = fromIndex >= 0 && fromIndex + 1 < args.length
      ? args[fromIndex + 1]
      : null;

  Future<String?> load(String name, String url) async {
    if (fromDir != null) {
      final file = File('$fromDir/$name');
      return file.existsSync() ? file.readAsString() : null;
    }
    return _fetch(url);
  }

  final gameDir = '$_base/game/g_$title';
  final mapSource = await load('map.rb', '$gameDir/map.rb');
  if (mapSource == null) {
    stderr.writeln('No map.rb found for $title');
    exit(1);
  }
  final tilesSource = await load('tiles.rb', '$gameDir/tiles.rb');
  final metaSource = await load('meta.rb', '$gameDir/meta.rb');
  final entitiesSource = await load('entities.rb', '$gameDir/entities.rb');
  final standardSource = await load('tile.rb', '$_base/config/tile.rb');
  if (standardSource == null) {
    stderr.writeln('Could not load the standard tile list (config/tile.rb)');
    exit(1);
  }

  final map = RubyConstants.parse(mapSource);
  final tiles = tilesSource == null ? map : RubyConstants.parse(tilesSource);
  final standard = RubyConstants.parse(standardSource);
  final meta = metaSource == null ? RubyConstants({}) : RubyConstants.parse(metaSource);
  final entities = entitiesSource == null
      ? RubyConstants({})
      : RubyConstants.parse(entitiesSource);

  if (map['LAYOUT'] != 'pointy') {
    stderr.writeln('$title uses a ${map['LAYOUT']} layout; only pointy-top '
        'maps are supported so far.');
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
  final manifest = tiles['TILES'];
  if (manifest is! Map) {
    stderr.writeln('No TILES manifest found for $title');
    exit(1);
  }
  manifest.forEach((id, spec) {
    String color;
    String code;
    int count;
    bool hidden = false;
    if (spec is Map) {
      count = (spec['count'] as num?)?.toInt() ?? 1;
      hidden = spec['hidden'] == true;
      final standardTile = standardTiles['$id'];
      color = (spec['color'] as String?) ?? standardTile?.$1 ?? 'yellow';
      code = (spec['code'] as String?) ?? standardTile?.$2 ?? '';
    } else {
      count = (spec as num).toInt();
      final standardTile = standardTiles['$id'];
      if (standardTile == null) {
        stderr.writeln('warning: tile $id is not in config/tile.rb; skipped');
        return;
      }
      (color, code) = standardTile;
    }
    // Tiles marked hidden are laid by the game itself rather than by a
    // player -- 1844's Gotthard tunnel opening, say -- but they do appear on
    // the board, so they are imported and marked.
    tileEntries.add("    TileData('$id', '$color', ${_dartString(code)}, "
        "count: $count${hidden ? ', laidByGame: true' : ''}),");
  });

  final names = (map['LOCATION_NAMES'] as Map?) ?? {};
  final hexEntries = <String>[];
  final hexes = map['HEXES'];
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
        final dsl = code == 'blank' ? '' : '$code';
        hexEntries.add("    MapHexData('$id', '$color', ${_dartString(dsl)}$nameArg),");
      }
    });
  });

  // The companies whose station tokens go on the board, with their token
  // colours and home cities, for recognising tokens in photos.
  final companyEntries = <String>[];
  void addCompany(Map company) {
    final sym = company['sym'];
    if (sym == null) return;
    var home = company['coordinates'];
    if (home is List) home = home.isEmpty ? null : home.first;
    final city = (company['city'] as num?)?.toInt();
    final text = company['text_color'] as String?;
    final kind = company['type'] as String?;
    companyEntries.add("    CompanyData('$sym', "
        "${_dartString('${company['name'] ?? sym}')}, "
        "${_dartString('${company['color'] ?? 'white'}')}"
        "${text == null ? '' : ', textColor: ${_dartString(text)}'}"
        "${home == null ? '' : ", home: '$home'"}"
        "${city == null ? '' : ', homeCity: $city'}"
        "${kind == null ? '' : ', kind: ${_dartString(kind)}'}),");
  }

  for (final list in [entities['CORPORATIONS'], entities['MINORS']]) {
    if (list is! List) continue;
    for (final company in list) {
      if (company is Map) addCompany(company);
    }
  }
  // 1854 builds its local railways in code from three parallel lists rather
  // than writing them out; the lists themselves are plain data.
  final localNames = entities['LOCAL_NAMES'];
  final localHomes = entities['LOCAL_COORDINATES'];
  final localCities = entities['LOCAL_CITIES'];
  if (entities['MINORS'] is! List &&
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
  }

  // 1844's tunnels: the hexes a tunnel company may tunnel through, and the
  // tiles whose narrow track shows which ways a tunnel can run.
  final tunnelHexes = entities['TUNNEL_HEXES'];
  final tunnelTiles = entities['TUNNEL_TILES'];
  // And its mountain railways: the mountains a revenue plate can be assigned
  // to, and the plates.
  final mountainHexes = entities['MOUNTAIN_HEXES'];
  final mountainTiles = entities['MOUNTAIN_TILES'];
  String words(Object? list) =>
      list is List ? list.map((w) => "'$w'").join(', ') : '';

  final location = meta['GAME_LOCATION'] as String?;
  final designer = meta['GAME_DESIGNER'] as String?;
  final out = StringBuffer()
    ..writeln('// GENERATED by tool/import_tobymao_title.dart from tobymao/18xx')
    ..writeln('// (https://github.com/tobymao/18xx, MIT licensed). Do not edit by')
    ..writeln('// hand: fix the importer or the upstream data and regenerate.')
    ..writeln()
    ..writeln("import 'title_data.dart';")
    ..writeln()
    ..writeln('const TitleData title$title = TitleData(')
    ..writeln("  id: '$title',")
    ..writeln("  name: '$title',")
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
    ..writeln(');');

  final path = 'lib/titles/title_$title.dart';
  File(path).writeAsStringSync(out.toString());
  stdout.writeln('Wrote $path: ${hexEntries.length} hexes, '
      '${tileEntries.length} tiles, ${companyEntries.length} companies.');
}

Future<String?> _fetch(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
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
  RubyConstants(this.values);

  Object? operator [](String name) => values[name];

  static RubyConstants parse(String source) {
    final tokens = _Tokenizer(source).tokenize();
    final values = <String, Object?>{};
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
        } on FormatException {
          // Not a literal (a method call or expression): not data we need.
        }
      }
    }
    return RubyConstants(values);
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
        if (out.isNotEmpty && out.last.kind == _T.string) {
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
    final v = _atom();
    // Trailing `.freeze` and similar method calls on a literal.
    while (_isPunct('.') && pos + 1 < t.length && t[pos + 1].kind == _T.ident) {
      pos += 2;
    }
    return v;
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
