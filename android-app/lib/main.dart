import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_settings.dart';
import 'core/l10n.dart';
import 'screens/lock_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final SettingsStore store = SettingsStore(prefs);
  // язык выбирается в настройках («Приложение»), до этого — сохранённый
  localeNotifier.value = store.locale;
  runApp(WifiCamBotApp(store: store));
}

class WifiCamBotApp extends StatefulWidget {
  const WifiCamBotApp({super.key, required this.store});

  final SettingsStore store;

  @override
  State<WifiCamBotApp> createState() => _WifiCamBotAppState();
}

class _WifiCamBotAppState extends State<WifiCamBotApp> {
  @override
  void initState() {
    super.initState();
    // смена языка в настройках перестраивает всё дерево (строки берутся
    // из L10n над MaterialApp)
    localeNotifier.addListener(_onLocale);
  }

  @override
  void dispose() {
    localeNotifier.removeListener(_onLocale);
    super.dispose();
  }

  void _onLocale() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // тёмная тема — видеопульт; строки — L10n над MaterialApp
    return L10n(
      locale: localeNotifier.value,
      child: MaterialApp(
        title: 'WiFiCamBot',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF00A0FF),
          useMaterial3: true,
        ),
        home: LockScreen(store: widget.store),
      ),
    );
  }
}
