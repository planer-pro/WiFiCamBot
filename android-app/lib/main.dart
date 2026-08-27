import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_settings.dart';
import 'screens/lock_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  runApp(WifiCamBotApp(store: SettingsStore(prefs)));
}

class WifiCamBotApp extends StatelessWidget {
  const WifiCamBotApp({super.key, required this.store});

  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    // тёмная тема — видеопульт
    return MaterialApp(
      title: 'WiFiCamBot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF00A0FF),
        useMaterial3: true,
      ),
      home: LockScreen(store: store),
    );
  }
}
