import 'package:flutter/material.dart';

/// Языки интерфейса приложения.
enum AppLocale { ru, en }

/// Выбор языка, общий для всего приложения. Инициализируется из хранилища
/// в main(), меняется из настроек («Приложение») — MaterialApp перечитывает.
final ValueNotifier<AppLocale> localeNotifier = ValueNotifier(AppLocale.ru);

/// Таблицы строк интерфейса. Лёгкая замена gen_l10n: две константные
/// константы-таблицы, доставка — InheritedWidget [L10n] над MaterialApp.
/// Подписи робота (качество, цвета, виды управления) обязаны идти по тем же
/// индексам, что таблицы прошивки (QUALITY_PRESETS / LIGHT_COLORS / ctrl).
class Strings {
  // не const: параметризованные строки — замыкания, константами не бывают
  Strings({
    required this.enterPin,
    required this.wrongPin,
    required this.signIn,
    required this.defaultPinHint,
    required this.eraseKey,
    required this.connLocal,
    required this.connInet,
    required this.connTooltip,
    required this.noAddress,
    required this.connecting,
    required this.disconnected,
    required this.lightTooltip,
    required this.ctrlMode,
    required this.ctrlNotAccepted,
    required this.robotRejected,
    required this.gamepadNotFound,
    required this.gamepadName,
    required this.settings,
    required this.robotAddressMissing,
    required this.openSettings,
    required this.streamStopped,
    required this.streamConnecting,
    required this.streamReconnecting,
    required this.done,
    required this.sectionConn,
    required this.connLocalTitle,
    required this.connInetTitle,
    required this.activeNow,
    required this.robotAddress,
    required this.robotAddressLocalHelper,
    required this.inetAddressHelper,
    required this.streamPort,
    required this.streamUrlOptional,
    required this.streamUrlHelperLocal,
    required this.streamUrlHelperInet,
    required this.testConn,
    required this.testing,
    required this.testOk,
    required this.testFail,
    required this.sectionRobot,
    required this.robotSilent,
    required this.retry,
    required this.sectionApp,
    required this.language,
    required this.currentPin,
    required this.newPin,
    required this.repeatNewPin,
    required this.changePin,
    required this.pinTooShort,
    required this.pinsMismatch,
    required this.pinWrong,
    required this.pinChanged,
    required this.videoQuality,
    required this.frameRotation,
    required this.control,
    required this.light,
    required this.lightColor,
    required this.drivePower,
    required this.turnPower,
    required this.driveAccel,
    required this.turnAccel,
    required this.accelDisabledHere,
    required this.startPoint,
    required this.startPointHelper,
    required this.accelOff,
    required this.secShort,
    required this.msShort,
    required this.qualityLabels,
    required this.ctrlLabels,
    required this.colorLabels,
  });

  // ---- экран входа ----
  final String enterPin;
  final String wrongPin;
  final String signIn;
  final String defaultPinHint;
  final String eraseKey;

  // ---- связь (главный экран) ----
  final String connLocal;
  final String connInet;
  final String Function(String kind) connTooltip;
  final String noAddress;
  final String connecting;
  final String disconnected;

  // ---- главный экран ----
  final String lightTooltip;
  final String ctrlMode;
  final String ctrlNotAccepted;
  final String Function(String what) robotRejected;
  final String gamepadNotFound;
  final String Function(String name) gamepadName;
  final String settings;
  final String robotAddressMissing;
  final String openSettings;
  final String streamStopped;
  final String streamConnecting;
  final String streamReconnecting;

  // ---- настройки ----
  final String done;
  final String sectionConn;
  final String connLocalTitle;
  final String connInetTitle;
  final String activeNow;
  final String robotAddress;
  final String robotAddressLocalHelper;
  final String inetAddressHelper;
  final String streamPort;
  final String streamUrlOptional;
  final String streamUrlHelperLocal;
  final String streamUrlHelperInet;
  final String testConn;
  final String testing;
  final String Function(String quality, String ctrl) testOk;
  final String testFail;
  final String sectionRobot;
  final String robotSilent;
  final String retry;
  final String sectionApp;
  final String language;
  final String currentPin;
  final String newPin;
  final String repeatNewPin;
  final String changePin;
  final String pinTooShort;
  final String pinsMismatch;
  final String pinWrong;
  final String pinChanged;
  final String videoQuality;
  final String frameRotation;
  final String control;
  final String light;
  final String lightColor;
  final String drivePower;
  final String turnPower;
  final String driveAccel;
  final String turnAccel;
  final String accelDisabledHere;
  final String startPoint;
  final String startPointHelper;

  // ---- подписи робота ----
  final String accelOff;
  final List<String> qualityLabels;
  final List<String> ctrlLabels;
  final List<String> colorLabels;

  /// «0.2 с» / «1 с» — разгон в секундах, прочие значения в мс.
  String accelMs(int ms) => switch (ms) {
    200 => '0.2 $secShort',
    500 => '0.5 $secShort',
    1000 => '1 $secShort',
    _ => '$ms $msShort',
  };

  /// Короткие обозначения единиц: «с»/«мс» или «s»/«ms».
  final String secShort;
  final String msShort;

  String accelLabel(int ms) => ms == 0 ? accelOff : accelMs(ms);
}

final Strings _ru = Strings(
  enterPin: 'Введите пароль',
  wrongPin: 'Неверный пароль',
  signIn: 'Войти',
  defaultPinHint: 'Стандартный пароль: 1234\n(меняется в настройках)',
  eraseKey: 'Стереть',
  connLocal: 'Локальное',
  connInet: 'Интернет',
  connTooltip: (kind) => 'Подключение: $kind',
  noAddress: 'Адрес не задан',
  connecting: 'Подключение…',
  disconnected: 'Нет связи',
  lightTooltip: 'Свет — переключить; удержание — цвет',
  ctrlMode: 'Вид управления',
  ctrlNotAccepted: 'Робот не принял вид управления',
  robotRejected: (what) => 'Робот не принял «$what»',
  gamepadNotFound: 'Геймпад не найден — подключите его к телефону',
  gamepadName: (name) => 'Геймпад: $name',
  settings: 'Настройки',
  robotAddressMissing: 'Адрес робота не задан',
  openSettings: 'Открыть настройки',
  streamStopped: 'стрим остановлен',
  streamConnecting: 'подключение к стриму…',
  streamReconnecting: 'связь потеряна, переподключение…',
  done: 'Готово',
  sectionConn: 'Подключение',
  connLocalTitle: 'Подключение локальное',
  connInetTitle: 'Подключение интернет',
  activeNow: 'активно — используется сейчас',
  robotAddress: 'Адрес робота',
  robotAddressLocalHelper:
      'В сети робота (дома); wificambot.local на Android обычно '
      'не резолвится — вводите IP',
  inetAddressHelper: 'Внешний адрес/туннель или домен Keenetic',
  streamPort: 'Порт стрима',
  streamUrlOptional: 'Полный URL стрима (необязательно)',
  streamUrlHelperLocal:
      'Когда стрим доступен по отдельному адресу. '
      'Пусто — адрес робота + порт стрима',
  streamUrlHelperInet:
      'Когда стрим доступен по отдельному адресу (облако Keenetic). '
      'Пусто — адрес робота + порт стрима',
  testConn: 'Проверить связь',
  testing: 'Проверяю…',
  testOk: (q, c) => 'Робот отвечает ($q), вид управления: $c',
  testFail: 'Нет ответа — проверьте адрес и что робот в сети',
  sectionRobot: 'Робот',
  robotSilent: 'Робот не отвечает — проверьте адрес и связь',
  retry: 'Повторить',
  sectionApp: 'Приложение',
  language: 'Язык',
  currentPin: 'Текущий пароль',
  newPin: 'Новый пароль',
  repeatNewPin: 'Повторите новый пароль',
  changePin: 'Сменить пароль',
  pinTooShort: 'Новый пароль — не меньше 4 цифр',
  pinsMismatch: 'Новый пароль и повтор не совпадают',
  pinWrong: 'Текущий пароль неверный',
  pinChanged: 'Пароль изменён',
  videoQuality: 'Качество видео',
  frameRotation: 'Поворот кадра',
  control: 'Управление',
  light: 'Свет',
  lightColor: 'Цвет света',
  drivePower: 'Мощность хода, %',
  turnPower: 'Мощность поворотов, %',
  driveAccel: 'Разгон хода',
  turnAccel: 'Разгон поворотов',
  accelDisabledHere:
      'Разгоны в этом виде управления отключены (движение мгновенное)',
  startPoint: 'Точка страгивания, % ШИМ (0–90)',
  startPointHelper:
      'Мощность, ниже которой танк не трогается; '
      'Enter — применить',
  accelOff: 'отключено',
  secShort: 'с',
  msShort: 'мс',
  qualityLabels: [
    'минимальное (QVGA 320×240)',
    'низкое (VGA 640×480)',
    'среднее (VGA 640×480)',
    'высокое (SVGA 800×600)',
    'максимальное (UXGA 1600×1200)',
  ],
  ctrlLabels: ['Кнопки', 'Трекпад', 'Геймпад'],
  colorLabels: [
    'белый',
    'красный',
    'оранжевый',
    'жёлтый',
    'зелёный',
    'голубой',
    'синий',
    'пурпурный',
  ],
);

final Strings _en = Strings(
  enterPin: 'Enter password',
  wrongPin: 'Wrong password',
  signIn: 'Sign in',
  defaultPinHint: 'Default password: 1234\n(change it in Settings)',
  eraseKey: 'Delete',
  connLocal: 'Local',
  connInet: 'Internet',
  connTooltip: (kind) => 'Connection: $kind',
  noAddress: 'No address set',
  connecting: 'Connecting…',
  disconnected: 'No connection',
  lightTooltip: 'Light — toggle; hold for color',
  ctrlMode: 'Control mode',
  ctrlNotAccepted: 'Robot rejected the control mode',
  robotRejected: (what) => 'Robot rejected "$what"',
  gamepadNotFound: 'No gamepad — connect one to the phone',
  gamepadName: (name) => 'Gamepad: $name',
  settings: 'Settings',
  robotAddressMissing: 'Robot address is not set',
  openSettings: 'Open settings',
  streamStopped: 'stream stopped',
  streamConnecting: 'connecting to stream…',
  streamReconnecting: 'connection lost, reconnecting…',
  done: 'Done',
  sectionConn: 'Connection',
  connLocalTitle: 'Local connection',
  connInetTitle: 'Internet connection',
  activeNow: 'active — in use now',
  robotAddress: 'Robot address',
  robotAddressLocalHelper:
      'On the robot’s network (home); wificambot.local usually does not '
      'resolve on Android — enter the IP',
  inetAddressHelper: 'External address/tunnel or Keenetic domain',
  streamPort: 'Stream port',
  streamUrlOptional: 'Full stream URL (optional)',
  streamUrlHelperLocal:
      'When the stream lives at a separate address. '
      'Empty — robot address + stream port',
  streamUrlHelperInet:
      'When the stream lives at a separate address (Keenetic cloud). '
      'Empty — robot address + stream port',
  testConn: 'Test connection',
  testing: 'Testing…',
  testOk: (q, c) => 'Robot responds ($q), control mode: $c',
  testFail: 'No response — check the address and that the robot is online',
  sectionRobot: 'Robot',
  robotSilent: 'Robot is not responding — check the address and connection',
  retry: 'Retry',
  sectionApp: 'App',
  language: 'Language',
  currentPin: 'Current password',
  newPin: 'New password',
  repeatNewPin: 'Repeat new password',
  changePin: 'Change password',
  pinTooShort: 'New password — at least 4 digits',
  pinsMismatch: 'New password and repeat do not match',
  pinWrong: 'Current password is wrong',
  pinChanged: 'Password changed',
  videoQuality: 'Video quality',
  frameRotation: 'Frame rotation',
  control: 'Control',
  light: 'Light',
  lightColor: 'Light color',
  drivePower: 'Drive power, %',
  turnPower: 'Turn power, %',
  driveAccel: 'Drive ramp-up',
  turnAccel: 'Turn ramp-up',
  accelDisabledHere:
      'Ramp-up is off in this control mode (movement is instant)',
  startPoint: 'Stall point, % PWM (0–90)',
  startPointHelper:
      'Power below which the tank won’t move; '
      'press Done to apply',
  accelOff: 'off',
  secShort: 's',
  msShort: 'ms',
  qualityLabels: [
    'lowest (QVGA 320×240)',
    'low (VGA 640×480)',
    'medium (VGA 640×480)',
    'high (SVGA 800×600)',
    'highest (UXGA 1600×1200)',
  ],
  ctrlLabels: ['Buttons', 'Trackpad', 'Gamepad'],
  colorLabels: [
    'white',
    'red',
    'orange',
    'yellow',
    'green',
    'cyan',
    'blue',
    'magenta',
  ],
);

/// InheritedWidget над MaterialApp: любой экран берёт строки через
/// [L10n.of]. Смена [localeNotifier] перестраивает всё дерево под MaterialApp.
class L10n extends InheritedWidget {
  const L10n({super.key, required this.locale, required super.child});

  final AppLocale locale;

  Strings get s => locale == AppLocale.en ? _en : _ru;

  static Strings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<L10n>()!.s;

  @override
  bool updateShouldNotify(L10n oldWidget) => oldWidget.locale != locale;
}
