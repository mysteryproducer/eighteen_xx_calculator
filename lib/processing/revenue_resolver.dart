import '../models/board.dart';
import '../models/board_graph.dart';
import 'revenue_ocr.dart';

/// Decides where each station's revenue comes from.
///
/// A confidently recognized tile already carries its revenue in the tile data,
/// which is more reliable than reading small print off a photo, so the tile is
/// used first. The photo is the fallback for stations whose tile match is
/// doubtful. Anything the user types beats both.
class RevenueResolver {
  RevenueResolver._();

  /// Stations that should have their revenue read off the photo: the tile
  /// under them wasn't recognized confidently, and the user hasn't set a value.
  static List<StationNode> stationsNeedingPhoto(
    BoardGraph graph, {
    required bool Function(HexCoord hex) isTileTrusted,
    required Map<String, int> manual,
  }) =>
      [
        for (final station in graph.stations)
          if (!manual.containsKey(station.id) && !isTileTrusted(station.hex))
            station,
      ];

  /// Sets [StationNode.revenue] and [StationNode.revenueSource] on every
  /// station in [graph]. Expects a freshly built graph, whose revenues are
  /// still the tile values.
  static void apply(
    BoardGraph graph, {
    required bool Function(HexCoord hex) isTileTrusted,
    required Map<String, int> manual,
    required Map<String, RevenueReading> readings,
  }) {
    for (final station in graph.stations) {
      final typed = manual[station.id];
      if (typed != null) {
        station.revenue = typed;
        station.revenueSource = RevenueSource.manual;
      } else if (isTileTrusted(station.hex)) {
        station.revenueSource = RevenueSource.tile;
      } else if (readings[station.id]?.value case final read?) {
        station.revenue = read;
        station.revenueSource = RevenueSource.photo;
      } else {
        station.revenueSource = RevenueSource.unverified;
      }
    }
  }
}
