/**
 * ESP32-S3 (N16R8) + модуль камеры OV2640 от ESP32-CAM
 * Захват изображения с камеры и живой веб-просмотр по WiFi (MJPEG-стрим).
 *
 * Маршруты веб-сервера:
 *   /              — страница с живым видео (порт 80)
 *   /set?quality=N — качество: 0 мин. … 4 макс. (меняется на лету)
 *   /set?light=0|1 — RGB-светодиод платы: выключен / включён
 *   /set?color=N   — цвет светодиода (таблица LIGHT_COLORS, 0 = белый)
 *   /stream        — MJPEG-поток (multipart/x-mixed-replace), ОТДЕЛЬНЫЙ
 *                    сервер на порту 81: поток httpd один, и бесконечный
 *                    стрим-хэндлер блокирует остальные запросы (проверено).
 *
 * Данные WiFi — в src/wifi_secrets.h (в git не попадает, см. .gitignore;
 * образец — wifi_secrets.h.example).
 */

#include <Arduino.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "driver/rmt.h"
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

static volatile int g_quality = QUALITY_DEFAULT;

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
         margin: 0; padding: 16px; text-align: center; }
  a   { color: #8cf; }
  select { background: #222; color: #eee; border: 1px solid #444;
           padding: 4px 8px; }
  button { background: #222; color: #eee; border: 1px solid #444;
           padding: 5px 14px; cursor: pointer; }
  button.on { background: #a60; border-color: #fc5; color: #fff; }
  /* Кадр VGA 640x480 поворачивается на 90° по часовой стрелке.
     Сцена (.stage) имеет «повёрнутые» пропорции 3:4, картинка внутри —
     натуральные 4:3. Другой угол: rotate(-90deg) или rotate(180deg)
     (для 180° верните сцене пропорции 4/3 и ширину картинки 100%). */
  .stage {
    position: relative;
    height: 82vh;          /* повёрнутый кадр — вертикальный */
    aspect-ratio: 3 / 4;   /* пропорции повёрнутого VGA-кадра */
    max-width: 100%;
    margin: 0 auto;
  }
  .stage img {
    position: absolute;
    top: 50%;
    left: 50%;
    width: 133.333%;       /* = высота сцены (640/480) */
    transform: translate(-50%, -50%) rotate(90deg);
    border: 1px solid #444;
    background: #000;
  }
</style>
</head>
<body>
<h2>ESP32-S3 &mdash; живой просмотр</h2>
<div class="stage"><img id="stream" alt="видеопоток"></div>
<p>
Качество:
<select id="quality">
  <option value="0">минимальное (QVGA 320x240)</option>
  <option value="1">низкое (VGA 640x480)</option>
  <option value="2">среднее (VGA 640x480)</option>
  <option value="3">высокое (SVGA 800x600)</option>
  <option value="4">максимальное (UXGA 1600x1200)</option>
</select>
</p>
<p>
<button id="light">Свет: выкл</button>
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
</p>
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
  // RGB-светодиод: кнопка вкл/выкл и выбор цвета
  // (список цветов тут и в таблице LIGHT_COLORS должен совпадать)
  var lightOn = ('@L@' === '1');
  var lightBtn = document.getElementById('light');
  var colorSel = document.getElementById('color');
  colorSel.value = '@C@';
  function lightLabel()
  {
    lightBtn.textContent = lightOn ? 'Свет: вкл' : 'Свет: выкл';
    lightBtn.className = lightOn ? 'on' : '';
  }
  lightBtn.onclick = function () {
    lightOn = !lightOn;
    fetch('/set?light=' + (lightOn ? 1 : 0));
    lightLabel();
  };
  colorSel.onchange = function () { fetch('/set?color=' + colorSel.value); };
  lightLabel();
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

  applyQuality(QUALITY_DEFAULT); // фактический стартовый уровень (буферы — UXGA)
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
        httpd_resp_set_type(req, "text/plain");
        return httpd_resp_send(req, "OK", 2);
      }
    }
    else if (httpd_query_key_value(query, "light", val, sizeof(val)) == ESP_OK)
    {
      g_lightOn = (atoi(val) != 0);
      applyLight();
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
  // подставляем текущие значения вместо меток @Q@/@L@/@C@ в странице
  const char *marks[3] = {"@Q@", "@L@", "@C@"};
  char qbuf[4], lbuf[4], cbuf[4];
  const char *vals[3] = {qbuf, lbuf, cbuf};
  int lens[3] = {
      snprintf(qbuf, sizeof(qbuf), "%d", (int)g_quality),
      snprintf(lbuf, sizeof(lbuf), "%d", g_lightOn ? 1 : 0),
      snprintf(cbuf, sizeof(cbuf), "%d", (int)g_lightColor)};
  const char *p = INDEX_HTML;
  while (*p)
  {
    // ищем ближайшую метку от текущей позиции
    const char *best = NULL;
    int bi = -1;
    for (int i = 0; i < 3; i++)
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
  applyLight(); // светодиод гарантированно выключен с момента старта

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
}

// ================================= LOOP ===================================
// Всё обслуживание идёт в потоках httpd — здесь делать нечего.
void loop()
{
  delay(100);
}
