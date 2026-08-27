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
    return Expanded(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => onPress(d),
        onPointerUp: (_) => onRelease(d),
        onPointerCancel: (_) => onRelease(d),
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
          child: Center(
            child: Icon(icon, size: 34, color: on ? cs.onPrimary : null),
          ),
        ),
      ),
    );
  }

  Widget _gap() => const Expanded(child: SizedBox());

  @override
  Widget build(BuildContext context) {
    // Сетка 3×2: «вверх» отдельно, «вниз» — в одном ряду с «влево»/«вправо»
    // (танковая схема: вперёд редко нужен одновременно с назад). Корневой
    // AspectRatio получает от панели ограниченные ширину и высоту, клетки
    // Expanded делят поле поровну. (Голая AspectRatio-клетка в строке с
    // бесконечной высотой растягивалась на всю ширину панели — кнопки
    // улетали за экран.)
    return AspectRatio(
      aspectRatio: 3 / 2,
      child: Column(
        children: [
          Expanded(
            child: Row(children: [
              _gap(),
              _cell(context, MotorDir.fwd, Icons.arrow_upward),
              _gap(),
            ]),
          ),
          Expanded(
            child: Row(children: [
              _cell(context, MotorDir.left, Icons.arrow_back),
              _cell(context, MotorDir.back, Icons.arrow_downward),
              _cell(context, MotorDir.right, Icons.arrow_forward),
            ]),
          ),
        ],
      ),
    );
  }
}
