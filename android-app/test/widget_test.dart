import 'package:flutter_test/flutter_test.dart';

import 'package:wificambot/core/mix_math.dart';

void main() {
  test('mixFromVec: полный ход вперёд', () {
    final m = mixFromVec(0, -1, 100, 100);
    expect((m.l, m.r), (100, 100));
  });

  test('mixFromVec: половинная мощность назад', () {
    final m = mixFromVec(0, 0.5, 50, 50);
    expect((m.l, m.r), (-25, -25));
  });

  test('mixFromVec: поворот вправо на месте', () {
    final m = mixFromVec(1, 0, 100, 100);
    expect((m.l, m.r), (100, -100));
  });

  test('mixFromVec: кламп при смешении', () {
    final m = mixFromVec(0.9, -1, 100, 100);
    expect((m.l, m.r), (100, 10)); // 100+90 клампится, 100-90 остаётся
  });

  test('дедзоны: мелкая дрожь — ноль', () {
    expect(joystickDeadzone(0.05, 0.05).x, 0);
    expect(gpadDeadzone(0.1, 0.1).x, 0);
  });

  test('дедзона геймпада: растяжка шкалы за зоной', () {
    final v = gpadDeadzone(0, -1);
    expect(v.y, closeTo(-1, 1e-9));
    final half = gpadDeadzone(0, -0.575); // (0.575-0.15)/0.85 = 0.5
    expect(half.y, closeTo(-0.5, 1e-9));
  });

  test('джойстик за кругом прижимается к краю', () {
    final v = joystickDeadzone(2, 0);
    expect(v.x, closeTo(1, 1e-9));
  });
}
