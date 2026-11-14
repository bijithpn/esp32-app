// All scenes. Each scene = begin(args) + frame() that draws into the canvas `cv`.
// To add a scene: write the two functions, add a row to SCENES[] at the bottom.
#pragma once
#include <math.h>

struct Scene {
  const char* id;
  const char* name;
  void (*begin)(JsonVariantConst args);
  void (*frame)();
  uint16_t frameMs;
  const char* argsJson;   // describes the options the app can show for this scene
  bool inRotation;        // included in auto-rotate / "next"
};

uint16_t hsv(float h, float s = 1.0, float v = 1.0) {   // h: 0..360
  h = fmodf(h, 360.0f); if (h < 0) h += 360;
  float c = v * s, x = c * (1 - fabsf(fmodf(h / 60.0, 2) - 1)), m = v - c, r, g, b;
  int i = (int)(h / 60) % 6;
  if (i == 0) { r = c; g = x; b = 0; } else if (i == 1) { r = x; g = c; b = 0; }
  else if (i == 2) { r = 0; g = c; b = x; } else if (i == 3) { r = 0; g = x; b = c; }
  else if (i == 4) { r = x; g = 0; b = c; } else { r = c; g = 0; b = x; }
  return rgb((r + m) * 255, (g + m) * 255, (b + m) * 255);
}

// ============================ ROBOT EYES ============================
String eyeMood = "normal";
float eLx = 0, eLy = 0, eTx = 0, eTy = 0;
uint32_t eNextLook = 0, eNextBlink = 0;
int eBlink = -1;

void eyes_begin(JsonVariantConst a) {
  if (a["mood"].is<const char*>()) eyeMood = a["mood"].as<String>();
  eNextLook = eNextBlink = 0; eBlink = -1;
}
void eyes_frame() {
  uint32_t now = millis();
  if (now > eNextLook) { eTx = random(-12, 13); eTy = random(-7, 8); eNextLook = now + random(1200, 3500); }
  if (eBlink < 0 && now > eNextBlink) { eBlink = 0; eNextBlink = now + random(2000, 5500); }
  eLx += (eTx - eLx) * 0.25f; eLy += (eTy - eLy) * 0.25f;
  float open = 1;
  if (eBlink >= 0) { open = fabsf(eBlink - 4) / 4.0f; if (++eBlink > 8) eBlink = -1; }
  if (eyeMood == "sleepy") open *= 0.45f;
  cv.fillScreen(0);
  int ew = 42, eh = (int)(56 * open); if (eh < 4) eh = 4;
  for (int s = -1; s <= 1; s += 2) {
    int cx = W / 2 + s * 40 + (int)eLx, cy = H / 2 + (int)eLy;
    int top = cy - eh / 2;
    int inner = cx - s * ew / 2, outer = cx + s * ew / 2;
    cv.fillRoundRect(cx - ew / 2, top, ew, eh, 14, rgb(60, 220, 255));
    if (open > 0.6f) cv.fillCircle(cx + (int)(eLx * 0.3f) - 6, top + 14, 4, rgb(255, 255, 255));
    if (eyeMood == "happy") cv.fillCircle(cx, cy + eh / 2 + 6, ew * 0.62f, 0);
    else if (eyeMood == "angry") cv.fillTriangle(outer, top - 1, inner, top - 1, inner, top + eh * 0.45f, 0);
    else if (eyeMood == "sad") cv.fillTriangle(inner, top - 1, outer, top - 1, outer, top + eh * 0.45f, 0);
  }
}

// ============================ BOUNCING LOGO ============================
String bText = "ESP32";
float bx = 20, by = 20, bvx = 1.7f, bvy = 1.3f;
uint16_t bCol = 0xFFE0;
int bCorners = 0;

void bounce_begin(JsonVariantConst a) {
  if (a["text"].is<const char*>()) bText = a["text"].as<String>();
  if (bText.length() > 8) bText = bText.substring(0, 8);
  if (!bText.length()) bText = "ESP32";
}
void bounce_frame() {
  int tw = bText.length() * 18 - 3, th = 21;
  bx += bvx; by += bvy;
  bool hx = false, hy = false;
  if (bx <= 0) { bx = 0; bvx = -bvx; hx = true; }
  if (bx + tw >= W) { bx = W - tw; bvx = -bvx; hx = true; }
  if (by <= 0) { by = 0; bvy = -bvy; hy = true; }
  if (by + th >= H) { by = H - th; bvy = -bvy; hy = true; }
  if (hx || hy) bCol = hsv(random(360));
  if (hx && hy) bCorners++;
  cv.fillScreen(0);
  cv.setTextSize(3); cv.setTextColor(bCol); cv.setCursor((int)bx, (int)by); cv.print(bText);
  cv.setTextSize(1); cv.setTextColor(rgb(90, 90, 90)); cv.setCursor(2, H - 9);
  cv.printf("corners: %d", bCorners);
}

// ============================ MATRIX RAIN ============================
#define MCOLS 20
#define MROWS 16
float mY[MCOLS], mSp[MCOLS]; int mLen[MCOLS];
void matrix_reset(int i) { mY[i] = -random(0, MROWS); mSp[i] = 0.2f + random(0, 40) / 100.0f; mLen[i] = random(6, 15); }
void matrix_begin(JsonVariantConst) { for (int i = 0; i < MCOLS; i++) matrix_reset(i); }
void matrix_frame() {
  cv.fillScreen(0);
  cv.setTextSize(1);
  for (int c = 0; c < MCOLS; c++) {
    mY[c] += mSp[c];
    int head = (int)mY[c];
    for (int i = 0; i < mLen[c]; i++) {
      int row = head - i;
      if (row < 0 || row >= MROWS) continue;
      uint16_t col = i == 0 ? rgb(210, 255, 210) : rgb(0, 255 - 255 * i / mLen[c], 40 * (mLen[c] - i) / mLen[c]);
      cv.drawChar(c * 8 + 1, row * 8, 33 + random(0, 60), col, 0, 1);
    }
    if (head - mLen[c] > MROWS) matrix_reset(c);
  }
}

// ============================ STARFIELD ============================
#define NSTARS 70
float sX[NSTARS], sY[NSTARS], sZ[NSTARS];
void star_spawn(int i, bool far_) {
  sX[i] = random(-400, 401); sY[i] = random(-320, 321); sZ[i] = far_ ? 32 : 1 + random(0, 310) / 10.0f;
}
void stars_begin(JsonVariantConst) { for (int i = 0; i < NSTARS; i++) star_spawn(i, false); }
void stars_frame() {
  cv.fillScreen(0);
  for (int i = 0; i < NSTARS; i++) {
    sZ[i] -= 0.4f;
    int x = W / 2 + (int)(sX[i] / sZ[i]), y = H / 2 + (int)(sY[i] / sZ[i]);
    if (sZ[i] < 1 || x < 0 || x >= W || y < 0 || y >= H) { star_spawn(i, true); continue; }
    int b = 255 - (int)(sZ[i] * 7);
    uint16_t c = rgb(b, b, 255);
    if (sZ[i] < 8) cv.fillRect(x, y, 2, 2, c); else cv.drawPixel(x, y, c);
  }
}

// ============================ PLASMA ============================
uint8_t sinLut[256]; uint16_t pal[256]; uint16_t plT = 0;
void plasma_begin(JsonVariantConst) {
  for (int i = 0; i < 256; i++) {
    sinLut[i] = 128 + 127 * sinf(i * 6.2831853f / 256);
    pal[i] = hsv(i * 360.0f / 256, 1, 1);
  }
}
void plasma_frame() {
  uint16_t* b = cv.getBuffer();
  plT += 2;
  for (int y = 0; y < H / 2; y++)
    for (int x = 0; x < W / 2; x++) {
      int v = sinLut[(x * 4 + plT) & 255] + sinLut[(y * 5 + plT * 2) & 255] + sinLut[((x + y) * 3 - plT) & 255];
      uint16_t c = pal[(v / 3 + plT) & 255];
      int i = y * 2 * W + x * 2;
      b[i] = b[i + 1] = b[i + W] = b[i + W + 1] = c;
    }
}

// ============================ ANALOG CLOCK ============================
int cSecLast = -1; uint32_t cSecStart = 0;
void clock_begin(JsonVariantConst) { cSecLast = -1; }
void hand(int cx, int cy, float deg, int len, uint16_t col, int thick) {
  float a = deg * 0.0174533f - 1.5708f, dx = cosf(a), dy = sinf(a);
  for (int t = -(thick / 2); t <= thick / 2; t++)
    cv.drawLine(cx + t, cy, cx + (int)(dx * len) + t, cy + (int)(dy * len), col);
}
void clock_frame() {
  cv.fillScreen(0);
  struct tm ti;
  int cx = W / 2, cy = H / 2, R = 60;
  if (!getLocalTime(&ti, 0)) {
    cv.setTextColor(ST77XX_WHITE); cv.setTextSize(2); cv.setCursor(14, 56);
    cv.print(apMode ? "No Wi-Fi" : "Syncing...");
    return;
  }
  cv.drawCircle(cx, cy, R, rgb(60, 60, 90));
  for (int i = 0; i < 12; i++) {
    float a = i * 30 * 0.0174533f;
    int l = (i % 3 == 0) ? 8 : 4;
    cv.drawLine(cx + sinf(a) * (R - l), cy - cosf(a) * (R - l), cx + sinf(a) * (R - 1), cy - cosf(a) * (R - 1),
                (i % 3 == 0) ? ST77XX_WHITE : rgb(120, 120, 150));
  }
  if (ti.tm_sec != cSecLast) { cSecLast = ti.tm_sec; cSecStart = millis(); }
  float frac = min(1.0f, (millis() - cSecStart) / 1000.0f);
  float sec = ti.tm_sec + frac;
  float min_ = ti.tm_min + sec / 60.0f, hr = (ti.tm_hour % 12) + min_ / 60.0f;
  hand(cx, cy, hr * 30, 32, ST77XX_WHITE, 3);
  hand(cx, cy, min_ * 6, 46, rgb(100, 200, 255), 3);
  hand(cx, cy, sec * 6, 52, rgb(255, 80, 80), 1);
  cv.fillCircle(cx, cy, 3, rgb(255, 80, 80));
  char d[16];
  cv.setTextSize(1); cv.setTextColor(rgb(150, 150, 170));
  strftime(d, sizeof d, "%a", &ti); cv.setCursor(2, 2); cv.print(d);
  strftime(d, sizeof d, "%d %b", &ti); cv.setCursor(W - 38, 2); cv.print(d);
}

// ============================ NAME (rainbow wave) ============================
String nName = "Bijith";
int nFrame = 0;
void name_begin(JsonVariantConst a) {
  if (a["text"].is<const char*>()) nName = a["text"].as<String>();
  if (nName.length() > 12) nName = nName.substring(0, 12);
  if (!nName.length()) nName = "Hello";
  nFrame = 0;
}
void name_frame() {
  int n = nName.length(), size = max(1, min(4, 150 / (6 * n)));
  int tw = n * 6 * size - size, x0 = (W - tw) / 2, y0 = (H - 7 * size) / 2;
  cv.fillScreen(0);
  cv.setTextSize(size);
  for (int i = 0; i < n; i++) {
    int bob = sinf(nFrame * 0.25f - i * 0.9f) * 8;
    cv.setTextColor(hsv(nFrame * 6 + i * 50));
    cv.setCursor(x0 + i * 6 * size, y0 + bob);
    cv.print(nName[i]);
  }
  int ux = x0 + (nFrame * 5) % (tw + 40) - 20;
  cv.fillRect(constrain(ux, x0, x0 + tw), y0 + 7 * size + 14, 30, 4, hsv(nFrame * 8));
  nFrame++;
}

// ============================ MESSAGE ============================
int mFrame = 0;
void message_begin(JsonVariantConst) { mFrame = 0; }
void message_frame() {
  float p = min(1.0f, mFrame / 12.0f); p = 1 - (1 - p) * (1 - p);
  int xoff = (int)((1 - p) * -W);
  cv.fillScreen(0);
  cv.setTextWrap(true);
  if (msgApp.length()) {                       // notification card: app name, title, body
    cv.fillRect(0, 0, W, 16, rgb(20, 40, 70));
    cv.setTextSize(1); cv.setTextColor(rgb(60, 220, 255)); cv.setCursor(6 + xoff, 4); cv.print(msgApp.substring(0, 24));
    int y = 22;
    if (msgTitle.length()) {
      cv.setTextColor(ST77XX_YELLOW); cv.setCursor(6 + xoff, y); cv.print(msgTitle.substring(0, 52));
      y += ((min((int)msgTitle.length(), 52) + 24) / 25) * 10 + 6;
    }
    cv.setTextColor(ST77XX_WHITE); cv.setCursor(6 + xoff, y); cv.print(msgText.substring(0, 150));
    mFrame++;
    return;
  }
  int n = msgText.length(), size = n <= 8 ? 3 : (n <= 24 ? 2 : 1);
  int charsPerLine = (W - 16) / (6 * size);
  int lines = (n + charsPerLine - 1) / charsPerLine; if (lines < 1) lines = 1;
  int y = max(8, (H - lines * 8 * size) / 2);
  cv.drawRoundRect(2, 2, W - 4, H - 4, 8, hsv(mFrame * 4));
  cv.setTextSize(size); cv.setTextColor(ST77XX_WHITE);
  cv.setCursor(8 + xoff, y); cv.print(msgText);
  mFrame++;
}

// ============================ INFO ============================
void info_begin(JsonVariantConst) {}
void info_frame() {
  cv.fillScreen(0);
  cv.setTextSize(2); cv.setTextColor(rgb(60, 220, 255)); cv.setCursor(6, 6); cv.print("ESP32 Hub");
  cv.setTextSize(1); cv.setTextColor(ST77XX_WHITE);
  if (apMode) {
    cv.setCursor(6, 32); cv.print("SETUP MODE");
    cv.setCursor(6, 48); cv.print("1. Join Wi-Fi:"); cv.setCursor(6, 58); cv.setTextColor(ST77XX_YELLOW); cv.print(AP_SSID " / " AP_PASS);
    cv.setTextColor(ST77XX_WHITE);
    cv.setCursor(6, 74); cv.print("2. Open the app or");
    cv.setCursor(6, 84); cv.setTextColor(ST77XX_YELLOW); cv.print("http://192.168.4.1");
  } else {
    cv.setCursor(6, 32); cv.print("Wi-Fi: "); cv.print(WiFi.SSID());
    cv.setCursor(6, 46); cv.print("IP:"); cv.setTextSize(2); cv.setTextColor(ST77XX_YELLOW);
    cv.setCursor(6, 58); cv.print(WiFi.localIP());
    cv.setTextSize(1); cv.setTextColor(ST77XX_WHITE);
    cv.setCursor(6, 82); cv.printf("Signal: %d dBm", WiFi.RSSI());
    cv.setCursor(6, 94); cv.printf("Heap: %u KB", ESP.getFreeHeap() / 1024);
    cv.setCursor(6, 106); cv.print("host: esp32-hub.local");
  }
  cv.setTextColor(rgb(110, 110, 110)); cv.setCursor(6, H - 10); cv.print("fw " FW_VERSION);
}

