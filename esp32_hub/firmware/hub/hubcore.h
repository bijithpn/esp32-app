// Hub core services (API v1): identity, capabilities, diagnostics, UDP discovery, request ids / idempotency,
// auth rate limiting, crash counters + safe mode, scene schedule, software dimming and OTA state.
// Included from hub.ino after the scene headers, before the HTTP handlers.
#pragma once
#include <esp_system.h>
#include <esp_ota_ops.h>
#include <WiFiUdp.h>

#define API_VERSION 1
#define DISCOVERY_PORT 41234
#define DISCOVERY_MAGIC "ESP32_HUB_DISCOVER_V1"
#define OTA_MODEL "esp32-hub"          // value of the X-Hub-Model header an update must carry (when it carries one)

void runCmd(JsonDocument& d, JsonDocument& r);   // hub.ino

// ============================ identity ============================
String deviceName = "ESP32 Hub";
uint16_t stateRev = 0;                 // bumped on every scene / state change; the app polls /api/ping and re-reads only when it moved
static inline void touchState() { stateRev++; }

// ============================ crash counters + safe mode ============================
uint8_t crashCount = 0;                // consecutive unclean resets (panic / watchdog / brownout); reset after a stable minute
uint32_t crashTotal = 0, bootCount = 0;
bool safeMode = false;                 // 3+ unclean resets in a row: skip the saved scene and MQTT so the board stays reachable
esp_reset_reason_t bootReason = ESP_RST_UNKNOWN;

const char* resetReasonStr(esp_reset_reason_t r) {
  switch (r) {
    case ESP_RST_POWERON: return "power_on";
    case ESP_RST_EXT: return "external_reset";
    case ESP_RST_SW: return "software_restart";
    case ESP_RST_PANIC: return "panic";
    case ESP_RST_INT_WDT: return "interrupt_watchdog";
    case ESP_RST_TASK_WDT: return "task_watchdog";
    case ESP_RST_WDT: return "other_watchdog";
    case ESP_RST_DEEPSLEEP: return "deep_sleep";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_SDIO: return "sdio";
    default: return "unknown";
  }
}

void bootDiagBegin() {
  bootReason = esp_reset_reason();
  bool unclean = bootReason == ESP_RST_PANIC || bootReason == ESP_RST_INT_WDT || bootReason == ESP_RST_TASK_WDT ||
                 bootReason == ESP_RST_WDT || bootReason == ESP_RST_BROWNOUT;
  crashCount = prefs.getUChar("crashes", 0);
  crashTotal = prefs.getUInt("crash_total", 0);
  bootCount = prefs.getUInt("boots", 0) + 1;
  prefs.putUInt("boots", bootCount);
  if (unclean) {
    crashCount = crashCount < 250 ? crashCount + 1 : crashCount;
    crashTotal++;
    prefs.putUChar("crashes", crashCount);
    prefs.putUInt("crash_total", crashTotal);
  }
  safeMode = crashCount >= 3;
  deviceName = prefs.getString("name", "ESP32 Hub");
  Serial.printf("[boot] reset=%s crashes=%u safe=%d boots=%u\n", resetReasonStr(bootReason), crashCount, safeMode, (unsigned)bootCount);
}

// After a minute of clean running the consecutive-crash counter goes back to zero.
void bootDiagTick() {
  static bool cleared = false;
  if (!cleared && millis() > 60000) {
    cleared = true;
    if (crashCount) { crashCount = 0; prefs.putUChar("crashes", 0); }
  }
}

// ============================ auth hardening ============================
static uint8_t authFails = 0;
static uint32_t authWindow = 0, authBlockUntil = 0;
bool authBlocked() { return authBlockUntil && (int32_t)(millis() - authBlockUntil) < 0; }
void authFailed() {                      // a wrong (not missing) token was presented
  uint32_t n = millis();
  if (n - authWindow > 60000) { authWindow = n; authFails = 0; }
  if (++authFails >= 6) { authBlockUntil = n + 30000; authFails = 0; Serial.println("[auth] too many wrong tokens: blocking 30 s"); }
}
bool tokenEq(const String& a, const String& b) {   // constant-time compare
  if (a.length() != b.length()) return false;
  uint8_t x = 0;
  for (size_t i = 0; i < a.length(); i++) x |= (uint8_t)a[i] ^ (uint8_t)b[i];
  return x == 0;
}

// ============================ request ids / idempotency ============================
// A command may carry "rid". If the same rid arrives again within two minutes (the app retrying after a lost reply) the
// stored answer is returned and the command is NOT run a second time.
struct IdemEntry { uint32_t h = 0; uint32_t at = 0; String res; };
static IdemEntry idem[8];
static uint8_t idemPos = 0;
static uint32_t fnv(const char* s) { uint32_t h = 2166136261u; while (*s) { h ^= (uint8_t)*s++; h *= 16777619u; } return h ? h : 1; }
bool idemLookup(const char* rid, String& out) {
  uint32_t h = fnv(rid), now = millis();
  for (auto& e : idem) if (e.h == h && now - e.at < 120000) { out = e.res; return true; }
  return false;
}
void idemStore(const char* rid, const String& res) {
  if (res.length() > 400) return;
  idem[idemPos] = {fnv(rid), (uint32_t)millis(), res};
  idemPos = (idemPos + 1) % 8;
}

const char* errCode(const char* e) {
  if (!e) return "command_failed";
  if (strstr(e, "unknown scene")) return "unknown_scene";
  if (strstr(e, "unknown cmd")) return "unknown_command";
  if (strstr(e, "bad rect") || strstr(e, "bad data") || strstr(e, "bad ")) return "bad_payload";
  if (strstr(e, "no memory")) return "no_memory";
  if (strstr(e, "hotspot")) return "own_hotspot";
  return "command_failed";
}

// Adds the v1 envelope fields next to the legacy ones ("ok", "error"), so old apps keep working.
void finishResponse(JsonDocument& r, const char* rid) {
  bool ok = r["ok"] | false;
  r["success"] = ok;
  r["deviceId"] = String("hub-") + deviceId;
  if (rid && *rid) r["requestId"] = rid;
  if (!ok) r["errorCode"] = errCode(r["error"] | (const char*)nullptr);
}

// ============================ capabilities / hello / diagnostics ============================
void buildCaps(JsonDocument& d) {
  d["deviceId"] = String("hub-") + deviceId;
  d["firmwareVersion"] = FW_VERSION;
  d["apiVersion"] = API_VERSION;
  JsonObject dp = d["display"].to<JsonObject>();
  dp["driver"] = "ST7735S"; dp["width"] = W; dp["height"] = H; dp["rotation"] = 1;
  dp["backlight"] = "fixed";            // LED pin is wired to 3V3: no hardware dimming
  JsonObject f = d["features"].to<JsonObject>();
  f["weather"] = true; f["music"] = true; f["notifications"] = true; f["animations"] = true;
  f["mqtt"] = true; f["ota"] = true; f["schedule"] = true; f["softDim"] = true; f["pairingMode"] = true;
  f["ble"] = bleAvailable; f["otaRollback"] = false; f["otaSigned"] = false; f["events"] = "poll";
  JsonObject l = d["limits"].to<JsonObject>();
  l["animationFrames"] = 7; l["maxBodyBytes"] = 9000; l["schedules"] = 8; l["canvas"] = "160x128";
}

void buildHello(JsonDocument& d) {
  bool online = WiFi.status() == WL_CONNECTED;
  d["type"] = "esp32_hub";
  d["device"] = "ESP32-Hub";           // legacy field older apps look for
  d["id"] = deviceId;
  d["deviceId"] = String("hub-") + deviceId;
  d["name"] = deviceName;
  d["ip"] = apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString();
  d["port"] = 80;
  d["fw"] = FW_VERSION;
  d["firmware"] = FW_VERSION;
  d["apiVersion"] = API_VERSION;
  d["ap"] = apMode;
  d["online"] = online;
  d["lock"] = lockOn;
  d["authRequired"] = lockOn && !apMode;
  d["pairing"] = apMode || hotspotOn;
  d["safeMode"] = safeMode;
  d["host"] = String("esp32-hub-") + deviceId + ".local";
  d["rev"] = stateRev;
  JsonArray c = d["caps"].to<JsonArray>();
  c.add("scenes"); c.add("weather"); c.add("music"); c.add("notify"); c.add("anim"); c.add("mqtt"); c.add("ota"); c.add("schedule"); c.add("diag");
}

extern uint32_t frameUsAvg, loopGapMax;
extern uint32_t lastClientMs;
extern bool otaBusy;
extern String otaState, otaError, otaFrom;
extern uint32_t otaWritten, otaTotal;

void buildDiag(JsonDocument& d) {
  d["deviceId"] = String("hub-") + deviceId;
  d["id"] = deviceId;
  d["fw"] = FW_VERSION;
  d["apiVersion"] = API_VERSION;
  d["uptime"] = millis() / 1000;
  d["resetReason"] = resetReasonStr(bootReason);
  d["crashes"] = crashCount;
  d["crashesTotal"] = crashTotal;
  d["boots"] = bootCount;
  d["safeMode"] = safeMode;
  d["scene"] = SCENES[curScene].id;
  JsonObject h = d["heap"].to<JsonObject>();
  uint32_t fr = ESP.getFreeHeap(), mb = ESP.getMaxAllocHeap();
  h["free"] = fr; h["min"] = ESP.getMinFreeHeap(); h["maxBlock"] = mb; h["size"] = ESP.getHeapSize();
  h["fragPct"] = fr ? 100 - (int)((uint64_t)mb * 100 / fr) : 0;
  d["loopStackFree"] = uxTaskGetStackHighWaterMark(nullptr) * 4;
  JsonObject w = d["wifi"].to<JsonObject>();
  w["mode"] = apMode ? "setup" : (hotspotOn ? "sta+pairing" : "sta");
  w["connected"] = WiFi.status() == WL_CONNECTED;
  w["ssid"] = apMode ? String(AP_SSID) : WiFi.SSID();
  w["rssi"] = apMode ? 0 : WiFi.RSSI();
  w["channel"] = WiFi.channel();
  w["ip"] = apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString();
  w["apClients"] = (apMode || hotspotOn) ? WiFi.softAPgetStationNum() : 0;
  w["lastDiscReason"] = lastDiscReason; w["discCount"] = discCount;
  d["mqtt"] = mqttOn;
  JsonObject r = d["render"].to<JsonObject>();
  r["frameUs"] = frameUsAvg; r["loopGapMaxMs"] = loopGapMax; r["frameMs"] = SCENES[curScene].frameMs;
  d["lastClientAgoMs"] = lastClientMs ? (uint32_t)(millis() - lastClientMs) : 0;
  d["timeSynced"] = time(nullptr) > 1700000000;
  JsonObject s = d["sketch"].to<JsonObject>();
  s["size"] = ESP.getSketchSize(); s["free"] = ESP.getFreeSketchSpace();
  JsonObject o = d["ota"].to<JsonObject>();
  o["state"] = otaState; o["error"] = otaError; o["from"] = otaFrom; o["written"] = otaWritten; o["total"] = otaTotal;
  o["rollback"] = false;
}

// ============================ UDP discovery ============================
// Request "ESP32_HUB_DISCOVER_V1" on UDP 41234 -> the same JSON as /api/hello (never a token). One answer per 150 ms at most.
WiFiUDP discUdp;
bool discOn = false;
void discoveryBegin() { if (!discOn) discOn = discUdp.begin(DISCOVERY_PORT); }
void discoveryLoop() {
  if (!discOn) return;
  int n = discUdp.parsePacket();
  if (n <= 0) return;
  char buf[48];
  int len = discUdp.read(buf, sizeof buf - 1);
  if (len <= 0) return;
  buf[len] = 0;
  static uint32_t last = 0;
  if (millis() - last < 150) return;
  last = millis();
  if (strncmp(buf, DISCOVERY_MAGIC, strlen(DISCOVERY_MAGIC))) return;
  JsonDocument d;
  buildHello(d);
  String out; serializeJson(d, out);
  discUdp.beginPacket(discUdp.remoteIP(), discUdp.remotePort());
  discUdp.print(out);
  discUdp.endPacket();
}

// ============================ software dimming ============================
// The backlight pin is wired to 3V3, so brightness cannot be changed in hardware. "Night mode" darkens the picture in software.
uint8_t dimLevel = 0;       // 0 off, 1 = 75%, 2 = 50%, 3 = 25%
static inline uint16_t dimPx(uint16_t p) {
  switch (dimLevel) {
    case 1: return (uint16_t)(((p >> 1) & 0x7BEF) + ((p >> 2) & 0x39E7));   // ~75%
    case 2: return (p >> 1) & 0x7BEF;                                        // 50%
    default: return (p >> 2) & 0x39E7;                                       // 25%
  }
}
// Draws the canvas to the panel in 8-row strips so no second full-size buffer is needed. The 2.5 KB strip is only allocated
// while dimming is on, and given back when it is switched off.
static uint16_t* dimStrip = nullptr;
void dimSet(uint8_t level) {
  dimLevel = level;
  if (level && !dimStrip) { dimStrip = (uint16_t*)malloc(W * 8 * 2); if (!dimStrip) dimLevel = 0; }
  if (!level && dimStrip) { free(dimStrip); dimStrip = nullptr; }
}
void drawCanvasDimmed() {
  const uint16_t* src = cv.getBuffer();
  for (int y = 0; y < H; y += 8) {
    for (int i = 0; i < W * 8; i++) dimStrip[i] = dimPx(src[y * W + i]);
    tft.drawRGBBitmap(0, y, dimStrip, W, 8);
  }
}

// ============================ scene schedule ============================
struct SchedItem { uint8_t h = 0, m = 0, days = 127; char scene[12] = ""; char mood[10] = ""; };
SchedItem sched[8];
uint8_t schedN = 0;
static void schedLoad() {
  schedN = 0;
  String s = prefs.getString("sched", "[]");
  JsonDocument d;
  if (deserializeJson(d, s)) return;
  for (JsonObject o : d.as<JsonArray>()) {
    if (schedN >= 8) break;
    SchedItem& it = sched[schedN];
    it.h = constrain((int)(o["h"] | 0), 0, 23); it.m = constrain((int)(o["m"] | 0), 0, 59); it.days = (o["d"] | 127) & 127;
    strlcpy(it.scene, o["s"] | "", sizeof it.scene); strlcpy(it.mood, o["mood"] | "", sizeof it.mood);
    schedN++;
  }
}
static void schedFill(JsonArray a) {
  for (int i = 0; i < schedN; i++) {
    JsonObject o = a.add<JsonObject>();
    o["h"] = sched[i].h; o["m"] = sched[i].m; o["d"] = sched[i].days; o["s"] = sched[i].scene;
    if (sched[i].mood[0]) o["mood"] = sched[i].mood;
  }
}
void schedTick() {
  static uint32_t lastChk = 0; static int lastKey = -1;
  uint32_t now = millis();
  if (now - lastChk < 5000) return;
  lastChk = now;
  if (!schedN || time(nullptr) < 1700000000 || otaBusy) return;           // needs NTP time; without it the schedule simply waits
  struct tm t;
  if (!getLocalTime(&t, 0)) return;
  int key = t.tm_yday * 1440 + t.tm_hour * 60 + t.tm_min;
  if (key == lastKey) return;
  for (int i = 0; i < schedN; i++) {
    if (sched[i].h != t.tm_hour || sched[i].m != t.tm_min || !(sched[i].days & (1 << t.tm_wday))) continue;
    lastKey = key;
    JsonDocument d, r;
    d["cmd"] = "scene"; d["id"] = sched[i].scene;
    if (sched[i].mood[0]) d["args"]["mood"] = sched[i].mood;
    runCmd(d, r);
    Serial.printf("[sched] %02d:%02d -> %s\n", t.tm_hour, t.tm_min, sched[i].scene);
    break;
  }
}

// ============================ extra commands ============================
// state: the authoritative device-side state the app mirrors (pomodoro, pet, weather).
bool hubCoreCmd(const char* cmd, JsonDocument& d, JsonDocument& r) {
  if (!strcmp(cmd, "noop") || !strcmp(cmd, "ping")) return true;
  if (!strcmp(cmd, "state")) {
    uint32_t now = millis();
    JsonObject p = r["pomo"].to<JsonObject>();
    uint32_t remain = pRunning ? (pEnd > now ? pEnd - now : 0) : pRemain;
    p["running"] = pRunning; p["mode"] = pMode == 0 ? "focus" : "break"; p["remainMs"] = remain; p["totalMs"] = pTotal();
    p["workMin"] = pWorkMin; p["brkMin"] = pBrkMin; p["done"] = pDone;
    JsonObject t = r["pet"].to<JsonObject>();
    t["hunger"] = petHunger; t["asleep"] = petSleep;
    JsonObject w = r["weather"].to<JsonObject>();
    w["lat"] = wLat; w["lon"] = wLon; w["code"] = wCode;
    if (!isnan(wTemp)) { w["temp"] = wTemp; w["humidity"] = wHum; w["wind"] = wWind; }
    w["ageSec"] = wLast ? (now - wLast) / 1000 : -1;
    r["scene"] = SCENES[curScene].id; r["dim"] = dimLevel; r["rev"] = stateRev;
    return true;
  }
  if (!strcmp(cmd, "dim")) {                         // {"level":0..3}
    dimSet(constrain((int)(d["level"] | 0), 0, 3));
    prefs.putUChar("dim", dimLevel);
    return true;
  }
  if (!strcmp(cmd, "name")) {                        // {"name":"Desk Hub"}
    String n = asciify(String(d["name"] | ""));
    n.trim();
    if (!n.length() || n.length() > 24) { r["ok"] = false; r["error"] = "bad name"; return true; }
    deviceName = n; prefs.putString("name", n);
    return true;
  }
  if (!strcmp(cmd, "sched")) {                       // {"action":"get"} | {"action":"set","items":[{h,m,d,s,mood}]}
    const char* a = d["action"] | "get";
    if (!strcmp(a, "set")) {
      JsonArrayConst items = d["items"].as<JsonArrayConst>();
      if (items.size() > 8) { r["ok"] = false; r["error"] = "bad too many items"; return true; }
      for (JsonObjectConst o : items) if (findScene(o["s"] | "") < 0) { r["ok"] = false; r["error"] = "unknown scene"; return true; }
      String s; serializeJson(items, s);
      prefs.putString("sched", s);
      schedLoad();
    }
    schedFill(r["items"].to<JsonArray>());
    r["timeSynced"] = time(nullptr) > 1700000000;
    return true;
  }
  if (!strcmp(cmd, "safe")) {                        // {"action":"clear"}: leave safe mode on the next boot
    crashCount = 0; prefs.putUChar("crashes", 0);
    r["safeMode"] = safeMode;
    return true;
  }
  return false;
}
