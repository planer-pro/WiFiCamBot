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
 *   /set?speed=N   — мощность моторов вперёд/назад, % (1..100)
 *   /set?tspeed=N  — мощность поворотов, % (1..100) — отдельно от хода
 *   /stream        — MJPEG-поток (multipart/x-mixed-replace), ОТДЕЛЬНЫЙ
 *                    сервер на порту 81: поток httpd один, и бесконечный
 *                    стрим-хэндлер блокирует остальные запросы (проверено).
 *
 * Настройки (качество, свет+цвет, обе мощности) сохраняются в NVS при каждом
 * изменении и восстанавливаются при включении питания — см. settingsLoad().
 *
 * Плюс приём прошивки по WiFi (ArduinoOTA, порт 3232) — см. setup().
 *
 * Данные WiFi — в src/wifi_secrets.h (в git не попадает, см. .gitignore;
 * образец — wifi_secrets.h.example).
 */

#include <Arduino.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include <Preferences.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "driver/rmt.h"
#include "driver/ledc.h"
#include "wifi_secrets.h"

#define HOSTNAME "esp32cam" // адрес будет http://esp32cam.local/

// ============================= НАСТРОЙКИ WiFi =============================
// SSID и пароль читаются из src/wifi_secrets.h. Файла нет — скопируйте
// wifi_secrets.h.example, впишите свои данные и прошейте заново.

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
// ПИНЫ ПОДКЛЮЧЕНИЯ — поменяйте под свою проводку (камере эти пины не нужны).
#define MOTOR_L_IN1_GPIO 1  // MX1508 IN1: левый мотор, вперёд
#define MOTOR_L_IN2_GPIO 2  // MX1508 IN2: левый мотор, назад
#define MOTOR_R_IN1_GPIO 3  // MX1508 IN3: правый мотор, вперёд
#define MOTOR_R_IN2_GPIO 14 // MX1508 IN4: правый мотор, назад
#define MOTOR_PWM_FREQ_HZ 20000   // выше слышимого диапазона — моторы не «пищат»
#define MOTOR_PWM_RES LEDC_TIMER_10_BIT
#define MOTOR_PWM_MAX 1023        // максимум duty при 10 битах
#define MOTOR_CMD_TIMEOUT_MS 1500 // нет команд так долго — стоп (обрыв WiFi)

static volatile char g_motorCmd = 's';      // f | b | l | r | s
static volatile int g_motorSpeed = 100;     // мощность вперёд/назад, %
static volatile int g_motorTurnSpeed = 100; // мощность поворотов, % (отдельно)
static volatile uint32_t g_motorLastMs = 0;

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

static void applyMotors()
{
  // ход и повороты — с раздельной мощностью (поворот на месте обычно
  // требует другой мощности, чем езда вперёд/назад)
  bool turn = (g_motorCmd == 'l' || g_motorCmd == 'r');
  int pct = turn ? g_motorTurnSpeed : g_motorSpeed;
  uint32_t duty = (uint32_t)MOTOR_PWM_MAX * pct / 100;
  char c = g_motorCmd;
  motorDuty(LEDC_CHANNEL_1, (c == 'f' || c == 'r') ? duty : 0); // левый вперёд
  motorDuty(LEDC_CHANNEL_2, (c == 'b' || c == 'l') ? duty : 0); // левый назад
  motorDuty(LEDC_CHANNEL_3, (c == 'f' || c == 'l') ? duty : 0); // правый вперёд
  motorDuty(LEDC_CHANNEL_4, (c == 'b' || c == 'r') ? duty : 0); // правый назад
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

// ==================== СОХРАНЕНИЕ НАСТРОЕК (NVS) ===========================
// Качество, свет (вкл/выкл + цвет) и обе мощности переживают перезагрузку
// питания: читаются здесь в setup(), пишутся в NVS при каждом изменении
// через /set. Направление движения (motor=) не сохраняется — оно мгновенное.
// Страница при открытии получает текущие значения метками (@Q@ и т.д.), так
// что после восстановления из NVS браузер всё покажет сам.
static Preferences s_prefs;

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

  int sp = (int)s_prefs.getUChar("speed", 100);
  g_motorSpeed = (sp >= 1 && sp <= 100) ? sp : 100;
  sp = (int)s_prefs.getUChar("tspeed", 100);
  g_motorTurnSpeed = (sp >= 1 && sp <= 100) ? sp : 100;
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
<title>ESP32-S3 камера</title>
<style>
  body { font-family: sans-serif; background: #111; color: #eee;
         margin: 0; padding: 8px; text-align: center; }
  a   { color: #8cf; }
  select { background: #222; color: #eee; border: 1px solid #444;
           padding: 4px 8px; }
  button { background: #222; color: #eee; border: 1px solid #444;
           padding: 5px 14px; cursor: pointer; }
  button.on { background: #a60; border-color: #fc5; color: #fff; }
  /* Кадр 4:3 поворачивается на странице (список «Поворот кадра»: 0/90/180/
     270). Функция setRotation в JS пересчитывает аспект сцены и размер
     картинки под угол — повёрнутый кадр заполняет сцену целиком, без чёрных
     полос; рамка (border у картинки) крутится вместе с кадром. Здесь в CSS —
     умолчание 90° по часовой (камера на платформе стоит повёрнутой). */
  .stage {
    position: relative;
    height: min(82vh, calc(100vh - 160px)); /* кадр + пульт под ним */
    aspect-ratio: 3 / 4;   /* пропорции повёрнутого кадра 4:3 */
    max-width: 100%;
  }
  .stage img {
    position: absolute;
    top: 50%;
    left: 50%;
    width: 133.333%;       /* = высота сцены (4:3, повёрнуто на 90°) */
    transform: translate(-50%, -50%) rotate(90deg);
    border: 1px solid #444;
    background: #000;
  }
  /* Видео и панель управления — в одну строку, чтобы всё влезало на экран;
     на узких экранах панель уходит под видео. */
  .row { display: flex; gap: 12px; justify-content: center;
         align-items: stretch; }
  /* Колонка «видео + пульт»: пульт центрируется относительно видео,
     а не всей страницы (панель настроек сбоку видео больше не сдвигает). */
  .col { display: flex; flex-direction: column; align-items: center; }
  .panel { display: flex; flex-direction: column; gap: 6px;
           width: 180px; flex: none; }
  .panel .lbl { font-size: 12px; color: #aaa; text-align: left;
                margin: 6px 0 0; }
  .panel select { width: 100%; box-sizing: border-box; font-size: 14px; }
  .pair { display: flex; gap: 6px; }
  .pair select { flex: 1; min-width: 0; }
  @media (max-width: 620px) {
    .row { flex-direction: column; align-items: center; }
    .stage { height: 55vh; }
    .panel { width: min(320px, 100%); }
  }
  /* Пульт гусениц: кнопки или клавиши (стрелки / WASD), удерживать.
     touch-action и запрет выделения — чтобы кнопка не скроллила страницу
     и не выделялась «подсветкой» при удержании. */
  .pad { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px;
         width: 100%; max-width: 280px; margin: 10px 0 0; }
  .pad button { height: 50px; font-size: 18px; user-select: none;
                -webkit-user-select: none; touch-action: none; }
  .pad button.on { background: #060; border-color: #4c6; color: #fff; }
</style>
</head>
<body>
<div class="row">
<div class="col">
<div class="stage" id="stage"><img id="stream" alt="видеопоток"></div>
<div class="pad" id="pad">
  <span></span><button data-dir="f">&#9650; W</button><span></span>
  <button data-dir="l">&#9664; A</button><button data-dir="b">&#9660; S</button><button data-dir="r">&#9654; D</button>
</div>
</div>
<div class="panel">
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
<span class="lbl">Свет</span>
<div class="pair">
<button id="light">вкл</button>
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
<span class="lbl">Мощность: вперёд/назад</span>
<select id="speed">
  <option value="25">25%</option>
  <option value="50">50%</option>
  <option value="75">75%</option>
  <option value="100">100%</option>
</select>
<span class="lbl">Мощность: повороты</span>
<select id="tspeed">
  <option value="25">25%</option>
  <option value="50">50%</option>
  <option value="75">75%</option>
  <option value="100">100%</option>
</select>
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
  // вместе с ним. Угол хранится на плате и подставляется меткой @R@.
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
  var colorSel = document.getElementById('color');
  colorSel.value = '@C@';
  function lightLabel()
  {
    lightBtn.textContent = lightOn ? 'вкл' : 'выкл';
    lightBtn.className = lightOn ? 'on' : '';
  }
  lightBtn.onclick = function () {
    lightOn = !lightOn;
    fetch('/set?light=' + (lightOn ? 1 : 0));
    lightLabel();
  };
  colorSel.onchange = function () { fetch('/set?color=' + colorSel.value); };
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
  window.addEventListener('blur', function () { stack = []; applyTop(); });
  window.addEventListener('pagehide', function () {
    fetch('/set?motor=s', {keepalive: true});
  });
  var speedSel = document.getElementById('speed');
  speedSel.value = '@S@';
  speedSel.onchange = function () { fetch('/set?speed=' + speedSel.value); };
  var turnSel = document.getElementById('tspeed');
  turnSel.value = '@T@';
  turnSel.onchange = function () { fetch('/set?tspeed=' + turnSel.value); };
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
  char query[64] = {0}, val[8] = {0};
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
    else if (httpd_query_key_value(query, "speed", val, sizeof(val)) == ESP_OK)
    {
      int pct = atoi(val);
      if (pct >= 1 && pct <= 100)
      {
        g_motorSpeed = pct;
        applyMotors();
        s_prefs.putUChar("speed", (uint8_t)pct);
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
        s_prefs.putUChar("tspeed", (uint8_t)pct);
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
  // подставляем текущие значения вместо меток @Q@/@L@/@C@/@S@/@T@/@R@ в странице
  const char *marks[6] = {"@Q@", "@L@", "@C@", "@S@", "@T@", "@R@"};
  char qbuf[4], lbuf[4], cbuf[4], sbuf[4], tbuf[4], rbuf[4];
  const char *vals[6] = {qbuf, lbuf, cbuf, sbuf, tbuf, rbuf};
  int lens[6] = {
      snprintf(qbuf, sizeof(qbuf), "%d", (int)g_quality),
      snprintf(lbuf, sizeof(lbuf), "%d", g_lightOn ? 1 : 0),
      snprintf(cbuf, sizeof(cbuf), "%d", (int)g_lightColor),
      snprintf(sbuf, sizeof(sbuf), "%d", (int)g_motorSpeed),
      snprintf(tbuf, sizeof(tbuf), "%d", (int)g_motorTurnSpeed),
      snprintf(rbuf, sizeof(rbuf), "%d", (int)g_rotation)};
  const char *p = INDEX_HTML;
  while (*p)
  {
    // ищем ближайшую метку от текущей позиции
    const char *best = NULL;
    int bi = -1;
    for (int i = 0; i < 6; i++)
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
static void startWebServer()
{
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;

  httpd_handle_t server = NULL;
  if (httpd_start(&server, &config) == ESP_OK)
  {
    const httpd_uri_t uri_index = {
        .uri = "/", .method = HTTP_GET, .handler = index_handler, .user_ctx = NULL};
    const httpd_uri_t uri_set = {
        .uri = "/set", .method = HTTP_GET, .handler = set_handler, .user_ctx = NULL};
    httpd_register_uri_handler(server, &uri_index);
    httpd_register_uri_handler(server, &uri_set);
  }

  httpd_config_t streamConfig = HTTPD_DEFAULT_CONFIG();
  streamConfig.server_port = 81;
  streamConfig.ctrl_port += 1; // управляющий сокет второго сервера не должен совпадать

  httpd_handle_t streamServer = NULL;
  if (httpd_start(&streamServer, &streamConfig) == ESP_OK)
  {
    const httpd_uri_t uri_stream = {
        .uri = "/stream", .method = HTTP_GET, .handler = stream_handler, .user_ctx = NULL};
    httpd_register_uri_handler(streamServer, &uri_stream);
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

  WiFi.mode(WIFI_STA);
  WiFi.setHostname(HOSTNAME);
  WiFi.setSleep(false); // отключаем энергосбережение ради низкой задержки стрима
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED)
  {
    delay(500);
    if (millis() - t0 > 20000)
    {
      ESP.restart(); // не подключились за 20 с (SSID/пароль?) — старт заново
    }
  }

  if (MDNS.begin(HOSTNAME))
  {
    MDNS.addService("http", "tcp", 80);
  }

  startWebServer();

  // ========================= OTA-ОБНОВЛЕНИЕ ПРОШИВКИ =======================
  // Приём прошивки по WiFi (ArduinoOTA, UDP-порт 3232): после первой прошивки
  // по USB дальше можно шить без провода — pio run -e ota -t upload
  // (env «ota» в platformio.ini; адрес платы — esp32cam.local или её IP).
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
  // Страховка от «залипания» команды: пока страница удерживает направление,
  // она повторяет его каждые 500 мс; если повторов нет дольше таймаута
  // (обрыв WiFi, закрыли вкладку) — моторы останавливаем сами.
  if (g_motorCmd != 's' && millis() - g_motorLastMs > MOTOR_CMD_TIMEOUT_MS)
  {
    motorCommand('s');
  }
  delay(100);
}
