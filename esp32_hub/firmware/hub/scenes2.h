// More scenes + extra commands + the scene registry.
#pragma once
// (HTTPClient, WiFiClientSecure and mbedtls/base64 are included at the top of hub.ino,
//  before the W/H macros are defined)

// ---- shared palette ----
uint16_t hpal[256]; bool hpalReady = false;
void ensurePal() {
  if (hpalReady) return;
  hpalReady = true;
  for (int i = 0; i < 256; i++) hpal[i] = hsv(i * 360.0f / 256, 1, 1);
}
void heart(int x, int y, int s, uint16_t c) {
  cv.fillCircle(x - s / 2, y, s / 2 + 1, c); cv.fillCircle(x + s / 2, y, s / 2 + 1, c);
  cv.fillTriangle(x - s - 1, y + 1, x + s + 1, y + 1, x, y + s + 3, c);
}

// ============================ GAME OF LIFE ============================
#define GW 80
#define GH 64
uint8_t gA[GH][GW], gB[GH][GW];
int gGen = 0, gPopLast = -1, gStable = 0;
void life_seed() {
  for (int y = 0; y < GH; y++) for (int x = 0; x < GW; x++) gA[y][x] = random(100) < 28;
  gGen = 0; gStable = 0; gPopLast = -1;
}
void life_begin(JsonVariantConst) { ensurePal(); life_seed(); }
void life_frame() {
  uint16_t* b = cv.getBuffer();
  memset(b, 0, W * H * 2);
  int pop = 0;
  for (int y = 0; y < GH; y++) {
    int ym = (y + GH - 1) % GH, yp = (y + 1) % GH;
    for (int x = 0; x < GW; x++) {
      int xm = (x + GW - 1) % GW, xp = (x + 1) % GW;
      int n = gA[ym][xm] + gA[ym][x] + gA[ym][xp] + gA[y][xm] + gA[y][xp] + gA[yp][xm] + gA[yp][x] + gA[yp][xp];
      uint8_t a = gA[y][x], nx = a ? (n == 2 || n == 3) : (n == 3);
      gB[y][x] = nx; pop += nx;
      if (a) {
        uint16_t c = hpal[(x * 2 + y * 2 + gGen * 3) & 255];
        int i = y * 2 * W + x * 2;
        b[i] = b[i + 1] = b[i + W] = b[i + W + 1] = c;
      }
    }
  }
  memcpy(gA, gB, sizeof gA);
  gGen++;
  gStable = (pop == gPopLast) ? gStable + 1 : 0;
  gPopLast = pop;
  if (gStable > 25 || gGen > 500 || pop == 0) life_seed();
}

// ============================ MANDELBROT ZOOM ============================
float mCx = -0.743644f, mCy = 0.131826f, mScale = 3.0f;
int mRow = 0, mHue = 0, mLevel = 0;
void mandel_begin(JsonVariantConst) { ensurePal(); mScale = 3.0f; mRow = 0; mLevel = 0; cv.fillScreen(0); }
void mandel_frame() {
  uint16_t* b = cv.getBuffer();
  int maxIt = min(110, 40 + mLevel * 4);
  for (int k = 0; k < 8 && mRow < H; k++, mRow++) {
    float y0 = mCy + (mRow - H / 2) * mScale / W;
    for (int x = 0; x < W; x++) {
      float x0 = mCx + (x - W / 2) * mScale / W, zx = 0, zy = 0;
      int i = 0;
      while (i < maxIt && zx * zx + zy * zy < 4) { float t = zx * zx - zy * zy + x0; zy = 2 * zx * zy + y0; zx = t; i++; }
      b[mRow * W + x] = (i == maxIt) ? 0 : hpal[(i * 7 + mHue) & 255];
    }
  }
  if (mRow >= H) {
    mRow = 0; mScale *= 0.8f; mHue += 15; mLevel++;
    if (mScale < 4e-4f) { mScale = 3.0f; mLevel = 0; }
  }
}

// ============================ PIXEL PET ============================
int petHunger = 20, petSave = 0;
uint32_t petLastTick = 0, petHappyUntil = 0, petEatUntil = 0, petFrame = 0;
bool petSleep = false;
void pet_begin(JsonVariantConst) { petHunger = prefs.getInt("hunger", 20); petLastTick = millis(); }
void petAction(const char* a) {
  uint32_t now = millis();
  if (!strcmp(a, "feed")) { petHunger = max(0, petHunger - 35); petEatUntil = now + 2000; petHappyUntil = now + 3500; petSleep = false; prefs.putInt("hunger", petHunger); }
  else if (!strcmp(a, "play")) { petHappyUntil = now + 4000; petHunger = min(100, petHunger + 5); petSleep = false; }
  else if (!strcmp(a, "pat")) { petHappyUntil = now + 2500; petSleep = false; }
  else if (!strcmp(a, "sleep")) petSleep = true;
  else if (!strcmp(a, "wake")) petSleep = false;
}
void pet_frame() {
  uint32_t now = millis(); petFrame++;
  if (now - petLastTick > 60000) {
    petLastTick = now; if (petHunger < 100) petHunger++;
    if (++petSave >= 5) { petSave = 0; prefs.putInt("hunger", petHunger); }
  }
  bool hungry = petHunger > 70, eating = now < petEatUntil, happy = now < petHappyUntil;
  cv.fillScreen(rgb(20, 24, 40));
  cv.fillRect(0, H - 20, W, 20, rgb(50, 40, 30));
  float bob = petSleep ? sinf(petFrame * 0.06f) * 1.5f : sinf(petFrame * 0.18f) * 2.5f;
  int cx = W / 2, cy = 74 + (int)bob;
  uint16_t fur = rgb(255, 150, 40), pink = rgb(255, 150, 170);
  int wag = (int)(sinf(petFrame * 0.3f) * (petSleep ? 2 : 8));
  for (int t = 0; t < 3; t++) cv.drawLine(cx + 30, cy + 22 + t, cx + 48, cy + 10 + wag + t, fur);
  cv.fillCircle(cx + 49, cy + 9 + wag, 5, fur);
  cv.fillTriangle(cx - 32, cy - 14, cx - 24, cy - 46, cx - 8, cy - 28, fur);
  cv.fillTriangle(cx + 32, cy - 14, cx + 24, cy - 46, cx + 8, cy - 28, fur);
  cv.fillTriangle(cx - 27, cy - 22, cx - 23, cy - 38, cx - 14, cy - 28, pink);
  cv.fillTriangle(cx + 27, cy - 22, cx + 23, cy - 38, cx + 14, cy - 28, pink);
  cv.fillCircle(cx, cy, 34, fur);
  int ey = cy - 6;
  if (petSleep) {
    cv.drawFastHLine(cx - 19, ey, 10, 0); cv.drawFastHLine(cx + 9, ey, 10, 0);
    cv.setTextColor(ST77XX_WHITE); cv.setTextSize(1 + ((petFrame / 20) % 2));
    cv.setCursor(cx + 38, cy - 40 - (int)((petFrame / 4) % 10)); cv.print("Z");
  } else if (happy || eating) {
    for (int t = 0; t < 2; t++) {
      cv.drawLine(cx - 20, ey + 3 + t, cx - 14, ey - 3 + t, 0); cv.drawLine(cx - 14, ey - 3 + t, cx - 8, ey + 3 + t, 0);
      cv.drawLine(cx + 8, ey + 3 + t, cx + 14, ey - 3 + t, 0);  cv.drawLine(cx + 14, ey - 3 + t, cx + 20, ey + 3 + t, 0);
    }
  } else if ((petFrame % 60) < 3) {
    cv.drawFastHLine(cx - 19, ey, 10, 0); cv.drawFastHLine(cx + 9, ey, 10, 0);
  } else {
    cv.fillCircle(cx - 14, ey, 5, 0); cv.fillCircle(cx + 14, ey, 5, 0);
    cv.fillCircle(cx - 12, ey - 2, 1, ST77XX_WHITE); cv.fillCircle(cx + 16, ey - 2, 1, ST77XX_WHITE);
    if (hungry) { cv.drawLine(cx - 20, ey - 9, cx - 9, ey - 6, 0); cv.drawLine(cx + 20, ey - 9, cx + 9, ey - 6, 0); }
  }
  cv.fillTriangle(cx - 3, cy + 4, cx + 3, cy + 4, cx, cy + 8, pink);
  if (eating) cv.fillCircle(cx, cy + 14, 4 + ((petFrame / 4) % 2) * 2, rgb(120, 30, 30));
  else if (happy) { cv.drawLine(cx, cy + 8, cx - 7, cy + 14, 0); cv.drawLine(cx, cy + 8, cx + 7, cy + 14, 0); cv.drawLine(cx - 7, cy + 14, cx + 7, cy + 14, 0); }
  else if (hungry) { cv.drawLine(cx - 5, cy + 14, cx, cy + 11, 0); cv.drawLine(cx, cy + 11, cx + 5, cy + 14, 0); }
  else { cv.drawLine(cx, cy + 8, cx - 5, cy + 12, 0); cv.drawLine(cx, cy + 8, cx + 5, cy + 12, 0); }
  for (int k = -1; k <= 1; k++) {
    cv.drawLine(cx - 18, cy + 6 + k * 3, cx - 36, cy + 3 + k * 5, rgb(255, 255, 255));
    cv.drawLine(cx + 18, cy + 6 + k * 3, cx + 36, cy + 3 + k * 5, rgb(255, 255, 255));
  }
  if (eating) {
    int fx = cx - 62 + min(52, (int)((2000 - (petEatUntil - now)) / 20));
    cv.fillCircle(fx, cy + 14, 6, rgb(120, 180, 255)); cv.fillTriangle(fx - 6, cy + 14, fx - 13, cy + 8, fx - 13, cy + 20, rgb(120, 180, 255));
  }
  if (happy) for (int k = 0; k < 3; k++) heart(cx - 24 + k * 24, cy - 52 - (int)((petFrame * 2 + k * 13) % 22), 4, rgb(255, 60, 90));
  cv.fillRect(6, 5, 64, 8, rgb(60, 60, 70));
  cv.fillRect(7, 6, (100 - petHunger) * 62 / 100, 6, hungry ? rgb(255, 70, 70) : rgb(80, 220, 120));
  cv.setTextSize(1); cv.setTextColor(rgb(160, 160, 170)); cv.setCursor(76, 5); cv.print("FOOD");
  if (hungry && !petSleep) { cv.setTextColor(rgb(255, 200, 80)); cv.setCursor(W - 62, 20); cv.print("feed me!"); }
}

// ============================ WEATHER (icons) ============================
float wLat = 28.61f, wLon = 77.21f, wTemp = NAN, wWind = 0, wHum = 0;
int wCode = -1; uint32_t wLast = 0; bool wFail = false; int wFrame = 0;
void weather_begin(JsonVariantConst) {
  wLat = prefs.getFloat("lat", 28.61f); wLon = prefs.getFloat("lon", 77.21f); wFrame = 0;
  if (wLast && millis() - wLast > 600000UL) wLast = 0;
}
bool wFetch() {
  WiFiClientSecure c; c.setInsecure();
  HTTPClient http;
  String url = String("https://api.open-meteo.com/v1/forecast?latitude=") + String(wLat, 3) + "&longitude=" + String(wLon, 3) +
               "&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m";
  if (!http.begin(c, url)) return false;
  http.setTimeout(6000);
  int code = http.GET();
  if (code != 200) { Serial.printf("[weather] failed http=%d heap=%u\n", code, ESP.getFreeHeap()); http.end(); return false; }
  JsonDocument d;
  DeserializationError e = deserializeJson(d, http.getString());
  http.end();
  if (e) return false;
  wTemp = d["current"]["temperature_2m"]; wHum = d["current"]["relative_humidity_2m"];
  wWind = d["current"]["wind_speed_10m"]; wCode = d["current"]["weather_code"];
  Serial.printf("[weather] ok temp=%.1f code=%d heap=%u\n", wTemp, wCode, ESP.getFreeHeap());
  return true;
}
void icoSun(int x, int y, int r) {
  cv.fillCircle(x, y, r, rgb(255, 200, 0));
  float rot = wFrame * 0.03f;
  for (int i = 0; i < 8; i++) {
    float a = rot + i * 0.785398f;
    cv.drawLine(x + cosf(a) * (r + 4), y + sinf(a) * (r + 4), x + cosf(a) * (r + 11), y + sinf(a) * (r + 11), rgb(255, 225, 70));
  }
}
void icoCloud(int x, int y, uint16_t c) {
  cv.fillCircle(x - 12, y + 4, 10, c); cv.fillCircle(x + 2, y - 4, 14, c); cv.fillCircle(x + 16, y + 5, 9, c);
  cv.fillRect(x - 12, y + 4, 29, 10, c);
}
void weather_frame() {
  uint32_t now = millis();
  if (!apMode && WiFi.status() == WL_CONNECTED && (wLast == 0 || now - wLast > (wFail ? 15000UL : 600000UL))) {
    cv.fillScreen(0); cv.setTextSize(2); cv.setTextColor(ST77XX_WHITE); cv.setCursor(14, 56); cv.print("Updating...");
    tft.drawRGBBitmap(0, 0, cv.getBuffer(), W, H);
    wFail = !wFetch(); wLast = millis(); if (wLast == 0) wLast = 1;
  }
  cv.fillScreen(rgb(10, 14, 30));
  wFrame++;
  if (apMode || WiFi.status() != WL_CONNECTED) { cv.setTextSize(2); cv.setTextColor(ST77XX_WHITE); cv.setCursor(14, 56); cv.print("No Wi-Fi"); return; }
  if (wCode < 0) { cv.setTextSize(2); cv.setTextColor(ST77XX_WHITE); cv.setCursor(14, 56); cv.print(wFail ? "No data" : "..."); return; }
  int ix = 40, iy = 50;
  uint16_t grey = rgb(170, 180, 200);
  const char* txt = "Storm";
  if (wCode == 0) { icoSun(ix, iy, 16); txt = "Clear"; }
  else if (wCode <= 2) { icoSun(ix + 8, iy - 8, 12); icoCloud(ix, iy + 8, grey); txt = "Partly cloudy"; }
  else if (wCode == 3) { icoCloud(ix, iy, grey); txt = "Overcast"; }
  else if (wCode <= 48) { icoCloud(ix, iy - 8, grey); for (int k = 0; k < 3; k++) cv.drawFastHLine(ix - 22, iy + 14 + k * 7, 44, rgb(130, 140, 160)); txt = "Fog"; }
  else if (wCode <= 67 || (wCode >= 80 && wCode <= 82)) {
    icoCloud(ix, iy - 10, rgb(120, 130, 160));
    for (int k = 0; k < 4; k++) { int dy = (wFrame * 3 + k * 7) % 18; cv.drawLine(ix - 14 + k * 9, iy + 10 + dy, ix - 16 + k * 9, iy + 15 + dy, rgb(80, 160, 255)); }
    txt = (wCode >= 80) ? "Showers" : (wCode <= 57 ? "Drizzle" : "Rain");
  } else if (wCode <= 77) {
    icoCloud(ix, iy - 10, rgb(150, 160, 190));
    for (int k = 0; k < 4; k++) { int dy = (wFrame + k * 5) % 18; cv.fillCircle(ix - 14 + k * 9, iy + 10 + dy, 2, ST77XX_WHITE); }
    txt = "Snow";
  } else {
    icoCloud(ix, iy - 10, rgb(90, 95, 120));
    if ((wFrame / 6) % 2) { cv.fillTriangle(ix + 2, iy + 4, ix - 6, iy + 20, ix + 2, iy + 18, ST77XX_YELLOW); cv.fillTriangle(ix + 2, iy + 18, ix + 10, iy + 8, ix - 2, iy + 10, ST77XX_YELLOW); }
  }
  String s = String((int)roundf(wTemp));
  int size = s.length() >= 3 ? 3 : 4;
  cv.setTextSize(size); cv.setTextColor(ST77XX_YELLOW); cv.setCursor(84, 22); cv.print(s);
  int ex = 84 + s.length() * 6 * size + 2;
  cv.setTextSize(2); cv.setCursor(ex, 22); cv.print((char)247); cv.print("C");
  cv.setTextSize(1); cv.setTextColor(ST77XX_CYAN); cv.setCursor(84, 62); cv.print(txt);
  cv.setTextColor(ST77XX_WHITE);
  cv.setCursor(8, 100); cv.printf("Humidity %.0f%%", wHum);
  cv.setCursor(8, 112); cv.printf("Wind %.0f km/h", wWind);
  cv.setTextColor(rgb(100, 100, 110)); cv.setCursor(W - 50, 112); cv.printf("%lum ago", (unsigned long)((millis() - wLast) / 60000));
}

// ============================ POMODORO ============================
int pMode = 0;                    // 0 = focus, 1 = break
bool pRunning = false;
uint32_t pWorkMin = 25, pBrkMin = 5, pEnd = 0, pRemain = 25UL * 60000, pDone = 0, pFlash = 0;
uint32_t pTotal() { return (pMode == 0 ? pWorkMin : pBrkMin) * 60000UL; }
void pomoAction(const char* a) {
  uint32_t now = millis();
  if (!strcmp(a, "start")) { if (!pRunning) { if (!pRemain) pRemain = pTotal(); pEnd = now + pRemain; pRunning = true; } }
  else if (!strcmp(a, "pause")) { if (pRunning) { pRemain = pEnd > now ? pEnd - now : 0; pRunning = false; } }
  else if (!strcmp(a, "reset")) { pRunning = false; pMode = 0; pRemain = pTotal(); }
  else if (!strcmp(a, "skip")) { pMode = !pMode; pRemain = pTotal(); pRunning = false; }
}
void pomo_begin(JsonVariantConst) {}
void pomo_frame() {
  uint32_t now = millis();
  uint32_t remain = pRunning ? (pEnd > now ? pEnd - now : 0) : pRemain;
  if (pRunning && remain == 0) {
    if (pMode == 0) pDone++;
    pMode = !pMode; pRemain = pTotal(); pEnd = now + pRemain; remain = pRemain; pFlash = now + 3000;
  }
  float prog = 1.0f - (float)remain / (float)pTotal();
  uint16_t col = pMode == 0 ? rgb(255, 90, 60) : rgb(70, 220, 130);
  if (!pRunning) col = (col >> 1) & 0x7BEF;
  cv.fillScreen(now < pFlash && ((now / 250) % 2) ? rgb(40, 40, 20) : 0);
  int cx = W / 2, cy = H / 2;
  cv.drawCircle(cx, cy, 61, rgb(50, 50, 60)); cv.drawCircle(cx, cy, 49, rgb(50, 50, 60));
  for (int a = 0; a < (int)(prog * 360); a++) {
    float r = (a - 90) * 0.0174533f;
    cv.drawLine(cx + cosf(r) * 50, cy + sinf(r) * 50, cx + cosf(r) * 60, cy + sinf(r) * 60, col);
  }
  char buf[8]; uint32_t secs = (remain + 999) / 1000;
  snprintf(buf, sizeof buf, "%02u:%02u", (unsigned)(secs / 60), (unsigned)(secs % 60));
  cv.setTextSize(3); cv.setTextColor(ST77XX_WHITE); cv.setCursor(cx - 45, cy - 11); cv.print(buf);
  cv.setTextSize(1); cv.setTextColor(col); cv.setCursor(cx - (pMode == 0 ? 15 : 15), cy - 28); cv.print(pMode == 0 ? "FOCUS" : "BREAK");
  cv.setTextColor(rgb(150, 150, 160)); cv.setCursor(cx - 24, cy + 18); cv.print(pRunning ? "running" : "paused");
  cv.setCursor(cx - 18, cy + 30); cv.printf("done: %u", (unsigned)pDone);
}

// ============================ PING MONITOR ============================
#define PN 78
int16_t pingH[PN]; int pingCount = 0;
void ping_begin(JsonVariantConst) { pingCount = 0; }
void ping_frame() {
  cv.fillScreen(0);
  cv.setTextSize(1); cv.setTextColor(rgb(120, 120, 140)); cv.setCursor(4, 4); cv.print("PING 1.1.1.1");
  if (apMode || WiFi.status() != WL_CONNECTED) { cv.setTextSize(2); cv.setTextColor(ST77XX_WHITE); cv.setCursor(14, 56); cv.print("No Wi-Fi"); return; }
  WiFiClient c; uint32_t t0 = millis();
  bool ok = c.connect(IPAddress(1, 1, 1, 1), 53, 800);
  int ms = ok ? (int)(millis() - t0) : -1;
  c.stop();
  if (pingCount == PN) { memmove(pingH, pingH + 1, (PN - 1) * sizeof(int16_t)); pingCount--; }
  pingH[pingCount++] = ms;
  int sum = 0, n = 0, lost = 0, mx = 60;
  for (int i = 0; i < pingCount; i++) { if (pingH[i] < 0) lost++; else { sum += pingH[i]; n++; if (pingH[i] > mx) mx = pingH[i]; } }
  cv.setTextSize(3); cv.setTextColor(ms < 0 ? rgb(255, 70, 70) : (ms < 50 ? rgb(80, 230, 120) : (ms < 120 ? ST77XX_YELLOW : rgb(255, 120, 60))));
  cv.setCursor(4, 18);
  if (ms < 0) cv.print("LOST"); else cv.printf("%d", ms);
  if (ms >= 0) { cv.setTextSize(1); cv.setCursor(4 + String(ms).length() * 18 + 3, 32); cv.print("ms"); }
  cv.setTextSize(1); cv.setTextColor(rgb(150, 150, 170));
  cv.setCursor(96, 20); cv.printf("avg %d ms", n ? sum / n : 0);
  cv.setCursor(96, 32); cv.printf("loss %d%%", pingCount ? lost * 100 / pingCount : 0);
  for (int i = 0; i < pingCount; i++) {
    int x = i * 2;
    if (pingH[i] < 0) { cv.fillRect(x, H - 6, 2, 6, rgb(255, 70, 70)); continue; }
    int h = max(2, pingH[i] * 62 / mx);
    cv.fillRect(x, H - h, 2, h, pingH[i] < 50 ? rgb(80, 230, 120) : (pingH[i] < 120 ? ST77XX_YELLOW : rgb(255, 120, 60)));
  }
}

// ============================ CANVAS (drawing pad / photo) ============================
void canvas_begin(JsonVariantConst) { cv.fillScreen(0); }
void canvas_frame() {}   // pixels arrive through the "pixels" command

// ============================ MUSIC BARS ============================
#define NB 16
float barV[NB], barPeak[NB]; uint32_t barLast = 0;
void bars_begin(JsonVariantConst) { ensurePal(); }
void bars_frame() {
  uint32_t now = millis();
  cv.fillScreen(0);
  int bw = W / NB;
  for (int i = 0; i < NB; i++) {
    if (now - barLast > 300) barV[i] *= 0.85f;
    barPeak[i] = max(barPeak[i] - 1.5f, barV[i]);
    int h = (int)(barV[i] * (H - 8) / 255.0f), ph = (int)(barPeak[i] * (H - 8) / 255.0f);
    uint16_t c = hpal[(i * 14) & 255];
    cv.fillRect(i * bw + 1, H - h, bw - 2, h, c);
    cv.fillRect(i * bw + 1, H - ph - 3, bw - 2, 2, ST77XX_WHITE);
  }
}

#include "music.h"     // now playing

// ============================ ANIMATION (GIF / frames from the app) ============================
// Frames are 80x64 pixels in RGB332 (8-bit colour, 5 KB each), shown at 2x size. Up to ANIM_MAX frames.
#define ANIM_MAX 10
#define AW 80
#define AH 64
uint8_t* animF[ANIM_MAX] = {nullptr};
uint16_t lut332[256]; bool lutReady = false;
int animN = 0, animCur = 0; uint32_t animDelay = 120, animNext = 0;
void ensureLut() {
  if (lutReady) return;
  lutReady = true;
  for (int i = 0; i < 256; i++) lut332[i] = rgb(((i >> 5) & 7) * 255 / 7, ((i >> 2) & 7) * 255 / 7, (i & 3) * 255 / 3);
}
void animClear() { for (int i = 0; i < ANIM_MAX; i++) { free(animF[i]); animF[i] = nullptr; } animN = 0; animCur = 0; }
void anim_begin(JsonVariantConst) { ensureLut(); animCur = 0; animNext = 0; }
void anim_frame() {
  if (!animN) {
    cv.fillScreen(0); cv.setTextSize(2); cv.setTextColor(ST77XX_WHITE); cv.setCursor(10, 50); cv.print("No animation");
    return;
  }
  uint32_t now = millis();
  uint8_t* src = animF[animCur % animN];
  if (src) {
    uint16_t* b = cv.getBuffer();
    for (int y = 0; y < AH; y++)
      for (int x = 0; x < AW; x++) {
        uint16_t c = lut332[src[y * AW + x]]; int i = y * 2 * W + x * 2;
        b[i] = b[i + 1] = b[i + W] = b[i + W + 1] = c;
      }
  }
  if (now >= animNext) { animNext = now + animDelay; animCur = (animCur + 1) % animN; }
}

// ============================ PAIRING QR ============================
QRCode pairQr; uint8_t pairQrBuf[256]; String pairText;
void pair_begin(JsonVariantConst) {
  pairText = String("hub://pair?id=") + deviceId + "&t=" + hubToken + "&ip=" +
             (apMode ? WiFi.softAPIP().toString() : WiFi.localIP().toString());
  qrcode_initText(&pairQr, pairQrBuf, 5, ECC_LOW, pairText.c_str());
}
void pair_frame() {
  cv.fillScreen(0);
  const int m = 3, box = pairQr.size * m + 8, ox = 4, oy = (H - box) / 2;
  cv.fillRect(ox, oy, box, box, ST77XX_WHITE);
  for (int y = 0; y < pairQr.size; y++)
    for (int x = 0; x < pairQr.size; x++)
      if (qrcode_getModule(&pairQr, x, y)) cv.fillRect(ox + 4 + x * m, oy + 4 + y * m, m, m, 0);
  cv.setTextSize(1); cv.setTextColor(rgb(60, 220, 255));
  cv.setCursor(box + 8, 14); cv.print("SCAN");
  cv.setCursor(box + 8, 26); cv.print("with");
  cv.setCursor(box + 8, 38); cv.print("app");
  cv.setTextColor(lockOn ? rgb(80, 230, 120) : rgb(255, 200, 80));
  cv.setCursor(box + 8, 70); cv.print(lockOn ? "LOCK" : "open");
}

// ============================ REGISTRY ============================
const Scene SCENES[] = {
  {"eyes",   "Robot Eyes",     eyes_begin,    eyes_frame,    33, "[{\"key\":\"mood\",\"type\":\"choice\",\"options\":[\"auto\",\"normal\",\"happy\",\"love\",\"excited\",\"surprised\",\"wink\",\"thinking\",\"sleepy\",\"sleeping\",\"sad\",\"angry\",\"dizzy\"]}]", true},
  {"bounce", "Bouncing Logo",  bounce_begin,  bounce_frame,  25, "[{\"key\":\"text\",\"type\":\"text\",\"max\":8}]", true},
  {"matrix", "Matrix Rain",    matrix_begin,  matrix_frame,  45, "[]", true},
  {"stars",  "Starfield",      stars_begin,   stars_frame,   30, "[]", true},
  {"plasma", "Plasma",         plasma_begin,  plasma_frame,  40, "[]", true},
  {"life",   "Game of Life",   life_begin,    life_frame,    90, "[]", true},
  {"mandel", "Mandelbrot",     mandel_begin,  mandel_frame,  30, "[]", true},
  {"clock",  "Analog Clock",   clock_begin,   clock_frame,   40, "[]", true},
  {"weather","Weather",        weather_begin, weather_frame, 50, "[]", true},
  {"name",   "Name Wave",      name_begin,    name_frame,    30, "[{\"key\":\"text\",\"type\":\"text\",\"max\":12}]", true},
  {"pet",    "Pixel Pet",      pet_begin,     pet_frame,     40, "[]", false},
  {"pomo",   "Pomodoro",       pomo_begin,    pomo_frame,    100, "[]", false},
  {"ping",   "Ping Monitor",   ping_begin,    ping_frame,    1000, "[]", false},
  {"buddy",  "AI Buddy",       buddy_begin,   buddy_frame,   40, "[]", false},
  {"bars",   "Music Bars",     bars_begin,    bars_frame,    35, "[]", false},
  {"nowplaying", "Now Playing", np_begin,     np_frame,      50, "[]", false},
  {"canvas", "Canvas",         canvas_begin,  canvas_frame,  150, "[]", false},
  {"anim",   "Animation",      anim_begin,    anim_frame,    30, "[]", false},
  {"pair",   "Pair (QR)",      pair_begin,    pair_frame,    500, "[]", false},
  {"message","Message",        message_begin, message_frame, 30, "[]", false},
  {"info",   "Device Info",    info_begin,    info_frame,    50, "[]", false},
};
const int SCENE_COUNT = sizeof(SCENES) / sizeof(SCENES[0]);

// ============================ EXTRA COMMANDS ============================
bool extraCmd(const char* cmd, JsonDocument& d, JsonDocument& r) {
  if (!strcmp(cmd, "pomo")) {
    gotoScene("pomo");
    if (d["work"].is<int>()) pWorkMin = constrain((int)d["work"], 1, 180);
    if (d["brk"].is<int>()) pBrkMin = constrain((int)d["brk"], 1, 60);
    const char* a = d["action"] | "show";
    if ((d["work"].is<int>() || d["brk"].is<int>()) && !pRunning) pRemain = pTotal();
    pomoAction(a);
    return true;
  }
  if (!strcmp(cmd, "pet")) { gotoScene("pet"); petAction(d["action"] | "show"); return true; }
  if (!strcmp(cmd, "loc")) {
    wLat = d["lat"] | 28.61f; wLon = d["lon"] | 77.21f;
    prefs.putFloat("lat", wLat); prefs.putFloat("lon", wLon);
    wLast = 0; wCode = -1;
    return true;
  }
  if (!strcmp(cmd, "say")) {      // {"text":"..","mood":"happy"}  (mood optional: picked from the words)
    gotoScene("buddy");
    int mi = d["mood"].is<const char*>() ? moodFromName(d["mood"]) : -1;
    buddySay(String(d["text"] | ""), mi);
    faceSet(buddyMood);
    return true;
  }
  if (!strcmp(cmd, "mood")) {     // {"mood":"love"}: show a mood on the robot eyes right now
    const char* m = d["mood"] | "normal";
    gotoScene("eyes"); eyesSetMood(String(m));
    return true;
  }
  if (!strcmp(cmd, "bands")) {
    gotoScene("bars");
    JsonArrayConst a = d["v"].as<JsonArrayConst>();
    for (int i = 0; i < NB && i < (int)a.size(); i++) barV[i] = constrain((float)a[i], 0.0f, 255.0f);
    barLast = millis();
    return true;
  }
  if (!strcmp(cmd, "nowplaying")) {
    // {"title","artist","dur","pos","playing","quiet"}: the phone sends this on every track / play-pause change.
    bool playing = d["playing"] | true;
    bool quiet = d["quiet"] | false;           // "quiet": only update the data (periodic position sync)
    if (!quiet && playing && strcmp(SCENES[curScene].id, "nowplaying")) {
      if (strcmp(SCENES[curScene].id, "message") && strcmp(SCENES[curScene].id, "info")) npPrev = curScene;
      else npPrev = pendingScene;
      infoUntil = 0; msgUntil = 0;
      gotoScene("nowplaying");
    }
    npSet(String(d["title"] | "Unknown"), String(d["artist"] | ""), d["dur"] | 0, d["pos"] | 0, playing);
    return true;
  }
  if (!strcmp(cmd, "pixels")) {
    int x = d["x"] | 0, y = d["y"] | 0, w = d["w"] | 0, h = d["h"] | 0;
    const char* s = d["data"] | "";
    size_t need = (size_t)w * h * 2;
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > W || y + h > H) { r["ok"] = false; r["error"] = "bad rect"; return true; }
    uint8_t* buf = (uint8_t*)malloc(need);
    if (!buf) { r["ok"] = false; r["error"] = "no memory"; return true; }
    size_t olen = 0;
    int rc = mbedtls_base64_decode(buf, need, &olen, (const unsigned char*)s, strlen(s));
    if (rc != 0 || olen != need) { free(buf); r["ok"] = false; r["error"] = "bad data"; return true; }
    gotoScene("canvas");
    uint16_t* b = cv.getBuffer();
    for (int j = 0; j < h; j++) memcpy(b + (y + j) * W + x, buf + (size_t)j * w * 2, w * 2);
    free(buf);
    return true;
  }
  if (!strcmp(cmd, "clear")) { gotoScene("canvas"); cv.fillScreen(0); return true; }
  if (!strcmp(cmd, "anim")) {           // {"action":"clear"} | {"action":"frame","i":0,"y":0,"h":32,"data":"<base64 RGB332, 80 bytes per row>"} | {"action":"play","delay":120}
    const char* a = d["action"] | "";
    if (!strcmp(a, "clear")) { animClear(); return true; }
    if (!strcmp(a, "play")) {
      animDelay = constrain((int)(d["delay"] | 120), 30, 3000);
      if (!animN) { r["ok"] = false; r["error"] = "no frames"; return true; }
      gotoScene("anim"); animCur = 0; animNext = 0;
      return true;
    }
    if (!strcmp(a, "frame")) {
      int i = d["i"] | -1, y = d["y"] | 0, h = d["h"] | 0;
      const char* s = d["data"] | "";
      size_t need = (size_t)AW * h;
      if (i < 0 || i >= ANIM_MAX || h <= 0 || y < 0 || y + h > AH) { r["ok"] = false; r["error"] = "bad frame"; return true; }
      if (!animF[i]) {
        if (ESP.getMaxAllocHeap() < AW * AH + 25000) { r["ok"] = false; r["error"] = "low memory"; return true; }
        animF[i] = (uint8_t*)calloc(AW * AH, 1);
        if (!animF[i]) { r["ok"] = false; r["error"] = "no memory"; return true; }
      }
      uint8_t* buf = (uint8_t*)malloc(need);
      if (!buf) { r["ok"] = false; r["error"] = "no memory"; return true; }
      size_t olen = 0;
      int rc = mbedtls_base64_decode(buf, need, &olen, (const unsigned char*)s, strlen(s));
      if (rc != 0 || olen != need) { free(buf); r["ok"] = false; r["error"] = "bad data"; return true; }
      memcpy(animF[i] + (size_t)y * AW, buf, need);
      free(buf);
      if (i + 1 > animN) animN = i + 1;
      return true;
    }
    r["ok"] = false; r["error"] = "bad action"; return true;
  }
  return false;
}
