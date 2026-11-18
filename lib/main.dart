import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ShelfVisionApp());
}

class ShelfVisionApp extends StatelessWidget {
  const ShelfVisionApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Shelf Vision',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2979FF), brightness: Brightness.dark, useMaterial3: true),
        home: const CameraScreen(),
      );
}
