import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/robot_settings.dart';
import 'app_settings.dart';

/// HTTP-клиент робота: команды /set, чтение /status.
/// Ошибки связи не бросает наружу — команды движения слать «в никуда» безопасно:
/// сторожевой таймер платы сам остановит моторы через 1.5 с.
class RobotClient {
  /// [timeout] — на соединение и ответ. Командам движения хватит короткого
  /// (страховка — сторожевой таймер платы), чтению /status через медленные
  /// туннели (облако Keenetic, замеры до 7 с) нужен запас.
  RobotClient(this._settingsOf, {Duration timeout = const Duration(seconds: 3)})
    : _timeout = timeout;

  /// Функция отдаёт актуальный адрес робота (может поменяться в настройках).
  final AppSettings Function() _settingsOf;

  final Duration _timeout;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    // медленные туннели (облако Keenetic): параллельные запросы душат канал
    ..maxConnectionsPerHost = 1;

  // Конвейер команд движения: максимум один запрос в полёте, новая команда
  // заменяет ждущую (промежуточные состояния теряются — для управления это
  // и нужно: важна последняя). Иначе на медленном канале команды копятся
  // быстрее, чем уходят, и робот «доигрывает» очередь после отпускания.
  String? _queued; // «имя=значение» последней несланной команды
  bool _sending = false;

  void sendCommand(String name, String value) {
    _queued = '$name=$value';
    unawaited(_commandLoop());
  }

  Future<void> _commandLoop() async {
    if (_sending) {
      return;
    }
    _sending = true;
    try {
      while (_queued != null) {
        final String cmd = _queued!;
        _queued = null;
        final int sp = cmd.indexOf('=');
        await _doSet(cmd.substring(0, sp), cmd.substring(sp + 1));
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _doSet(String name, String value) async {
    try {
      final req = await _http.getUrl(_uri('/set', {name: value}));
      final res = await req.close().timeout(_timeout);
      await res.drain<void>().catchError((_) {});
    } catch (_) {
      // ошибка команды не страшна: сторожевой таймер платы сам остановит
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    var u = _settingsOf().baseUri.replace(path: path);
    if (query != null) {
      // строку запроса собираем сами: прошивка ждёт буквальную запятую
      // в mix=L,R, а queryParameters закодировала бы её в %2C
      final String q = query.entries
          .map((e) => '${e.key}=${e.value}')
          .join('&');
      u = u.replace(query: q);
    }
    return u;
  }

  /// GET /set?name=value — у платы строго один параметр за запрос.
  /// true — плата подтвердила (200), false — ошибка/невалидное значение.
  Future<bool> setParam(String name, String value) async {
    try {
      final req = await _http.getUrl(_uri('/set', {name: value}));
      final res = await req.close().timeout(_timeout);
      await res.drain<void>().catchError((_) {});
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Смена вида управления; в ответе плата отдаёт «ход,поворот» выбранного
  /// вида мощностей (например «75,50»).
  Future<List<int>?> setCtrl(int mode) async {
    try {
      final req = await _http.getUrl(_uri('/set', {'ctrl': '$mode'}));
      final res = await req.close().timeout(_timeout);
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode != 200) {
        return null;
      }
      final parts = body.split(',').map(int.tryParse).toList();
      if (parts.length == 2 && parts.every((p) => p != null)) {
        return parts.cast<int>();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Текущие настройки робота одним запросом.
  Future<RobotSettings?> fetchStatus() async {
    try {
      final req = await _http.getUrl(_uri('/status'));
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        return null;
      }
      final body = await utf8.decoder.bind(res).join();
      return RobotSettings.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _http.close(force: true);
  }
}
