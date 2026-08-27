import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальные настройки приложения: адрес робота и пароль входа.
/// (Настройки самого робота — в models/robot_settings.dart.)
class AppSettings {
  const AppSettings({this.baseUrl = '', this.streamPort = 81, this.streamUrl = ''});

  /// Базовый адрес робота: «http://192.168.1.137» или «192.168.1.137»
  /// (без схемы считается http). Для доступа извне локальной сети —
  /// внешний адрес/туннель (например «https://robot.myhome3.netcraze.link»).
  final String baseUrl;

  /// Порт MJPEG-стрима (у робота 81; для внешнего доступа прокидывается
  /// отдельно, как в tunnel.sh). Игнорируется, если задан [streamUrl].
  final int streamPort;

  /// Полный URL стрима для доступа извне, где стрим живёт на отдельном
  /// адресе (облако Keenetic: «https://stream.myhome3.netcraze.link»).
  /// Пусто — стрим берётся с хоста робота на порт [streamPort].
  final String streamUrl;

  bool get hasAddress => baseUrl.trim().isNotEmpty;

  /// Адрес с нормализованной схемой.
  Uri get baseUri {
    var s = baseUrl.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    return Uri.parse(s);
  }

  /// URL стрима: полный override, если задан (без пути — дописываем
  /// «/stream»), иначе тот же хост, порт стрима.
  Uri get streamUri {
    var s = streamUrl.trim();
    if (s.isEmpty) {
      return baseUri.replace(port: streamPort, path: '/stream');
    }
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    final Uri u = Uri.parse(s);
    return u.path.isEmpty ? u.replace(path: '/stream') : u;
  }

  AppSettings copyWith({String? baseUrl, int? streamPort, String? streamUrl}) =>
      AppSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        streamPort: streamPort ?? this.streamPort,
        streamUrl: streamUrl ?? this.streamUrl,
      );
}

/// Хранение локальных настроек (SharedPreferences) и пароля входа.
class SettingsStore {
  SettingsStore(this._prefs);

  static const String defaultPin = '1234';

  static const String _kBaseUrl = 'base_url';
  static const String _kStreamPort = 'stream_port';
  static const String _kStreamUrl = 'stream_url';
  static const String _kSalt = 'pin_salt';
  static const String _kPinHash = 'pin_hash';

  final SharedPreferences _prefs;

  AppSettings get settings => AppSettings(
        baseUrl: _prefs.getString(_kBaseUrl) ?? '',
        streamPort: _prefs.getInt(_kStreamPort) ?? 81,
        streamUrl: _prefs.getString(_kStreamUrl) ?? '',
      );

  Future<void> saveSettings(AppSettings s) async {
    await _prefs.setString(_kBaseUrl, s.baseUrl.trim());
    await _prefs.setInt(_kStreamPort, s.streamPort);
    await _prefs.setString(_kStreamUrl, s.streamUrl.trim());
  }

  /// Пользователь менял пароль (иначе действует стандартный 1234).
  bool get hasCustomPin => (_prefs.getString(_kSalt) ?? '').isNotEmpty;

  Future<bool> checkPin(String pin) async {
    if (!hasCustomPin) {
      return pin == defaultPin;
    }
    final String salt = _prefs.getString(_kSalt)!;
    final String hash = _prefs.getString(_kPinHash) ?? '';
    return _hash(salt, pin) == hash;
  }

  Future<void> setPin(String pin) async {
    final String salt = _randomHex(16);
    await _prefs.setString(_kSalt, salt);
    await _prefs.setString(_kPinHash, _hash(salt, pin));
  }

  String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt$pin')).toString();

  String _randomHex(int bytes) {
    final rnd = Random.secure();
    return List<int>.generate(bytes, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
