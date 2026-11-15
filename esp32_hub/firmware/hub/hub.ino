// ESP32 Hub - modular scene firmware for a 1.8" ST7735 (128x160, landscape 160x128)
// Control it from the Flutter app (Wi-Fi HTTP, MQTT remote, BLE setup) or any browser.
//
// First boot (no saved Wi-Fi): the board starts a hotspot "ESP32-Hub" (password hub12345).
// Join it, open http://192.168.4.1 (or use the app) and enter your home Wi-Fi.
//
// Wiring (unchanged): CS=15 DC/A0=2 RST=4 SCK=18 SDA/MOSI=23 LED=3V3 VCC=3V3 GND=GND
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <SPI.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <time.h>
#include <ArduinoOTA.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include "mbedtls/base64.h"
#include <Update.h>
#include <esp_mac.h>
#include "esp_bt.h"
#include "qrcode_lib.h"   // vendored copy of the MIT-licensed "QRCode" library (ESP-IDF ships a different qrcode.h)

#define FW_VERSION "0.4.7"
#define TFT_CS 15
#define TFT_DC 2
#define TFT_RST 4
#define TFT_SCK 18
#define TFT_MOSI 23
#define TAB INITR_BLACKTAB      // try INITR_GREENTAB / INITR_REDTAB if colors/edges look wrong
#define W 160
#define H 128
#define AP_SSID "ESP32-Hub"
#define AP_PASS "hub12345"

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_RST);
GFXcanvas16 cv(W, H);
Preferences prefs;
WebServer server(80);

long tzSec = 19800;           // default IST (+5:30); change with {"cmd":"tz","sec":...}
bool apMode = false;
String msgText = "Hello!";    // shown by the "message" scene
String msgApp = "", msgTitle = "";   // set for notification cards (see "notify")
String hubToken, deviceId;    // security token (16 hex) and 6-char id from the MAC
bool lockOn = false;          // when true, API calls from the network need the token
bool mqttOn = false, bleOn = false;
bool bleAvailable = false;   // BLE can only be used if it was kept at boot (setup mode, or enabled earlier)

static inline uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
}

uint32_t lastClientMs = 0;            // last time an app / browser talked to the board (shown on the status screen)
uint32_t msgStartMs = 0, msgTtlMs = 0; // current message card timing (progress bar)
String savedSsid, savedPass;          // Wi-Fi from NVS, kept so the board can keep trying to rejoin
// Joining a network from the setup hotspot: the app sends the credentials, then polls /api/wifi/status.
// They are only saved once the join worked, so a typo never overwrites a working saved network.
enum WifiTry { WT_IDLE, WT_TRY, WT_OK, WT_FAIL };
WifiTry wifiTry = WT_IDLE;
uint32_t wifiTryAt = 0;
String trySsid, tryPass, tryIp, tryReason;
volatile int lastDiscReason = 0, discCount = 0;   // last Wi-Fi disconnect reason and how many since the join started (see the event handler in setup)
void mqttApply();
void bleStart();
void bleStop();
int findScene(const char* id);
void switchScene(int idx, JsonVariantConst args, bool save = true);
void gotoScene(const char* id);
extern int curScene, pendingScene;
extern uint32_t infoUntil, msgUntil;

#include "scenes.h"
#include "scenes2.h"
#include "webpage.h"

int curScene = 0, prevScene = 0, pendingScene = 0;
uint32_t lastFrame = 0, infoUntil = 0, msgUntil = 0, autoMs = 0, lastRotate = 0;

int findScene(const char* id) {
  for (int i = 0; i < SCENE_COUNT; i++) if (!strcmp(SCENES[i].id, id)) return i;
  return -1;
}

int nextScene(int from) {   // next scene, skipping the system scenes (info, message)
  for (int k = 1; k <= SCENE_COUNT; k++) {
    int i = (from + k) % SCENE_COUNT;
    if (SCENES[i].inRotation) return i;
  }
  return from;
}

void switchScene(int idx, JsonVariantConst args, bool save) {
  if (idx < 0 || idx >= SCENE_COUNT) return;
  if (idx != curScene && !strcmp(SCENES[curScene].id, "anim")) animClear();   // give the frames' RAM back
  curScene = idx;
  SCENES[idx].begin(args);
  lastFrame = 0;
  lastRotate = millis();
  if (save && SCENES[idx].inRotation) prefs.putString("scene", SCENES[idx].id);
}

// Switch to a scene only if not already showing it (used by commands that stream data)
void gotoScene(const char* id) {
  int i = findScene(id);
  if (i < 0 || i == curScene) return;
  infoUntil = 0; msgUntil = 0;
  switchScene(i, JsonVariantConst(), false);
}

// ---------- HTTP API ----------
void sendJson(int code, JsonDocument& d) {
  String out; serializeJson(d, out);
  server.send(code, "application/json", out);
}

void buildList(JsonDocument& d) {
  d["device"] = "ESP32-Hub";
  d["id"] = deviceId;
  d["fw"] = FW_VERSION;
  d["scene"] = SCENES[curScene].id;
  d["ip"] = apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString();
  d["ap"] = apMode;
  d["online"] = WiFi.status() == WL_CONNECTED;   // joined a router (false in setup mode)
  d["saved"] = savedSsid.length() > 0;           // a Wi-Fi network is stored on the board
  d["lock"] = lockOn;
  d["mqtt"] = mqttOn;
  d["ble"] = bleOn;
  JsonArray arr = d["scenes"].to<JsonArray>();
  for (int i = 0; i < SCENE_COUNT; i++) {
    JsonObject o = arr.add<JsonObject>();
    o["id"] = SCENES[i].id;
    o["name"] = SCENES[i].name;
    o["args"] = serialized(SCENES[i].argsJson);
  }
}

void apiList() {
  lastClientMs = millis();
  JsonDocument d;
  buildList(d);
  sendJson(200, d);
}

void apiStatus() {
  lastClientMs = millis();
  JsonDocument d;
  d["fw"] = FW_VERSION;
  d["scene"] = SCENES[curScene].id;
  d["heap"] = ESP.getFreeHeap();
  d["uptime"] = millis() / 1000;
  d["rssi"] = apMode ? 0 : WiFi.RSSI();
  d["ssid"] = apMode ? AP_SSID : WiFi.SSID();
  d["tz"] = tzSec;
  sendJson(200, d);
}

uint32_t rebootAt = 0;

String genToken() { char b[17]; snprintf(b, sizeof b, "%08x%08x", (unsigned)esp_random(), (unsigned)esp_random()); return String(b); }

// Runs one command. Used by HTTP, MQTT and BLE. Never sends a response itself.
void runCmd(JsonDocument& d, JsonDocument& r) {
  const char* cmd = d["cmd"] | "";
  r["ok"] = true;
  if (!strcmp(cmd, "scene")) {
    int i = findScene(d["id"] | "");
    if (i < 0) { r["ok"] = false; r["error"] = "unknown scene"; }
    else { infoUntil = 0; msgUntil = 0; switchScene(i, d["args"]); }
  } else if (!strcmp(cmd, "msg") || !strcmp(cmd, "notify")) {
    bool n = cmd[0] == 'n';
    msgApp = n ? asciify(String(d["app"] | "")) : String("");
    msgTitle = n ? asciify(String(d["title"] | "")) : String("");
    msgText = asciify(String(d["text"] | ""));
    int ttl = d["ttl"] | (n ? 7 : 10);
    msgStartMs = millis(); msgTtlMs = ttl > 0 ? ttl * 1000UL : 0;
    if (strcmp(SCENES[curScene].id, "message")) prevScene = curScene;
    infoUntil = 0;
    switchScene(findScene("message"), JsonVariantConst(), false);
    msgUntil = ttl > 0 ? millis() + ttl * 1000UL : 0;
  } else if (!strcmp(cmd, "next")) {
    switchScene(nextScene(curScene), JsonVariantConst());
  } else if (!strcmp(cmd, "auto")) {
    autoMs = (uint32_t)(d["sec"] | 0) * 1000UL;
  } else if (!strcmp(cmd, "tz")) {
    tzSec = d["sec"] | 19800L;
    prefs.putLong("tz", tzSec);
    configTime(tzSec, 0, "pool.ntp.org", "time.google.com");
  } else if (!strcmp(cmd, "forget")) {
    prefs.remove("ssid"); prefs.remove("pass");
    rebootAt = millis() + 500;
  } else if (!strcmp(cmd, "reboot")) {
    rebootAt = millis() + 500;
  } else if (!strcmp(cmd, "lock")) {            // {"on":true} -> returns the token once
    lockOn = d["on"] | true;
    prefs.putBool("lock", lockOn);
    if (lockOn) r["token"] = hubToken;
  } else if (!strcmp(cmd, "token")) {           // make a new token (old one stops working)
    hubToken = genToken();
    prefs.putString("token", hubToken);
    r["token"] = hubToken;
  } else if (!strcmp(cmd, "mqtt")) {            // {"on":true,"host":"..","port":1883,"user":"","pass":"","tls":false}
    prefs.putBool("mq_on", d["on"] | false);
    if (d["host"].is<const char*>()) prefs.putString("mq_host", d["host"].as<String>());
    if (d["port"].is<int>()) prefs.putUShort("mq_port", d["port"]);
    if (d["user"].is<const char*>()) prefs.putString("mq_user", d["user"].as<String>());
    if (d["pass"].is<const char*>()) prefs.putString("mq_pass", d["pass"].as<String>());
    if (d["tls"].is<bool>()) prefs.putBool("mq_tls", d["tls"]);
    mqttApply();
    r["mqtt"] = mqttOn;
  } else if (!strcmp(cmd, "ble")) {             // {"on":true}: saved, then the board reboots to apply it
    // BLE needs ~70 KB of RAM that the board frees at boot when BLE is not wanted, so it is a boot-time choice.
    prefs.putBool("ble", d["on"] | true);
    r["reboot"] = true;
    rebootAt = millis() + 500;
  } else if (!strcmp(cmd, "pair")) {
    gotoScene("pair");
  } else if (extraCmd(cmd, d, r)) {
    // handled by scenes2.h
  } else { r["ok"] = false; r["error"] = "unknown cmd"; }
}

// Token check for network calls. Setup mode (hotspot) is always open so you can recover a locked board.
bool authed() {
  if (!lockOn || apMode) return true;
  String t = server.header("X-Hub-Token");
  if (!t.length()) t = server.arg("t");
  return t == hubToken;
}
void deny() { server.send(401, "application/json", "{\"ok\":false,\"error\":\"locked: token required\"}"); }

void apiCmd() {
  if (!authed()) { deny(); return; }
  lastClientMs = millis();
  JsonDocument d;
  if (deserializeJson(d, server.arg("plain"))) { server.send(400, "text/plain", "bad json"); return; }
  JsonDocument r;
  runCmd(d, r);
  sendJson(200, r);
}

void apiWifi() {
  if (!authed()) { deny(); return; }
  String ssid, pass;
  bool json = false;
  if (server.hasArg("ssid")) { ssid = server.arg("ssid"); pass = server.arg("pass"); }
  else {
    JsonDocument d;
    if (deserializeJson(d, server.arg("plain"))) { server.send(400, "text/plain", "bad json"); return; }
    ssid = String(d["ssid"] | ""); pass = String(d["pass"] | "");
    json = true;
  }
  if (!ssid.length()) { server.send(400, "text/plain", "ssid required"); return; }
  if (ssid == AP_SSID) {
    server.send(200, "application/json", "{\"ok\":false,\"state\":\"fail\",\"reason\":\"own_hotspot\"}");
    return;
  }
  if (json) {
    // Try the network first (see wifiKeepAlive). From the setup hotspot the hotspot stays up so the app can read the result;
    // on a board that is already online a failed try goes back to the old network, so a typo never strands it.
    trySsid = ssid; tryPass = pass; tryIp = ""; tryReason = "";
    wifiTry = WT_TRY; wifiTryAt = millis();
    lastDiscReason = 0; discCount = 0;
    server.send(200, "application/json", "{\"ok\":true,\"state\":\"connecting\"}");   // answer first: the radio may leave the app's network now
    delay(50);
    esp_wifi_scan_stop();             // a scan that is still running makes the join fail
    WiFi.scanDelete();
    WiFi.setAutoReconnect(true);      // let the radio retry by itself during the attempt
    WiFi.disconnect(false);
    WiFi.begin(ssid.c_str(), pass.c_str());
    return;
  }
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  server.send(200, "text/html", "<h3>Saved. Rebooting and joining the network...</h3>");
  rebootAt = millis() + 600;
}

// Progress of the join started by apiWifi. state: idle | connecting | ok | fail (reason: bad_password | not_found | timeout)
void apiWifiStatus() {
  const char* st = wifiTry == WT_TRY ? "connecting" : wifiTry == WT_OK ? "ok" : wifiTry == WT_FAIL ? "fail" : "idle";
  JsonDocument d;
  d["state"] = st;
  d["ssid"] = trySsid;
  d["ip"] = tryIp;
  d["reason"] = tryReason;
  d["online"] = WiFi.status() == WL_CONNECTED;
  sendJson(200, d);
}

// Tiny and always open: the app uses it to find the board on the network (it never reveals the token).
void apiHello() {
  String ip = apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString();
  String out = String("{\"device\":\"ESP32-Hub\",\"id\":\"") + deviceId + "\",\"fw\":\"" FW_VERSION "\",\"ap\":" + (apMode ? "true" : "false") +
               ",\"online\":" + (WiFi.status() == WL_CONNECTED ? "true" : "false") + ",\"lock\":" + (lockOn ? "true" : "false") + ",\"ip\":\"" + ip + "\"}";
  server.send(200, "application/json", out);
}

// Networks around the board, strongest first. The scan runs in the background and restarts by itself, so an empty or
// stale result never sticks (the app and the setup page just keep asking).
void apiScan() {
  static uint32_t scanStarted = 0;
  int n = WiFi.scanComplete();
  JsonDocument d;
  JsonArray arr = d.to<JsonArray>();
  if (n > 0) {
    String names[24]; int rs[24]; int m = 0;
    for (int i = 0; i < n; i++) {
      String s = WiFi.SSID(i);
      if (!s.length() || s == AP_SSID) continue;
      int r = WiFi.RSSI(i);
      bool dup = false;
      for (int j = 0; j < m; j++) if (names[j] == s) { dup = true; if (r > rs[j]) rs[j] = r; break; }
      if (!dup && m < 24) { names[m] = s; rs[m] = r; m++; }
    }
    for (int a = 0; a < m; a++) for (int b = a + 1; b < m; b++) if (rs[b] > rs[a]) { int t = rs[a]; rs[a] = rs[b]; rs[b] = t; String ts = names[a]; names[a] = names[b]; names[b] = ts; }
    for (int j = 0; j < m; j++) arr.add(names[j]);
    if (millis() - scanStarted > 20000) { WiFi.scanDelete(); WiFi.scanNetworks(true); scanStarted = millis(); }   // refresh for next time
  } else if (n != WIFI_SCAN_RUNNING) {      // nothing found, or never started: start (again)
    WiFi.scanDelete();
    WiFi.scanNetworks(true);
    scanStarted = millis();
  }
  String out; serializeJson(d, out);
  server.send(200, "application/json", out);
}

#include "remote.h"

void startAP();
volatile bool gotIpFlag = false;
void startMdns() {
  MDNS.end();
  if (!MDNS.begin("esp32-hub")) return;
  MDNS.addService("http", "tcp", 80);
  MDNS.addService("esp32hub", "tcp", 80);               // lets apps find the board without typing an IP
  MDNS.addServiceTxt("esp32hub", "tcp", "id", deviceId);
  MDNS.addServiceTxt("esp32hub", "tcp", "fw", FW_VERSION);
}

// Keeps the board on Wi-Fi: re-joins after router restarts or signal drops, and while in the fallback hotspot
// keeps trying the saved network so the board comes back by itself after a power cut.
void wifiKeepAlive() {
  static uint32_t lastChk = 0, downSince = 0, lastKick = 0;
  uint32_t now = millis();
  if (now - lastChk < 1000) return;
  lastChk = now;
  if (wifiTry == WT_OK) return;                                                // joined: waiting for the restart
  if (wifiTry == WT_TRY) {                                                     // a join started from the app is in progress
    {
      wl_status_t st = WiFi.status();
      uint32_t el = now - wifiTryAt;
      if (st == WL_CONNECTED && WiFi.SSID() == trySsid) {   // (an online board is still on the old network for a moment)
        prefs.putString("ssid", trySsid); prefs.putString("pass", tryPass);    // saved only now that it works
        savedSsid = trySsid; savedPass = tryPass;
        tryIp = WiFi.localIP().toString();
        wifiTry = WT_OK;
        rebootAt = now + 6000;                                                 // leave time for the app to read the result, then restart cleanly
      } else {
        // reasons: 15/202/204/14 = the password (handshake/auth) was refused, 201 = no network with that name in range
        int rsn = lastDiscReason;
        const char* why = nullptr;
        if (el > 3000 && discCount >= 1 && (rsn == 15 || rsn == 202 || rsn == 204 || rsn == 14)) why = "bad_password";
        else if (el > 9000 && rsn == 201) why = "not_found";
        else if (el > 14000 && rsn == 0) why = "not_found";          // not even a disconnect event: nothing answered under that name
        else if (el > 20000) why = "not_found";                       // never joined and never a password error: the name is wrong or out of range
        if (why) {
          tryReason = why; wifiTry = WT_FAIL; WiFi.disconnect(false);
          Serial.printf("[wifi] join failed: %s (reason %d)\n", why, rsn);
          if (!apMode && savedSsid.length()) { WiFi.setAutoReconnect(true); WiFi.begin(savedSsid.c_str(), savedPass.c_str()); downSince = 0; }   // back to the old network
          else WiFi.setAutoReconnect(false);
        }
      }
    }
    return;
  }
  if (!savedSsid.length()) return;
  if (apMode) {
    if (WiFi.status() == WL_CONNECTED) { rebootAt = now + 300; return; }     // joined: restart cleanly into normal mode
    if (lastKick && now - lastKick > 12000 && now - lastKick < 20000) WiFi.disconnect(false);   // attempt over: stop hopping channels so the hotspot stays visible
    if (WiFi.softAPgetStationNum() == 0 && now - lastKick > 60000) { lastKick = now; WiFi.begin(savedSsid.c_str(), savedPass.c_str()); }
    return;
  }
  if (WiFi.status() == WL_CONNECTED) {
    downSince = 0;
    if (gotIpFlag) { gotIpFlag = false; startMdns(); }
    return;
  }
  if (!downSince) downSince = now;
  if (now - downSince > 8000 && now - lastKick > 15000) { lastKick = now; WiFi.disconnect(); WiFi.begin(savedSsid.c_str(), savedPass.c_str()); }
  if (now - downSince > 120000) {                                              // 2 minutes with no Wi-Fi: show pairing mode again
    startAP();                                                                 // hotspot + setup screen; the saved Wi-Fi is kept and still retried
    infoUntil = 0; msgUntil = 0;
    switchScene(findScene("info"), JsonVariantConst(), false);
    return;
  }                          // 5 minutes without Wi-Fi: clean restart
}

void startAP() {
  apMode = true;
  WiFi.mode(WIFI_AP_STA);
  bool ok = WiFi.softAP(AP_SSID, AP_PASS, 6);
  Serial.printf("[wifi] softAP %s ssid=%s ip=%s heap=%u\n", ok ? "ok" : "FAILED", AP_SSID, WiFi.softAPIP().toString().c_str(), ESP.getFreeHeap());
  // A STA that keeps retrying a saved network makes the radio hop channels, and then the hotspot is barely visible
  // ("Wi-Fi not available" when scanning its QR). Stop the constant retries; wifiKeepAlive tries again briefly now and then.
  WiFi.setAutoReconnect(false);
  WiFi.disconnect(false);
  WiFi.scanNetworks(true);   // async, used for the setup page list
}

void setup() {
  Serial.begin(115200);
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t) { gotIpFlag = true; }, ARDUINO_EVENT_WIFI_STA_GOT_IP);
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t info) {   // why the Wi-Fi dropped (2 auth expired, 15 handshake timeout, 201 network not found, 202 auth failed, 205 connection failed)
    lastDiscReason = info.wifi_sta_disconnected.reason; discCount++;
    Serial.printf("[wifi] STA disconnected, reason %d\n", info.wifi_sta_disconnected.reason);
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t) { Serial.printf("[wifi] STA connected, ip %s rssi %d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI()); }, ARDUINO_EVENT_WIFI_STA_GOT_IP);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, -1);   // CS is driven by the display library, not the SPI peripheral
  tft.initR(TAB);
  tft.setRotation(1);
  tft.fillScreen(0);
  prefs.begin("hub", false);
  tzSec = prefs.getLong("tz", 19800);
  uint8_t mac[6]; esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char idb[8]; snprintf(idb, sizeof idb, "%02X%02X%02X", mac[3], mac[4], mac[5]);
  deviceId = idb;
  hubToken = prefs.getString("token", "");
  if (hubToken.length() < 8) { hubToken = genToken(); prefs.putString("token", hubToken); }
  lockOn = prefs.getBool("lock", false);
  String ssid = prefs.getString("ssid", ""), pass = prefs.getString("pass", "");
#if __has_include("secrets.h")
  #include "secrets.h"
  // First boot only: use the Wi-Fi from secrets.h so the board comes online without app setup (the flag keeps "Forget Wi-Fi" working).
  if (!prefs.getBool("seeded", false)) {
    prefs.putBool("seeded", true);
    if (!ssid.length() && strlen(WIFI_SSID)) { ssid = WIFI_SSID; pass = WIFI_PASS; prefs.putString("ssid", ssid); prefs.putString("pass", pass); Serial.println("[wifi] using the Wi-Fi from secrets.h"); }
    if (!prefs.isKey("lat")) { prefs.putFloat("lat", atof(LATITUDE)); prefs.putFloat("lon", atof(LONGITUDE)); }
  }
#endif
  if (ssid == AP_SSID) {                          // an earlier version could save the board's own hotspot as its Wi-Fi: it can never join itself
    prefs.remove("ssid"); prefs.remove("pass");   // and retrying forever kept knocking the hotspot (and the phone) offline
    ssid = ""; pass = "";
    Serial.println("[wifi] removed the saved network 'ESP32-Hub' (that is the board's own hotspot)");
  }
  // Bluetooth is off unless it was switched on (the app no longer uses it): its ~70 KB of RAM goes back to the system.
  bleAvailable = prefs.getBool("ble", false);

  savedSsid = ssid; savedPass = pass;
  if (ssid.length()) {
    WiFi.persistent(false);
    WiFi.mode(WIFI_STA);
    WiFi.setHostname("esp32-hub");
    WiFi.setAutoReconnect(true);
    WiFi.begin(ssid.c_str(), pass.c_str());
    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) {      // up to 20 s: a router that is still booting is common after a power cut
      bootScreen("Joining Wi-Fi", ssid.substring(0, 24).c_str(), (int)((millis() - t0) * 90 / 20000));
      delay(60);
    }
    Serial.printf("[wifi] saved network '%s' (%u chars password): %s\n", ssid.c_str(), (unsigned)pass.length(), WiFi.status() == WL_CONNECTED ? "joined" : "NOT joined");
  } else { Serial.println("[wifi] no saved network"); bootScreen("Setup mode", "starting hotspot", 50); }
  if (!bleAvailable) esp_bt_controller_mem_release(ESP_BT_MODE_BTDM);
  if (WiFi.status() != WL_CONNECTED) startAP();   // keeps trying the saved Wi-Fi in the background (see wifiKeepAlive)
  else {
    WiFi.setSleep(false);                         // no radio sleep: the board answers instantly and stays reachable
    bootScreen("Connected!", WiFi.localIP().toString().c_str(), 100);
    configTime(tzSec, 0, "pool.ntp.org", "time.google.com");
    startMdns();
    ArduinoOTA.setHostname("esp32-hub");
    ArduinoOTA.setPassword(AP_PASS);
    ArduinoOTA.onStart([] { tft.fillScreen(0); tft.setTextSize(2); tft.setTextColor(ST77XX_WHITE); tft.setCursor(14, 40); tft.print("Updating..."); });
    ArduinoOTA.onProgress([](unsigned int p, unsigned int t) { tft.fillRect(10, 80, (W - 20) * p / t, 10, ST77XX_GREEN); });
    ArduinoOTA.begin();
  }

  server.on("/", HTTP_GET, [] { server.send_P(200, "text/html", PAGE_HTML); });
  server.on("/api/scan", HTTP_GET, apiScan);
  // Any unknown URL (phones probing for a captive portal, typos...) goes to the setup page
  server.onNotFound([] {
    server.sendHeader("Location", String("http://") + (apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString()) + "/");
    server.send(302, "text/plain", "");
  });
  server.on("/wifi", HTTP_POST, apiWifi);
  server.on("/api/wifi", HTTP_POST, apiWifi);
  server.on("/api/wifi/status", HTTP_GET, apiWifiStatus);
  server.on("/api/hello", HTTP_GET, apiHello);
  server.on("/api/list", HTTP_GET, apiList);
  server.on("/api/status", HTTP_GET, apiStatus);
  server.on("/api/cmd", HTTP_POST, apiCmd);
  server.on("/update", HTTP_POST, [] {
    if (!authed()) { deny(); return; }
    server.sendHeader("Connection", "close");
    server.send(200, "text/plain", Update.hasError() ? "Update FAILED" : "Update OK, rebooting...");
    rebootAt = millis() + 600;
  }, [] {
    static bool ok = false;
    HTTPUpload& up = server.upload();
    if (up.status == UPLOAD_FILE_START) { ok = authed(); if (ok) Update.begin(UPDATE_SIZE_UNKNOWN); }
    else if (ok && up.status == UPLOAD_FILE_WRITE) Update.write(up.buf, up.currentSize);
    else if (ok && up.status == UPLOAD_FILE_END) Update.end(true);
  });
  const char* hdrs[] = {"X-Hub-Token"};
  server.collectHeaders(hdrs, 1);
  server.begin();
  mqttApply();                                   // starts MQTT if it was enabled before
  if (bleAvailable) bleStart();                  // BLE Wi-Fi setup is on in first-time setup mode
  Serial.printf("\n[hub] fw %s  id=%s  mode=%s  ip=%s  lock=%d  mqtt=%d  ble=%d  heap=%u\n", FW_VERSION, deviceId.c_str(),
                apMode ? "AP(setup)" : "STA", apMode ? WiFi.softAPIP().toString().c_str() : WiFi.localIP().toString().c_str(),
                lockOn, mqttOn, bleOn, ESP.getFreeHeap());
  if (apMode) Serial.println("[hub] join Wi-Fi '" AP_SSID "' (password " AP_PASS ") then open http://192.168.4.1");

  pendingScene = findScene(prefs.getString("scene", "eyes").c_str());
  if (pendingScene < 0) pendingScene = 0;
  switchScene(findScene("info"), JsonVariantConst(), false);
  if (!apMode) infoUntil = millis() + 6000;   // show IP for 6 s, then the saved scene
}

// Serial console (115200): type a JSON command such as {"cmd":"mood","mood":"love"} and press Enter. Handy for testing without Wi-Fi.
void serialConsole() {
  static String line;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (line.length() > 1 && line[0] == '{') {
        JsonDocument d, r;
        if (deserializeJson(d, line)) Serial.println("[cmd] bad json");
        else { runCmd(d, r); String out; serializeJson(r, out); Serial.println("[cmd] " + out); }
      }
      line = "";
    } else if (line.length() < 1500) line += c;
  }
}

void loop() {
  serialConsole();
  server.handleClient();
  static uint32_t lastLog = 0;
  if (millis() - lastLog > 15000) { lastLog = millis(); Serial.printf("[hub] scene=%s heap=%u mqtt=%s\n", SCENES[curScene].id, ESP.getFreeHeap(), mqttOn ? (mqtt.connected() ? "up" : "down") : "off"); }
  if (!apMode) ArduinoOTA.handle();
  mqttLoop();
  bleLoop();
  wifiKeepAlive();
  uint32_t now = millis();
  if (rebootAt && now > rebootAt) ESP.restart();
  if (!strcmp(SCENES[curScene].id, "nowplaying") && !npPlaying && npPauseAt && now - npPauseAt > 25000) {   // music stopped: go back
    npPauseAt = 0;
    switchScene(npPrev >= 0 ? npPrev : findScene("eyes"), JsonVariantConst(), false);
  }
  if (infoUntil && now > infoUntil) { infoUntil = 0; switchScene(pendingScene, JsonVariantConst()); }
  if (msgUntil && now > msgUntil) { msgUntil = 0; switchScene(prevScene, JsonVariantConst(), false); }
  if (autoMs && !infoUntil && !msgUntil && now - lastRotate > autoMs)
    switchScene(nextScene(curScene), JsonVariantConst());
  if (now - lastFrame >= SCENES[curScene].frameMs) {
    lastFrame = now;
    SCENES[curScene].frame();
    tft.drawRGBBitmap(0, 0, cv.getBuffer(), W, H);
  } else delay(1);
}
