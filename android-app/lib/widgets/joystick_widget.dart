import 'package:flutter/material.dart';

import '../core/mix_math.dart';

/// Рисунок круга джойстика: поле, крестовина-указатель, ручка.
class JoystickPainter extends CustomPainter {
  JoystickPainter({required this.vec, required this.accent});

  /// Нормированный вектор ручки (после мёртвой зоны), |v| ≤ 1;
  /// y положительный вниз (экранная система).
  final Offset vec;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double rad = size.shortestSide / 2;
    final bool live = vec != Offset.zero;
    final Paint field = Paint()
      ..style = PaintingStyle.fill
      ..color = live ? const Color(0x22FFFFFF) : const Color(0x11FFFFFF);
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = live ? accent : const Color(0x66FFFFFF);
    canvas.drawCircle(c, rad, field);
    canvas.drawCircle(c, rad, ring);
    final Paint cross = Paint()
      ..strokeWidth = 1
      ..color = const Color(0x33FFFFFF);
    canvas.drawLine(
        c - Offset(rad * 0.85, 0), c + Offset(rad * 0.85, 0), cross);
    canvas.drawLine(
        c - Offset(0, rad * 0.85), c + Offset(0, rad * 0.85), cross);
    final Offset knob = c + vec * (rad * 0.82);
    final Paint knobPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = live ? accent : Colors.white70;
    canvas.drawCircle(knob, rad * 0.16, knobPaint);
  }

  @override
  bool shouldRepaint(JoystickPainter oldDelegate) =>
      oldDelegate.vec != vec || oldDelegate.accent != accent;
}

/// Экранный джойстик (вид управления «джойстик»): палец задаёт направление
/// и мощность — отклонение от центра, за круг не выходит, в центре мёртвая
/// зона, отпускание — стоп. Математика трекпада веб-версии.
class JoystickWidget extends StatefulWidget {
  const JoystickWidget({
    super.key,
    required this.size,
    required this.onVector,
    required this.onRelease,
  });

  final double size;
  final void Function(double x, double y) onVector;
  final VoidCallback onRelease;

  @override
  State<JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<JoystickWidget> {
  Offset _vec = Offset.zero; // после мёртвой зоны, для рисунка
  int? _pointer;

  void _handle(Offset pos, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double rad = size.shortestSide / 2;
    final Offset raw = (pos - c) / rad;
    final v = joystickDeadzone(raw.dx, raw.dy);
    final Offset next = Offset(v.x, v.y);
    if (next != _vec) {
      setState(() => _vec = next);
      widget.onVector(v.x, v.y);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (ev) {
          _pointer = ev.pointer;
          _handle(ev.localPosition, context.size!);
        },
        onPointerMove: (ev) {
          if (ev.pointer == _pointer) {
            _handle(ev.localPosition, context.size!);
          }
        },
        onPointerUp: (ev) => _release(ev.pointer),
        onPointerCancel: (ev) => _release(ev.pointer),
        child: CustomPaint(
          painter: JoystickPainter(vec: _vec, accent: accent),
        ),
      ),
    );
  }

  void _release(int pointer) {
    if (pointer != _pointer) {
      return;
    }
    _pointer = null;
    if (_vec != Offset.zero) {
      setState(() => _vec = Offset.zero);
      widget.onRelease();
    }
  }
}

/// Индикатор стика физического геймпада: тот же круг, но read-only —
/// ручка ходит за левым стиком геймпада, касания не ловятся.
class JoystickIndicator extends StatelessWidget {
  const JoystickIndicator({super.key, required this.size, required this.vec});

  final double size;
  final Offset vec;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: JoystickPainter(
            vec: vec,
            accent: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
