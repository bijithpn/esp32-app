// Animated name slideshow for 1.8" ST7735 128x160 (landscape 160x128)
// Draws into an off-screen canvas, then pushes it to the display (no flicker).
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <SPI.h>
#include <math.h>

#define TFT_CS 15
#define TFT_DC 2
#define TFT_RST 4
#define TFT_SCK 18
#define TFT_MOSI 23

#define NAME "Bijith"
#define NLEN 6
#define W 160
#define H 128
#define TSIZE 4                 // 24x32 px per letter
#define TAB INITR_BLACKTAB      // try INITR_GREENTAB / INITR_REDTAB if colors/edges look wrong
#define TEXT_W (NLEN * 6 * TSIZE - TSIZE)
#define TEXT_X ((W - TEXT_W) / 2)
#define TEXT_Y ((H - 7 * TSIZE) / 2)

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_RST);
GFXcanvas16 cv(W, H);

uint16_t hsv(float h, float s = 1.0, float v = 1.0) {   // h: 0..360
  float c = v * s, x = c * (1 - fabsf(fmodf(h / 60.0, 2) - 1)), m = v - c, r, g, b;
  int i = ((int)h / 60) % 6;
  if (i == 0) { r = c; g = x; b = 0; } else if (i == 1) { r = x; g = c; b = 0; }
  else if (i == 2) { r = 0; g = c; b = x; } else if (i == 3) { r = 0; g = x; b = c; }
  else if (i == 4) { r = x; g = 0; b = c; } else { r = c; g = 0; b = x; }
  return tft.color565((r + m) * 255, (g + m) * 255, (b + m) * 255);
}

void push() { tft.drawRGBBitmap(0, 0, cv.getBuffer(), W, H); }

void letter(int i, int x, int y, uint16_t col) {
  cv.setTextSize(TSIZE);
  cv.setTextColor(col);
  cv.setCursor(x, y);
  cv.print(NAME[i]);
}
int lx(int i) { return TEXT_X + i * 6 * TSIZE; }

// Scene 1: letters pop in one by one (typewriter) with a blinking cursor
void sceneType() {
  for (int n = 0; n <= NLEN; n++) {
    for (int blink = 0; blink < 4; blink++) {
      cv.fillScreen(0);
      for (int i = 0; i < n; i++) letter(i, lx(i), TEXT_Y, hsv(i * 60 + 10));
      if (blink % 2 == 0) cv.fillRect(lx(n) + 2, TEXT_Y, 6, 7 * TSIZE, ST77XX_WHITE);
      push();
      delay(n == NLEN ? 120 : 90);
    }
  }
  delay(600);
}

// Scene 2: letters fly in from top/bottom alternately and settle
void sceneSlide() {
  for (int f = 0; f <= 30; f++) {
    cv.fillScreen(0);
    for (int i = 0; i < NLEN; i++) {
      float p = constrain((f - i * 3) / 14.0, 0.0, 1.0);
      p = 1 - (1 - p) * (1 - p);                       // ease out
      int startY = (i % 2) ? H + 10 : -60;
      int y = startY + (TEXT_Y - startY) * p;
      letter(i, lx(i), y, hsv(200 + i * 25));
    }
    push();
    delay(25);
  }
  delay(900);
}

// Scene 3: rainbow wave through the letters, with a sweeping underline
void sceneRainbow() {
  for (int f = 0; f < 90; f++) {
    cv.fillScreen(0);
    for (int i = 0; i < NLEN; i++) {
      int bob = sinf((f * 0.25) - i * 0.9) * 6;
      letter(i, lx(i), TEXT_Y + bob, hsv(fmodf(f * 6 + i * 50, 360)));
    }
    int ux = TEXT_X + (f * 5) % (TEXT_W + 40) - 20;
    cv.fillRect(constrain(ux, TEXT_X, TEXT_X + TEXT_W), TEXT_Y + 7 * TSIZE + 14,
                30, 4, hsv(fmodf(f * 8, 360)));
    push();
    delay(25);
  }
}

// Scene 4: neon glow (blurred halo + bright core) with pulsing border
void sceneNeon() {
  for (int f = 0; f < 80; f++) {
    float pulse = 0.55 + 0.45 * sinf(f * 0.18);
    uint16_t glow = tft.color565(0, 90 * pulse, 130 * pulse);
    uint16_t core = tft.color565(180, 255, 255);
    cv.fillScreen(0);
    for (int d = -2; d <= 2; d++)
      for (int e = -2; e <= 2; e++)
        if (d || e) for (int i = 0; i < NLEN; i++) letter(i, lx(i) + d, TEXT_Y + e, glow);
    for (int i = 0; i < NLEN; i++) letter(i, lx(i), TEXT_Y, core);
    cv.drawRoundRect(2, 2, W - 4, H - 4, 8, hsv(180, 1, pulse));
    cv.drawRoundRect(6, 6, W - 12, H - 12, 8, hsv(300, 1, 1 - pulse * 0.6));
    push();
    delay(25);
  }
}

// Scene 5: expanding ripples behind a shadowed name
void sceneRipple() {
  for (int f = 0; f < 90; f++) {
    cv.fillScreen(0);
    for (int k = 0; k < 4; k++) {
      int r = (f * 3 + k * 40) % 110;
      cv.drawCircle(W / 2, H / 2, r, hsv(fmodf(r * 3 + f * 2, 360), 1, 1 - r / 120.0));
    }
    for (int i = 0; i < NLEN; i++) letter(i, lx(i) + 3, TEXT_Y + 3, tft.color565(20, 20, 40));
    for (int i = 0; i < NLEN; i++) letter(i, lx(i), TEXT_Y, ST77XX_WHITE);
    push();
    delay(25);
  }
}

void setup() {
  SPI.begin(TFT_SCK, -1, TFT_MOSI, -1);   // CS is driven by the display library, not the SPI peripheral
  tft.initR(TAB);
  tft.setRotation(1);
  tft.fillScreen(0);
}

void loop() {
  sceneType();
  sceneSlide();
  sceneRainbow();
  sceneNeon();
  sceneRipple();
}
