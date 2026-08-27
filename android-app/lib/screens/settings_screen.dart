import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../core/robot_client.dart';
import '../models/robot_settings.dart';

/// Меню настроек: подключение, настройки робота, приложение (пароль).
/// Изменения настроек робота уходят на него сразу (/set, оптимистично);
/// при ошибке — откат и сообщение. Возвращает (AppSettings, RobotSettings?).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.appSettings,
    this.robotSettings,
  });

  final SettingsStore store;
  final AppSettings appSettings;
  final RobotSettings? robotSettings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<int> powerSteps = [25, 50, 75, 100];

  late final TextEditingController _url;
  late final TextEditingController _port;
  late final TextEditingController _streamUrl;
  final TextEditingController _oldPin = TextEditingController();
  final TextEditingController _newPin = TextEditingController();
  final TextEditingController _repeatPin = TextEditingController();

  late final RobotClient _robot; // пишет по адресу на момент открытия экрана
  RobotSettings? _rs;
  bool _loading = false;
  String? _connTest; // результат «Проверить связь»

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.appSettings.baseUrl);
    _port = TextEditingController(text: '${widget.appSettings.streamPort}');
    _streamUrl = TextEditingController(text: widget.appSettings.streamUrl);
    // адрес читается из поля на момент запроса: если пользователь поправил
    // его прямо здесь, «Повторить» стучится уже по новому адресу; таймаут
    // с запасом — облако Keenetic отвечает на /status до нескольких секунд
    _robot = RobotClient(() => AppSettings(baseUrl: _url.text.trim()),
        timeout: const Duration(seconds: 8));
    _rs = widget.robotSettings;
    if (_rs == null) {
      _loadStatus();
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _port.dispose();
    _streamUrl.dispose();
    _oldPin.dispose();
    _newPin.dispose();
    _repeatPin.dispose();
    _robot.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() => _loading = true);
    final RobotSettings? rs = await _robot.fetchStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _rs = rs;
    });
  }

  ({AppSettings app, RobotSettings? rs}) _result() {
    final int? port = int.tryParse(_port.text.trim());
    return (
      app: AppSettings(
        baseUrl: _url.text.trim(),
        streamPort: (port != null && port > 0 && port < 65536) ? port : 81,
        streamUrl: _streamUrl.text.trim(),
      ),
      rs: _rs,
    );
  }

  void _pop() => Navigator.of(context).pop(_result());

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- запись настройки робота: оптимистично + откат при ошибке ----

  Future<void> _setParam(
    String title,
    RobotSettings Function(RobotSettings) change,
    String name,
    String value,
  ) async {
    final RobotSettings? rs = _rs;
    if (rs == null) {
      return;
    }
    final RobotSettings next = change(rs);
    setState(() => _rs = next);
    if (!await _robot.setParam(name, value)) {
      if (mounted) {
        setState(() => _rs = rs);
        _snack('Робот не принял «$title»');
      }
    }
  }

  Future<void> _changeCtrl(int mode) async {
    final RobotSettings? rs = _rs;
    if (rs == null) {
      return;
    }
    setState(() => _rs = rs.copyWith(ctrl: mode));
    final List<int>? pair = await _robot.setCtrl(mode);
    if (!mounted) {
      return;
    }
    if (pair == null) {
      setState(() => _rs = rs);
      _snack('Робот не принял вид управления');
      return;
    }
    // в ответе — пара мощностей выбранного вида; кладём её в свою пару
    setState(() => _rs = _rs!.copyWith(
          ctrl: mode,
          speed: mode == 0 ? pair[0] : _rs!.speed,
          tspeed: mode == 0 ? pair[1] : _rs!.tspeed,
          pspeed: mode != 0 ? pair[0] : _rs!.pspeed,
          ptspeed: mode != 0 ? pair[1] : _rs!.ptspeed,
        ));
  }

  // ---- проверка связи с введённым адресом ----

  Future<void> _testConnection() async {
    setState(() => _connTest = 'Проверяю…');
    final int port = int.tryParse(_port.text.trim()) ?? 81;
    final RobotClient probe = RobotClient(
        () => AppSettings(baseUrl: _url.text.trim(), streamPort: port),
        timeout: const Duration(seconds: 8));
    final RobotSettings? rs = await probe.fetchStatus();
    probe.dispose();
    if (!mounted) {
      return;
    }
    setState(() {
      _connTest = rs != null
          ? 'Робот отвечает (${RobotSettings.qualityLabels[rs.quality]}), '
              'вид управления: ${RobotSettings.ctrlLabels[rs.ctrl]}'
          : 'Нет ответа — проверьте адрес и что робот в сети';
      if (rs != null && _rs == null) {
        _rs = rs;
      }
    });
  }

  // ---- смена пароля ----

  Future<void> _changePin() async {
    final String old = _oldPin.text;
    final String pin = _newPin.text;
    if (pin.length < 4) {
      _snack('Новый пароль — не меньше 4 символов');
      return;
    }
    if (pin != _repeatPin.text) {
      _snack('Новый пароль и повтор не совпадают');
      return;
    }
    if (!await widget.store.checkPin(old)) {
      _snack('Текущий пароль неверный');
      return;
    }
    await widget.store.setPin(pin);
    _oldPin.clear();
    _newPin.clear();
    _repeatPin.clear();
    _snack('Пароль изменён');
  }

  // ---- построение ----

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          _pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Настройки'),
          actions: [
            TextButton(onPressed: _pop, child: const Text('Готово')),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _section('Подключение'),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Адрес робота',
                hintText: 'http://192.168.1.137',
                helperText: 'Для доступа извне — внешний адрес/туннель '
                    'или домен Keenetic (https://robot…)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.router_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Порт стрима',
                hintText: '81',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.videocam_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _streamUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Полный URL стрима (необязательно)',
                hintText: 'https://stream.myhome3.netcraze.link',
                helperText: 'Когда стрим доступен по отдельному адресу '
                    '(облако Keenetic). Пусто — адрес робота + порт стрима',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cloud_outlined),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _testConnection,
              icon: const Icon(Icons.network_check),
              label: const Text('Проверить связь'),
            ),
            if (_connTest != null) ...[
              const SizedBox(height: 8),
              Text(_connTest!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            _section('Робот'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_rs == null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Робот не отвечает — проверьте адрес и связь'),
              ),
              OutlinedButton.icon(
                onPressed: _loadStatus,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ] else
              ..._robotRows(),
            _section('Приложение'),
            TextField(
              controller: _oldPin,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Текущий пароль',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newPin,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Новый пароль',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _repeatPin,
              obscureText: true,
              onSubmitted: (_) => _changePin(),
              decoration: const InputDecoration(
                labelText: 'Повторите новый пароль',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _changePin,
              icon: const Icon(Icons.key),
              label: const Text('Сменить пароль'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  List<Widget> _robotRows() {
    final RobotSettings rs = _rs!;
    final bool buttonsMode = rs.ctrl == 0;
    final String pairNote = buttonsMode
        ? 'пара кнопочного вида'
        : 'общая пара джойстика и геймпада';
    return [
      DropdownButtonFormField<int>(
        initialValue: rs.quality,
        decoration: const InputDecoration(
            labelText: 'Качество видео', border: OutlineInputBorder()),
        items: [
          for (int i = 0; i < RobotSettings.qualityLabels.length; i++)
            DropdownMenuItem(
                value: i, child: Text(RobotSettings.qualityLabels[i])),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam('качество', (s) => s.copyWith(quality: v),
                'quality', '$v'),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.rot,
        decoration: const InputDecoration(
            labelText: 'Поворот кадра', border: OutlineInputBorder()),
        items: [
          for (final int deg in RobotSettings.rotSteps)
            DropdownMenuItem(value: deg, child: Text('$deg°')),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam('поворот', (s) => s.copyWith(rot: v), 'rot', '$v'),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.ctrl,
        decoration: const InputDecoration(
            labelText: 'Управление', border: OutlineInputBorder()),
        items: [
          for (int i = 0; i < RobotSettings.ctrlLabels.length; i++)
            DropdownMenuItem(
                value: i, child: Text(RobotSettings.ctrlLabels[i])),
        ],
        onChanged: (v) => v == null ? null : _changeCtrl(v),
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Свет'),
        value: rs.light != 0,
        onChanged: (on) => _setParam(
            'свет', (s) => s.copyWith(light: on ? 1 : 0), 'light', on ? '1' : '0'),
      ),
      DropdownButtonFormField<int>(
        initialValue: rs.color,
        decoration: const InputDecoration(
            labelText: 'Цвет света', border: OutlineInputBorder()),
        items: [
          for (int i = 0; i < RobotSettings.colorLabels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Row(children: [
                CircleAvatar(
                    radius: 7, backgroundColor: RobotSettings.colorSwatches[i]),
                const SizedBox(width: 10),
                Text(RobotSettings.colorLabels[i]),
              ]),
            ),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam('цвет', (s) => s.copyWith(color: v), 'color', '$v'),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.activeSpeed,
        decoration: InputDecoration(
            labelText: 'Мощность хода, %',
            helperText: pairNote,
            border: const OutlineInputBorder()),
        items: _powerItems(rs.activeSpeed),
        onChanged: (v) => v == null
            ? null
            : _setParam(
                'мощность хода',
                (s) => buttonsMode
                    ? s.copyWith(speed: v)
                    : s.copyWith(pspeed: v),
                'speed',
                '$v'),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.activeTurn,
        decoration: InputDecoration(
            labelText: 'Мощность поворотов, %',
            helperText: pairNote,
            border: const OutlineInputBorder()),
        items: _powerItems(rs.activeTurn),
        onChanged: (v) => v == null
            ? null
            : _setParam(
                'мощность поворотов',
                (s) => buttonsMode
                    ? s.copyWith(tspeed: v)
                    : s.copyWith(ptspeed: v),
                'tspeed',
                '$v'),
      ),
      const SizedBox(height: 12),
      if (buttonsMode) ...[
        DropdownButtonFormField<int>(
          initialValue: rs.accel,
          decoration: const InputDecoration(
              labelText: 'Разгон хода',
              border: OutlineInputBorder()),
          items: [
            for (final int ms in RobotSettings.accelSteps)
              DropdownMenuItem(
                  value: ms, child: Text(RobotSettings.accelLabel(ms))),
          ],
          onChanged: (v) => v == null
              ? null
              : _setParam(
                  'разгон хода', (s) => s.copyWith(accel: v), 'accel', '$v'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: rs.taccel,
          decoration: const InputDecoration(
              labelText: 'Разгон поворотов',
              border: OutlineInputBorder()),
          items: [
            for (final int ms in RobotSettings.accelSteps)
              DropdownMenuItem(
                  value: ms, child: Text(RobotSettings.accelLabel(ms))),
          ],
          onChanged: (v) => v == null
              ? null
              : _setParam('разгон поворотов',
                  (s) => s.copyWith(taccel: v), 'taccel', '$v'),
        ),
        const SizedBox(height: 12),
      ] else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text('Разгоны в этом виде управления отключены '
              '(движение мгновенное)'),
        ),
      _StartField(
        value: rs.start,
        onChanged: (int cl) => _setParam('точка страгирования',
            (s) => s.copyWith(start: cl), 'start', '$cl'),
      ),
    ];
  }

  List<DropdownMenuItem<int>> _powerItems(int current) {
    final List<int> values = [
      ...powerSteps,
      if (!powerSteps.contains(current)) current
    ];
    return [
      for (final int v in values) DropdownMenuItem(value: v, child: Text('$v %')),
    ];
  }
}

/// Поле «точка страгирования»: показывает текущее значение, Enter — записать.
class _StartField extends StatefulWidget {
  const _StartField({required this.value, required this.onChanged});

  final int value;
  final void Function(int pct) onChanged;

  @override
  State<_StartField> createState() => _StartFieldState();
}

class _StartFieldState extends State<_StartField> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(covariant _StartField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _ctl.text != '${widget.value}') {
      _ctl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctl,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onSubmitted: (String text) {
        final int? v = int.tryParse(text);
        if (v == null) {
          return;
        }
        final int cl = v.clamp(0, 90);
        _ctl.text = '$cl';
        widget.onChanged(cl);
      },
      decoration: const InputDecoration(
        labelText: 'Точка страгирования, % ШИМ (0–90)',
        helperText: 'Мощность, ниже которой танк не трогается; Enter — применить',
        border: OutlineInputBorder(),
      ),
    );
  }
}
