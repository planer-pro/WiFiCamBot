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

  // поля двух профилей подключения: локальное и интернет
  late final TextEditingController _lUrl;
  late final TextEditingController _lPort;
  late final TextEditingController _lStream;
  late final TextEditingController _iUrl;
  late final TextEditingController _iPort;
  late final TextEditingController _iStream;
  late ConnKind _kind; // какой профиль активен
  final TextEditingController _oldPin = TextEditingController();
  final TextEditingController _newPin = TextEditingController();
  final TextEditingController _repeatPin = TextEditingController();

  late final RobotClient _robot; // пишет по адресу на момент открытия экрана
  RobotSettings? _rs;
  bool _loading = false;
  final Map<ConnKind, String?> _connTest = {}; // результаты «Проверить связь»

  @override
  void initState() {
    super.initState();
    final AppSettings app = widget.appSettings;
    _lUrl = TextEditingController(text: app.local.baseUrl);
    _lPort = TextEditingController(text: '${app.local.streamPort}');
    _lStream = TextEditingController(text: app.local.streamUrl);
    _iUrl = TextEditingController(text: app.inet.baseUrl);
    _iPort = TextEditingController(text: '${app.inet.streamPort}');
    _iStream = TextEditingController(text: app.inet.streamUrl);
    _kind = app.kind;
    // адрес читается из полей на момент запроса: если пользователь поправил
    // его прямо здесь, «Повторить» стучится уже по новому адресу; таймаут
    // с запасом — облако Keenetic отвечает на /status до нескольких секунд
    _robot = RobotClient(
      () => _appOfFields(),
      timeout: const Duration(seconds: 8),
    );
    _rs = widget.robotSettings;
    if (_rs == null) {
      _loadStatus();
    }
  }

  @override
  void dispose() {
    _lUrl.dispose();
    _lPort.dispose();
    _lStream.dispose();
    _iUrl.dispose();
    _iPort.dispose();
    _iStream.dispose();
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

  /// Профиль из полей ввода (порт — с защитой от ерунды).
  ConnProfile _profileOf(ConnKind k) {
    final TextEditingController url = k == ConnKind.inet ? _iUrl : _lUrl;
    final TextEditingController port = k == ConnKind.inet ? _iPort : _lPort;
    final TextEditingController stream = k == ConnKind.inet
        ? _iStream
        : _lStream;
    final int? p = int.tryParse(port.text.trim());
    return ConnProfile(
      baseUrl: url.text.trim(),
      streamPort: (p != null && p > 0 && p < 65536) ? p : 81,
      streamUrl: stream.text.trim(),
    );
  }

  AppSettings _appOfFields() => AppSettings(
    local: _profileOf(ConnKind.local),
    inet: _profileOf(ConnKind.inet),
    kind: _kind,
  );

  ({AppSettings app, RobotSettings? rs}) _result() =>
      (app: _appOfFields(), rs: _rs);

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

  // ---- проверка связи с введённым адресом ----

  Future<void> _testConnection(ConnKind k) async {
    setState(() => _connTest[k] = 'Проверяю…');
    final RobotClient probe = RobotClient(
      () => AppSettings(
        local: _profileOf(ConnKind.local),
        inet: _profileOf(ConnKind.inet),
        kind: k,
      ),
      timeout: const Duration(seconds: 8),
    );
    final RobotSettings? rs = await probe.fetchStatus();
    probe.dispose();
    if (!mounted) {
      return;
    }
    setState(() {
      _connTest[k] = rs != null
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
      _snack('Новый пароль — не меньше 4 цифр');
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
          actions: [TextButton(onPressed: _pop, child: const Text('Готово'))],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _section('Подключение'),
            // RadioGroup — общий предок обоих переключателей (профили
            // разнесены полями ввода); ядро 3.32+ требует так вместо
            // groupValue/onChanged у каждой плитки
            RadioGroup<ConnKind>(
              groupValue: _kind,
              onChanged: (v) => setState(() => _kind = v ?? ConnKind.local),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RadioListTile<ConnKind>(
                    value: ConnKind.local,
                    title: const Text('Подключение локальное'),
                    subtitle: _kind == ConnKind.local
                        ? const Text('активно — используется сейчас')
                        : null,
                    secondary: const Icon(Icons.home_outlined),
                    contentPadding: EdgeInsets.zero,
                  ),
                  TextField(
                    controller: _lUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Адрес робота',
                      hintText: 'http://192.168.1.137',
                      helperText:
                          'В сети робота (дома); wificambot.local на '
                          'Android обычно не резолвится — вводите IP',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.router_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _lPort,
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
                    controller: _lStream,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Полный URL стрима (необязательно)',
                      hintText: 'http://192.168.1.137:81',
                      helperText:
                          'Когда стрим доступен по отдельному адресу. '
                          'Пусто — адрес робота + порт стрима',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _testConnection(ConnKind.local),
                    icon: const Icon(Icons.network_check),
                    label: const Text('Проверить связь'),
                  ),
                  if (_connTest[ConnKind.local] != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _connTest[ConnKind.local]!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                  const SizedBox(height: 12),
                  RadioListTile<ConnKind>(
                    value: ConnKind.inet,
                    title: const Text('Подключение интернет'),
                    subtitle: _kind == ConnKind.inet
                        ? const Text('активно — используется сейчас')
                        : null,
                    secondary: const Icon(Icons.cloud_outlined),
                    contentPadding: EdgeInsets.zero,
                  ),
                  TextField(
                    controller: _iUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Адрес робота',
                      hintText: 'https://robot.myhome3.netcraze.link',
                      helperText: 'Внешний адрес/туннель или домен Keenetic',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.public),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _iPort,
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
                    controller: _iStream,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Полный URL стрима (необязательно)',
                      hintText: 'https://stream.myhome3.netcraze.link',
                      helperText:
                          'Когда стрим доступен по отдельному адресу '
                          '(облако Keenetic). Пусто — адрес робота + порт стрима',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.cloud_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _testConnection(ConnKind.inet),
                    icon: const Icon(Icons.network_check),
                    label: const Text('Проверить связь'),
                  ),
                  if (_connTest[ConnKind.inet] != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _connTest[ConnKind.inet]!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
            ),
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
            // пароль только цифровой — иначе его не ввести на крупном
            // цифровом паде экрана входа
            TextField(
              controller: _oldPin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
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
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              decoration: const InputDecoration(
                labelText: 'Новый пароль',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _repeatPin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
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
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  List<Widget> _robotRows() {
    final RobotSettings rs = _rs!;
    final bool buttonsMode = rs.ctrl == 0;
    return [
      DropdownButtonFormField<int>(
        initialValue: rs.quality,
        decoration: const InputDecoration(
          labelText: 'Качество видео',
          border: OutlineInputBorder(),
        ),
        items: [
          for (int i = 0; i < RobotSettings.qualityLabels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(RobotSettings.qualityLabels[i]),
            ),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam(
                'качество',
                (s) => s.copyWith(quality: v),
                'quality',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.rot,
        decoration: const InputDecoration(
          labelText: 'Поворот кадра',
          border: OutlineInputBorder(),
        ),
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
          labelText: 'Управление',
          border: OutlineInputBorder(),
        ),
        items: [
          for (int i = 0; i < RobotSettings.ctrlLabels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(RobotSettings.ctrlLabels[i]),
            ),
        ],
        onChanged: (v) => v == null ? null : _changeCtrl(v),
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Свет'),
        value: rs.light != 0,
        onChanged: (on) => _setParam(
          'свет',
          (s) => s.copyWith(light: on ? 1 : 0),
          'light',
          on ? '1' : '0',
        ),
      ),
      DropdownButtonFormField<int>(
        initialValue: rs.color,
        decoration: const InputDecoration(
          labelText: 'Цвет света',
          border: OutlineInputBorder(),
        ),
        items: [
          for (int i = 0; i < RobotSettings.colorLabels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 7,
                    backgroundColor: RobotSettings.colorSwatches[i],
                  ),
                  const SizedBox(width: 10),
                  Text(RobotSettings.colorLabels[i]),
                ],
              ),
            ),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam('цвет', (s) => s.copyWith(color: v), 'color', '$v'),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.activeSpeed,
        decoration: const InputDecoration(
          labelText: 'Мощность хода, %',
          border: OutlineInputBorder(),
        ),
        items: _powerItems(rs.activeSpeed),
        onChanged: (v) => v == null
            ? null
            : _setParam(
                'мощность хода',
                (s) =>
                    buttonsMode ? s.copyWith(speed: v) : s.copyWith(pspeed: v),
                'speed',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.activeTurn,
        decoration: const InputDecoration(
          labelText: 'Мощность поворотов, %',
          border: OutlineInputBorder(),
        ),
        items: _powerItems(rs.activeTurn),
        onChanged: (v) => v == null
            ? null
            : _setParam(
                'мощность поворотов',
                (s) => buttonsMode
                    ? s.copyWith(tspeed: v)
                    : s.copyWith(ptspeed: v),
                'tspeed',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      if (buttonsMode) ...[
        DropdownButtonFormField<int>(
          initialValue: rs.accel,
          decoration: const InputDecoration(
            labelText: 'Разгон хода',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final int ms in RobotSettings.accelSteps)
              DropdownMenuItem(
                value: ms,
                child: Text(RobotSettings.accelLabel(ms)),
              ),
          ],
          onChanged: (v) => v == null
              ? null
              : _setParam(
                  'разгон хода',
                  (s) => s.copyWith(accel: v),
                  'accel',
                  '$v',
                ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: rs.taccel,
          decoration: const InputDecoration(
            labelText: 'Разгон поворотов',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final int ms in RobotSettings.accelSteps)
              DropdownMenuItem(
                value: ms,
                child: Text(RobotSettings.accelLabel(ms)),
              ),
          ],
          onChanged: (v) => v == null
              ? null
              : _setParam(
                  'разгон поворотов',
                  (s) => s.copyWith(taccel: v),
                  'taccel',
                  '$v',
                ),
        ),
        const SizedBox(height: 12),
      ] else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Разгоны в этом виде управления отключены '
            '(движение мгновенное)',
          ),
        ),
      _StartField(
        value: rs.start,
        onChanged: (int cl) => _setParam(
          'точка страгирования',
          (s) => s.copyWith(start: cl),
          'start',
          '$cl',
        ),
      ),
    ];
  }

  List<DropdownMenuItem<int>> _powerItems(int current) {
    final List<int> values = [
      ...powerSteps,
      if (!powerSteps.contains(current)) current,
    ];
    return [
      for (final int v in values)
        DropdownMenuItem(value: v, child: Text('$v %')),
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
        helperText:
            'Мощность, ниже которой танк не трогается; Enter — применить',
        border: OutlineInputBorder(),
      ),
    );
  }
}
