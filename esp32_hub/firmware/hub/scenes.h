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

#include "face.h"      // robot eyes + AI buddy face

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

#include "cards.h"     // message / notification cards, status + setup screen, boot screen
