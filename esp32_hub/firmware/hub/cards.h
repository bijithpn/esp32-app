// Message / notification cards, the status ("info") screen with the Wi-Fi setup QR, and the boot screen.
// Included from scenes.h. Uses face.h for the little mascot.
#pragma once

extern uint32_t lastClientMs;           // last time an app / browser talked to the board (set in hub.ino)
extern uint32_t msgStartMs, msgTtlMs;   // when the current message card appeared and how long it stays

static inline float easeOutBack(float t) { const float c1 = 1.70158f, c3 = c1 + 1; float u = t - 1; return 1 + c3 * u * u * u + c1 * u * u; }

// One colour per well-known app, a stable colour from the name for everything else.
uint16_t appColor(const String& app) {
  String a = app; a.toLowerCase();
  struct K { const char* k; uint8_t r, g, b; };
  static const K tbl[] = {
    {"whatsapp", 37, 211, 102}, {"telegram", 42, 171, 238}, {"gmail", 234, 67, 53}, {"mail", 90, 160, 255}, {"messages", 80, 170, 255},
    {"message", 80, 170, 255}, {"sms", 80, 170, 255}, {"phone", 70, 210, 120}, {"dialer", 70, 210, 120}, {"instagram", 225, 48, 108},
    {"youtube", 255, 60, 60}, {"spotify", 30, 215, 96}, {"calendar", 66, 133, 244}, {"slack", 224, 30, 90}, {"discord", 114, 137, 218},
    {"x", 230, 230, 240}, {"twitter", 29, 161, 242}, {"facebook", 66, 103, 178}, {"messenger", 0, 132, 255}, {"snapchat", 255, 252, 0},
    {"maps", 52, 168, 83}, {"photos", 251, 188, 5}, {"amazon", 255, 153, 0}, {"uber", 230, 230, 230}, {"zomato", 226, 55, 68},
    {"swiggy", 252, 128, 25}, {"paytm", 0, 185, 241}, {"gpay", 66, 133, 244}, {"google pay", 66, 133, 244}, {"phonepe", 130, 80, 220},
    {"github", 200, 200, 210}, {"linkedin", 10, 102, 194}, {"clock", 255, 190, 80}, {"alarm", 255, 190, 80}, {"reminder", 255, 190, 80},
  };
  for (const K& k : tbl) if (a.indexOf(k.k) >= 0) return rgb(k.r, k.g, k.b);
  uint32_t h = 5381; for (size_t i = 0; i < a.length(); i++) h = h * 33 + (uint8_t)a[i];
  return hsv(h % 360, 0.65f, 1.0f);
}

// ============================ MESSAGE / NOTIFICATION ============================
int mFrame = 0;
void message_begin(JsonVariantConst) { mFrame = 0; }

void notifCard(float xoff) {
  uint32_t now = millis();
  uint16_t ac = appColor(msgApp);
  int ox = (int)xoff;
  cv.fillScreen(rgb(6, 8, 18));
  // card
  cv.fillRoundRect(4 + ox, 4, W - 8, H - 8, 9, rgb(17, 22, 40));
  cv.drawRoundRect(4 + ox, 4, W - 8, H - 8, 9, rgb(40, 52, 86));
  cv.fillRoundRect(4 + ox, 4, 5, H - 8, 2, ac);                       // coloured edge
  // badge: coloured disc with the app's first letter, a ring pulses when the card arrives
  int bx = 24 + ox, by = 23;
  if (mFrame < 36) cv.drawCircle(bx, by, 12 + (mFrame % 18) / 3, ac);
  cv.fillCircle(bx, by, 11, ac);
  String initial = msgApp.length() ? msgApp.substring(0, 1) : String("!"); initial.toUpperCase();
  cv.setTextSize(2); cv.setTextColor(rgb(10, 12, 24)); cv.setCursor(bx - 5, by - 7); cv.print(initial);
  // app name + "now"
  cv.setTextSize(1);
  cv.setTextColor(rgb(235, 240, 255)); cv.setCursor(42 + ox, 15); cv.print(msgApp.substring(0, 14));
  cv.setTextColor(rgb(110, 120, 150)); cv.setCursor(42 + ox, 26); cv.print(now - msgStartMs < 60000 ? "now" : "earlier");
  // bell that rings for the first second
  int bell = (mFrame < 30) ? (int)(sinf(mFrame * 1.1f) * 2) : 0;
  int ex = W - 22 + ox;
  cv.fillRoundRect(ex - 4 + bell, 15, 9, 8, 3, rgb(255, 214, 110));
  cv.fillRect(ex - 6 + bell, 22, 13, 2, rgb(255, 214, 110));
  cv.fillCircle(ex + bell, 26, 2, rgb(255, 214, 110));
  cv.drawFastHLine(14 + ox, 38, W - 28, rgb(40, 52, 86));
  // title (bright) and body (soft), word-wrapped
  int y = 44;
  String lines[5];
  if (msgTitle.length()) {
    int n = wrapText(msgTitle, 22, 1, lines);
    cv.setTextColor(rgb(255, 255, 255));
    if (n) { cv.setCursor(14 + ox, y); cv.print(lines[0]); }
    y += 13;
  }
  int bodyLines = msgTitle.length() ? 4 : 6;
  String body[6];
  int n = wrapText(msgText, 22, bodyLines, body);
  cv.setTextColor(rgb(175, 186, 215));
  for (int i = 0; i < n; i++) { cv.setCursor(14 + ox, y + i * 10); cv.print(body[i]); }
  // time left
  if (msgTtlMs) {
    float left = 1.0f - min(1.0f, (float)(now - msgStartMs) / msgTtlMs);
    cv.fillRoundRect(14 + ox, H - 12, W - 28, 3, 1, rgb(30, 38, 64));
    int w = (int)((W - 28) * left);
    if (w > 0) cv.fillRoundRect(14 + ox, H - 12, w, 3, 1, ac);
  }
}

void message_frame() {
  float p = min(1.0f, mFrame / 16.0f);
  float xoff = (1 - easeOutBack(p)) * W;
  if (msgApp.length()) { notifCard(xoff); mFrame++; return; }

  // plain message: a speech bubble from the mascot
  uint32_t now = millis();
  int ox = (int)xoff;
  cv.fillScreen(FACE_BG);
  int n = msgText.length(), size = n <= 10 ? 3 : (n <= 28 ? 2 : 1);
  int cpl = (W - 28) / (6 * size);
  String lines[8];
  int ln = wrapText(msgText, cpl, size == 1 ? 6 : (size == 2 ? 3 : 2), lines);
  int th = ln * (8 * size + 2), bh = th + 16;
  int by = 6;
  if (bh > 76) bh = 76;
  uint16_t hue = hsv(200 + (mFrame * 2) % 80, 0.55f, 1.0f);
  cv.fillRoundRect(6 + ox, by, W - 12, bh, 10, rgb(20, 28, 52));
  cv.drawRoundRect(6 + ox, by, W - 12, bh, 10, hue);
  cv.fillTriangle(30 + ox, by + bh - 1, 46 + ox, by + bh - 1, 30 + ox, by + bh + 9, rgb(20, 28, 52));
  cv.drawLine(30 + ox, by + bh + 9, 46 + ox, by + bh - 1, hue);
  cv.setTextSize(size); cv.setTextColor(rgb(255, 255, 255)); cv.setTextWrap(false);
  for (int i = 0; i < ln; i++) {
    int tw = lines[i].length() * 6 * size;
    cv.setCursor(W / 2 - tw / 2 + ox, by + 8 + i * (8 * size + 2)); cv.print(lines[i]);
  }
  // little face that talks while the message arrives, then smiles
  bool talk = mFrame < 45;
  faceSet(talk ? M_EXCITED : M_HAPPY); faceStep();
  faceDraw(W / 2 + ox, 104, 0.34f, ((mFrame % 70) < 3) ? 0.1f : 1.0f, talk ? fabsf(sinf(now * 0.02f)) * 0.8f : -1, 0, 0);
  if (msgTtlMs) {
    float left = 1.0f - min(1.0f, (float)(now - msgStartMs) / msgTtlMs);
    cv.fillRect(0, H - 2, (int)(W * left), 2, hue);
  }
  mFrame++;
}

// ============================ INFO / STATUS / SETUP ============================
QRCode wifiQr; uint8_t wifiQrBuf[200]; bool wifiQrReady = false;
void drawWifiBars(int x, int y, int rssi, uint16_t on) {
  int bars = rssi > -55 ? 4 : rssi > -65 ? 3 : rssi > -75 ? 2 : rssi > -90 ? 1 : 0;
  for (int i = 0; i < 4; i++) cv.fillRect(x + i * 4, y + 9 - i * 3, 3, 3 + i * 3, i < bars ? on : rgb(45, 52, 75));
}

int infoFrame = 0;
void info_begin(JsonVariantConst) {
  infoFrame = 0; faceSet(M_HAPPY); faceSnap();
  if (apMode && !wifiQrReady) {
    String s = String("WIFI:T:WPA;S:") + AP_SSID + ";P:" + AP_PASS + ";;";
    qrcode_initText(&wifiQr, wifiQrBuf, 3, ECC_LOW, s.c_str());
    wifiQrReady = true;
  }
}

void info_frame() {
  uint32_t now = millis(); infoFrame++;
  cv.fillScreen(FACE_BG);
  cv.setTextWrap(false);
  if (apMode) {
    // ---- first-time setup: scan the QR with the phone camera to join the board's hotspot ----
    const int m = 3, q = 7, box = wifiQr.size * m + 2 * q, ox = 1, oy = (H - box) / 2;   // q = white margin: scanners need it to find the code
    cv.fillRect(ox, oy, box, box, rgb(255, 255, 255));
    for (int y = 0; y < wifiQr.size; y++)
      for (int x = 0; x < wifiQr.size; x++)
        if (qrcode_getModule(&wifiQr, x, y)) cv.fillRect(ox + q + x * m, oy + q + y * m, m, m, 0);
    int rx = box + 5;                       // text column is 160-rx = ~54 px = 9 characters at size 1
    cv.setTextSize(1);
    cv.setTextColor(rgb(60, 220, 255)); cv.setCursor(rx, 8); cv.print(savedSsid.length() ? "NO WI-FI" : "SETUP");
    cv.setTextColor(rgb(255, 255, 255)); cv.setCursor(rx, 26); cv.print("1 Scan QR");
    cv.setTextColor(rgb(150, 160, 190)); cv.setCursor(rx, 36); cv.print("to join");
    cv.setTextColor(rgb(255, 214, 110)); cv.setCursor(rx, 46); cv.print("ESP32-Hub");
    cv.setTextColor(rgb(255, 255, 255)); cv.setCursor(rx, 66); cv.print("2 Open the");
    cv.setTextColor(rgb(150, 160, 190)); cv.setCursor(rx, 76); cv.print("ESP32 Hub");
    cv.setCursor(rx, 86); cv.print("app");
    // pulsing dot + password (for phones that cannot scan)
    int pulse = 2 + (int)((sinf(now * 0.006f) + 1) * 1.5f);
    cv.fillCircle(8, H - 9, pulse, rgb(255, 214, 110));
    cv.setTextColor(rgb(110, 120, 150)); cv.setCursor(18, H - 12); cv.print("Password: " AP_PASS);
    return;
  }

  // ---- normal status screen ----
  bool app = (now - lastClientMs) < 12000 && lastClientMs != 0;
  // header
  cv.setTextSize(1); cv.setTextColor(rgb(110, 120, 150)); cv.setCursor(6, 5); cv.print("ESP32 HUB");
  drawWifiBars(W - 22, 3, WiFi.RSSI(), rgb(80, 230, 140));
  // mascot + greeting
  faceSet(app ? M_HAPPY : M_NORMAL); faceStep();
  faceDraw(32, 40, 0.34f, ((infoFrame % 40) < 2) ? 0.1f : 1.0f, -1, sinf(now * 0.002f) * 4, 0);
  cv.setTextSize(2); cv.setTextColor(rgb(255, 255, 255)); cv.setCursor(66, 22); cv.print(app ? "Linked!" : "Hello!");
  cv.setTextSize(1); cv.setTextColor(rgb(150, 160, 190));
  cv.setCursor(66, 42); cv.print(app ? "App connected" : "I'm online and");
  cv.setCursor(66, 52); cv.print(app ? "Enjoy the show" : "ready to play");
  // IP pill
  String ip = WiFi.localIP().toString();
  cv.fillRoundRect(6, 68, W - 12, 24, 9, rgb(16, 24, 46));
  cv.drawRoundRect(6, 68, W - 12, 24, 9, rgb(60, 220, 255));
  int sz = ip.length() <= 11 ? 2 : 1, tw = ip.length() * 6 * sz;
  cv.setTextSize(sz); cv.setTextColor(rgb(255, 214, 110)); cv.setCursor(W / 2 - tw / 2, 80 - 4 * sz); cv.print(ip);
  cv.setTextSize(1); cv.setTextColor(rgb(110, 120, 150)); cv.setCursor(8, 98); cv.print("esp32-hub.local");
  cv.setCursor(W - 8 - 6 * 9, 98); cv.printf("ID %s", deviceId.c_str());
  // status line: pulses while waiting for the app
  int pulse = app ? 3 : 2 + (int)((sinf(now * 0.007f) + 1) * 1.6f);
  uint16_t dot = app ? rgb(80, 230, 140) : rgb(255, 190, 80);
  cv.fillCircle(11, H - 11, pulse, dot);
  cv.setTextColor(app ? rgb(80, 230, 140) : rgb(200, 205, 225));
  cv.setCursor(20, H - 14); cv.print(app ? "Connected to the app" : "Open the ESP32 Hub app");
}

// ============================ BOOT SCREEN ============================
// Called while the board joins Wi-Fi: the mascot wakes up and a progress bar fills.
void bootScreen(const char* line1, const char* line2, int percent) {
  uint32_t now = millis();
  static uint32_t nb = 0; static float open = 0.1f;
  if (now > nb) { nb = now + 2200; open = 0.1f; }
  open = min(1.0f, open + 0.12f);
  faceSet(percent > 60 ? M_HAPPY : M_NORMAL); faceStep();
  cv.fillScreen(FACE_BG);
  faceDraw(W / 2, 46, 0.62f, open, -1, sinf(now * 0.003f) * 5, 0);
  cv.setTextSize(1); cv.setTextWrap(false);
  int w1 = strlen(line1) * 6; cv.setTextColor(rgb(235, 240, 255)); cv.setCursor(W / 2 - w1 / 2, 92); cv.print(line1);
  int w2 = strlen(line2) * 6; cv.setTextColor(rgb(130, 140, 175)); cv.setCursor(W / 2 - w2 / 2, 104); cv.print(line2);
  cv.fillRoundRect(20, H - 12, W - 40, 4, 2, rgb(28, 36, 62));
  cv.fillRoundRect(20, H - 12, max(4, (W - 40) * constrain(percent, 0, 100) / 100), 4, 2, rgb(60, 220, 255));
  tft.drawRGBBitmap(0, 0, cv.getBuffer(), W, H);
}
