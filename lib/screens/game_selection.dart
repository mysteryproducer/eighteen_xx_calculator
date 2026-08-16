import 'package:flutter/material.dart';
import 'camera_capture.dart';

class GameSelection extends StatelessWidget {
  const GameSelection({Key? key}) : super(key: key);

  static final List<Map<String, dynamic>> demoGames = [
    {
      'id': '18xx_example',
      'name': '18xx Example Set',
      'description': 'Demo tile set and board for prototyping.',
    },
    {
      'id': '18xx_standard',
      'name': '18xx Standard',
      'description': 'Common tile set (placeholder).',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select 18xx Title')),
      body: ListView.builder(
        itemCount: demoGames.length,
        itemBuilder: (context, index) {
          final game = demoGames[index];
          return ListTile(
            title: Text(game['name']),
            subtitle: Text(game['description']),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) {
                return CameraCapture(game: game);
              }));
            },
          );
        },
      ),
    );
  }
}
