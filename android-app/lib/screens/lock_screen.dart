import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import 'main_screen.dart';

/// Вход в приложение по паролю (стандартный — 1234, меняется в настройках).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.store});

  final SettingsStore store;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final bool ok = await widget.store.checkPin(_pin.text);
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MainScreen(store: widget.store)),
      );
    } else {
      setState(() => _error = 'Неверный пароль');
      _pin.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool firstRun = !widget.store.hasCustomPin;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.smart_toy_outlined, size: 72),
                  const SizedBox(height: 8),
                  Text(
                    'WiFiCamBot',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pin,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Пароль',
                      errorText: _error,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                    ),
                    onSubmitted: (_) => _login(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _login,
                    icon: const Icon(Icons.login),
                    label: const Text('Войти'),
                  ),
                  if (firstRun) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Стандартный пароль: 1234\n(меняется в настройках)',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
