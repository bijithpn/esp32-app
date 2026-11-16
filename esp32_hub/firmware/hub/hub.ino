// ESP32 Hub - modular scene firmware for a 1.8" ST7735 (128x160, landscape 160x128)
// Control it from the Flutter app (Wi-Fi HTTP, MQTT remote, BLE setup) or any browser.
//
// First boot (no saved Wi-Fi): the board starts a hotspot "ESP32-Hub". Its password is generated per board on first boot and is
// shown on the board's screen (and inside the Wi-Fi QR code). Join it, open http://192.168.4.1 (or use the app) and enter your home Wi-Fi.
//
// Wiring (unchanged): CS=15 DC/A0=2 RST=4 SCK=18 SDA/MOSI=23 LED=3V3 VCC=3V3 GND=GND
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <SPI.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <DNSServer.h>
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

#define FW_VERSION "0.9.1"
#define TFT_CS 15
#define TFT_DC 2
#define TFT_RST 4
#define TFT_SCK 18
#define TFT_MOSI 23
#define TAB INITR_BLACKTAB      // try INITR_GREENTAB / INITR_REDTAB if colors/edges look wrong
#define W 160
#define H 128
#define AP_SSID "ESP32-Hub"

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_RST);
GFXcanvas16 cv(W, H);
Preferences prefs;
WebServer server(80);

long tzSec = 19800;           // default IST (+5:30); change with {"cmd":"tz","sec":...}
bool apMode = false;
DNSServer dnsServer;          // answers every name with the board, so phones can run their "is there internet" check against it
bool dnsOn = false;
bool hotspotOn = false;       // "pairing mode": the ESP32-Hub hotspot is up while the board stays on the home Wi-Fi
uint32_t hotspotUntil = 0;
String msgText = "Hello!";    // shown by the "message" scene
String msgApp = "", msgTitle = "";   // set for notification cards (see "notify")
String apPass;               // per-board hotspot password (8 characters, generated on first boot, shown on the display)
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
volatile bool assocSeen = false;                 // the radio associated with the router (before DHCP)
volatile int lastDiscReason = 0, discCount = 0;   // last Wi-Fi disconnect reason and how many since the join started (see the event handler in setup)
void mqttApply();
void bleStart();
void startHotspot(uint32_t ms = 600000);
void stopHotspot();
void bleStop();
int findScene(const char* id);
void switchScene(int idx, JsonVariantConst args, bool save = true);
void gotoScene(const char* id);
extern int curScene, pendingScene;
extern uint32_t infoUntil, msgUntil;

#include "scenes.h"
#include "scenes2.h"
#include "webpage.h"
#include "hubcore.h"

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
  touchState();
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
  d["name"] = deviceName;
  d["apiVersion"] = API_VERSION;
  d["rev"] = stateRev;
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
  d["rev"] = stateRev;
  d["dim"] = dimLevel;
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
  } else if (!strcmp(cmd, "pairing")) {           // {"sec":600}: hotspot + Wi-Fi QR on (60..1800 s) without leaving the home Wi-Fi; {"off":true} ends it
    if (d["off"] | false) stopHotspot();
    else { startHotspot((uint32_t)constrain((int)(d["sec"] | 600), 60, 1800) * 1000UL); r["hotspot"] = AP_SSID; r["seconds"] = (int)((hotspotUntil - millis()) / 1000); }
  } else if (hubCoreCmd(cmd, d, r)) {
    // handled by hubcore.h
  } else if (extraCmd(cmd, d, r)) {
    // handled by scenes2.h
  } else { r["ok"] = false; r["error"] = "unknown cmd"; }
}

// Token check for network calls. Setup mode (hotspot) is always open so you can recover a locked board.
bool authed() {
  if (!lockOn || apMode) return true;
  if (authBlocked()) return false;
  String t = server.header("X-Hub-Token");
  if (!t.length()) t = server.arg("t");
  if (tokenEq(t, hubToken)) return true;
  if (t.length()) authFailed();                   // a wrong token counts towards the rate limit, a missing one does not
  return false;
}
void deny() {
  if (authBlocked()) {
    server.sendHeader("Retry-After", "30");
    server.send(429, "application/json", "{\"ok\":false,\"success\":false,\"errorCode\":\"rate_limited\",\"error\":\"too many wrong tokens, try again in 30 s\"}");
  } else server.send(401, "application/json", "{\"ok\":false,\"success\":false,\"errorCode\":\"auth_required\",\"error\":\"locked: token required\"}");
}

void apiCmd() {
  if (!authed()) { deny(); return; }
  lastClientMs = millis();
  const String& body = server.arg("plain");
  if (body.length() > 9000) { server.send(413, "application/json", "{\"ok\":false,\"success\":false,\"errorCode\":\"payload_too_large\",\"error\":\"payload too large\"}"); return; }
  JsonDocument d;
  if (deserializeJson(d, body)) { server.send(400, "application/json", "{\"ok\":false,\"success\":false,\"errorCode\":\"bad_json\",\"error\":\"bad json\"}"); return; }
  String rid = String(d["rid"] | server.header("X-Request-Id").c_str());
  JsonDocument r;
  String cached;
  if (rid.length() && idemLookup(rid.c_str(), cached)) {        // the app is retrying a command whose reply got lost: do not run it twice
    if (!deserializeJson(r, cached)) { r["replay"] = true; sendJson(200, r); return; }
  }
  runCmd(d, r);
  finishResponse(r, rid.c_str());
  if (rid.length()) { String s; serializeJson(r, s); idemStore(rid.c_str(), s); }
  if (rid.length()) server.sendHeader("X-Request-Id", rid);
  sendJson(200, r);
}

void apiWifi() {
  if (!authed()) { deny(); return; }
  String ssid, pass;
  bool json = false;
  if (server.hasArg("ssid")) { ssid = server.arg("ssid"); pass = server.arg("pass"); }
  else {
    if (server.arg("plain").length() > 400) { server.send(413, "application/json", "{\"ok\":false,\"errorCode\":\"payload_too_large\"}"); return; }
    JsonDocument d;
    if (deserializeJson(d, server.arg("plain"))) { server.send(400, "text/plain", "bad json"); return; }
    ssid = String(d["ssid"] | ""); pass = String(d["pass"] | "");
    json = true;
  }
  if (!ssid.length() || ssid.length() > 32 || pass.length() > 63) { server.send(400, "application/json", "{\"ok\":false,\"state\":\"fail\",\"reason\":\"invalid_credentials\"}"); return; }
  if (ssid == AP_SSID) {
    server.send(200, "application/json", "{\"ok\":false,\"state\":\"fail\",\"reason\":\"own_hotspot\"}");
    return;
  }
  if (json) {
    // Try the network first (see wifiKeepAlive). From the setup hotspot the hotspot stays up so the app can read the result;
    // on a board that is already online a failed try goes back to the old network, so a typo never strands it.
    trySsid = ssid; tryPass = pass; tryIp = ""; tryReason = "";
    wifiTry = WT_TRY; wifiTryAt = millis();
    lastDiscReason = 0; discCount = 0; assocSeen = false;
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

// Progress of the join started by apiWifi.
// state: idle | connecting | ok | fail
// phase: idle | associating | waiting_dhcp | verifying | completed | failed
// reason: bad_password | not_found | unsupported_security | assoc_failed | weak_signal | dhcp_timeout | router_unavailable | timeout
void apiWifiStatus() {
  const char* st = wifiTry == WT_TRY ? "connecting" : wifiTry == WT_OK ? "ok" : wifiTry == WT_FAIL ? "fail" : "idle";
  const char* ph = wifiTry == WT_TRY ? (!assocSeen ? "associating" : "waiting_dhcp") : wifiTry == WT_OK ? "completed" : wifiTry == WT_FAIL ? "failed" : "idle";
  JsonDocument d;
  d["state"] = st;
  d["phase"] = ph;
  d["ssid"] = trySsid;
  d["ip"] = tryIp;
  d["reason"] = tryReason;
  d["discReason"] = lastDiscReason;
  d["elapsedMs"] = wifiTry == WT_TRY ? (uint32_t)(millis() - wifiTryAt) : 0;
  d["online"] = WiFi.status() == WL_CONNECTED;
  sendJson(200, d);
}

// Small and always open: the app and UDP discovery use it to identify the board. It never reveals the token.
void apiHello() { JsonDocument d; buildHello(d); sendJson(200, d); }

// Tiny health probe for the app's connection monitor: identity + a change counter, so the app only re-reads the scene list when it moved.
void apiPing() {
  lastClientMs = millis();
  JsonDocument d;
  d["ok"] = true; d["id"] = deviceId; d["fw"] = FW_VERSION; d["scene"] = SCENES[curScene].id; d["rev"] = stateRev;
  d["uptime"] = millis() / 1000; d["rssi"] = apMode ? 0 : WiFi.RSSI(); d["heap"] = ESP.getFreeHeap(); d["lock"] = lockOn;
  sendJson(200, d);
}
void apiCaps() { JsonDocument d; buildCaps(d); sendJson(200, d); }
void apiDiag() { if (!authed()) { deny(); return; } lastClientMs = millis(); JsonDocument d; buildDiag(d); sendJson(200, d); }

// Networks around the board, strongest first. The scan runs in the background and restarts by itself, so an empty or
// stale result never sticks (the app and the setup page just keep asking).
// rich = false: ["name", ...] (older apps and the web page); rich = true: [{ssid, rssi, channel, auth, secure, supported}, ...]
static const char* authName(int m, bool& supported) {
  supported = true;
  switch (m) {
    case WIFI_AUTH_OPEN: return "open";
    case WIFI_AUTH_WEP: supported = false; return "wep";
    case WIFI_AUTH_WPA_PSK: return "wpa";
    case WIFI_AUTH_WPA2_PSK: return "wpa2";
    case WIFI_AUTH_WPA_WPA2_PSK: return "wpa/wpa2";
    case WIFI_AUTH_WPA2_ENTERPRISE: supported = false; return "enterprise";
    case WIFI_AUTH_WPA3_PSK: supported = false; return "wpa3";            // WPA3-only networks have not been verified on this board
    case WIFI_AUTH_WPA2_WPA3_PSK: return "wpa2/wpa3";                       // mixed mode: the board joins with WPA2
    default: supported = false; return "other";
  }
}

static void scanCollect(JsonDocument& d, bool rich) {
  static uint32_t scanStarted = 0;
  int n = WiFi.scanComplete();
  JsonArray arr = d.to<JsonArray>();
  if (n > 0) {
    String names[24]; int rs[24], idx[24]; int m = 0;
    for (int i = 0; i < n; i++) {
      String s = WiFi.SSID(i);
      if (!s.length() || s == AP_SSID) continue;
      int r = WiFi.RSSI(i);
      bool dup = false;
      for (int j = 0; j < m; j++) if (names[j] == s) { dup = true; if (r > rs[j]) { rs[j] = r; idx[j] = i; } break; }
      if (!dup && m < 24) { names[m] = s; rs[m] = r; idx[m] = i; m++; }
    }
    for (int a = 0; a < m; a++) for (int b = a + 1; b < m; b++) if (rs[b] > rs[a]) {
      int t = rs[a]; rs[a] = rs[b]; rs[b] = t; t = idx[a]; idx[a] = idx[b]; idx[b] = t; String ts = names[a]; names[a] = names[b]; names[b] = ts;
    }
    for (int j = 0; j < m; j++) {
      if (!rich) { arr.add(names[j]); continue; }
      bool sup; const char* an = authName(WiFi.encryptionType(idx[j]), sup);
      JsonObject o = arr.add<JsonObject>();
      o["ssid"] = names[j]; o["rssi"] = rs[j]; o["channel"] = WiFi.channel(idx[j]);
      o["auth"] = an; o["secure"] = strcmp(an, "open") != 0; o["supported"] = sup;
    }
    if (millis() - scanStarted > 20000 && wifiTry != WT_TRY) { WiFi.scanDelete(); WiFi.scanNetworks(true); scanStarted = millis(); }   // refresh for next time (never during a join attempt)
  } else if (n != WIFI_SCAN_RUNNING && wifiTry != WT_TRY) {      // nothing found, or never started: start (again)
    WiFi.scanDelete();
    WiFi.scanNetworks(true);
    scanStarted = millis();
  }
}
void apiScan() { JsonDocument d; scanCollect(d, false); String out; serializeJson(d, out); server.send(200, "application/json", out); }
void apiNetworks() { JsonDocument d; scanCollect(d, true); String out; serializeJson(d, out); server.send(200, "application/json", out); }

#include "remote.h"

void startAP();
volatile bool gotIpFlag = false;
void startMdns() {
  MDNS.end();
  String host = String("esp32-hub-") + deviceId;
  host.toLowerCase();                                   // unique per board, so several hubs can share one network
  if (!MDNS.begin(host.c_str())) return;
  MDNS.setInstanceName(deviceName);
  MDNS.addService("http", "tcp", 80);
  MDNS.addService("esp32hub", "tcp", 80);               // _esp32hub._tcp: lets apps find the board without typing an IP
  MDNS.addServiceTxt("esp32hub", "tcp", "id", deviceId);
  MDNS.addServiceTxt("esp32hub", "tcp", "name", deviceName);
  MDNS.addServiceTxt("esp32hub", "tcp", "fw", FW_VERSION);
  MDNS.addServiceTxt("esp32hub", "tcp", "api", String(API_VERSION));
  MDNS.addServiceTxt("esp32hub", "tcp", "caps", "scenes,weather,music,notify,anim,mqtt,ota,schedule");
}

// Keeps the board on Wi-Fi: re-joins after router restarts or signal drops, and while in the fallback hotspot
// keeps trying the saved network so the board comes back by itself after a power cut.
void wifiKeepAlive() {
  static uint32_t lastChk = 0, downSince = 0, lastKick = 0;
  uint32_t now = millis();
  if (now - lastChk < 1000) return;
  lastChk = now;
  if (hotspotOn && (int32_t)(now - hotspotUntil) > 0) stopHotspot();             // pairing window is over
  if (apMode && savedSsid.length() && wifiTry == WT_IDLE && WiFi.softAPgetStationNum() == 0 && now > 1800000UL && now - lastClientMs > 1800000UL) {
    Serial.println("[wifi] fallback hotspot idle for 30 min: restarting to retry the saved network");   // never leave the hotspot up forever after a router outage
    rebootAt = now + 300;
  }
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
        // IDF disconnect reasons: 15/202/204/14 = handshake / auth refused (password), 201 = no network with that name,
        // 210/211 = only networks with another security mode, 203/5 = association refused, 200/212 = beacon lost / signal too weak,
        // 205 = the router dropped the connection. associated but no address for 15 s = the router's DHCP is not answering.
        int rsn = lastDiscReason;
        const char* why = nullptr;
        if (el > 3000 && discCount >= 1 && (rsn == 15 || rsn == 202 || rsn == 204 || rsn == 14)) why = "bad_password";
        else if (el > 4000 && (rsn == 210 || rsn == 211)) why = "unsupported_security";
        else if (el > 9000 && rsn == 201) why = "not_found";
        else if (el > 6000 && (rsn == 203 || rsn == 5)) why = "assoc_failed";
        else if (el > 8000 && (rsn == 200 || rsn == 212)) why = "weak_signal";
        else if (assocSeen && el > 15000) why = "dhcp_timeout";
        else if (el > 10000 && rsn == 205) why = "router_unavailable";
        else if (el > 14000 && rsn == 0 && !assocSeen) why = "not_found";   // not even a disconnect event: nothing answered under that name
        else if (el > 25000) why = "timeout";                                // nothing more specific is known
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

// Pairing mode: ESP32-Hub hotspot alongside the home Wi-Fi (the hotspot follows the router's channel). Ends after `ms` (default 10 minutes).
void startHotspot(uint32_t ms) {
  if (apMode) return;                              // setup mode already has the hotspot
  hotspotOn = true;
  hotspotUntil = millis() + ms;
  if (WiFi.getMode() != WIFI_AP_STA) WiFi.mode(WIFI_AP_STA);
  int ch = WiFi.status() == WL_CONNECTED ? WiFi.channel() : 6;
  bool ok = WiFi.softAP(AP_SSID, apPass.c_str(), ch ? ch : 6, 0, 4);
  Serial.printf("[wifi] pairing mode: hotspot %s on channel %d for %u s\n", ok ? "up" : "FAILED", ch, (unsigned)(ms / 1000));
  if (!dnsOn) { dnsServer.start(53, "*", WiFi.softAPIP()); dnsOn = true; }
  wifiQrReady = false;
  infoUntil = 0; msgUntil = 0;
  switchScene(findScene("info"), JsonVariantConst(), false);   // shows the Wi-Fi QR
}

void stopHotspot() {
  if (!hotspotOn) return;
  hotspotOn = false;
  if (dnsOn) { dnsServer.stop(); dnsOn = false; }
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  Serial.println("[wifi] pairing mode ended");
  if (!strcmp(SCENES[curScene].id, "info")) infoUntil = millis() + 500;   // leave the QR screen
}

void startAP() {
  apMode = true;
  WiFi.mode(WIFI_AP_STA);
  bool ok = WiFi.softAP(AP_SSID, apPass.c_str(), 6, 0, 4);
  Serial.printf("[wifi] softAP %s ssid=%s ip=%s heap=%u\n", ok ? "ok" : "FAILED", AP_SSID, WiFi.softAPIP().toString().c_str(), ESP.getFreeHeap());
  // A STA that keeps retrying a saved network makes the radio hop channels, and then the hotspot is barely visible
  // ("Wi-Fi not available" when scanning its QR). Stop the constant retries; wifiKeepAlive tries again briefly now and then.
  WiFi.setAutoReconnect(false);
  WiFi.disconnect(false);
  if (!dnsOn) { dnsServer.start(53, "*", WiFi.softAPIP()); dnsOn = true; }
  WiFi.scanNetworks(true);   // async, used for the setup page list
}

// ---------- OTA (HTTP upload): authenticated, size + header + MD5 checked, progress on the display ----------
// Compatibility checks: X-Hub-Model must match when sent, the image must fit the free slot, the first bytes must be a valid ESP32
// app image header, and X-Hub-Md5 (when sent) must match what was written. The other slot is only switched to when everything passed.
// There is NO automatic rollback: the stock Arduino bootloader is built without app-rollback support (see README).
bool otaBusy = false;
String otaState = "idle", otaError = "", otaFrom = "";
uint32_t otaWritten = 0, otaTotal = 0, otaLastMs = 0;
static bool otaOk = false;
static int otaPct = -1;

static void otaFail(const char* why) {
  otaOk = false; otaError = why; otaState = "failed"; otaBusy = false;
  if (Update.isRunning()) Update.abort();
  Serial.printf("[ota] failed: %s\n", why);
}

static void otaScreen(int pct) {
  tft.fillScreen(0); tft.setTextColor(ST77XX_WHITE); tft.setTextSize(2); tft.setCursor(14, 36); tft.print("Updating");
  tft.setTextSize(1); tft.setCursor(14, 62); tft.print("Do not unplug the board");
  tft.drawRect(10, 80, W - 20, 12, ST77XX_WHITE);
  tft.fillRect(12, 82, (W - 24) * constrain(pct, 0, 100) / 100, 8, ST77XX_GREEN);
}

void otaUpload() {
  HTTPUpload& up = server.upload();
  if (up.status == UPLOAD_FILE_START) {
    otaOk = true; otaError = ""; otaState = "receiving"; otaWritten = 0; otaPct = -1;
    otaTotal = server.header("X-Hub-Size").toInt();
    if (!authed()) return otaFail("unauthorized");
    String model = server.header("X-Hub-Model");
    if (model.length() && model != OTA_MODEL) return otaFail("wrong_model");
    if (otaTotal && otaTotal > ESP.getFreeSketchSpace()) return otaFail("too_large");
    if (!Update.begin(otaTotal ? otaTotal : UPDATE_SIZE_UNKNOWN)) return otaFail("begin_failed");
    String md5 = server.header("X-Hub-Md5");
    if (md5.length() == 32) Update.setMD5(md5.c_str());
    otaBusy = true; otaLastMs = millis();
    otaScreen(0);
  } else if (up.status == UPLOAD_FILE_WRITE) {
    if (!otaOk) return;
    if (otaWritten == 0 && up.currentSize >= 24) {                // ESP image header: magic 0xE9, <= 16 segments, chip id 0 (ESP32)
      if (up.buf[0] != 0xE9 || up.buf[1] > 16 || up.buf[12] != 0 || up.buf[13] != 0) return otaFail("not_esp32_image");
    }
    if (Update.write(up.buf, up.currentSize) != up.currentSize) return otaFail("write_failed");
    otaWritten += up.currentSize; otaLastMs = millis();
    int pct = otaTotal ? (int)((uint64_t)otaWritten * 100 / otaTotal) : 0;
    if (pct / 4 != otaPct / 4) { otaPct = pct; otaScreen(pct); }
  } else if (up.status == UPLOAD_FILE_END) {
    if (!otaOk) return;
    if (!Update.end(true)) return otaFail(Update.hasError() ? Update.errorString() : "verify_failed");
    otaFrom = FW_VERSION; otaState = "ok"; otaBusy = false;
    prefs.putString("ota_from", FW_VERSION);                      // the next boot reports which version it was updated from
  } else if (up.status == UPLOAD_FILE_ABORTED) {
    otaFail("aborted");
  }
}

void otaFinish() {
  server.sendHeader("Connection", "close");
  if (otaState == "ok") {
    server.send(200, "application/json", String("{\"ok\":true,\"state\":\"ok\",\"reboot\":true,\"from\":\"") + FW_VERSION + "\"}");
    rebootAt = millis() + 800;
  } else {
    int code = otaError == "unauthorized" ? (authBlocked() ? 429 : 401) : 400;
    server.send(code, "application/json", String("{\"ok\":false,\"state\":\"failed\",\"errorCode\":\"ota_") + otaError + "\",\"error\":\"" + otaError + "\"}");
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(0, INPUT_PULLUP);                        // BOOT button: hold 1.5 s for pairing mode
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t) { gotIpFlag = true; }, ARDUINO_EVENT_WIFI_STA_GOT_IP);
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t info) {   // why the Wi-Fi dropped (2 auth expired, 15 handshake timeout, 201 network not found, 202 auth failed, 205 connection failed)
    lastDiscReason = info.wifi_sta_disconnected.reason; discCount++;
    Serial.printf("[wifi] STA disconnected, reason %d\n", info.wifi_sta_disconnected.reason);
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t) { Serial.printf("[wifi] STA got ip %s rssi %d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI()); }, ARDUINO_EVENT_WIFI_STA_GOT_IP);
  WiFi.onEvent([](arduino_event_id_t, arduino_event_info_t) { assocSeen = true; }, ARDUINO_EVENT_WIFI_STA_CONNECTED);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, -1);   // CS is driven by the display library, not the SPI peripheral
  tft.initR(TAB);
  tft.setSPISpeed(20000000);   // the library default (8 MHz) needs ~80 ms to push a frame: that is what made animations stutter
  tft.setRotation(1);
  tft.fillScreen(0);
  prefs.begin("hub", false);
  bootDiagBegin();                                // reset reason, crash counters, safe mode, device name
  dimSet(prefs.getUChar("dim", 0));
  schedLoad();
  tzSec = prefs.getLong("tz", 19800);
  uint8_t mac[6]; esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char idb[8]; snprintf(idb, sizeof idb, "%02X%02X%02X", mac[3], mac[4], mac[5]);
  deviceId = idb;
  apPass = prefs.getString("appass", "");         // per-board hotspot password: generated once, never the old shared default
  if (apPass.length() != 8) {
    static const char alphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";   // no look-alike characters (i l o 0 1)
    apPass = "";
    for (int i = 0; i < 8; i++) apPass += alphabet[esp_random() % (sizeof(alphabet) - 1)];
    prefs.putString("appass", apPass);
  }
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
    { String hn = String("esp32-hub-") + deviceId; hn.toLowerCase(); WiFi.setHostname(hn.c_str()); }
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
    { String hn = String("esp32-hub-") + deviceId; hn.toLowerCase(); ArduinoOTA.setHostname(hn.c_str()); }
    ArduinoOTA.setPassword(apPass.c_str());
    ArduinoOTA.onStart([] { tft.fillScreen(0); tft.setTextSize(2); tft.setTextColor(ST77XX_WHITE); tft.setCursor(14, 40); tft.print("Updating..."); });
    ArduinoOTA.onProgress([](unsigned int p, unsigned int t) { tft.fillRect(10, 80, (W - 20) * p / t, 10, ST77XX_GREEN); });
    ArduinoOTA.begin();
  }

  server.on("/", HTTP_GET, [] { server.send_P(200, "text/html", PAGE_HTML); });
  server.on("/api/scan", HTTP_GET, apiScan);
  // Phones test "is this Wi-Fi online?" by asking a well-known page. Answering like a normal online network (204 / "Success")
  // keeps Android and iOS connected to the hotspot; a redirect made them treat it as a broken sign-in network and switch away.
  server.on("/generate_204", HTTP_GET, [] { server.send(204, "text/plain", ""); });
  server.on("/gen_204", HTTP_GET, [] { server.send(204, "text/plain", ""); });
  server.on("/hotspot-detect.html", HTTP_GET, [] { server.send(200, "text/html", "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"); });
  server.on("/library/test/success.html", HTTP_GET, [] { server.send(200, "text/html", "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"); });
  server.on("/ncsi.txt", HTTP_GET, [] { server.send(200, "text/plain", "Microsoft NCSI"); });
  server.on("/connecttest.txt", HTTP_GET, [] { server.send(200, "text/plain", "Microsoft Connect Test"); });
  // Any other unknown URL (typos...) goes to the setup page
  server.onNotFound([] {
    server.sendHeader("Location", String("http://") + (apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString()) + "/");
    server.send(302, "text/plain", "");
  });
  server.on("/wifi", HTTP_POST, apiWifi);
  server.on("/api/wifi", HTTP_POST, apiWifi);
  server.on("/api/wifi/status", HTTP_GET, apiWifiStatus);
  server.on("/api/hello", HTTP_GET, apiHello);
  server.on("/api/ping", HTTP_GET, apiPing);
  server.on("/api/capabilities", HTTP_GET, apiCaps);
  server.on("/api/diag", HTTP_GET, apiDiag);
  server.on("/api/networks", HTTP_GET, apiNetworks);
  server.on("/api/ota/status", HTTP_GET, [] { JsonDocument d; d["state"] = otaState; d["error"] = otaError; d["written"] = otaWritten; d["total"] = otaTotal; d["from"] = otaFrom; d["fw"] = FW_VERSION; sendJson(200, d); });
  server.on("/api/list", HTTP_GET, apiList);
  server.on("/api/status", HTTP_GET, apiStatus);
  server.on("/api/cmd", HTTP_POST, apiCmd);
  server.on("/update", HTTP_POST, otaFinish, otaUpload);
  const char* hdrs[] = {"X-Hub-Token", "X-Request-Id", "X-Hub-Model", "X-Hub-Size", "X-Hub-Md5"};
  server.collectHeaders(hdrs, 5);
  server.begin();
  if (!safeMode) mqttApply();                    // starts MQTT if it was enabled before (not in safe mode)
  if (bleAvailable) bleStart();                  // BLE Wi-Fi setup is on in first-time setup mode
  Serial.printf("\n[hub] fw %s  id=%s  mode=%s  ip=%s  lock=%d  mqtt=%d  ble=%d  heap=%u\n", FW_VERSION, deviceId.c_str(),
                apMode ? "AP(setup)" : "STA", apMode ? WiFi.softAPIP().toString().c_str() : WiFi.localIP().toString().c_str(),
                lockOn, mqttOn, bleOn, ESP.getFreeHeap());
  if (apMode) Serial.println("[hub] join Wi-Fi '" AP_SSID "' (password shown on the display) then open http://192.168.4.1");
  if (apMode) Serial.printf("[hub] hotspot password: %s\n", apPass.c_str());

  otaFrom = prefs.getString("ota_from", "");
  if (otaFrom.length()) { otaState = "updated"; prefs.remove("ota_from"); }   // this boot follows a successful update
  discoveryBegin();                              // UDP discovery on port 41234
  pendingScene = findScene(safeMode ? "eyes" : prefs.getString("scene", "eyes").c_str());   // safe mode: no saved scene that might be the one that crashed
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

uint32_t frameUsAvg = 0, loopGapMax = 0;

void loop() {
  static uint32_t lastLoopMs = 0, gapReset = 0;
  { uint32_t t = millis(); if (lastLoopMs && t - lastLoopMs > loopGapMax) loopGapMax = t - lastLoopMs; lastLoopMs = t; if (t - gapReset > 60000) { gapReset = t; loopGapMax = 0; } }
  serialConsole();
  discoveryLoop();
  schedTick();
  bootDiagTick();
  if (dnsOn) dnsServer.processNextRequest();
  {                                                // hold the BOOT button for 1.5 s: pairing mode (hotspot + Wi-Fi QR)
    static uint32_t downAt = 0;
    if (digitalRead(0) == LOW) { if (!downAt) downAt = millis(); else if (millis() - downAt > 1500 && !hotspotOn && !apMode) { downAt = 0xFFFFFFFF - 5000; startHotspot(); } }
    else downAt = 0;
  }
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
  if (otaBusy) {                                   // an update is running: leave the screen alone, give up if the upload stalls
    if (now - otaLastMs > 20000) otaFail("stalled");
    return;
  }
  if (now - lastFrame >= SCENES[curScene].frameMs) {
    lastFrame = now;
    uint32_t t0 = micros();
    SCENES[curScene].frame();
    if (dimLevel) drawCanvasDimmed(); else tft.drawRGBBitmap(0, 0, cv.getBuffer(), W, H);
    uint32_t us = micros() - t0;
    frameUsAvg = frameUsAvg ? (frameUsAvg * 7 + us) / 8 : us;
  } else delay(1);
}
