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

  HttpClient _http = _makeHttp();

  static HttpClient _makeHttp() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    // медленные туннели (облако Keenetic): параллельные запросы душат канал
    ..maxConnectionsPerHost = 1;

  /// Рвёт клиента со всеми соединениями и создаёт новый. Лечит «отравленный»
  /// пул: при maxConnectionsPerHost=1 ОДИН зависший запрос (обрыв релея,
  /// полумёртвый keep-alive) навсегда занимал единственный слот — все
  /// следующие команды молча ждали его внутри getUrl, моторы и свет умирали
  /// разом при живом стриме (стрим — порт 81, отдельный пул, потому и жил).
  void _recycle(HttpClient dead) {
    if (identical(_http, dead)) {
      dead.close(force: true); // заодно рвёт и сам зависший сокет
      _http = _makeHttp();
    }
  }

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
        try {
          // страховочный таймаут на ВЕСЬ запрос: даже если внутри что-то
          // зависнет неожиданным образом, конвейер обязан освободиться —
          // иначе одна команда хоронит управление до перезапуска приложения
          await _doSet(
            cmd.substring(0, sp),
            cmd.substring(sp + 1),
          ).timeout(_timeout * 2);
        } catch (_) {
          // команда не прошла — не страшно: повторит keepalive/следующее
          // движение, а стоп подстрахует сторожевой таймер платы
        }
      }
    } finally {
      _sending = false;
    }
  }

  /// GET без разбора тела (drain аккуратно закрывает соединение). Каждый
  /// шаг под таймаутом — ВКЛЮЧАЯ ожидание слота в пуле (getUrl): без этого
  /// зависшее соединение держало слот вечно. [recycleOnFail] — прибить
  /// клиента при сбое (пути команд: сбой означает испорченное соединение);
  /// прогреву и опросу статуса пересоздание не нужно — через облако они
  /// нередко не укладываются в таймаут, а лишний churn рвал бы прогретое
  /// соединение; их застрявший слот вылечит любая неудачная команда.
  Future<bool> _ping(Uri uri, {required bool recycleOnFail}) async {
    final HttpClient http = _http;
    try {
      final req = await http.getUrl(uri).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      await res.drain<void>().timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      if (recycleOnFail) {
        _recycle(http);
      }
      return false;
    }
  }

  /// GET с телом ответа строкой (null — сбой/не 200), таймауты те же.
  Future<String?> _getText(Uri uri, {required bool recycleOnFail}) async {
    final HttpClient http = _http;
    try {
      final req = await http.getUrl(uri).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      final String body = await utf8.decoder.bind(res).join().timeout(_timeout);
      return res.statusCode == 200 ? body : null;
    } catch (_) {
      if (recycleOnFail) {
        _recycle(http);
      }
      return null;
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
  Future<void> _doSet(String name, String value) async {
    await _ping(_uri('/set', {name: value}), recycleOnFail: true);
  }

  /// true — плата подтвердила (200), false — ошибка/невалидное значение.
  Future<bool> setParam(String name, String value) =>
      _ping(_uri('/set', {name: value}), recycleOnFail: true);

  /// Смена вида управления; в ответе плата отдаёт «ход,поворот» выбранного
  /// вида мощностей (например «75,50»).
  Future<List<int>?> setCtrl(int mode) async {
    final String? body = await _getText(
      _uri('/set', {'ctrl': '$mode'}),
      recycleOnFail: true,
    );
    if (body == null) {
      return null;
    }
    final parts = body.split(',').map(int.tryParse).toList();
    if (parts.length == 2 && parts.every((p) => p != null)) {
      return parts.cast<int>();
    }
    return null;
  }

  /// Прогрев соединения: клиент держит неиспользуемые сокеты открытыми
  /// лишь 15 с, а через облако установка нового соединения стоит секунд —
  /// поэтому первая команда после простоя шла долго (вот и «управление
  /// засыпало при простое»). Лёгкий пинг каждые ~10 с держит сокет живым;
  /// результат не важен, клиент при сбое НЕ пересоздаётся.
  Future<void> warmUp() async {
    await _ping(_uri('/status'), recycleOnFail: false);
  }

  /// Текущие настройки робота одним запросом.
  Future<RobotSettings?> fetchStatus() async {
    final String? body = await _getText(_uri('/status'), recycleOnFail: false);
    if (body == null) {
      return null;
    }
    try {
      return RobotSettings.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _http.close(force: true);
  }
}
