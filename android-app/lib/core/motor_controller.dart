import 'dart:async';

import 'mix_math.dart';
import 'robot_client.dart';

/// Направление кнопочной крестовины.
enum MotorDir { fwd, back, left, right }

String _dirCmd(MotorDir d) => switch (d) {
      MotorDir.fwd => 'f',
      MotorDir.back => 'b',
      MotorDir.left => 'l',
      MotorDir.right => 'r',
    };

/// Логика движения — порт веб-версии 1:1:
///  - активная команда повторяется каждые 500 мс, пока удерживается
///    (страховка от сторожевого таймера платы 1.5 с);
///  - стоп дублируется ещё дважды с интервалом 400 мс — застрявшие в очереди
///    TCP команды движения не должны «догнать» стоп и снова сдвинуть робота;
///    новое движение повторы отменяет;
///  - кнопки держат стек направлений (активен последний нажатый).
class MotorController {
  MotorController(this._robot);

  final RobotClient _robot;

  final List<MotorDir> _stack = [];
  String _heldMix = ''; // удерживаемый микс ('' = ничего не удерживается)
  Timer? _keepalive;
  Timer? _stopRepeats;
  int _stopCount = 0;
  bool _disposed = false;

  // ---- кнопочная крестовина ----

  void pressDir(MotorDir d) {
    if (_disposed) return;
    _cancelStopRepeats();
    _stack.remove(d);
    _stack.add(d); // последний в стеке активен
    _applyTopDir();
  }

  void releaseDir(MotorDir d) {
    if (_disposed) return;
    _stack.remove(d);
    _applyTopDir();
  }

  void _applyTopDir() {
    _keepalive?.cancel();
    if (_stack.isEmpty) {
      _sendStop();
      return;
    }
    final String cmd = _dirCmd(_stack.last);
    _heldMix = '';
    unawaited(_robot.setParam('motor', cmd));
    _keepalive = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_robot.setParam('motor', cmd));
    });
  }

  // ---- аналоговый вектор (экранный джойстик / геймпад) ----

  /// x/y — нормированный вектор ПОСЛЕ мёртвой зоны (mix_math).
  /// speed/turn — пара мощностей активного вида.
  void updateVector(double x, double y, int speed, int turn) {
    if (_disposed) return;
    final mix = mixFromVec(x, y, speed, turn);
    final String m = mixString(mix.l, mix.r);
    if (m == '0,0' && _heldMix.isEmpty) {
      return; // уже стоим — ноль не шлём (и не плодим дубли стопа)
    }
    if (m == _heldMix && m != '0,0') {
      return; // микс не изменился — шлёт только keepalive раз в 500 мс
    }
    _cancelStopRepeats();
    _keepalive?.cancel();
    if (m == '0,0') {
      _heldMix = '';
      _sendStop();
      return;
    }
    _heldMix = m;
    unawaited(_robot.setParam('mix', m));
    _keepalive = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_robot.setParam('mix', m));
    });
  }

  /// Отпускание джойстика/пропажа геймпада — немедленный стоп с дублями.
  void releaseVector() {
    if (_disposed || _heldMix.isEmpty) return;
    _heldMix = '';
    _sendStop();
  }

  // ---- стоп ----

  void _sendStop() {
    _keepalive?.cancel();
    unawaited(_robot.setParam('mix', '0,0'));
    unawaited(_robot.setParam('motor', 's'));
    _cancelStopRepeats();
    _stopCount = 0;
    _stopRepeats = Timer.periodic(const Duration(milliseconds: 400), (_) {
      _stopCount++;
      final bool moving = _stack.isNotEmpty || _heldMix.isNotEmpty;
      if (moving || _stopCount > 2) {
        _stopRepeats?.cancel();
        _stopRepeats = null;
        return;
      }
      unawaited(_robot.setParam('mix', '0,0'));
      unawaited(_robot.setParam('motor', 's'));
    });
  }

  /// Немедленный стоп без повторов (уход в фон/закрытие экрана).
  void stopAll() {
    _stack.clear();
    _heldMix = '';
    _keepalive?.cancel();
    _cancelStopRepeats();
    unawaited(_robot.setParam('mix', '0,0'));
    unawaited(_robot.setParam('motor', 's'));
  }

  void _cancelStopRepeats() {
    _stopRepeats?.cancel();
    _stopRepeats = null;
  }

  void dispose() {
    _disposed = true;
    _keepalive?.cancel();
    _cancelStopRepeats();
  }
}
