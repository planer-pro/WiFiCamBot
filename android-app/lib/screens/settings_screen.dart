import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../core/l10n.dart';
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
    final Strings s = L10n.of(context);
    final RobotSettings next = change(rs);
    setState(() => _rs = next);
    if (!await _robot.setParam(name, value)) {
      if (mounted) {
        setState(() => _rs = rs);
        _snack(s.robotRejected(title));
      }
    }
  }

  Future<void> _changeCtrl(int mode) async {
    final RobotSettings? rs = _rs;
    if (rs == null) {
      return;
    }
    final Strings s = L10n.of(context);
    setState(() => _rs = rs.copyWith(ctrl: mode));
    final List<int>? pair = await _robot.setCtrl(mode);
    if (!mounted) {
      return;
    }
    if (pair == null) {
      setState(() => _rs = rs);
      _snack(s.ctrlNotAccepted);
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
    final Strings s = L10n.of(context);
    setState(() => _connTest[k] = s.testing);
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
          ? s.testOk(s.qualityLabels[rs.quality], s.ctrlLabels[rs.ctrl])
          : s.testFail;
      if (rs != null && _rs == null) {
        _rs = rs;
      }
    });
  }

  // ---- смена пароля ----

  Future<void> _changePin() async {
    final Strings s = L10n.of(context);
    final String old = _oldPin.text;
    final String pin = _newPin.text;
    if (pin.length < 4) {
      _snack(s.pinTooShort);
      return;
    }
    if (pin != _repeatPin.text) {
      _snack(s.pinsMismatch);
      return;
    }
    if (!await widget.store.checkPin(old)) {
      _snack(s.pinWrong);
      return;
    }
    await widget.store.setPin(pin);
    _oldPin.clear();
    _newPin.clear();
    _repeatPin.clear();
    _snack(s.pinChanged);
  }

  // ---- построение ----

  @override
  Widget build(BuildContext context) {
    final Strings s = L10n.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          _pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.settings),
          actions: [TextButton(onPressed: _pop, child: Text(s.done))],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _section(s.sectionConn),
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
                    title: Text(s.connLocalTitle),
                    subtitle: _kind == ConnKind.local
                        ? Text(s.activeNow)
                        : null,
                    secondary: const Icon(Icons.home_outlined),
                    contentPadding: EdgeInsets.zero,
                  ),
                  TextField(
                    controller: _lUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: s.robotAddress,
                      hintText: 'http://192.168.1.137',
                      helperText: s.robotAddressLocalHelper,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.router_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _lPort,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: s.streamPort,
                      hintText: '81',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.videocam_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _lStream,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: s.streamUrlOptional,
                      hintText: 'http://192.168.1.137:81',
                      helperText: s.streamUrlHelperLocal,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _testConnection(ConnKind.local),
                    icon: const Icon(Icons.network_check),
                    label: Text(s.testConn),
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
                    title: Text(s.connInetTitle),
                    subtitle: _kind == ConnKind.inet ? Text(s.activeNow) : null,
                    secondary: const Icon(Icons.cloud_outlined),
                    contentPadding: EdgeInsets.zero,
                  ),
                  TextField(
                    controller: _iUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: s.robotAddress,
                      hintText: 'https://robot.myhome3.netcraze.link',
                      helperText: s.inetAddressHelper,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.public),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _iPort,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: s.streamPort,
                      hintText: '81',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.videocam_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _iStream,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: s.streamUrlOptional,
                      hintText: 'https://stream.myhome3.netcraze.link',
                      helperText: s.streamUrlHelperInet,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.cloud_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _testConnection(ConnKind.inet),
                    icon: const Icon(Icons.network_check),
                    label: Text(s.testConn),
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
            _section(s.sectionRobot),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_rs == null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(s.robotSilent),
              ),
              OutlinedButton.icon(
                onPressed: _loadStatus,
                icon: const Icon(Icons.refresh),
                label: Text(s.retry),
              ),
            ] else
              ..._robotRows(),
            _section(s.sectionApp),
            // язык интерфейса: пункты — на самих языках (Русский/English),
            // применяется сразу и запоминается
            DropdownButtonFormField<AppLocale>(
              initialValue: widget.store.locale,
              decoration: InputDecoration(
                labelText: s.language,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.translate),
              ),
              items: const [
                DropdownMenuItem(value: AppLocale.ru, child: Text('Русский')),
                DropdownMenuItem(value: AppLocale.en, child: Text('English')),
              ],
              onChanged: (AppLocale? v) {
                if (v == null || v == localeNotifier.value) {
                  return;
                }
                setState(() {}); // сам список
                localeNotifier.value = v; // всё дерево — через слушателя
                unawaited(widget.store.saveLocale(v));
              },
            ),
            const SizedBox(height: 12),
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
              decoration: InputDecoration(
                labelText: s.currentPin,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
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
              decoration: InputDecoration(
                labelText: s.newPin,
                border: const OutlineInputBorder(),
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
              decoration: InputDecoration(
                labelText: s.repeatNewPin,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _changePin,
              icon: const Icon(Icons.key),
              label: Text(s.changePin),
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
    final Strings s = L10n.of(context);
    final RobotSettings rs = _rs!;
    final bool buttonsMode = rs.ctrl == 0;
    return [
      DropdownButtonFormField<int>(
        initialValue: rs.quality,
        decoration: InputDecoration(
          labelText: s.videoQuality,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (int i = 0; i < s.qualityLabels.length; i++)
            DropdownMenuItem(value: i, child: Text(s.qualityLabels[i])),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam(
                s.videoQuality,
                (r) => r.copyWith(quality: v),
                'quality',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.rot,
        decoration: InputDecoration(
          labelText: s.frameRotation,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final int deg in RobotSettings.rotSteps)
            DropdownMenuItem(value: deg, child: Text('$deg°')),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam(
                s.frameRotation,
                (r) => r.copyWith(rot: v),
                'rot',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.ctrl,
        decoration: InputDecoration(
          labelText: s.control,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (int i = 0; i < s.ctrlLabels.length; i++)
            DropdownMenuItem(value: i, child: Text(s.ctrlLabels[i])),
        ],
        onChanged: (v) => v == null ? null : _changeCtrl(v),
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(s.light),
        value: rs.light != 0,
        onChanged: (on) => _setParam(
          s.light,
          (r) => r.copyWith(light: on ? 1 : 0),
          'light',
          on ? '1' : '0',
        ),
      ),
      DropdownButtonFormField<int>(
        initialValue: rs.color,
        decoration: InputDecoration(
          labelText: s.lightColor,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (int i = 0; i < s.colorLabels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 7,
                    backgroundColor: RobotSettings.colorSwatches[i],
                  ),
                  const SizedBox(width: 10),
                  Text(s.colorLabels[i]),
                ],
              ),
            ),
        ],
        onChanged: (v) => v == null
            ? null
            : _setParam(
                s.lightColor,
                (r) => r.copyWith(color: v),
                'color',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.activeSpeed,
        decoration: InputDecoration(
          labelText: s.drivePower,
          border: const OutlineInputBorder(),
        ),
        items: _powerItems(rs.activeSpeed),
        onChanged: (v) => v == null
            ? null
            : _setParam(
                s.drivePower,
                (r) =>
                    buttonsMode ? r.copyWith(speed: v) : r.copyWith(pspeed: v),
                'speed',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: rs.activeTurn,
        decoration: InputDecoration(
          labelText: s.turnPower,
          border: const OutlineInputBorder(),
        ),
        items: _powerItems(rs.activeTurn),
        onChanged: (v) => v == null
            ? null
            : _setParam(
                s.turnPower,
                (r) => buttonsMode
                    ? r.copyWith(tspeed: v)
                    : r.copyWith(ptspeed: v),
                'tspeed',
                '$v',
              ),
      ),
      const SizedBox(height: 12),
      if (buttonsMode) ...[
        DropdownButtonFormField<int>(
          initialValue: rs.accel,
          decoration: InputDecoration(
            labelText: s.driveAccel,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final int ms in RobotSettings.accelSteps)
              DropdownMenuItem(value: ms, child: Text(s.accelLabel(ms))),
          ],
          onChanged: (v) => v == null
              ? null
              : _setParam(
                  s.driveAccel,
                  (r) => r.copyWith(accel: v),
                  'accel',
                  '$v',
                ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: rs.taccel,
          decoration: InputDecoration(
            labelText: s.turnAccel,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final int ms in RobotSettings.accelSteps)
              DropdownMenuItem(value: ms, child: Text(s.accelLabel(ms))),
          ],
          onChanged: (v) => v == null
              ? null
              : _setParam(
                  s.turnAccel,
                  (r) => r.copyWith(taccel: v),
                  'taccel',
                  '$v',
                ),
        ),
        const SizedBox(height: 12),
      ] else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(s.accelDisabledHere),
        ),
      _StartField(
        value: rs.start,
        onChanged: (int cl) => _setParam(
          s.startPoint,
          (r) => r.copyWith(start: cl),
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
