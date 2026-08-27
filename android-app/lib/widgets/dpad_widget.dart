import 'package:flutter/material.dart';

import '../core/motor_controller.dart';

/// Крестовина управления: кнопка удерживается пальцем — движение продолжается;
/// отпускание — стоп (как на веб-странице, отдельной кнопки «стоп» нет).
/// Кнопки независимы (мультитач), удерживаемые подсвечены.
class DpadWidget extends StatelessWidget {
  const DpadWidget({
    super.key,
    required this.onPress,
    required this.onRelease,
    required this.held,
  });

  final void Function(MotorDir dir) onPress;
  final void Function(MotorDir dir) onRelease;
  final Set<MotorDir> held;

  Widget _cell(BuildContext context, MotorDir d, IconData icon) {
    final bool on = held.contains(d);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onPress(d),
      onPointerUp: (_) => onRelease(d),
      onPointerCancel: (_) => onRelease(d),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: on ? cs.primary : null,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: on ? cs.primary : cs.outline,
              width: 2,
            ),
          ),
          child: Icon(icon, size: 34, color: on ? cs.onPrimary : null),
        ),
      ),
    );
  }

  Widget _gap() => const AspectRatio(aspectRatio: 1, child: SizedBox());

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          _gap(),
          _cell(context, MotorDir.fwd, Icons.arrow_upward),
          _gap(),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _cell(context, MotorDir.left, Icons.arrow_back),
          _gap(),
          _cell(context, MotorDir.right, Icons.arrow_forward),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _gap(),
          _cell(context, MotorDir.back, Icons.arrow_downward),
          _gap(),
        ]),
      ],
    );
  }
}
