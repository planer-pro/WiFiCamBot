import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../core/gamepad_source.dart';
import '../core/mix_math.dart';
import '../core/mjpeg_stream.dart';
import '../core/motor_controller.dart';
import '../core/robot_client.dart';
import '../models/robot_settings.dart';
import '../widgets/dpad_widget.dart';
import '../widgets/joystick_widget.dart';
import '../widgets/mjpeg_view.dart';
import 'settings_screen.dart';

/// Главный экран: лайв-видео и органы управления (по выбранному виду)
/// — всё на одном экране без скроллинга, адаптив под поворот.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.store});

  final SettingsStore store;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const MethodChannel _deviceCh = MethodChannel('wificambot/device');

  late AppSettings _app;
  late RobotClient _robot;
  late MjpegStream _stream;
  late MotorController _motor;
  final GamepadSource _gpadSrc = GamepadSource();
  StreamSubscription<GamepadEvent>? _gpadSub;
  List<String> _gpadNames = const [];
  Offset _gpadVec = Offset.zero;
  RobotSettings? _rs;
  bool _robotOk = false;
  final Set<MotorDir> _held = {};

  @override
  void initState() {
    super.initState();
    _app = widget.store.settings;
    _robot = RobotClient(() => _app);
    _stream = MjpegStream(urlOf: () => _app.streamUri);
    _motor = MotorController(_robot);
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _setKeepScreenOn(true);
    _refreshStatus();
    if (_app.hasAddress) {
      _stream.start();
    }
    _syncGamepad(prevMode: -1);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gpadSub?.cancel();
    _motor.dispose();
    _stream.dispose();
    _robot.dispose();
    _setKeepScreenOn(false);
    super.dispose();
  }

  void _setKeepScreenOn(bool on) {
    _deviceCh.invokeMethod<void>('keepScreenOn', on).catchError((_) {});
  }

  // ---- связь и настройки робота ----

  Future<void> _refreshStatus() async {
    if (!_app.hasAddress) {
      if (mounted) {
        setState(() => _robotOk = false);
      }
      return;
    }
    final RobotSettings? rs = await _robot.fetchStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _rs = rs;
      _robotOk = rs != null;
    });
    _syncGamepad();
  }

  /// Включает/выключает подписку на геймпад по виду управления.
  void _syncGamepad({int? prevMode}) {
    final int mode = _rs?.ctrl ?? 0;
    final bool want = mode == 2;
    if (prevMode != null && prevMode != mode) {
      _motor.stopAll(); // сменили вид во время движения — safest стоп
    }
    if (want && _gpadSub == null) {
      _gpadSub = _gpadSrc.events().listen(_onGpad, onError: (_) {});
    } else if (!want && _gpadSub != null) {
      _gpadSub?.cancel();
      _gpadSub = null;
      _gpadNames = const [];
      _gpadVec = Offset.zero;
      _motor.releaseVector();
    }
  }

  void _onGpad(GamepadEvent ev) {
    if (ev.devicesChanged) {
      final bool lost = _gpadNames.isNotEmpty && ev.names.isEmpty;
      if (!mounted) {
        return;
      }
      setState(() {
        _gpadNames = ev.names;
        if (lost) {
          _gpadVec = Offset.zero;
        }
      });
      if (lost) {
        // геймпад пропал при отклонённом стике — стоп (как в веб-версии)
        _motor.releaseVector();
      }
      return;
    }
    final ({double x, double y}) v = gpadDeadzone(ev.x, ev.y);
    _motor.updateVector(
      v.x,
      v.y,
      _rs?.activeSpeed ?? 100,
      _rs?.activeTurn ?? 100,
    );
    final Offset vec = Offset(v.x, v.y);
    if (vec != _gpadVec && mounted) {
      setState(() => _gpadVec = vec);
    }
  }

  // ---- жизненный цикл ----

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // уход в фон/потеря фокуса — моторы немедленно стоп (как blur на странице)
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _motor.stopAll();
    }
    if (state == AppLifecycleState.paused) {
      _stream.stop();
    } else if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (_app.hasAddress && _stream.state == MjpegState.idle) {
        _stream.start();
      }
      _refreshStatus();
    }
  }

  // ---- настройки ----

  Future<void> _openSettings() async {
    _motor.stopAll();
    final ({AppSettings app, RobotSettings? rs})? res =
        await Navigator.of(
          context,
        ).push<({AppSettings app, RobotSettings? rs})>(
          MaterialPageRoute(
            builder: (_) => SettingsScreen(
              store: widget.store,
              appSettings: _app,
              robotSettings: _rs,
            ),
          ),
        );
    if (!mounted || res == null) {
      return;
    }
    final bool urlChanged =
        res.app.baseUrl != _app.baseUrl ||
        res.app.streamPort != _app.streamPort ||
        res.app.streamUrl != _app.streamUrl;
    final bool qualityChanged =
        res.rs != null && _rs != null && res.rs!.quality != _rs!.quality;
    final int prevCtrl = _rs?.ctrl ?? 0;
    setState(() {
      _app = res.app;
      if (res.rs != null) {
        _rs = res.rs;
      }
    });
    unawaited(widget.store.saveSettings(_app));
    if (!_app.hasAddress) {
      _stream.stop();
    } else if (urlChanged || qualityChanged) {
      _stream.restart();
    }
    unawaited(_refreshStatus());
    _syncGamepad(prevMode: prevCtrl);
  }

  // ---- быстрый выбор вида управления (меню в верхней панели) ----

  /// Порт _changeCtrl экрана настроек: оптимистично + откат; в ответе плата
  /// отдаёт пару мощностей выбранного вида — кладём её в свою пару.
  Future<void> _changeCtrl(int mode) async {
    final RobotSettings? rs = _rs;
    if (rs == null || rs.ctrl == mode) {
      return;
    }
    setState(() => _rs = rs.copyWith(ctrl: mode));
    _syncGamepad(prevMode: rs.ctrl); // смена вида во время движения — стоп
    final List<int>? pair = await _robot.setCtrl(mode);
    if (!mounted) {
      return;
    }
    if (pair == null) {
      setState(() => _rs = rs);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Робот не принял вид управления')),
      );
      return;
    }
    setState(
      () => _rs = _rs!.copyWith(
        ctrl: mode,
        speed: mode == 0 ? pair[0] : _rs!.speed,
        tspeed: mode == 0 ? pair[1] : _rs!.tspeed,
        pspeed: mode != 0 ? pair[0] : _rs!.pspeed,
        ptspeed: mode != 0 ? pair[1] : _rs!.ptspeed,
      ),
    );
  }

  /// Быстрая кнопка света: переключает вкл/выкл (цвет остаётся прежним),
  /// оптимистично + откат, если плата не подтвердила.
  Future<void> _toggleLight() async {
    final RobotSettings? rs = _rs;
    if (rs == null) {
      return;
    }
    final int next = rs.light == 0 ? 1 : 0;
    setState(() => _rs = rs.copyWith(light: next));
    if (!await _robot.setParam('light', '$next') && mounted) {
      setState(() => _rs = rs);
    }
  }

  Widget _ctrlMenu() {
    final int mode = _rs?.ctrl ?? 0;
    final ThemeData th = Theme.of(context);
    return PopupMenuButton<int>(
      tooltip: 'Вид управления',
      initialValue: mode,
      enabled: _rs != null,
      onSelected: _changeCtrl,
      itemBuilder: (_) => [
        for (int i = 0; i < RobotSettings.ctrlLabels.length; i++)
          PopupMenuItem(value: i, child: Text(RobotSettings.ctrlLabels[i])),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Text(RobotSettings.ctrlLabels[mode], style: th.textTheme.bodySmall),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: th.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  // ---- построение ----

  @override
  Widget build(BuildContext context) {
    final bool portrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    return Scaffold(
      body: SafeArea(
        child: portrait
            ? Column(children: _rows(false))
            : Row(children: _rows(true)),
      ),
    );
  }

  List<Widget> _rows(bool landscape) {
    return [
      _topBar(),
      Expanded(
        child: landscape
            ? Row(
                children: [
                  Expanded(child: _videoArea()),
                  _controlPanel(constrainedSide: true),
                ],
              )
            : _videoArea(),
      ),
      if (!landscape) _controlPanel(constrainedSide: false),
    ];
  }

  Widget _topBar() {
    final MjpegState st = _stream.state;
    final String label;
    final IconData icon;
    final Color color;
    if (!_app.hasAddress) {
      label = 'Адрес не задан';
      icon = Icons.settings;
      color = Colors.grey;
    } else if (_robotOk && st == MjpegState.live) {
      label = 'На связи';
      icon = Icons.wifi;
      color = Colors.greenAccent;
    } else if (st == MjpegState.connecting || st == MjpegState.reconnecting) {
      label = 'Подключение…';
      icon = Icons.wifi_find;
      color = Colors.amber;
    } else {
      label = 'Нет связи';
      icon = Icons.wifi_off;
      color = Colors.redAccent;
    }
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color)),
            const Spacer(),
            IconButton(
              tooltip: 'Свет',
              onPressed: _rs == null ? null : _toggleLight,
              icon: Icon(
                (_rs?.light ?? 0) != 0
                    ? Icons.lightbulb
                    : Icons.lightbulb_outline,
                size: 20,
                color: (_rs?.light ?? 0) != 0 ? Colors.amber : null,
              ),
            ),
            _ctrlMenu(),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Настройки',
              onPressed: _openSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoArea() {
    if (!_app.hasAddress) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.router_outlined, size: 56),
            const SizedBox(height: 12),
            const Text('Адрес робота не задан'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Открыть настройки'),
            ),
          ],
        ),
      );
    }
    return ListenableBuilder(
      listenable: _stream,
      builder: (context, _) => Stack(
        alignment: Alignment.center,
        children: [
          MjpegView(stream: _stream, rot: _rs?.rot ?? 90),
          if (_stream.image == null)
            switch (_stream.state) {
              MjpegState.live => const SizedBox.shrink(),
              MjpegState.idle => const _VideoHint('стрим остановлен'),
              MjpegState.connecting => const _VideoHint(
                'подключение к стриму…',
              ),
              MjpegState.reconnecting => const _VideoHint(
                'связь потеряна, переподключение…',
              ),
            },
        ],
      ),
    );
  }

  /// Панель управления фиксированного размера — общий экран не скроллится.
  Widget _controlPanel({required bool constrainedSide}) {
    final int mode = _rs?.ctrl ?? 0;
    final Size size = MediaQuery.sizeOf(context);
    final double side = constrainedSide
        ? (size.shortestSide * 0.55).clamp(220.0, 340.0)
        : (size.height * 0.45).clamp(200.0, 330.0);
    // Крестовина — как в браузере: 2 ряда (▼ в ряду с ◀/▶), клетка та же
    // (side/3): в портрете панель на треть ниже — видео больше.
    final double panelSide = mode == 0 && !constrainedSide
        ? side * 2 / 3
        : side;
    final Widget control = switch (mode) {
      1 => JoystickWidget(
        size: panelSide * 0.8,
        onVector: (x, y) => _motor.updateVector(
          x,
          y,
          _rs?.activeSpeed ?? 100,
          _rs?.activeTurn ?? 100,
        ),
        onRelease: _motor.releaseVector,
      ),
      2 => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JoystickIndicator(size: panelSide * 0.8, vec: _gpadVec),
          const SizedBox(height: 10),
          Text(
            _gpadNames.isEmpty
                ? 'Геймпад не найден — подключите его к телефону'
                : 'Геймпад: ${_gpadNames.first}',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
      _ => DpadWidget(
        onPress: (d) {
          setState(() => _held.add(d));
          _motor.pressDir(d);
        },
        onRelease: (d) {
          setState(() => _held.remove(d));
          _motor.releaseDir(d);
        },
        held: _held,
      ),
    };
    return SizedBox(
      width: constrainedSide ? panelSide + 24 : double.infinity,
      height: constrainedSide ? double.infinity : panelSide + 24,
      child: Center(child: control),
    );
  }
}

class _VideoHint extends StatelessWidget {
  const _VideoHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white70)),
    );
  }
}
