/**
 * ESP32-S3 (N16R8) + модуль камеры OV2640 от ESP32-CAM
 * Захват изображения с камеры и живой веб-просмотр по WiFi (MJPEG-стрим).
 *
 * Маршруты веб-сервера:
 *   /              — страница с живым видео (порт 80)
 *   /set?quality=N — качество: 0 мин. … 4 макс. (меняется на лету)
 *   /set?light=0|1 — RGB-светодиод платы: выключен / включён
 *   /set?color=N   — цвет светодиода (таблица LIGHT_COLORS, 0 = белый)
 *   /set?rot=N     — поворот кадра на странице: 0/90/180/270 градусов
 *   /set?motor=X   — моторы гусениц (MX1508): f вперёд, b назад,
 *                    l/r поворот влево/вправо (разворот на месте), s стоп
 *   /set?mix=L,R   — трекпад на странице: раздельная мощность гусениц, %
 *                    от -100 до 100 (знак = направление); 0,0 — стоп
 *   /set?ctrl=N    — вид управления на странице: 0 кнопки, 1 трекпад;
 *                    в ответе — мощности выбранного вида "ход,поворот"
 *   /set?speed=N   — мощность моторов вперёд/назад, % (1..100; в трекпаде —
 *                    предел крайних положений по вертикали); у каждого вида
 *                    управления мощности свои, пишутся раздельно
 *   /set?tspeed=N  — мощность поворотов, % (1..100; в трекпаде — предел
 *                    по горизонтали) — отдельно от хода
 *   /set?accel=N   — разгон моторов вперёд/назад, мс от нуля до полной
 *                    мощности (0 — отключено; варианты — MOTOR_ACCEL_STEPS)
 *   /set?taccel=N  — разгон поворотов, мс (отдельно от хода); разгоны
 *                    действуют только в режиме кнопок — трекпад без них
 *   /stream        — MJPEG-поток (multipart/x-mixed-replace), ОТДЕЛЬНЫЙ
 *                    сервер на порту 81: поток httpd один, и бесконечный
 *                    стрим-хэндлер блокирует остальные запросы (проверено).
 *
 * Настройки (качество, свет+цвет, мощности — свои у каждого вида управления,
 * разгоны, вид управления) — в NVS
 * записываются при каждом изменении и восстанавливаются при включении
 * питания — см. settingsLoad().
 *
 * Плюс приём прошивки по WiFi (ArduinoOTA, порт 3232) — см. setup().
 *
 * WiFi: сеть выбирается через WiFiManager — если подключиться не удалось,
 * поднимается настроечная точка доступа WIFI_AP_NAME (имя — в
 * src/wifi_secrets.h, файл в git не попадает, см. .gitignore; образец —
 * wifi_secrets.h.example); выбранная сеть и пароль запоминаются в памяти
 * платы (NVS) и используются при следующих включениях.
 */

#include <Arduino.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include <Preferences.h>
#include <WiFiManager.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "driver/rmt.h"
#include "driver/ledc.h"
#include "wifi_secrets.h"

#define HOSTNAME "wificambot" // адрес будет http://wificambot.local/

// ============================= НАСТРОЙКИ WiFi =============================
// Сеть выбирается и запоминается через WiFiManager: если подключиться не
// удалось, плата поднимает настроечную точку доступа WIFI_AP_NAME (имя —
// в src/wifi_secrets.h), в ней открывается страница выбора сети; выбранная
// сеть и пароль сохраняются в энергонезависимой памяти платы.
#define WIFI_CONNECT_TIMEOUT_MS 15000 // столько ждём сеть до подъёма портала
#define WIFI_PORTAL_TIMEOUT_S 120     // портал без действий (сек) — перезапуск
#define WIFI_FAIL_PORTAL_MS 20000     // связь пропала так надолго — портал

static void wsSendColor(uint8_t r, uint8_t g, uint8_t b); // ниже по коду
static void applyLight();                                 // ниже по коду

// Общие настройки WiFiManager для обоих подъёмов портала: при старте
// (autoConnect из connectWiFi) и по пропаданию сети (startConfigPortal
// из loop). Таймауты: попытка подключения — WIFI_CONNECT_TIMEOUT_MS,
// портал без действий — WIFI_PORTAL_TIMEOUT_S, потом перезапуск.
static void wmConfigure(WiFiManager &wm)
{
  wm.setConnectTimeout(WIFI_CONNECT_TIMEOUT_MS / 1000);
  wm.setConfigPortalTimeout(WIFI_PORTAL_TIMEOUT_S);
  wm.setBreakAfterConfig(true);   // неудачные новые данные — снова в цикл попыток
  wm.setAPCallback([](WiFiManager *) { wsSendColor(0, 0, 255); }); // портал — синий
}

// Подключение к WiFi; при неудаче — настроечная точка доступа (WiFiManager).
// Возвращает управление только когда сеть подключена.
static void connectWiFi()
{
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true); // короткие пропадания ядро лечит само
  WiFi.setHostname(HOSTNAME);
  WiFi.setSleep(false); // отключаем энергосбережение ради низкой задержки стрима

  // Подключаемся к сети, сохранённой в NVS (выбранной когда-то через портал).
  // Не получилось за WIFI_CONNECT_TIMEOUT_MS — WiFiManager поднимет
  // настроечную точку доступа WIFI_AP_NAME со страницей выбора сети;
  // выбранное сохранится в NVS и плата подключится уже к нему.
  WiFiManager wm;
  wmConfigure(wm);
  if (!wm.autoConnect(WIFI_AP_NAME))
  {
    ESP.restart(); // таймаут портала — перезапуск и новая попытка
  }
  // Подключились: портал больше не активен — возвращаем сохранённый свет
  // (иначе синий индикатор портала остался бы гореть до ручного вкл/выкл).
  applyLight();
}

// ============================ ПИНЫ КАМЕРЫ =================================
// По умолчанию — распиновка Freenove ESP32-S3-WROOM CAM (самый частый вариант
// плат ESP32-S3 с 24-пиновым разъёмом под модуль камеры от ESP32-CAM).
// Если у вас ДРУГАЯ плата и камера не инициализируется — замените значения
// на пины из примера/схемы производителя вашей платы. Меняется только этот блок.
#define PWDN_GPIO_NUM -1  // питание камеры (на этом модуле не подключено)
#define RESET_GPIO_NUM -1 // сброс камеры (на этом модуле не подключено)
#define XCLK_GPIO_NUM 15  // тактовый сигнал сенсора
#define SIOD_GPIO_NUM 4   // I2C SDA (SCCB)
#define SIOC_GPIO_NUM 5   // I2C SCL (SCCB)
#define Y9_GPIO_NUM 16    // шина данных D7
#define Y8_GPIO_NUM 17    // шина данных D6
#define Y7_GPIO_NUM 18    // шина данных D5
#define Y6_GPIO_NUM 12    // шина данных D4
#define Y5_GPIO_NUM 10    // шина данных D3
#define Y4_GPIO_NUM 8     // шина данных D2
#define Y3_GPIO_NUM 9     // шина данных D1
#define Y2_GPIO_NUM 11    // шина данных D0
#define VSYNC_GPIO_NUM 6  // кадровая синхронизация
#define HREF_GPIO_NUM 7   // строчная синхронизация
#define PCLK_GPIO_NUM 13  // такт пикселей

// ========================= ПАРАМЕТРЫ КАМЕРЫ ===============================
#define XCLK_FREQ_HZ 20000000 // если артефакты/сбой DMA — попробуйте 16000000

// ========================== RGB-СВЕТОДИОД =================================
// Адресуемый светодиод WS2812, управляется со страницы: кнопка «Свет» + выбор
// цвета. Пин 48 подтверждён на этой плате тестом (Espressif DevKitC-1 и платы
// Freenove; 38 — старые ревизии DevKitC-1). -1 — отключить управление.
// Важно: штатный neopixelWrite() ядра 2.0.17 этот светодиод не зажигает —
// отправка идёт собственным драйвером ниже (wsSendColor).
#define RGB_LED_GPIO_NUM 48

// Уровни качества для переключателя на странице (/set?quality=N).
// Все разрешения 4:3 — чтобы поворот картинки на странице на 90° оставался
// корректным. jpeg_quality: 0-63, меньше = лучше качество.
struct QualityPreset
{
  const char *name;
  framesize_t framesize;
  int jpeg_quality;
};
static const QualityPreset QUALITY_PRESETS[] = {
    {"минимальное (QVGA 320x240)", FRAMESIZE_QVGA, 25},
    {"низкое (VGA 640x480)", FRAMESIZE_VGA, 18},
    {"среднее (VGA 640x480)", FRAMESIZE_VGA, 10},
    {"высокое (SVGA 800x600)", FRAMESIZE_SVGA, 8},
    {"максимальное (UXGA 1600x1200)", FRAMESIZE_UXGA, 6}};
#define QUALITY_DEFAULT 2 // стартовый уровень

// Угол поворота кадра на странице (CSS): 0 / 90 / 180 / 270 градусов.
// Камера на платформе стоит повёрнутой — потому умолчание 90 (по часовой).
#define ROTATION_DEFAULT 90

static volatile int g_quality = QUALITY_DEFAULT;
static volatile int g_rotation = ROTATION_DEFAULT;

// Цвета подсветки для выпадающего списка на странице (/set?color=N).
struct LightColor
{
  const char *name;
  uint8_t r, g, b;
};
// Порядок должен совпадать с <option> в INDEX_HTML ниже.
static const LightColor LIGHT_COLORS[] = {
    {"белый", 255, 255, 255},
    {"красный", 255, 0, 0},
    {"оранжевый", 255, 60, 0},
    {"жёлтый", 255, 160, 0},
    {"зелёный", 0, 255, 0},
    {"голубой", 0, 160, 255},
    {"синий", 0, 0, 255},
    {"пурпурный", 180, 0, 255}};
#define LIGHT_COLOR_DEFAULT 0 // белый

static volatile bool g_lightOn = false;
static volatile int g_lightColor = LIGHT_COLOR_DEFAULT;

// Отправка одного кадра WS2812 через RMT (канал 0, тик 50 нс). Собственная
// реализация вместо neopixelWrite(): проверено на этой плате — штатная из
// ядра 2.0.17 светодиод не зажигает, эта работает.
static bool s_wsRmtReady = false;

static void wsSendColor(uint8_t r, uint8_t g, uint8_t b)
{
#if RGB_LED_GPIO_NUM >= 0
  if (!s_wsRmtReady)
  {
    rmt_config_t cfg = RMT_DEFAULT_CONFIG_TX((gpio_num_t)RGB_LED_GPIO_NUM,
                                             RMT_CHANNEL_0);
    cfg.clk_div = 4; // 80 МГц / 4 = 20 МГц, тик 50 нс
    if (rmt_config(&cfg) != ESP_OK ||
        rmt_driver_install(RMT_CHANNEL_0, 0, 0) != ESP_OK)
    {
      return; // RMT недоступен — светодиод просто не заработает
    }
    s_wsRmtReady = true;
  }
  rmt_item32_t items[24];
  int i = 0;
  uint8_t cols[3] = {g, r, b}; // порядок байтов в WS2812: GRB
  for (int c = 0; c < 3; c++)
  {
    for (int bit = 7; bit >= 0; bit--)
    {
      bool one = cols[c] & (1 << bit);
      items[i].level0 = 1;
      items[i].duration0 = one ? 16 : 8; // 0.8 / 0.4 мкс
      items[i].level1 = 0;
      items[i].duration1 = one ? 8 : 16; // 0.4 / 0.8 мкс
      i++;
    }
  }
  rmt_write_items(RMT_CHANNEL_0, items, 24, true);
  rmt_wait_tx_done(RMT_CHANNEL_0, pdMS_TO_TICKS(100));
#endif
}

// Применяет текущие g_lightOn/g_lightColor к светодиоду (выключен — гасит).
static void applyLight()
{
  const LightColor &c = LIGHT_COLORS[g_lightColor];
  wsSendColor(g_lightOn ? c.r : 0, g_lightOn ? c.g : 0, g_lightOn ? c.b : 0);
}

// ====================== МОТОРЫ ГУСЕНИЦ (MX1508) ===========================
// Драйвер MX1508 — два канала: A (IN1/IN2) — левая гусеница, B (IN3/IN4) —
// правая. Танковая схема: ШИМ подаётся на один вход канала, второй при этом
// 0 — так выбирается направление. Повороты l/r — разворот на месте (гусеницы
// в противоположные стороны). Если гусеница крутится не в ту сторону —
// поменяйте местами пару пинов её канала (IN1<->IN2 или IN3<->IN4).
// Разгон — плавный набор мощности при старте (свой для хода и поворотов,
// 0 = отключено): рост скважности растянут на N мс, а стоп и ЛЮБОЕ снижение
// мощности всегда мгновенные — торможение не должно зависеть от настроек.
// ПИНЫ ПОДКЛЮЧЕНИЯ — поменяйте под свою проводку (камере эти пины не нужны).
#define MOTOR_L_IN1_GPIO 1  // MX1508 IN1: левый мотор, вперёд
#define MOTOR_L_IN2_GPIO 2  // MX1508 IN2: левый мотор, назад
#define MOTOR_R_IN1_GPIO 3  // MX1508 IN3: правый мотор, вперёд
#define MOTOR_R_IN2_GPIO 14 // MX1508 IN4: правый мотор, назад
#define MOTOR_PWM_FREQ_HZ 20000   // выше слышимого диапазона — моторы не «пищат»
#define MOTOR_PWM_RES LEDC_TIMER_10_BIT
#define MOTOR_PWM_MAX 1023        // максимум duty при 10 битах
#define MOTOR_CMD_TIMEOUT_MS 1500 // нет команд так долго — стоп (обрыв WiFi)

// Варианты разгона, мс от нуля до полной мощности (0 — отключено, старт
// сразу на полную). Порядок совпадает с <option> селектов в INDEX_HTML.
static const uint16_t MOTOR_ACCEL_STEPS[] = {0, 200, 500, 1000, 2000};
#define MOTOR_ACCEL_DEFAULT 500

static bool accelValid(int ms)
{
  for (int i = 0; i < (int)(sizeof(MOTOR_ACCEL_STEPS) / sizeof(MOTOR_ACCEL_STEPS[0])); i++)
  {
    if ((int)MOTOR_ACCEL_STEPS[i] == ms)
    {
      return true;
    }
  }
  return false;
}

static volatile char g_motorCmd = 's';      // f | b | l | r | s | m (m — трекпад)
static volatile int g_mixL = 0;             // трекпад: мощность левой/правой
static volatile int g_mixR = 0;             // гусеницы, % (-100..100, знак = ход)
static volatile int g_motorSpeed = 100;     // мощность вперёд/назад, %
static volatile int g_motorTurnSpeed = 100; // мощность поворотов, % (отдельно)
static volatile uint16_t g_accelMs = MOTOR_ACCEL_DEFAULT;     // разгон хода
static volatile uint16_t g_turnAccelMs = MOTOR_ACCEL_DEFAULT; // разгон поворотов
static volatile int g_ctrlMode = 0; // вид управления на странице: 0 кнопки, 1 трекпад
static volatile uint32_t g_motorLastMs = 0;
static uint32_t g_chDuty[4] = {0, 0, 0, 0};   // текущая скважность каналов
static uint32_t g_chTarget[4] = {0, 0, 0, 0}; // цель по команде/мощности
static volatile uint16_t g_chAccelMs = MOTOR_ACCEL_DEFAULT; // разгон активной команды

// Duty в один канал ШИМ моторов. Каналы 1-4 на таймере 1: канал 0 и таймер 0
// заняты камерой (XCLK) — их трогать нельзя.
static void motorDuty(ledc_channel_t ch, uint32_t duty)
{
  ledc_set_duty(LEDC_LOW_SPEED_MODE, ch, duty);
  ledc_update_duty(LEDC_LOW_SPEED_MODE, ch);
}

static void initMotors()
{
  ledc_timer_config_t timer = {};
  timer.speed_mode = LEDC_LOW_SPEED_MODE;
  timer.timer_num = LEDC_TIMER_1;
  timer.duty_resolution = MOTOR_PWM_RES;
  timer.freq_hz = MOTOR_PWM_FREQ_HZ;
  timer.clk_cfg = LEDC_AUTO_CLK;
  if (ledc_timer_config(&timer) != ESP_OK)
  {
    return; // без ШИМ моторы не поедут
  }

  const int pins[] = {MOTOR_L_IN1_GPIO, MOTOR_L_IN2_GPIO,
                      MOTOR_R_IN1_GPIO, MOTOR_R_IN2_GPIO};
  for (int i = 0; i < 4; i++)
  {
    ledc_channel_config_t ch = {};
    ch.gpio_num = pins[i];
    ch.speed_mode = LEDC_LOW_SPEED_MODE;
    ch.channel = (ledc_channel_t)(LEDC_CHANNEL_1 + i);
    ch.intr_type = LEDC_INTR_DISABLE;
    ch.timer_sel = LEDC_TIMER_1;
    ch.duty = 0; // на старте моторы гарантированно выключены
    ledc_channel_config(&ch);
  }
}

// Считает целевую скважность каналов по команде/мощности и применяет её:
// рост — оставляется на разгон (motorsTick в loop), если он включён;
// отключённый разгон и ЛЮБОЕ снижение (включая стоп) — применяются сразу.
// Для трекпада (команда 'm') мощность каждой гусеницы своя (g_mixL/g_mixR,
// знак = направление) — так смешиваются ход и поворот (езда по дуге).
static void applyMotors()
{
  uint32_t target[4]; // цель каналов: левый вперёд/назад, правый вперёд/назад
  if (g_motorCmd == 'm')
  {
    // трекпад без разгона: палец сам ведёт плавно, аппаратный разгон здесь —
    // только запаздывание; мощность тоже не ограничиваем — её задаёт палец
    g_chAccelMs = 0;
    const int mix[4] = {
        g_mixL > 0 ? g_mixL : 0,  // левый вперёд
        g_mixL < 0 ? -g_mixL : 0, // левый назад
        g_mixR > 0 ? g_mixR : 0,  // правый вперёд
        g_mixR < 0 ? -g_mixR : 0  // правый назад
    };
    for (int i = 0; i < 4; i++)
    {
      target[i] = (uint32_t)MOTOR_PWM_MAX * mix[i] / 100;
    }
  }
  else
  {
    // ход и повороты — с раздельной мощностью и раздельным разгоном
    // (поворот на месте обычно требует другой мощности, чем езда).
    // Мощность действует в обоих видах управления (в трекпаде ею же
    // ограничиваются крайние положения — страницу шлёт уже умноженный
    // микс, сюда доходят только клавиши). Разгон в режиме трекпада
    // ведёт себя как позиция «отключено» у списков разгона — и для
    // трекпада, и для клавиш: любое движение мгновенное. В режиме
    // кнопок мощность и разгон работают как настроено.
    bool turn = (g_motorCmd == 'l' || g_motorCmd == 'r');
    int pct = turn ? g_motorTurnSpeed : g_motorSpeed;
    g_chAccelMs = (g_ctrlMode == 1) ? 0 : (turn ? g_turnAccelMs : g_accelMs);
    uint32_t duty = (uint32_t)MOTOR_PWM_MAX * pct / 100;
    char c = g_motorCmd;
    const bool active[4] = {
        (c == 'f' || c == 'r'), // левый вперёд
        (c == 'b' || c == 'l'), // левый назад
        (c == 'f' || c == 'l'), // правый вперёд
        (c == 'b' || c == 'r')  // правый назад
    };
    for (int i = 0; i < 4; i++)
    {
      target[i] = active[i] ? duty : 0;
    }
  }
  for (int i = 0; i < 4; i++)
  {
    g_chTarget[i] = target[i];
    if (g_chAccelMs == 0 || g_chTarget[i] < g_chDuty[i])
    {
      g_chDuty[i] = g_chTarget[i];
    }
    motorDuty((ledc_channel_t)(LEDC_CHANNEL_1 + i), g_chDuty[i]);
  }
}

// Шаг разгона — вызывается из loop() с прошествием dt: плавно ведёт
// скважность вверх к цели (только вверх — снижение applyMotors делает сразу).
static void motorsTick(uint32_t dtMs)
{
  if (g_chAccelMs == 0)
  {
    return; // разгон отключён — всё применяется мгновенно в applyMotors
  }
  if (dtMs > 100)
  {
    dtMs = 100; // защита от пропусков цикла и самого первого вызова
  }
  uint32_t step = (uint32_t)MOTOR_PWM_MAX * dtMs / g_chAccelMs;
  if (step == 0)
  {
    step = 1; // даже самый медленный разгон понемногу двигается
  }
  bool changed = false;
  for (int i = 0; i < 4; i++)
  {
    if (g_chDuty[i] < g_chTarget[i])
    {
      g_chDuty[i] += step;
      if (g_chDuty[i] > g_chTarget[i])
      {
        g_chDuty[i] = g_chTarget[i];
      }
      changed = true;
    }
  }
  if (changed)
  {
    for (int i = 0; i < 4; i++)
    {
      motorDuty((ledc_channel_t)(LEDC_CHANNEL_1 + i), g_chDuty[i]);
    }
  }
}

static bool motorCommand(char c)
{
  if (c != 'f' && c != 'b' && c != 'l' && c != 'r' && c != 's')
  {
    return false;
  }
  g_motorCmd = c;
  g_motorLastMs = millis();
  applyMotors();
  return true;
}

// Трекпад: раздельная мощность гусениц -100..100% (знак = направление).
// 0,0 помечаем как 's' — это тот же стоп, что и у кнопок (таймаут команд
// в loop() и состояние покоя страницы видят одно и то же).
static void motorMix(int l, int r)
{
  if (l > 100)
    l = 100;
  else if (l < -100)
    l = -100;
  if (r > 100)
    r = 100;
  else if (r < -100)
    r = -100;
  g_mixL = l;
  g_mixR = r;
  g_motorCmd = (l == 0 && r == 0) ? 's' : 'm';
  g_motorLastMs = millis();
  applyMotors();
}

// ==================== СОХРАНЕНИЕ НАСТРОЕК (NVS) ===========================
// Качество, свет (вкл/выкл + цвет), обе мощности, разгоны и вид управления
// переживают перезагрузку питания: читаются здесь в setup(), пишутся в NVS
// при каждом изменении через /set. Направление движения (motor=/mix=) не
// сохраняется — оно мгновенное.
// Страница при открытии получает текущие значения метками (@Q@ и т.д.), так
// что после восстановления из NVS браузер всё покажет сам.
static Preferences s_prefs;

// Мощности у каждого вида управления СВОИ: кнопки — speed/tspeed, трекпад —
// pspeed/ptspeed; в g_motorSpeed/g_motorTurnSpeed всегда лежит пара активного
// вида (по g_ctrlMode). Заполняется при старте и при смене вида управления.
static void loadPowers()
{
  const bool pad = (g_ctrlMode == 1);
  int sp = (int)s_prefs.getUChar(pad ? "pspeed" : "speed", 100);
  g_motorSpeed = (sp >= 1 && sp <= 100) ? sp : 100;
  sp = (int)s_prefs.getUChar(pad ? "ptspeed" : "tspeed", 100);
  g_motorTurnSpeed = (sp >= 1 && sp <= 100) ? sp : 100;
}

static void settingsLoad()
{
  s_prefs.begin("cam", false); // пространство создаётся при первом обращении
  int q = (int)s_prefs.getUChar("quality", QUALITY_DEFAULT);
  if (q >= (int)(sizeof(QUALITY_PRESETS) / sizeof(QUALITY_PRESETS[0])))
  {
    q = QUALITY_DEFAULT;
  }
  g_quality = q;

  int r = (int)s_prefs.getUChar("rot", ROTATION_DEFAULT);
  if (r != 0 && r != 90 && r != 180 && r != 270)
  {
    r = ROTATION_DEFAULT;
  }
  g_rotation = r;

  g_lightOn = s_prefs.getBool("light", false);

  int c = (int)s_prefs.getUChar("color", LIGHT_COLOR_DEFAULT);
  if (c >= (int)(sizeof(LIGHT_COLORS) / sizeof(LIGHT_COLORS[0])))
  {
    c = LIGHT_COLOR_DEFAULT;
  }
  g_lightColor = c;

  int a = (int)s_prefs.getUShort("accel", MOTOR_ACCEL_DEFAULT);
  g_accelMs = accelValid(a) ? (uint16_t)a : MOTOR_ACCEL_DEFAULT;
  a = (int)s_prefs.getUShort("taccel", MOTOR_ACCEL_DEFAULT);
  g_turnAccelMs = accelValid(a) ? (uint16_t)a : MOTOR_ACCEL_DEFAULT;

  g_ctrlMode = (s_prefs.getUChar("ctrl", 0) == 1) ? 1 : 0; // вид управления
  loadPowers(); // мощности — пара активного вида (свои для кнопок/трекпада)
}

// ========================= СТРАНИЦА И СТРИМ ===============================
#define STREAM_BOUNDARY "123456789000000000000987654321"
static const char STREAM_CONTENT_TYPE[] =
    "multipart/x-mixed-replace;boundary=" STREAM_BOUNDARY;
static const char STREAM_BOUNDARY_PART[] = "\r\n--" STREAM_BOUNDARY "\r\n";
static const char STREAM_PART_HEADER[] =
    "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

static const char INDEX_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WiFiCamBot</title>
<style>
  :root {
    --bg: #0b0d10; --card: #14171c; --field: #0f1216;
    --border: #262c35; --border-hi: #3d4652;
    --text: #e8eaed; --muted: #9aa3ad;
    --accent: #55b2ff; --green: #2ecc71; --amber: #f5a623;
  }
  body { font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
         background: radial-gradient(120% 90% at 50% 0%, #131820 0%, var(--bg) 55%);
         color: var(--text); margin: 0; padding: 10px; text-align: center; }
  a   { color: var(--accent); }
  /* Поля и кнопки — тёмные, скруглённые; у селектов своя стрелка
     (нативная в тёмной теме рисуется то светлая, то тёмная) */
  select { appearance: none; -webkit-appearance: none;
           background-color: var(--field);
           background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6'%3E%3Cpath d='M1 1l4 4 4-4' stroke='%239aa3ad' stroke-width='1.5' fill='none' stroke-linecap='round'/%3E%3C/svg%3E");
           background-repeat: no-repeat; background-position: right 9px center;
           color: var(--text); border: 1px solid var(--border); border-radius: 8px;
           padding: 6px 26px 6px 9px; font-size: 13px; width: 100%;
           cursor: pointer; transition: border-color .15s, box-shadow .15s; }
  select:hover { border-color: var(--border-hi); }
  select:focus-visible { outline: none; border-color: var(--accent);
                         box-shadow: 0 0 0 2px rgba(85, 178, 255, .25); }
  button { background: var(--field); color: var(--text);
           border: 1px solid var(--border); border-radius: 8px;
           padding: 6px 14px; font-size: 13px; cursor: pointer;
           transition: border-color .15s, background .15s, box-shadow .15s; }
  button:hover { border-color: var(--border-hi); }
  /* Кадр 4:3 поворачивается на странице (список «Поворот кадра»: 0/90/180/
     270). Функция setRotation в JS пересчитывает аспект сцены и размер
     картинки под угол — повёрнутый кадр заполняет сцену целиком, без чёрных
     полос; рамка (border у картинки) крутится вместе с кадром. Здесь в CSS —
     умолчание 90° по часовой (камера на платформе стоит повёрнутой). */
  .stage {
    position: relative;
    height: min(82vh, calc(100vh - 170px)); /* кадр + пульт под ним */
    aspect-ratio: 3 / 4;   /* пропорции повёрнутого кадра 4:3 */
    max-width: 100%;
  }
  .stage img {
    position: absolute;
    top: 50%;
    left: 50%;
    width: 133.333%;       /* = высота сцены (4:3, повёрнуто на 90°) */
    transform: translate(-50%, -50%) rotate(90deg);
    border: 1px solid #2a313a;
    border-radius: 12px;
    background: #000;
    box-shadow: 0 12px 36px rgba(0, 0, 0, .55);
  }
  /* Видео и панель управления — в одну строку, чтобы всё влезало на экран;
     на узких экранах панель уходит под видео (группами в два столбца). */
  .row { display: flex; gap: 14px; justify-content: center;
         align-items: stretch; }
  /* Колонка «видео + пульт»: пульт центрируется относительно видео,
     а не всей страницы (панель настроек сбоку видео больше не сдвигает). */
  .col { display: flex; flex-direction: column; align-items: center; }
  /* Панель настроек — карточками-группами: Видео / Свет / Моторы */
  .panel { display: flex; flex-direction: column; gap: 10px;
           width: 210px; flex: none; }
  .group { background: var(--card); border: 1px solid var(--border);
           border-radius: 12px; padding: 10px 10px 11px;
           display: flex; flex-direction: column; gap: 5px; text-align: left; }
  .group .cap { font-size: 11px; font-weight: 600; letter-spacing: .08em;
                text-transform: uppercase; color: var(--muted); margin: 0; }
  .group .lbl { font-size: 11px; color: var(--muted); margin: 3px 0 0; }
  .pair { display: flex; gap: 6px; align-items: center; }
  .pair select { flex: 1; min-width: 0; }
  /* Кнопка света с точкой-индикатором выбранного цвета; ширина зафиксирована
     под «выкл» — при переключении вкл/выкл кнопка не меняет длину и не
     сдвигает соседний список цветов */
  #light { display: inline-flex; align-items: center; justify-content: center;
           gap: 7px; flex: none; min-width: 82px; }
  .dot { width: 10px; height: 10px; border-radius: 50%;
         border: 1px solid var(--muted); background: transparent; flex: none; }
  button.on { background: #3a2b09; border-color: var(--amber); color: #ffd98a;
              box-shadow: 0 0 12px rgba(245, 166, 35, .25); }
  /* Моторы: мощности и разгоны — сетка 2x2, подписи над полями */
  .mgrid { display: grid; grid-template-columns: 1fr 1fr; gap: 5px 6px; }
  /* Строка разгона — отдельная сетка на оба столбца родителя (иначе она
     стала бы одной ячейкой). .off — режим трекпада: разгон ему не нужен,
     строку гасим, поля отключаем (мощности при этом остаются активными —
     они ограничивают край круга трекпада) */
  .arow { display: grid; grid-template-columns: 1fr 1fr; gap: 5px 6px;
          grid-column: 1 / 3; }
  .arow.off { opacity: .45; }
  select:disabled, select:disabled:hover { border-color: var(--border);
                                           color: var(--muted);
                                           cursor: default; }
  @media (max-width: 620px) {
    .row { flex-direction: column; align-items: center; }
    .stage { height: 55vh; }
    .panel { width: 100%; flex-direction: row; flex-wrap: wrap; }
    .group { flex: 1 1 150px; }
  }
  /* Пульт гусениц: кнопки или клавиши (стрелки / WASD), удерживать.
     touch-action и запрет выделения — чтобы кнопка не скроллила страницу
     и не выделялась «подсветкой» при удержании. */
  .pad { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px;
         width: 100%; max-width: 280px; margin: 12px 0 0; }
  .pad button { height: 54px; font-size: 17px; border-radius: 12px;
                display: inline-flex; align-items: center;
                justify-content: center; gap: 6px;
                user-select: none; -webkit-user-select: none;
                touch-action: none; }
  .pad button .k { font-size: 11px; color: var(--muted); }
  .pad button.on { background: #0e3b22; border-color: var(--green);
                   color: #d9ffe8;
                   box-shadow: 0 0 16px rgba(46, 204, 113, .3); }
  .pad button.on .k { color: #93d8ab; }
  /* Трекпад — аналоговая альтернатива кнопкам пульта: палец задаёт
     направление и мощность, чем дальше от центра — тем быстрее. Крест —
     ориентир, ручка ездит за пальцем (сама события не ловит). */
  .track { position: relative; width: 100%; max-width: min(280px, 50vh);
           aspect-ratio: 1 / 1; background: var(--field);
           border: 1px solid var(--border); border-radius: 12px;
           margin: 12px 0 0; touch-action: none;
           user-select: none; -webkit-user-select: none; }
  .track.live { border-color: var(--green);
                box-shadow: 0 0 16px rgba(46, 204, 113, .3); }
  .track::before, .track::after { content: ''; position: absolute;
                                  background: var(--border); }
  .track::before { left: 8px; right: 8px; top: 50%; height: 1px; }
  .track::after { top: 8px; bottom: 8px; left: 50%; width: 1px; }
  .knob { position: absolute; left: 50%; top: 50%; width: 52px; height: 52px;
          border-radius: 50%; background: var(--card);
          border: 1px solid var(--border-hi);
          transform: translate(-50%, -50%); pointer-events: none; }
  .track.live .knob { border-color: var(--green); }
</style>
</head>
<body>
<div class="row">
<div class="col">
<div class="stage" id="stage"><img id="stream" alt="видеопоток"></div>
<div class="pad" id="pad">
  <span></span><button data-dir="f">&#9650;<span class="k">W</span></button><span></span>
  <button data-dir="l">&#9664;<span class="k">A</span></button><button data-dir="b">&#9660;<span class="k">S</span></button><button data-dir="r">&#9654;<span class="k">D</span></button>
</div>
<div class="track" id="track" style="display:none"><div class="knob" id="knob"></div></div>
</div>
<div class="panel">
<div class="group">
<span class="cap">Видео</span>
<span class="lbl">Качество</span>
<select id="quality">
  <option value="0">минимальное (QVGA 320x240)</option>
  <option value="1">низкое (VGA 640x480)</option>
  <option value="2">среднее (VGA 640x480)</option>
  <option value="3">высокое (SVGA 800x600)</option>
  <option value="4">максимальное (UXGA 1600x1200)</option>
</select>
<span class="lbl">Поворот кадра</span>
<select id="rot">
  <option value="0">0° — горизонтально</option>
  <option value="90">90° по часовой</option>
  <option value="180">180°</option>
  <option value="270">90° против часовой</option>
</select>
</div>
<div class="group">
<span class="cap">Свет</span>
<div class="pair">
<button id="light"><span class="dot" id="lightDot"></span><span id="lightTxt">вкл</span></button>
<select id="color">
  <option value="0">белый</option>
  <option value="1">красный</option>
  <option value="2">оранжевый</option>
  <option value="3">жёлтый</option>
  <option value="4">зелёный</option>
  <option value="5">голубой</option>
  <option value="6">синий</option>
  <option value="7">пурпурный</option>
</select>
</div>
</div>
<div class="group">
<span class="cap">Моторы</span>
<span class="lbl">Управление</span>
<select id="ctrl">
  <option value="0">кнопки (крестовина)</option>
  <option value="1">трекпад (плавный)</option>
</select>
<div class="mgrid">
<span class="lbl">вперёд/назад</span><span class="lbl">повороты</span>
<select id="speed">
  <option value="25">25%</option>
  <option value="50">50%</option>
  <option value="75">75%</option>
  <option value="100">100%</option>
</select>
<select id="tspeed">
  <option value="25">25%</option>
  <option value="50">50%</option>
  <option value="75">75%</option>
  <option value="100">100%</option>
</select>
<div class="arow" id="arow">
<span class="lbl">разгон</span><span class="lbl">разгон</span>
<select id="accel">
  <option value="0">отключено</option>
  <option value="200">0.2 с</option>
  <option value="500">0.5 с</option>
  <option value="1000">1 с</option>
  <option value="2000">2 с</option>
</select>
<select id="taccel">
  <option value="0">отключено</option>
  <option value="200">0.2 с</option>
  <option value="500">0.5 с</option>
  <option value="1000">1 с</option>
  <option value="2000">2 с</option>
</select>
</div>
</div>
</div>
</div>
</div>
<script>
  // Стрим обслуживает ОТДЕЛЬНЫЙ сервер на порту 81 (бесконечный /stream
  // блокирует поток httpd, а с ним и /set на порту 80 — см. startWebServer).
  // Относительной ссылки на другой порт не бывает — строим абсолютную.
  var streamUrl = 'http://' + location.hostname + ':81/stream';
  var img = document.getElementById('stream');
  img.src = streamUrl; // при обрыве потока перезапускаем его через секунду
  img.onerror = function () {
    setTimeout(function () { img.src = streamUrl + '?' + Date.now(); }, 1000);
  };
  // переключатель качества: применяется на плате, затем поток перезапускается
  var sel = document.getElementById('quality');
  sel.value = '@Q@';
  sel.onchange = function () {
    fetch('/set?quality=' + sel.value).then(function () {
      img.src = streamUrl + '?' + Date.now();
    });
  };
  // Поворот кадра: аспект сцены и размер картинки пересчитываются под угол,
  // чтобы кадр заполнял сцену целиком (без чёрных полей), рамка крутится
  // вместе с ним. Угол хранится на плате и приходит в страницу меткой.
  var stage = document.getElementById('stage');
  var rotSel = document.getElementById('rot');
  function setRotation(deg)
  {
    var vertical = (deg % 180 !== 0);
    stage.style.aspectRatio = vertical ? '3 / 4' : '4 / 3';
    img.style.width = vertical ? '133.333%' : '100%';
    img.style.transform = 'translate(-50%, -50%) rotate(' + deg + 'deg)';
  }
  rotSel.value = '@R@';
  setRotation(parseInt(rotSel.value, 10) || 0);
  rotSel.onchange = function () {
    var deg = parseInt(rotSel.value, 10);
    setRotation(deg);
    fetch('/set?rot=' + deg);
  };
  // RGB-светодиод: кнопка вкл/выкл и выбор цвета
  // (список цветов тут и в таблице LIGHT_COLORS должен совпадать)
  var lightOn = ('@L@' === '1');
  var lightBtn = document.getElementById('light');
  var lightTxt = document.getElementById('lightTxt');
  var lightDot = document.getElementById('lightDot');
  var colorSel = document.getElementById('color');
  colorSel.value = '@C@';
  // те же цвета, что в таблице LIGHT_COLORS прошивки — для точки-индикатора
  var LED_COLORS = ['#ffffff', '#ff0000', '#ff3c00', '#ffa000',
                    '#00ff00', '#00a0ff', '#0000ff', '#b400ff'];
  function lightLabel()
  {
    var c = LED_COLORS[+colorSel.value] || LED_COLORS[0];
    lightTxt.textContent = lightOn ? 'вкл' : 'выкл';
    lightBtn.className = lightOn ? 'on' : '';
    lightDot.style.background = lightOn ? c : 'transparent';
    lightDot.style.borderColor = c;
  }
  lightBtn.onclick = function () {
    lightOn = !lightOn;
    fetch('/set?light=' + (lightOn ? 1 : 0));
    lightLabel();
  };
  colorSel.onchange = function () {
    fetch('/set?color=' + colorSel.value);
    lightLabel();
  };
  lightLabel();
  // Моторы MX1508 (танковая схема). Управление: кнопки пульта или клавиши
  // (стрелки / WASD) — удерживать. Пока направление удерживается, команда
  // повторяется каждые 500 мс: если связь оборвётся, плата сама остановит
  // моторы по таймауту команды (MOTOR_CMD_TIMEOUT_MS).
  var KEY2DIR = {ArrowUp: 'f', KeyW: 'f', ArrowDown: 'b', KeyS: 'b',
                 ArrowLeft: 'l', KeyA: 'l', ArrowRight: 'r', KeyD: 'r'};
  var motorDir = 's'; // последняя отправленная команда
  var stack = [];     // удерживаемые направления, последнее — активное
  var keepalive = null;
  var padBtns = document.querySelectorAll('#pad button[data-dir]');
  function sendMotor(d) { fetch('/set?motor=' + d); }
  function motorUI()
  {
    for (var i = 0; i < padBtns.length; i++)
      padBtns[i].className =
          padBtns[i].getAttribute('data-dir') === motorDir ? 'on' : '';
  }
  function applyTop()
  {
    var d = stack.length ? stack[stack.length - 1] : 's';
    if (d === motorDir)
      return;
    motorDir = d;
    sendMotor(d);
    clearInterval(keepalive);
    keepalive = null;
    if (d !== 's')
      keepalive = setInterval(function () { sendMotor(motorDir); }, 500);
    motorUI();
  }
  function motorPress(d)
  {
    if (stack.indexOf(d) < 0)
      stack.push(d);
    applyTop();
  }
  function motorRelease(d)
  {
    var i = stack.indexOf(d);
    if (i >= 0)
      stack.splice(i, 1);
    applyTop();
  }
  Array.prototype.forEach.call(padBtns, function (b) {
    var d = b.getAttribute('data-dir');
    // preventDefault не даёт кнопке забрать фокус: иначе стрелки после
    // клика мышью попали бы в кнопку, а не в управление моторами
    b.addEventListener('pointerdown', function (ev) {
      ev.preventDefault();
      motorPress(d);
    });
    b.addEventListener('pointerup', function () { motorRelease(d); });
    b.addEventListener('pointerleave', function () { motorRelease(d); });
    b.addEventListener('pointercancel', function () { motorRelease(d); });
    b.addEventListener('contextmenu', function (ev) { ev.preventDefault(); });
  });
  document.addEventListener('keydown', function (ev) {
    var d = KEY2DIR[ev.code]; // e.code — работает и в русской раскладке
    if (!d)
      return;
    var t = ev.target && ev.target.tagName;
    if (t === 'SELECT' || t === 'INPUT' || t === 'TEXTAREA')
      return; // стрелки в выпадающем списке листают сам список
    ev.preventDefault(); // без этого стрелки скроллят страницу
    if (!ev.repeat)
      motorPress(d);
  });
  document.addEventListener('keyup', function (ev) {
    var d = KEY2DIR[ev.code];
    if (d)
      motorRelease(d);
  });
  // фокус ушёл из окна (Alt-Tab) или страница закрывается — моторы стоп
  window.addEventListener('blur', function () {
    stack = [];
    applyTop();
    if (trackRect)
      trackEnd(); // палец был на трекпаде — тоже отпустить (стоп)
  });
  window.addEventListener('pagehide', function () {
    fetch('/set?motor=s', {keepalive: true});
  });
  // Мощности: плата принимает через /set любые 1-100 %, а в списках — только
  // стандартные шаги. Если сохранено промежуточное значение (заданное напрямую
  // через адресную строку), добавляем его в список на лету — иначе
  // селект остался бы пустым.
  function applySelectValue(sel, val)
  {
    sel.value = val;
    if (sel.value !== val)
    {
      var o = document.createElement('option');
      o.value = val;
      o.textContent = val + '%';
      sel.appendChild(o);
      sel.value = val;
    }
  }
  var speedSel = document.getElementById('speed');
  applySelectValue(speedSel, '@S@');
  speedSel.onchange = function () { fetch('/set?speed=' + speedSel.value); };
  var turnSel = document.getElementById('tspeed');
  applySelectValue(turnSel, '@T@');
  turnSel.onchange = function () { fetch('/set?tspeed=' + turnSel.value); };
  // Разгон: время плавного набора мощности от нуля при старте (0 — отключено,
  // сразу на полную). Стоп всегда мгновенный. Список значений обязан
  // совпадать с таблицей MOTOR_ACCEL_STEPS в прошивке.
  var accelSel = document.getElementById('accel');
  accelSel.value = '@A@';
  accelSel.onchange = function () { fetch('/set?accel=' + accelSel.value); };
  var tAccelSel = document.getElementById('taccel');
  tAccelSel.value = '@B@';
  tAccelSel.onchange = function () { fetch('/set?taccel=' + tAccelSel.value); };
  // Вид управления — кнопки или трекпад (хранится на плате: метка @P@,
  // /set?ctrl=). Клавиши (стрелки/WASD) работают в обоих видах — это те же
  // команды motor= (в режиме трекпада клавиши едут на 100% и без разгона).
  var ctrlSel = document.getElementById('ctrl');
  var padEl = document.getElementById('pad');
  var arowEl = document.getElementById('arow');
  var trackEl = document.getElementById('track');
  var knob = document.getElementById('knob');
  // Трекпад: палец задаёт направление И мощность — отклонение от центра
  // даёт процент от настроенного предела (край круга = выбранная в списке
  // мощность; вертикаль — вперёд/назад, горизонталь — повороты, списки
  // мощности при этом активны и менять их можно на лету). Разгон на
  // трекпад не действует — поле гасится. Поворот
  // подмешивается к ходу (можно вести по дуге). В центре мёртвая зона —
  // робот стоит. Отпускание — стоп, пока палец удержан, команда
  // повторяется каждые 500 мс (та же страховка от обрыва, что у кнопок:
  // плата сама даёт стоп, если команд нет 1.5 с).
  var trackRect = null; // геометрия касания; не null — палец на трекпаде
  var trackVec = {x: 0, y: 0};
  var trackTimer = null;
  var mixSent = '';
  function trackMix()
  {
    // предел хода/поворота — из списков мощности (в режиме трекпада они
    // активны и ограничивают край круга); .value — строка, умножение
    // само приводит к числу
    var fwd = Math.round(-trackVec.y * speedSel.value); // ход, %
    var trn = Math.round(trackVec.x * turnSel.value);   // поворот, %
    function cl(v) { return v > 100 ? 100 : (v < -100 ? -100 : v); }
    return cl(fwd + trn) + ',' + cl(fwd - trn); // левая, правая гусеница
  }
  function trackSend(force)
  {
    var m = trackMix();
    if (force || m !== mixSent)
    {
      mixSent = m;
      fetch('/set?mix=' + m);
    }
  }
  function trackPoint(ev)
  {
    var x = (ev.clientX - trackRect.cx) / trackRect.rad;
    var y = (ev.clientY - trackRect.cy) / trackRect.rad;
    var len = Math.sqrt(x * x + y * y);
    if (len > 1) { x /= len; y /= len; } // палец за кругом — ведём по краю
    if (len < 0.12) { x = 0; y = 0; }    // мёртвая зона в центре
    trackVec.x = x;
    trackVec.y = y;
    knob.style.transform = 'translate(-50%,-50%) translate(' +
        (x * trackRect.kmax).toFixed(1) + 'px,' +
        (y * trackRect.kmax).toFixed(1) + 'px)';
    trackEl.className = (x !== 0 || y !== 0) ? 'track live' : 'track';
    trackSend(false);
  }
  function trackEnd()
  {
    if (trackTimer) { clearInterval(trackTimer); trackTimer = null; }
    trackRect = null;
    trackVec = {x: 0, y: 0};
    knob.style.transform = 'translate(-50%,-50%)';
    trackEl.className = 'track';
    trackSend(true); // отпустили — микс 0,0, это стоп
  }
  trackEl.addEventListener('pointerdown', function (ev) {
    ev.preventDefault();
    // захват указателя: продолжаем вести палец и за краем трекпада
    trackEl.setPointerCapture(ev.pointerId);
    var r = trackEl.getBoundingClientRect();
    trackRect = {cx: r.left + r.width / 2, cy: r.top + r.height / 2,
                 rad: r.width / 2, kmax: r.width / 2 - 32};
    trackTimer = setInterval(function () { trackSend(true); }, 500);
    trackPoint(ev);
  });
  trackEl.addEventListener('pointermove', function (ev) {
    if (trackRect)
      trackPoint(ev); // без нажатия (просто мышь над трекпадом) — игнор
  });
  trackEl.addEventListener('pointerup', trackEnd);
  trackEl.addEventListener('pointercancel', trackEnd);
  trackEl.addEventListener('contextmenu', function (ev) { ev.preventDefault(); });
  var accelSaved = null; // разгоны до входа в режим трекпада (вернуть обратно)
  function setCtrl(mode)
  {
    var track = (mode === '1');
    padEl.style.display = track ? 'none' : 'grid';
    trackEl.style.display = track ? 'block' : 'none';
    // мощности действуют в обоих видах управления: кнопкам задают скважность,
    // трекпаду — предел крайних положений (край круга = выбранная мощность),
    // поля всегда активны. Разгон — настройка кнопочного пульта: в режиме
    // трекпада строку гасим, поля делаем неактивными и показываем
    // «отключено» — в прошивке так же (любое движение мгновенное и для
    // трекпада, и для клавиш). Сохранённые разгоны возвращаем в режиме
    // кнопок (на плату ничего не пишем).
    arowEl.className = track ? 'arow off' : 'arow';
    accelSel.disabled = tAccelSel.disabled = track;
    if (track)
    {
      if (!accelSaved)
        accelSaved = [accelSel.value, tAccelSel.value];
      accelSel.value = '0';
      tAccelSel.value = '0';
    }
    else if (accelSaved)
    {
      accelSel.value = accelSaved[0];
      tAccelSel.value = accelSaved[1];
      accelSaved = null;
    }
    if (!track && trackRect)
      trackEnd(); // ушли с трекпада во время движения — остановиться
  }
  ctrlSel.value = '@P@';
  setCtrl(ctrlSel.value);
  ctrlSel.onchange = function () {
    setCtrl(ctrlSel.value);
    fetch('/set?ctrl=' + ctrlSel.value)
        .then(function (r) { return r.text(); })
        .then(function (s) {
          // мощности у каждого вида управления свои — плата присылает в
          // ответе пару выбранного вида, подставляем её в поля
          // (applySelectValue добавит нестандартное значение в список)
          var p = s.split(',');
          if (p.length == 2)
          {
            applySelectValue(speedSel, p[0]);
            applySelectValue(turnSel, p[1]);
          }
        });
  };
  motorUI();
</script>
</body>
</html>
)rawliteral";

// =========================== ИНИЦИАЛИЗАЦИЯ КАМЕРЫ ========================
static bool applyQuality(int level); // определяется ниже по коду

static bool initCamera()
{
  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;

  config.xclk_freq_hz = XCLK_FREQ_HZ;
  config.pixel_format = PIXFORMAT_JPEG; // OV2640 умеет аппаратный JPEG
  // Буферы кадров выделяются под размер ИЗ НАЧАЛЬНОЙ КОНФИГУРАЦИИ, поэтому
  // инициализируем сразу максимальным пресетом (UXGA) — иначе переключение
  // качества «вверх» на лету подвешивает поток. Фактический стартовый
  // уровень возвращаем сразу после init (applyQuality ниже).
  const int maxLevel = (int)(sizeof(QUALITY_PRESETS) / sizeof(QUALITY_PRESETS[0])) - 1;
  config.frame_size = QUALITY_PRESETS[maxLevel].framesize;
  config.jpeg_quality = QUALITY_PRESETS[QUALITY_DEFAULT].jpeg_quality;

  // С PSRAM — два буфера в PSRAM и захват последнего кадра (плавнее стрим),
  // без PSRAM — один буфер в обычной памяти.
  bool psram = psramFound();
  config.fb_count = psram ? 2 : 1;
  config.fb_location = psram ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM;
  config.grab_mode = CAMERA_GRAB_LATEST;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK)
  {
    return false; // вероятные причины: чужая распиновка, разъём, питание
  }

  sensor_t *s = esp_camera_sensor_get();
  if (s)
  {
    s->set_vflip(s, 0);      // перевернуть по вертикали: 1
    s->set_hmirror(s, 0);    // зеркально: 1
    s->set_brightness(s, 0); // -2..2
  }

  applyQuality(g_quality); // стартовый уровень — из NVS (по умолчанию QUALITY_DEFAULT)
  return true;
}

// ============================ HTTP-ХЭНДЛЕРЫ ===============================
// Применяет уровень качества (0..N-1) к сенсору на лету, без переинициализации.
static bool applyQuality(int level)
{
  if (level < 0 || level >= (int)(sizeof(QUALITY_PRESETS) / sizeof(QUALITY_PRESETS[0])))
    return false;
  sensor_t *s = esp_camera_sensor_get();
  if (!s)
    return false;
  const QualityPreset &p = QUALITY_PRESETS[level];
  s->set_framesize(s, p.framesize);
  s->set_quality(s, p.jpeg_quality);
  g_quality = level;
  return true;
}

// GET /set?quality=N | light=0|1 | color=N — управление со страницы.
// Цвет применяется сразу (если свет выключен — запоминается до включения).
static esp_err_t set_handler(httpd_req_t *req)
{
  char query[64] = {0}, val[8] = {0}, mixv[12] = {0};
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK)
  {
    if (httpd_query_key_value(query, "quality", val, sizeof(val)) == ESP_OK)
    {
      if (applyQuality(atoi(val)))
      {
        s_prefs.putUChar("quality", (uint8_t)g_quality);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "light", val, sizeof(val)) == ESP_OK)
    {
      g_lightOn = (atoi(val) != 0);
      applyLight();
      s_prefs.putBool("light", g_lightOn);
      httpd_resp_set_type(req, "text/plain");
      return httpd_resp_send(req, "OK", 2);
    }
    else if (httpd_query_key_value(query, "color", val, sizeof(val)) == ESP_OK)
    {
      int idx = atoi(val);
      if (idx >= 0 && idx < (int)(sizeof(LIGHT_COLORS) / sizeof(LIGHT_COLORS[0])))
      {
        g_lightColor = idx;
        applyLight();
        s_prefs.putUChar("color", (uint8_t)idx);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "rot", val, sizeof(val)) == ESP_OK)
    {
      int deg = atoi(val);
      if (deg == 0 || deg == 90 || deg == 180 || deg == 270)
      {
        g_rotation = deg;
        s_prefs.putUChar("rot", (uint8_t)deg);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "motor", val, sizeof(val)) == ESP_OK)
    {
      if (motorCommand(val[0]))
      {
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "mix", mixv, sizeof(mixv)) == ESP_OK)
    {
      char *comma = strchr(mixv, ','); // "L,R" — мощности левой/правой гусениц
      if (comma)
      {
        *comma = '\0';
        motorMix(atoi(mixv), atoi(comma + 1));
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "ctrl", val, sizeof(val)) == ESP_OK)
    {
      int m = atoi(val);
      if (m == 0 || m == 1)
      {
        g_ctrlMode = m;
        s_prefs.putUChar("ctrl", (uint8_t)m);
        // активной стала пара мощностей выбранного вида — отдаём её
        // странице (свои мощности для кнопок и трекпада)
        loadPowers();
        char pbuf[10]; // "100,100"
        snprintf(pbuf, sizeof(pbuf), "%d,%d", (int)g_motorSpeed,
                 (int)g_motorTurnSpeed);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, pbuf, strlen(pbuf));
      }
    }
    else if (httpd_query_key_value(query, "speed", val, sizeof(val)) == ESP_OK)
    {
      int pct = atoi(val);
      if (pct >= 1 && pct <= 100)
      {
        g_motorSpeed = pct;
        applyMotors();
        s_prefs.putUChar(g_ctrlMode == 1 ? "pspeed" : "speed", (uint8_t)pct);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "tspeed", val, sizeof(val)) == ESP_OK)
    {
      int pct = atoi(val);
      if (pct >= 1 && pct <= 100)
      {
        g_motorTurnSpeed = pct;
        applyMotors();
        s_prefs.putUChar(g_ctrlMode == 1 ? "ptspeed" : "tspeed", (uint8_t)pct);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "accel", val, sizeof(val)) == ESP_OK)
    {
      int ms = atoi(val);
      if (accelValid(ms))
      {
        g_accelMs = (uint16_t)ms;
        applyMotors();
        s_prefs.putUShort("accel", (uint16_t)ms);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "taccel", val, sizeof(val)) == ESP_OK)
    {
      int ms = atoi(val);
      if (accelValid(ms))
      {
        g_turnAccelMs = (uint16_t)ms;
        applyMotors();
        s_prefs.putUShort("taccel", (uint16_t)ms);
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
  }
  httpd_resp_send_404(req);
  return ESP_FAIL;
}

static esp_err_t index_handler(httpd_req_t *req)
{
  httpd_resp_set_type(req, "text/html");
  // страницу не кэшировать: после перепрошивки JS должен обновиться
  httpd_resp_set_hdr(req, "Cache-Control", "no-cache");
  // подставляем текущие значения вместо меток @Q@/@L@/@C@/@S@/@T@/@R@/@A@/@B@/
  // @P@ (@A@/@B@ — разгоны хода/поворотов, @P@ — вид управления)
  const char *marks[9] = {"@Q@", "@L@", "@C@", "@S@", "@T@", "@R@", "@A@", "@B@",
                          "@P@"};
  char qbuf[4], lbuf[4], cbuf[4], sbuf[4], tbuf[4], rbuf[4], abuf[8], bbuf[8],
      pbuf[4];
  const char *vals[9] = {qbuf, lbuf, cbuf, sbuf, tbuf, rbuf, abuf, bbuf, pbuf};
  int lens[9] = {
      snprintf(qbuf, sizeof(qbuf), "%d", (int)g_quality),
      snprintf(lbuf, sizeof(lbuf), "%d", g_lightOn ? 1 : 0),
      snprintf(cbuf, sizeof(cbuf), "%d", (int)g_lightColor),
      snprintf(sbuf, sizeof(sbuf), "%d", (int)g_motorSpeed),
      snprintf(tbuf, sizeof(tbuf), "%d", (int)g_motorTurnSpeed),
      snprintf(rbuf, sizeof(rbuf), "%d", (int)g_rotation),
      snprintf(abuf, sizeof(abuf), "%d", (int)g_accelMs),
      snprintf(bbuf, sizeof(bbuf), "%d", (int)g_turnAccelMs),
      snprintf(pbuf, sizeof(pbuf), "%d", (int)g_ctrlMode)};
  const char *p = INDEX_HTML;
  while (*p)
  {
    // ищем ближайшую метку от текущей позиции
    const char *best = NULL;
    int bi = -1;
    for (int i = 0; i < 9; i++)
    {
      if (lens[i] <= 0)
        continue;
      const char *f = strstr(p, marks[i]);
      if (f && (best == NULL || f < best))
      {
        best = f;
        bi = i;
      }
    }
    if (!best)
    {
      httpd_resp_send_chunk(req, p, strlen(p));
      break;
    }
    if (httpd_resp_send_chunk(req, p, best - p) != ESP_OK ||
        httpd_resp_send_chunk(req, vals[bi], lens[bi]) != ESP_OK)
    {
      return ESP_FAIL;
    }
    p = best + strlen(marks[bi]);
  }
  return httpd_resp_send_chunk(req, NULL, 0); // конец chunked-ответа
}

static esp_err_t stream_handler(httpd_req_t *req)
{
  char part_buf[64];
  esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK)
  {
    return res;
  }

  while (true)
  {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb)
    {
      res = ESP_FAIL;
      break;
    }

    res = httpd_resp_send_chunk(req, STREAM_BOUNDARY_PART,
                                strlen(STREAM_BOUNDARY_PART));
    if (res == ESP_OK)
    {
      size_t hlen = snprintf(part_buf, sizeof(part_buf),
                             STREAM_PART_HEADER, (unsigned)fb->len);
      res = httpd_resp_send_chunk(req, part_buf, hlen);
    }
    if (res == ESP_OK)
    {
      res = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
    }

    esp_camera_fb_return(fb);
    if (res != ESP_OK)
    {
      break; // клиент отключился
    }
  }

  // закрываем chunked-ответ
  httpd_resp_send_chunk(req, NULL, 0);
  return res == ESP_FAIL ? ESP_OK : res;
}

// ============================= ВЕБ-СЕРВЕР =================================
// esp_http_server обслуживает все соединения ОДНИМ потоком, а stream_handler
// не возвращается, пока клиент не отключится. На одном сервере это намертво
// блокирует /set — кнопка «Свет» и качество не работали при открытом стриме
// (проверено на железе: /set при открытом /stream не отвечает, после закрытия
// отвечает мгновенно). Поэтому ДВА экземпляра сервера: порт 80 — страница и
// управление, порт 81 — только стрим. Так же сделано в CameraWebServer.
static httpd_handle_t s_httpdMain = NULL;   // порт 80: страница и /set
static httpd_handle_t s_httpdStream = NULL; // порт 81: стрим

static void startWebServer()
{
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;

  if (httpd_start(&s_httpdMain, &config) == ESP_OK)
  {
    const httpd_uri_t uri_index = {
        .uri = "/", .method = HTTP_GET, .handler = index_handler, .user_ctx = NULL};
    const httpd_uri_t uri_set = {
        .uri = "/set", .method = HTTP_GET, .handler = set_handler, .user_ctx = NULL};
    httpd_register_uri_handler(s_httpdMain, &uri_index);
    httpd_register_uri_handler(s_httpdMain, &uri_set);
  }

  httpd_config_t streamConfig = HTTPD_DEFAULT_CONFIG();
  streamConfig.server_port = 81;
  streamConfig.ctrl_port += 1; // управляющий сокет второго сервера не должен совпадать

  if (httpd_start(&s_httpdStream, &streamConfig) == ESP_OK)
  {
    const httpd_uri_t uri_stream = {
        .uri = "/stream", .method = HTTP_GET, .handler = stream_handler, .user_ctx = NULL};
    httpd_register_uri_handler(s_httpdStream, &uri_stream);
  }
}

// Останавливает оба сервера (стрим-хэндлер бесконечный, но по закрытию
// сокета его отправки падают и он выходит). Нужна перед порталом
// WiFiManager из loop(): его страница занимает порт 80 — не остановив
// наши серверы, портал не поднялся бы.
static void stopWebServer()
{
  if (s_httpdStream)
  {
    httpd_stop(s_httpdStream);
    s_httpdStream = NULL;
  }
  if (s_httpdMain)
  {
    httpd_stop(s_httpdMain);
    s_httpdMain = NULL;
  }
}

// ================================ SETUP ===================================
void setup()
{
  settingsLoad(); // настройки из NVS — до всех применений (свет/качество/мощности)
  applyLight();   // применяем сохранённые свет и цвет
  initMotors();   // пины моторов в 0 — гусеницы не дёрнутся при старте

  if (!initCamera())
  {
    return; // без камеры сервер не поднимаем
  }

  connectWiFi();

  if (MDNS.begin(HOSTNAME))
  {
    MDNS.addService("http", "tcp", 80);
  }

  startWebServer();

  // ========================= OTA-ОБНОВЛЕНИЕ ПРОШИВКИ =======================
  // Приём прошивки по WiFi (ArduinoOTA, UDP-порт 3232): после первой прошивки
  // по USB дальше можно шить без провода — pio run -e ota -t upload
  // (env «ota» в platformio.ini; адрес платы — wificambot.local или её IP).
  // Собственный mDNS у библиотеки отключён: наш MDNS.begin уже поднят выше,
  // а повторный MDNS.begin() внутри ArduinoOTA.begin() сбросил бы имя хоста
  // и службу «http» — службу OTA регистрируем сами, в уже работающий mDNS.
  ArduinoOTA.setMdnsEnabled(false);
#ifdef OTA_PASSWORD
  ArduinoOTA.setPassword(OTA_PASSWORD); // пароль задан — без него прошить нельзя
#endif
  // Индикация на RGB-светодиоде (Serial-отладки на этой плате нет): синий —
  // начало приёма, от красного к зелёному — прогресс, зелёный — успех (плата
  // сама перезагружается), красный — ошибка.
  ArduinoOTA.onStart([]() { wsSendColor(0, 0, 255); });
  ArduinoOTA.onProgress([](unsigned int done, unsigned int total) {
    unsigned int pct = total ? done * 100 / total : 0;
    wsSendColor((uint8_t)(255 - 255 * pct / 100),
                (uint8_t)(255 * pct / 100), 0);
  });
  ArduinoOTA.onEnd([]() { wsSendColor(0, 255, 0); });
  ArduinoOTA.onError([](ota_error_t) { wsSendColor(255, 0, 0); });
  ArduinoOTA.begin();
#ifdef OTA_PASSWORD
  MDNS.enableArduino(3232, true); // служба _arduino._tcp для Arduino IDE / PlatformIO
#else
  MDNS.enableArduino(3232);
#endif
}

// ================================= LOOP ===================================
// Обслуживание страницы и стрима идёт в потоках httpd — здесь только приём
// OTA-прошивки. Во время обновления стрим может подтормаживать: запись во
// flash на время стирания сектора останавливает оба ядра — это нормально.
void loop()
{
  ArduinoOTA.handle();

  // Контроль связи: короткие пропадания лечит автореконнект ядра; если сети
  // нет дольше WIFI_FAIL_PORTAL_MS — поднимаем настроечную точку доступа
  // прямо здесь, не дожидаясь перезагрузки (без сети управлять роботом всё
  // равно нельзя). Портал ждёт выбора сети WIFI_PORTAL_TIMEOUT_S, при
  // таймауте — перезапуск и новая попытка. Серверы на время портала
  // останавливаем (порт 80 нужен порталу), после подключения поднимаем
  // заново. Блокирующий вызов: пока портал открыт, loop стоит — моторы к
  // этому моменту уже остановлены страховкой команд (1.5 с без команд).
  static uint32_t wifiDownSince = 0;
  if (WiFi.status() == WL_CONNECTED)
  {
    wifiDownSince = 0;
  }
  else if (wifiDownSince == 0)
  {
    wifiDownSince = millis();
  }
  else if (millis() - wifiDownSince > WIFI_FAIL_PORTAL_MS)
  {
    wifiDownSince = 0;
    stopWebServer();
    WiFiManager wm;
    wmConfigure(wm);
    if (!wm.startConfigPortal(WIFI_AP_NAME))
    {
      ESP.restart(); // таймаут портала — перезапуск и новая попытка
    }
    // Выбрали сеть и подключились: возвращаем свет (гасим синий индикатор
    // портала) и серверы — работаем дальше без перезагрузки.
    applyLight();
    startWebServer();
  }

  // Страховка от «залипания» команды: пока страница удерживает направление,
  // она повторяет его каждые 500 мс; если повторов нет дольше таймаута
  // (обрыв WiFi, закрыли вкладку) — моторы останавливаем сами.
  if (g_motorCmd != 's' && millis() - g_motorLastMs > MOTOR_CMD_TIMEOUT_MS)
  {
    motorCommand('s');
  }

  // Разгон моторов: плавно ведём скважность к цели. Частый цикл (20 мс) —
  // ради мелких шагов разгона; приёму OTA и контролю связи он не мешает.
  static uint32_t motorLastTick = 0;
  uint32_t now = millis();
  motorsTick(now - motorLastTick);
  motorLastTick = now;
  delay(20);
}
