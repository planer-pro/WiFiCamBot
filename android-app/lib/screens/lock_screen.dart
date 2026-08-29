import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../core/l10n.dart';
import 'main_screen.dart';

/// Вход в приложение по паролю (стандартный — 1234, меняется в настройках).
/// Пароль ТОЛЬКО цифровой — ввод с собственного крупного пада, системная
/// клавиатура не вызывается вовсе (поле ввода не создаётся).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.store});

  final SettingsStore store;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  static const int _pinMax = 12;

  String _pin = '';
  String? _error;

  void _digit(int d) {
    HapticFeedback.selectionClick();
    if (_pin.length >= _pinMax) {
      return;
    }
    setState(() {
      _pin += '$d';
      _error = null;
    });
  }

  void _backspace() {
    if (_pin.isEmpty) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  Future<void> _login() async {
    if (_pin.isEmpty) {
      return;
    }
    final bool ok = await widget.store.checkPin(_pin);
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MainScreen(store: widget.store)),
      );
    } else {
      HapticFeedback.vibrate();
      setState(() {
        _error = L10n.of(context).wrongPin;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Strings s = L10n.of(context);
    final bool firstRun = !widget.store.hasCustomPin;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // на низких ландшафтных экранах пад не обрезается — скролл
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.smart_toy_outlined, size: 64),
                    const SizedBox(height: 8),
                    Text(
                      'WiFiCamBot',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 28),
                    Text(
                      s.enterPin,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    _PinDots(count: _pin.length, max: _pinMax),
                    // место под ошибку зарезервировано — пад не прыгает
                    SizedBox(
                      height: 24,
                      child: _error == null
                          ? null
                          : Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                    ),
                    _Keypad(
                      s: s,
                      pin: _pin,
                      onDigit: _digit,
                      onBackspace: _backspace,
                      onSubmit: _login,
                    ),
                    if (firstRun) ...[
                      const SizedBox(height: 20),
                      Text(
                        s.defaultPinHint,
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
      ),
    );
  }
}

/// Введённые цифры — точки (одна на символ), как на экранах блокировки.
class _PinDots extends StatelessWidget {
  const _PinDots({required this.count, required this.max});

  final int count;
  final int max;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (int i = 0; i < max && i < count; i++)
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

/// Крупный цифровой пад: 1–9, ⌫, 0 и «войти» (✓).
class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.s,
    required this.pin,
    required this.onDigit,
    required this.onBackspace,
    required this.onSubmit,
  });

  final Strings s;
  final String pin;
  final void Function(int d) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  static const List<List<String>> _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['del', '0', 'ok'],
  ];

  Widget _key(BuildContext context, String k) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget icon;
    final VoidCallback? tap;
    final String semantic;
    final bool accent;
    switch (k) {
      case 'del':
        icon = Icon(Icons.backspace_outlined, size: 28, color: cs.primary);
        tap = pin.isEmpty ? null : onBackspace;
        semantic = s.eraseKey;
        accent = false;
      case 'ok':
        icon = Icon(
          Icons.check_rounded,
          size: 30,
          color: pin.isEmpty ? null : cs.onPrimary,
        );
        tap = pin.isEmpty ? null : onSubmit;
        semantic = s.signIn;
        accent = true;
      default:
        icon = Text(
          k,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
        );
        tap = () => onDigit(int.parse(k));
        semantic = k;
        accent = false;
    }
    return _PadKey(
      onTap: tap,
      semanticLabel: semantic,
      accent: accent,
      child: icon,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final List<String> row in _rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final String k in row) ...[
                  _key(context, k),
                  if (k != row.last) const SizedBox(width: 16),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Клавиша пада: крупный квадрат со скруглением, нажатие с всплеском.
class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.onTap,
    required this.child,
    required this.semanticLabel,
    this.accent = false,
  });

  final VoidCallback? onTap;
  final Widget child;
  final String semanticLabel;

  /// Акцентная клавиша («войти») — залита основным цветом темы.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        width: 76,
        height: 64,
        child: Material(
          color: accent && onTap != null
              ? cs.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
