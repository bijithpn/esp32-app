// Remote access: MQTT (control from anywhere) and BLE (Wi-Fi setup / control from a nearby phone).
// Included from hub.ino after runCmd() and buildList() are defined.
#pragma once
#include <PubSubClient.h>
#include <NimBLEDevice.h>

// ============================ MQTT ============================
// Topics (device id is shown in the app and on the Device Info scene):
//   esp32hub/<id>/cmd     -> subscribe: JSON command + "t":"<token>"   (same commands as HTTP /api/cmd)
//   esp32hub/<id>/res     -> publish:   JSON result of the last command
//   esp32hub/<id>/list    -> publish (retained): device + scene list (same as /api/list)
//   esp32hub/<id>/state   -> publish (retained): {"scene":..,"heap":..,"ip":..} every 10 s
//   esp32hub/<id>/online  -> "1" retained, "0" as last will
// The token is mandatory on MQTT, always, whatever the HTTP "lock" setting is.
WiFiClient mqttPlain;
WiFiClientSecure mqttTls;
PubSubClient mqtt;
String mqHost, mqUser, mqPass;
uint16_t mqPort = 1883;
bool mqTlsOn = false;
uint32_t mqNextTry = 0, mqLastState = 0;

String mqTopic(const char* leaf) { return String("esp32hub/") + deviceId + "/" + leaf; }

void mqttPublishList() {
  JsonDocument d;
  buildList(d);
  String out; serializeJson(d, out);
  mqtt.publish(mqTopic("list").c_str(), (const uint8_t*)out.c_str(), out.length(), true);
}

void mqttPublishState() {
  JsonDocument d;
  d["scene"] = SCENES[curScene].id;
  d["heap"] = ESP.getFreeHeap();
  d["ip"] = WiFi.localIP().toString();
  d["rssi"] = WiFi.RSSI();
  d["uptime"] = millis() / 1000;
  String out; serializeJson(d, out);
  mqtt.publish(mqTopic("state").c_str(), (const uint8_t*)out.c_str(), out.length(), true);
}

void mqttCallback(char* topic, byte* payload, unsigned int len) {
  JsonDocument d;
  if (deserializeJson(d, payload, len)) return;
  if (hubToken != String(d["t"] | "")) return;      // wrong or missing token: ignore silently
  JsonDocument r;
  runCmd(d, r);
  String out; serializeJson(r, out);
  mqtt.publish(mqTopic("res").c_str(), out.c_str());
  mqLastState = 0;                                   // publish fresh state soon
}

// (Re)read settings from NVS and start or stop MQTT.
void mqttApply() {
  if (mqtt.connected()) mqtt.disconnect();
  mqttOn = prefs.getBool("mq_on", false) && prefs.getString("mq_host", "").length() > 0;
  if (!mqttOn) return;
  mqHost = prefs.getString("mq_host", "");
  mqPort = prefs.getUShort("mq_port", 1883);
  mqUser = prefs.getString("mq_user", "");
  mqPass = prefs.getString("mq_pass", "");
  mqTlsOn = prefs.getBool("mq_tls", false);
  if (mqTlsOn) { mqttTls.setInsecure(); mqtt.setClient(mqttTls); }
  else mqtt.setClient(mqttPlain);
  mqtt.setServer(mqHost.c_str(), mqPort);
  mqtt.setBufferSize(9000);                          // room for a 16-row pixel strip
  mqtt.setCallback(mqttCallback);
  mqNextTry = 0;
}

void mqttLoop() {
  if (!mqttOn || apMode || WiFi.status() != WL_CONNECTED) return;
  uint32_t now = millis();
  if (!mqtt.connected()) {
    if (now < mqNextTry) return;
    mqNextTry = now + 30000;                         // retry every 30 s (connect can block a few seconds)
    String cid = "hub-" + deviceId;
    String will = mqTopic("online");
    bool ok = mqUser.length()
                  ? mqtt.connect(cid.c_str(), mqUser.c_str(), mqPass.c_str(), will.c_str(), 0, true, "0")
                  : mqtt.connect(cid.c_str(), nullptr, nullptr, will.c_str(), 0, true, "0");
    Serial.printf("[mqtt] connect %s:%u -> %s\n", mqHost.c_str(), mqPort, ok ? "ok" : "failed");
    if (!ok) return;
    mqtt.publish(will.c_str(), "1", true);
    mqtt.subscribe(mqTopic("cmd").c_str());
    mqttPublishList();
    mqLastState = 0;
  }
  mqtt.loop();
  if (now - mqLastState > 10000) { mqLastState = now; mqttPublishState(); }
}

// ============================ BLE ============================
// Service 6e400001-...: write JSON to the command characteristic; read the info characteristic.
//   write {"ssid":"..","pass":".."}            -> saves Wi-Fi and reboots (allowed in setup mode, or with token)
//   write any hub command + "t":"<token>"      -> same commands as HTTP; result is readable from the info characteristic
//   read                                        -> {"id":..,"ip":..,"mode":"setup|sta","fw":..,"lock":..}
#define BLE_SVC  "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_CMD  "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_INFO "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
NimBLECharacteristic* bleInfoChr = nullptr;
String bleIn;                 // written by the BLE task, handled in loop()
volatile bool bleReady = false;

String bleLast;               // result of the last BLE command, included in the info JSON as "last"
void bleInfoJson(String& out) {
  JsonDocument d;
  if (bleLast.length()) d["last"] = serialized(bleLast.c_str());
  d["id"] = deviceId; d["fw"] = FW_VERSION; d["lock"] = lockOn;
  d["mode"] = apMode ? "setup" : "sta";
  d["ip"] = apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString();
  serializeJson(d, out);
}

class BleCmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    if (bleReady) return;                            // previous write not handled yet
    std::string v = c->getValue();
    bleIn = String(v.c_str());
    bleReady = true;
  }
};
class BleInfoCb : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    String s; bleInfoJson(s);
    c->setValue(std::string(s.c_str()));
  }
};
BleCmdCb bleCmdCb;
BleInfoCb bleInfoCb;

void bleStart() {
  if (bleOn) return;
  String name = "ESP32-Hub-" + deviceId;
  NimBLEDevice::init(name.c_str());
  NimBLEServer* srv = NimBLEDevice::createServer();
  NimBLEService* svc = srv->createService(BLE_SVC);
  NimBLECharacteristic* cmdChr = svc->createCharacteristic(BLE_CMD, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  cmdChr->setCallbacks(&bleCmdCb);
  bleInfoChr = svc->createCharacteristic(BLE_INFO, NIMBLE_PROPERTY::READ);
  bleInfoChr->setCallbacks(&bleInfoCb);
  String s; bleInfoJson(s);
  bleInfoChr->setValue(std::string(s.c_str()));
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(name.c_str());
  adv->addServiceUUID(BLE_SVC);
  adv->enableScanResponse(true);
  adv->start();
  bleOn = true;
  Serial.printf("[ble] advertising as %s\n", name.c_str());
}

void bleStop() {
  if (!bleOn) return;
  NimBLEDevice::deinit(true);
  bleOn = false;
  bleInfoChr = nullptr;
}

void bleLoop() {
  if (!bleReady) return;
  String in = bleIn;
  JsonDocument d, r;
  if (deserializeJson(d, in)) { r["ok"] = false; r["error"] = "bad json"; }
  else if (d["ssid"].is<const char*>()) {            // Wi-Fi provisioning
    if (!(apMode || !lockOn || hubToken == String(d["t"] | ""))) { r["ok"] = false; r["error"] = "locked: token required"; }
    else {
      prefs.putString("ssid", d["ssid"].as<String>());
      prefs.putString("pass", d["pass"] | "");
      r["ok"] = true; r["saved"] = true;
      rebootAt = millis() + 1500;
    }
  } else if (lockOn && hubToken != String(d["t"] | "")) { r["ok"] = false; r["error"] = "locked: token required"; }
  else runCmd(d, r);
  String out; serializeJson(r, out);
  bleLast = out;                                     // the app reads it from the info characteristic ("last")
  bleReady = false;
}
