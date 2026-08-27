import 'dart:math';

/// Смешивание хода и поворота в мощности гусениц — 1:1 с mixFromVec веб-страницы.
/// Вход: x/y нормированного единичного круга, y ВНИЗ положительный (экранная
/// система: вверх = отрицательный y — потому знак минус у хода).
/// Выход: проценты левой/правой гусеницы −100..100 (знак = направление).
({int l, int r}) mixFromVec(double x, double y, int speed, int turnSpeed) {
  final int fwd = (-y * speed).round();
  final int trn = (x * turnSpeed).round();
  int cl(int v) => v > 100 ? 100 : (v < -100 ? -100 : v);
  return (l: cl(fwd + trn), r: cl(fwd - trn));
}

/// Строка «L,R» для /set?mix=.
String mixString(int l, int r) => '$l,$r';

/// Мёртвая зона экранного трекпада — как в веб-версии: 0.12 радиуса,
/// без растяжки шкалы; выход за круг прижимается к краю. Вне зоны — ноль.
({double x, double y}) joystickDeadzone(double x, double y) {
  final double len = sqrt(x * x + y * y);
  double xx = x, yy = y;
  if (len > 1) {
    xx = x / len;
    yy = y / len;
  }
  if (len < 0.12) {
    return (x: 0.0, y: 0.0);
  }
  return (x: xx, y: yy);
}

/// Мёртвая зона ФИЗИЧЕСКОГО геймпада — как gpadPoll веб-версии: 0.15 с
/// растяжкой шкалы на весь ход стика (за границей зоны — полный контроль,
/// без «полумёртвого» края).
({double x, double y}) gpadDeadzone(double x, double y) {
  final double len = sqrt(x * x + y * y);
  double xx = x, yy = y;
  if (len > 1) {
    xx = x / len;
    yy = y / len;
  }
  if (len <= 0.15) {
    return (x: 0.0, y: 0.0);
  }
  final double k = min(1.0, (len - 0.15) / 0.85) / len;
  return (x: xx * k, y: yy * k);
}
