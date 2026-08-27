import 'dart:async';

import 'package:flutter/services.dart';

/// События физического геймпада, подключённого к телефону
/// (Bluetooth/USB — для Android это просто устройство ввода).
/// Реализация канала — MainActivity.kt ('wificambot/gamepad').
class GamepadEvent {
  const GamepadEvent.axes(this.x, this.y)
      : devicesChanged = false,
        names = const [];

  const GamepadEvent.devices(this.names)
      : devicesChanged = true,
        x = 0,
        y = 0;

  /// true — изменился список подключённых геймпадов (names).
  final bool devicesChanged;
  final List<String> names;

  /// Левый стик: x вправо, y вниз (экранная система, как в веб-версии).
  final double x, y;
}

/// Подписка на события геймпадов.
class GamepadSource {
  static const EventChannel _ch = EventChannel('wificambot/gamepad');

  Stream<GamepadEvent>? _stream;

  Stream<GamepadEvent> events() =>
      _stream ??= _ch.receiveBroadcastStream().map((dynamic raw) {
        final Map<dynamic, dynamic> m = raw as Map<dynamic, dynamic>;
        if (m['type'] == 'devices') {
          return GamepadEvent.devices(
              (m['names'] as List<dynamic>).cast<String>());
        }
        return GamepadEvent.axes(
            (m['x'] as num).toDouble(), (m['y'] as num).toDouble());
      });
}
