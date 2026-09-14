import 'package:flutter/material.dart';

/// A railway company on the board, identified by its station token colour.
///
/// Real 18xx titles each have their own company list and livery; until the app
/// carries per-title data, companies are just the common token colours, and the
/// user picks whichever matches the company they're calculating for. Names are
/// editable so a player can relabel "Blue" as, say, "B&O".
class Company {
  final String id;
  final String name;
  final Color color;

  const Company({required this.id, required this.name, required this.color});

  Company copyWith({String? name}) =>
      Company(id: id, name: name ?? this.name, color: color);

  /// The default palette: distinct colours that survive being photographed.
  static const List<Company> defaults = [
    Company(id: 'red', name: 'Red', color: Color(0xFFD32F2F)),
    Company(id: 'blue', name: 'Blue', color: Color(0xFF1976D2)),
    Company(id: 'green', name: 'Green', color: Color(0xFF388E3C)),
    Company(id: 'yellow', name: 'Yellow', color: Color(0xFFFBC02D)),
    Company(id: 'orange', name: 'Orange', color: Color(0xFFF57C00)),
    Company(id: 'purple', name: 'Purple', color: Color(0xFF7B1FA2)),
    Company(id: 'black', name: 'Black', color: Color(0xFF212121)),
    Company(id: 'white', name: 'White', color: Color(0xFFFAFAFA)),
  ];

  static Company? byId(String? id, [List<Company> from = defaults]) {
    if (id == null) return null;
    for (final c in from) {
      if (c.id == id) return c;
    }
    return null;
  }
}
