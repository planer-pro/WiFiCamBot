import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

enum MjpegState { idle, connecting, live, reconnecting }

/// Сторож чтения: столько можно ждать очередной порцию байтов стрима.
/// При резком отключении питания робот не успевает закрыть соединение
/// (нет FIN/RST) — TCP-чтение молчит вечно, стрим «замирал» в live
/// при выключенном роботе: замёрзший кадр, зелёный индикатор. Нет данных
/// дольше этого времени — связь считаем мёртвой и переподключаемся.
const Duration _readTimeout = Duration(seconds: 3);

/// Приём MJPEG-потока робота (multipart/x-mixed-replace) и декодирование
/// кадров. Один кадр в памяти, очередь декода глубиной 1 (пока кадр
/// декодируется, новые скипаются — поток быстрее декодера, гоняться
/// незачем). Обрыв — реконнект через 1 с, как в веб-версии.
class MjpegStream extends ChangeNotifier {
  MjpegStream({required this.urlOf, this.targetWidth = 640});

  /// URL стрима (хост из адреса робота + порт стрима).
  final Uri Function() urlOf;

  /// Кадр декодируется ужатым до этой ширины (px): UXGA-кадр 1600×1200
  /// рисуется в виджет гораздо меньшего размера — незачем держать ~8 МБ.
  int targetWidth;

  MjpegState state = MjpegState.idle;
  ui.Image? image;

  bool _running = false;
  HttpClient? _http;
  Timer? _reconnect;
  bool _decoding = false;
  int _generation = 0; // защита от гонок restart/stop

  void start() {
    if (_running) {
      return;
    }
    _running = true;
    _generation++;
    unawaited(_connect(_generation));
  }

  void stop() {
    _running = false;
    _generation++;
    _reconnect?.cancel();
    _reconnect = null;
    _http?.close(force: true);
    _http = null;
    image?.dispose();
    image = null;
    state = MjpegState.idle;
    notifyListeners();
  }

  /// Принудительный реконнект (смена качества/адреса): рвёт текущее
  /// соединение — поток чтения упадёт и начнётся переподключение.
  /// Был остановлен — просто поднимаем (иначе после первых настроек
  /// стрим навсегда оставался в idle).
  void restart() {
    if (!_running) {
      start();
      return;
    }
    _http?.close(force: true);
  }

  Future<void> _connect(int generation) async {
    if (!_running || generation != _generation) {
      return;
    }
    state = MjpegState.connecting;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    _http = client;
    try {
      // подключение тоже под таймаутом (с запасом на TLS+релей облака):
      // зависший getUrl/close оставил бы индикатор в «Подключение…» навечно
      final req = await client
          .getUrl(urlOf())
          .timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (!_running || generation != _generation) {
        return;
      }
      final String boundary =
          _boundaryOf(res.headers.value(HttpHeaders.contentTypeHeader)) ??
          '123456789000000000000987654321';
      await for (final Uint8List frame in _frames(res, boundary, generation)) {
        if (!_running || generation != _generation) {
          return;
        }
        state = MjpegState.live;
        await _decode(frame);
      }
    } catch (_) {
      // обрыв связи лечит реконнект ниже
    } finally {
      client.close(force: true);
      if (_http == client) {
        _http = null;
      }
    }
    if (!_running || generation != _generation) {
      return;
    }
    state = MjpegState.reconnecting;
    notifyListeners();
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 1), () => _connect(generation));
  }

  /// Разбор multipart: маркер «--BOUNDARY», заголовки части до \r\n\r\n,
  /// затем Content-Length байт JPEG. Конечного маркера сервер не шлёт.
  Stream<Uint8List> _frames(
    HttpClientResponse res,
    String boundary,
    int generation,
  ) async* {
    final List<int> marker = utf8.encode('--$boundary');
    final List<int> headerEnd = [13, 10, 13, 10]; // \r\n\r\n
    List<int> bytes = [];
    final int cap = 2 * 1024 * 1024; // защита от рассинхрона парсера

    int find(int from, List<int> needle) {
      // поиск в буфере; возвращает индекс или -1
      outer:
      for (int i = from; i + needle.length <= bytes.length; i++) {
        for (int j = 0; j < needle.length; j++) {
          if (bytes[i + j] != needle[j]) {
            continue outer;
          }
        }
        return i;
      }
      return -1;
    }

    final StreamIterator<List<int>> it = StreamIterator(res);
    // чтение под сторож-таймаутом (_readTimeout): обрывается и «тихая»
    // смерть соединения — иначе moveNext висел вечно
    Future<bool> more() => it.moveNext().timeout(_readTimeout);
    try {
      while (true) {
        // 1. ждём маркер границы
        int pos = find(0, marker);
        while (pos < 0) {
          if (bytes.length > cap) {
            throw const SocketException('mjpeg: маркер не найден');
          }
          if (!await more()) {
            return;
          }
          bytes = bytes.sublist(math.max(0, bytes.length - marker.length + 1))
            ..addAll(it.current);
          pos = find(0, marker);
        }
        // 2. ждём конец заголовков части
        int hend = find(pos, headerEnd);
        while (hend < 0) {
          if (bytes.length > cap) {
            throw const SocketException('mjpeg: нет конца заголовков');
          }
          if (!await more()) {
            return;
          }
          bytes.addAll(it.current);
          hend = find(pos, headerEnd);
        }
        final String headers = String.fromCharCodes(
          bytes.sublist(pos, hend),
        ).toLowerCase();
        final RegExp lenRe = RegExp(r'content-length:\s*(\d+)');
        final RegExpMatch? m = lenRe.firstMatch(headers);
        if (m == null) {
          throw const SocketException('mjpeg: нет content-length');
        }
        final int frameLen = int.parse(m.group(1)!);
        final int bodyStart = hend + headerEnd.length;
        // 3. ждём кадр целиком
        while (bytes.length < bodyStart + frameLen) {
          if (!await more()) {
            return;
          }
          bytes.addAll(it.current);
        }
        yield Uint8List.fromList(
          bytes.sublist(bodyStart, bodyStart + frameLen),
        );
        // буфер: отрезаем обработанное
        bytes = bytes.sublist(bodyStart + frameLen);
        if (!_running || generation != _generation) {
          return;
        }
      }
    } finally {
      it.cancel();
    }
  }

  Future<void> _decode(Uint8List data) async {
    if (_decoding) {
      return; // кадры приходят быстрее декода — лишнее выбрасываем
    }
    _decoding = true;
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(
        data,
        targetWidth: targetWidth,
      );
      final ui.FrameInfo fi = await codec.getNextFrame();
      codec.dispose();
      final ui.Image? old = image;
      image = fi.image;
      notifyListeners();
      old?.dispose();
    } catch (_) {
      // битый кадр — просто пропускаем
    } finally {
      _decoding = false;
    }
  }

  String? _boundaryOf(String? contentType) {
    if (contentType == null) {
      return null;
    }
    final RegExpMatch? m = RegExp(
      'boundary=(\\S+)',
    ).firstMatch(contentType.toLowerCase());
    return m?.group(1);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
