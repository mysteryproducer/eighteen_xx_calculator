import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// One hex as photographed, with what it actually held.
class LabelledHex {
  /// The title and printed hex the picture came from.
  final String titleId;
  final String hexId;

  /// What was really there: a tile id, or null for the bare map.
  final String? tileId;
  final int rotation;

  /// What recognition had said, and how sure it was -- so a later look can
  /// tell the cases it got wrong from the ones it merely doubted.
  final String? readAsTileId;
  final int? readAsRotation;
  final double readConfidence;

  final DateTime when;

  /// File name of the picture beside the log.
  final String picture;

  const LabelledHex({
    required this.titleId,
    required this.hexId,
    required this.tileId,
    required this.rotation,
    required this.readAsTileId,
    required this.readAsRotation,
    required this.readConfidence,
    required this.when,
    required this.picture,
  });

  bool get wasRight =>
      readAsTileId == tileId && (tileId == null || readAsRotation == rotation);

  Map<String, Object?> toJson() => {
        'title': titleId,
        'hex': hexId,
        'tile': tileId,
        'rotation': rotation,
        'readAs': readAsTileId,
        'readAsRotation': readAsRotation,
        'confidence': readConfidence,
        'when': when.toIso8601String(),
        'picture': picture,
        'right': wasRight,
      };

  static LabelledHex fromJson(Map<String, Object?> json) => LabelledHex(
        titleId: json['title'] as String,
        hexId: json['hex'] as String,
        tileId: json['tile'] as String?,
        rotation: (json['rotation'] as num?)?.toInt() ?? 0,
        readAsTileId: json['readAs'] as String?,
        readAsRotation: (json['readAsRotation'] as num?)?.toInt(),
        readConfidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        when: DateTime.parse(json['when'] as String),
        picture: json['picture'] as String,
      );
}

/// Keeps the hexes the user has corrected, with the pictures they were read
/// from.
///
/// Every correction is a labelled example of a real board under real light,
/// which is the one kind of training data that can't be synthesised. The app
/// already squares up and saves a picture of every hex it reads; this records
/// what that hex turned out to hold, so the set grows by itself while the
/// game is played. Nothing is sent anywhere -- it is a folder on the device,
/// there to be copied off when there is enough of it to be worth training on.
class TrainingLog {
  final Future<Directory> Function() _root;

  TrainingLog({Future<Directory> Function()? root}) : _root = root ?? _defaultRoot;

  static Future<Directory> _defaultRoot() async => Directory(
      '${(await getApplicationDocumentsDirectory()).path}/training');

  /// Records that [hexId] really held [tileId] turned [rotation], with the
  /// picture it was read from.
  Future<void> record(
    LabelledHex label,
    Uint8List picture,
  ) async {
    final dir = await _root();
    await Directory('${dir.path}/pictures').create(recursive: true);
    await File('${dir.path}/pictures/${label.picture}').writeAsBytes(picture);
    await File('${dir.path}/labels.jsonl').writeAsString(
      '${jsonEncode(label.toJson())}\n',
      mode: FileMode.append,
    );
  }

  /// A file name that won't collide: the game, the hex and the moment.
  static String pictureName(String sessionId, String hexId, DateTime when) =>
      '$sessionId-$hexId-${when.millisecondsSinceEpoch}.png';

  /// Everything recorded so far, oldest first.
  Future<List<LabelledHex>> entries() async {
    final file = File('${(await _root()).path}/labels.jsonl');
    if (!await file.exists()) return [];
    final entries = <LabelledHex>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        entries.add(LabelledHex.fromJson(
            (jsonDecode(line) as Map).cast<String, Object?>()));
      } on FormatException {
        // A half-written last line: skip it rather than lose the rest.
      }
    }
    return entries;
  }

  /// How many examples are banked, and how many of them recognition had got
  /// wrong -- the pair worth showing someone deciding whether to train.
  Future<(int, int)> tally() async {
    final all = await entries();
    return (all.length, all.where((e) => !e.wasRight).length);
  }

  Future<Directory> directory() => _root();
}
