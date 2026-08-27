import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Профиль подключения: адрес робота + параметры стрима.
/// (Настройки самого робота — в models/robot_settings.dart.)
class ConnProfile {
  const ConnProfile({
    this.baseUrl = '',
    this.streamPort = 81,
    this.streamUrl = '',
  });

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

  ConnProfile copyWith({String? baseUrl, int? streamPort, String? streamUrl}) =>
      ConnProfile(
        baseUrl: baseUrl ?? this.baseUrl,
        streamPort: streamPort ?? this.streamPort,
        streamUrl: streamUrl ?? this.streamUrl,
      );
}

/// Какое подключение активно: локальная сеть или интернет.
enum ConnKind { local, inet }

extension ConnKindX on ConnKind {
  String get label => this == ConnKind.inet ? 'Интернет' : 'Локальное';
}

/// Локальные настройки приложения: два профиля подключения и пароль входа.
class AppSettings {
  const AppSettings({
    this.local = const ConnProfile(),
    this.inet = const ConnProfile(),
    this.kind = ConnKind.local,
  });

  /// Профиль «Локальное»: дома, в сети робота.
  final ConnProfile local;

  /// Профиль «Интернет»: доступ извне (облако Keenetic, туннель).
  final ConnProfile inet;

  /// Активный профиль — по нему ходят команды и стрим.
  final ConnKind kind;

  ConnProfile get active => kind == ConnKind.inet ? inet : local;

  bool get hasAddress => active.hasAddress;
  Uri get baseUri => active.baseUri;
  Uri get streamUri => active.streamUri;

  AppSettings copyWith({
    ConnProfile? local,
    ConnProfile? inet,
    ConnKind? kind,
  }) => AppSettings(
    local: local ?? this.local,
    inet: inet ?? this.inet,
    kind: kind ?? this.kind,
  );
}

/// Хранение локальных настроек (SharedPreferences) и пароля входа.
class SettingsStore {
  SettingsStore(this._prefs);

  static const String defaultPin = '1234';

  static const String _kLocalUrl = 'local_base_url';
  static const String _kLocalPort = 'local_stream_port';
  static const String _kLocalStream = 'local_stream_url';
  static const String _kInetUrl = 'inet_base_url';
  static const String _kInetPort = 'inet_stream_port';
  static const String _kInetStream = 'inet_stream_url';
  static const String _kKind = 'conn_kind';
  // одиночные ключи до появления двух профилей — для миграции
  static const String _kBaseUrl = 'base_url';
  static const String _kStreamPort = 'stream_port';
  static const String _kStreamUrl = 'stream_url';
  static const String _kSalt = 'pin_salt';
  static const String _kPinHash = 'pin_hash';

  final SharedPreferences _prefs;

  AppSettings get settings {
    // миграция: раньше адрес был один — кладём его в оба профиля,
    // дальше пользователь разведёт их сам
    if (!_prefs.containsKey(_kLocalUrl) && _prefs.containsKey(_kBaseUrl)) {
      final String url = _prefs.getString(_kBaseUrl) ?? '';
      final int port = _prefs.getInt(_kStreamPort) ?? 81;
      final String stream = _prefs.getString(_kStreamUrl) ?? '';
      _prefs.setString(_kLocalUrl, url);
      _prefs.setInt(_kLocalPort, port);
      _prefs.setString(_kLocalStream, stream);
      _prefs.setString(_kInetUrl, url);
      _prefs.setInt(_kInetPort, port);
      _prefs.setString(_kInetStream, stream);
    }
    return AppSettings(
      local: ConnProfile(
        baseUrl: _prefs.getString(_kLocalUrl) ?? '',
        streamPort: _prefs.getInt(_kLocalPort) ?? 81,
        streamUrl: _prefs.getString(_kLocalStream) ?? '',
      ),
      inet: ConnProfile(
        baseUrl: _prefs.getString(_kInetUrl) ?? '',
        streamPort: _prefs.getInt(_kInetPort) ?? 81,
        streamUrl: _prefs.getString(_kInetStream) ?? '',
      ),
      kind: (_prefs.getString(_kKind) ?? 'local') == 'inet'
          ? ConnKind.inet
          : ConnKind.local,
    );
  }

  Future<void> saveSettings(AppSettings s) async {
    await _prefs.setString(_kLocalUrl, s.local.baseUrl.trim());
    await _prefs.setInt(_kLocalPort, s.local.streamPort);
    await _prefs.setString(_kLocalStream, s.local.streamUrl.trim());
    await _prefs.setString(_kInetUrl, s.inet.baseUrl.trim());
    await _prefs.setInt(_kInetPort, s.inet.streamPort);
    await _prefs.setString(_kInetStream, s.inet.streamUrl.trim());
    await _prefs.setString(_kKind, s.kind.name);
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
    final Random rnd = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => rnd.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
