import 'dart:io';

import 'package:eighteen_xx_calculator/services/training_log.dart';
import 'package:flutter/foundation.dart';

/// A training log that keeps everything in memory and answers immediately,
/// so a widget test can check the app banks a correction without the fake
/// clock having to drive real file writes.
class FakeTrainingLog implements TrainingLog {
  final List<LabelledHex> banked = [];
  final List<Uint8List> pictures = [];

  @override
  Future<void> record(LabelledHex label, Uint8List picture) {
    banked.add(label);
    pictures.add(picture);
    return SynchronousFuture(null);
  }

  @override
  Future<List<LabelledHex>> entries() => SynchronousFuture(banked);

  @override
  Future<(int, int)> tally() =>
      SynchronousFuture((banked.length, banked.where((e) => !e.wasRight).length));

  @override
  Future<Directory> directory() => SynchronousFuture(Directory.systemTemp);
}
