import 'package:flutter/material.dart';

/// Настройки робота: читаются GET /status, меняются через /set.
/// Подписи и индексы обязаны совпадать с таблицами прошивки
/// (QUALITY_PRESETS / LIGHT_COLORS / MOTOR_ACCEL_STEPS).
class RobotSettings {
  const RobotSettings({
    this.quality = 2,
    this.rot = 90,
    this.light = 0,
    this.color = 0,
    this.ctrl = 0,
    this.speed = 100,
    this.tspeed = 100,
    this.pspeed = 100,
    this.ptspeed = 100,
    this.accel = 500,
    this.taccel = 500,
    this.start = 0,
  });

  final int quality; // 0..4 — индекс QUALITY_PRESETS
  final int rot; // 0/90/180/270 — поворот кадра (только отрисовка)
  final int light; // 0/1 — свет вкл/выкл
  final int color; // 0..7 — индекс LIGHT_COLORS
  final int ctrl; // 0 кнопки, 1 трекпад, 2 геймпад
  final int speed; // мощность хода, кнопочный вид (1..100)
  final int tspeed; // мощность поворотов, кнопочный вид
  final int pspeed; // мощность хода, аналоговые виды (трекпад/геймпад)
  final int ptspeed; // мощность поворотов, аналоговые виды
  final int accel; // разгон хода, мс (MOTOR_ACCEL_STEPS)
  final int taccel; // разгон поворотов, мс
  final int start; // точка страгивания, % ШИМ (0..90)

  factory RobotSettings.fromJson(Map<String, dynamic> j) => RobotSettings(
        quality: j['quality'] as int? ?? 2,
        rot: j['rot'] as int? ?? 90,
        light: (j['light'] as int? ?? 0) != 0 ? 1 : 0,
        color: j['color'] as int? ?? 0,
        ctrl: j['ctrl'] as int? ?? 0,
        speed: j['speed'] as int? ?? 100,
        tspeed: j['tspeed'] as int? ?? 100,
        pspeed: j['pspeed'] as int? ?? 100,
        ptspeed: j['ptspeed'] as int? ?? 100,
        accel: j['accel'] as int? ?? 500,
        taccel: j['taccel'] as int? ?? 500,
        start: j['start'] as int? ?? 0,
      );

  /// Пара мощностей активного вида (у кнопок своя, у аналоговых общая).
  int get activeSpeed => ctrl != 0 ? pspeed : speed;
  int get activeTurn => ctrl != 0 ? ptspeed : tspeed;

  RobotSettings copyWith({
    int? quality,
    int? rot,
    int? light,
    int? color,
    int? ctrl,
    int? speed,
    int? tspeed,
    int? pspeed,
    int? ptspeed,
    int? accel,
    int? taccel,
    int? start,
  }) =>
      RobotSettings(
        quality: quality ?? this.quality,
        rot: rot ?? this.rot,
        light: light ?? this.light,
        color: color ?? this.color,
        ctrl: ctrl ?? this.ctrl,
        speed: speed ?? this.speed,
        tspeed: tspeed ?? this.tspeed,
        pspeed: pspeed ?? this.pspeed,
        ptspeed: ptspeed ?? this.ptspeed,
        accel: accel ?? this.accel,
        taccel: taccel ?? this.taccel,
        start: start ?? this.start,
      );

  // ---- подписи (синхронизированы с прошивкой) ----

  static const List<String> qualityLabels = [
    'минимальное (QVGA 320×240)',
    'низкое (VGA 640×480)',
    'среднее (VGA 640×480)',
    'высокое (SVGA 800×600)',
    'максимальное (UXGA 1600×1200)',
  ];

  static const List<String> colorLabels = [
    'белый', 'красный', 'оранжевый', 'жёлтый',
    'зелёный', 'голубой', 'синий', 'пурпурный',
  ];

  /// RGB из LIGHT_COLORS прошивки (белый, красный, оранжевый 255,60,0,
  /// жёлтый 255,160,0, зелёный, голубой 0,160,255, синий, пурпурный 180,0,255).
  static const List<Color> colorSwatches = [
    Color(0xFFFFFFFF), Color(0xFFFF0000), Color(0xFFFF3C00), Color(0xFFFFA000),
    Color(0xFF00FF00), Color(0xFF00A0FF), Color(0xFF0000FF), Color(0xFFB400FF),
  ];

  static const List<int> accelSteps = [0, 200, 500, 1000, 2000];

  static String accelLabel(int ms) => switch (ms) {
        0 => 'отключено',
        200 => '0.2 с',
        500 => '0.5 с',
        1000 => '1 с',
        2000 => '2 с',
        _ => '$ms мс',
      };

  static const List<String> ctrlLabels = ['Кнопки', 'Трекпад', 'Геймпад'];

  static const List<int> rotSteps = [0, 90, 180, 270];
}
