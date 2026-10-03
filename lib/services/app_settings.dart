import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Preferences that belong to the device rather than to a game, kept in a
/// small JSON file beside the saved games.
class AppSettings {
  final Future<File> Function() _file;

  AppSettings({Future<File> Function()? file}) : _file = file ?? _defaultFile;

  /// The one the app uses. Tests swap in their own.
  static AppSettings shared = AppSettings();

  static Future<File> _defaultFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  /// How strongly the tiles already on the board are drawn over the camera
  /// preview of a close-up, 0..1. Half is what stop-motion apps use for
  /// lining a shot up with the last one: enough to aim by, not so much that
  /// it hides the board.
  final ValueNotifier<double> overlayOpacity =
      ValueNotifier(defaultOverlayOpacity);

  static const double defaultOverlayOpacity = 0.5;

  /// Whether the hexes to drag on the align screen are labelled by the place
  /// printed there (`Sukumo`) rather than by grid reference (`A10`): a board
  /// like 1889's prints only names.
  final ValueNotifier<bool> labelAnchorsByName = ValueNotifier(true);

  bool _loaded = false;

  /// Reads the saved settings, once; anything unreadable keeps its default.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      final opacity = json['overlayOpacity'];
      if (opacity is num) overlayOpacity.value = opacity.toDouble().clamp(0.0, 1.0);
      final byName = json['labelAnchorsByName'];
      if (byName is bool) labelAnchorsByName.value = byName;
    } catch (e) {
      debugPrint('Could not read settings: $e');
    }
  }

  Future<void> setOverlayOpacity(double value) async {
    overlayOpacity.value = value.clamp(0.0, 1.0);
    await _save();
  }

  Future<void> setLabelAnchorsByName(bool value) async {
    labelAnchorsByName.value = value;
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'overlayOpacity': overlayOpacity.value,
        'labelAnchorsByName': labelAnchorsByName.value,
      }));
    } catch (e) {
      debugPrint('Could not save settings: $e');
    }
  }
}
