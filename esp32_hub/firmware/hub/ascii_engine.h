// ASCII animals: the simulation and the character-cell renderer, ported from the "ascii animals" web page (pocketstudio.design)
// after reverse engineering its shipped bundle: a flock of creatures with depth (far = smaller and fainter), steering with
// separation, a pointer "startle", a glowing trail that diffuses and fades, and a renderer that draws every animal as
// coloured character cells (a tile plus a glyph) instead of pixels. Seven animals: butterflies, koi, jellyfish, dragonflies,
// frogs, cranes, crabs. The shapes are rebuilt from ellipses and capsules because the display's cells are 6 x 8 pixels.
// No Arduino dependency, so the same file is compiled on a PC by tools/ascii_host_test.cpp.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

namespace asc {

static const int ASW = 160, ASH = 128, ACW = 4, ACH = 6, ACOLS = 40, AROWS = 22, ANC = ACOLS * AROWS;
static const int MAXC = 12, MAXFOOD = 24;
static const int NANIMALS = 7;
static const float PI_ = 3.14159265f, TAU = 6.2831853f;

// ----------------------------------------------------------------------------- tuning (the knobs the app shows)
struct Tune {
  float density, speed, size, trail, trailFade, hue, sparkle, fog, shimmer, direction;
  bool corner;
  float k[3];
  float grid = 1;   // how visible the background grid lines are   // the animal's own three knobs, see Animal::knob*
};

struct Animal {
  const char* id; const char* label;
  uint8_t swatch[3];
  Tune def;
  const char* knobKey[3]; const char* knobLabel[3];
  float kmin[3], kmax[3];
  float count;     // creatures on screen at density 1
  float scale;     // body size relative to the others
  float speed;     // cruising speed, pixels per second
  uint8_t trail[3];
};

enum { A_BUTTERFLY, A_KOI, A_JELLY, A_DRAGON, A_FROG, A_CRANE, A_CRAB };

static const Animal ANIMALS[NANIMALS] = {
  {"butterflies", "Butterfly", {50, 135, 255},
   {1.0f, 1.0f, 1.0f, 1.5f, 0.4f, 0, 0.12f, 0.05f, 0.3f, 49, true, {0.6f, 1.5f, 1.0f}},
   {"flutter", "glide", "flapRate"}, {"Flutter", "Glide", "Flap rate"}, {0, 0, 0.2f}, {3, 4, 3}, 4, 1.0f, 28, {96, 156, 255}},
  {"koi", "Koi", {244, 196, 44},
   {1.0f, 1.0f, 1.0f, 1.0f, 0.5f, 0, 0.12f, 0.1f, 0.3f, 49, true, {1.0f, 1.0f, 90}},
   {"meander", "tailBeat", "foodRange"}, {"Meander", "Tail beat", "Food range"}, {0, 0.2f, 0}, {3, 3, 200}, 3, 1.15f, 16, {110, 170, 220}},
  {"jellyfish", "Jellyfish", {230, 120, 255},
   {1.0f, 1.0f, 1.0f, 1.0f, 0.5f, 0, 0.18f, 0.1f, 0.3f, 49, true, {1.0f, 1.0f, 1.0f}},
   {"pulseRate", "pulsePower", "tentacles"}, {"Pulse rate", "Pulse power", "Tentacles"}, {0.2f, 0.2f, 0.3f}, {3, 3, 2}, 3, 1.1f, 12, {190, 130, 255}},
  {"dragonflies", "Dragonfly", {50, 220, 120},
   {1.0f, 1.0f, 1.0f, 0.6f, 1.2f, 0, 0.18f, 0.1f, 0.3f, 49, true, {1.3f, 0.5f, 1.5f}},
   {"hover", "cruising", "dart"}, {"Hover time", "Cruising", "Dart speed"}, {0, 0, 0.3f}, {3, 1, 3}, 5, 0.85f, 32, {120, 232, 150}},
  {"frogs", "Frog", {96, 232, 130},
   {1.0f, 1.0f, 1.0f, 1.0f, 0.8f, 0, 0.12f, 0.1f, 0.2f, 49, true, {1.0f, 1.0f, 1.0f}},
   {"hop", "leap", "height"}, {"How often", "Leap length", "Leap height"}, {0.2f, 0.4f, 0.2f}, {3, 2.5f, 2.5f}, 4, 0.95f, 34, {150, 220, 170}},
  {"cranes", "Crane", {236, 238, 242},
   {1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 0, 0.04f, 0.1f, 0.1f, 49, true, {1.0f, 1.0f, 0.0f}},
   {"wingbeat", "glide", "foldFlap"}, {"Wingbeat", "Glide", "Folding flap"}, {0.2f, 0, 0}, {3, 3, 1}, 2, 1.0f, 24, {200, 210, 225}},
  {"crabs", "Crab", {204, 82, 52},
   {1.0f, 1.0f, 1.0f, 0.6f, 1.0f, 0, 0.03f, 0.1f, 0.1f, 49, true, {1.0f, 1.0f, 0.55f}},
   {"burst", "rest", "scare"}, {"Burst length", "Pause length", "Scare"}, {0.2f, 0, 0}, {3, 3, 1.5f}, 4, 0.8f, 28, {206, 178, 136}},
};

// ----------------------------------------------------------------------------- random numbers and small maths
static uint32_t rngState = 2463534242u;
static inline float rnd() { rngState ^= rngState << 13; rngState ^= rngState >> 17; rngState ^= rngState << 5; return (rngState >> 8) * (1.0f / 16777216.0f); }
static inline float rf(float a, float b) { return a + rnd() * (b - a); }
static inline float clampf(float v, float a, float b) { return v < a ? a : v > b ? b : v; }
static inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
static inline float fract(float v) { return v - floorf(v); }
static inline float smooth(float a, float b, float v) { float t = clampf((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
static inline float angDiff(float a, float b) { float s = fmodf(b - a, TAU); if (s > PI_) s -= TAU; if (s < -PI_) s += TAU; return s; }
static inline uint32_t hash3(int a, int b, int c) {
  uint32_t i = (uint32_t)a * 374761393u ^ (uint32_t)b * 668265263u ^ (uint32_t)c * 1442695041u;
  i = (i ^ (i >> 13)) * 1274126177u; i ^= i >> 16; return i;
}
static inline float hash01(int a, int b, int c) { return hash3(a, b, c) * (1.0f / 4294967296.0f); }

// ----------------------------------------------------------------------------- state
struct Cr {
  float x, y, vx, vy, heading, bias, depth, span, roll, phase, startled;
  float a, b, until, aim, fx, fy, tx, ty, s, dur, glide, glideUntil, open, flx, fly, alarm, gait, squeeze, turn;
  float nodes[8][2];
  int8_t facing; bool mode, leaping, gone; uint8_t m, variety; uint16_t id;
};
struct Food { float x, y, vx, vy, born; bool live; };

static Tune T = ANIMALS[0].def;
static int animal = 0;
static Cr* cr = nullptr;                // all the big buffers are allocated the first time the scene runs, so they cost nothing at boot
static int ncr = 0;
static Food* food = nullptr;
static bool ready = false;
static float now = 0;
static uint16_t nextId = 1;
static float accx, accy;

// cell output (what the screen draws)
static uint8_t* cFlag;             // 0 empty, 1 thin (glyph only), 2 solid (tile + glyph)
static char* cGlyph;
static uint16_t *cFill, *cCol, *cTrail;
static float *energy, *energyTmp;
static float hueM[9]; static bool hueOn = false;
static uint16_t BG = 0;
static const uint8_t BGR = 6, BGG = 8, BGB = 16;

// One block for everything (about 10 KB). Returns false when there is no memory; the caller then shows nothing instead of crashing.
static bool alloc() {
  if (ready) return true;
  size_t nCr = sizeof(Cr) * MAXC, nFood = sizeof(Food) * MAXFOOD, nF = sizeof(float) * ANC * 2, n16 = sizeof(uint16_t) * ANC * 3, n8 = ANC * 2;
  uint8_t* m = (uint8_t*)calloc(1, nCr + nFood + nF + n16 + n8 + 16);
  if (!m) return false;
  cr = (Cr*)m; m += nCr;
  food = (Food*)m; m += nFood;
  energy = (float*)m; m += sizeof(float) * ANC; energyTmp = (float*)m; m += sizeof(float) * ANC;
  cFill = (uint16_t*)m; m += sizeof(uint16_t) * ANC; cCol = (uint16_t*)m; m += sizeof(uint16_t) * ANC; cTrail = (uint16_t*)m; m += sizeof(uint16_t) * ANC;
  cFlag = m; m += ANC; cGlyph = (char*)m;
  ready = true;
  return true;
}

// ----------------------------------------------------------------------------- colour
static inline uint16_t pack(float r, float g, float b) {
  int R = (int)clampf(r, 0, 255), G = (int)clampf(g, 0, 255), B = (int)clampf(b, 0, 255);
  return (uint16_t)(((R & 0xF8) << 8) | ((G & 0xFC) << 3) | (B >> 3));
}
static void setHue(float deg) {
  float a = deg * PI_ / 180.0f, c = cosf(a), s = sinf(a);
  hueM[0] = 0.213f + c * 0.787f - s * 0.213f; hueM[1] = 0.715f - c * 0.715f - s * 0.715f; hueM[2] = 0.072f - c * 0.072f + s * 0.928f;
  hueM[3] = 0.213f - c * 0.213f + s * 0.143f; hueM[4] = 0.715f + c * 0.285f + s * 0.140f; hueM[5] = 0.072f - c * 0.072f - s * 0.283f;
  hueM[6] = 0.213f - c * 0.213f - s * 0.787f; hueM[7] = 0.715f - c * 0.715f + s * 0.715f; hueM[8] = 0.072f + c * 0.928f + s * 0.072f;
  hueOn = fmodf(deg, 360.0f) != 0;
}
// Colour of an ink after the hue shift and the distance fade (f = 0 near, 1 = background).
static uint16_t tint(const uint8_t* c, float mul, float add, float f) {
  float r = c[0], g = c[1], b = c[2];
  if (hueOn) { float R = hueM[0] * r + hueM[1] * g + hueM[2] * b, G = hueM[3] * r + hueM[4] * g + hueM[5] * b, B = hueM[6] * r + hueM[7] * g + hueM[8] * b; r = R; g = G; b = B; }
  r = r * mul + add; g = g * mul + add; b = b * mul + add;
  r += (BGR - r) * f; g += (BGG - g) * f; b += (BGB - b) * f;
  return pack(r, g, b);
}

// The 3 x 5 pixel font the cells use (every glyph the renderer can pick). Row by row, 3 bits a row, top row in the high bits.
static uint16_t glyphBits(char c) {
  static const uint8_t R[][5] = {
    {0, 0, 0, 0, 2},   // .
    {0, 0, 0, 2, 4},   // ,
    {0, 2, 0, 2, 0},   // :
    {0, 2, 0, 2, 4},   // ;
    {0, 2, 5, 5, 2},   // o
    {0, 5, 2, 5, 0},   // x
    {5, 1, 2, 4, 5},   // %
    {5, 7, 5, 7, 5},   // #
    {7, 5, 7, 4, 7},   // @
    {0, 0, 7, 0, 0},   // -
    {4, 4, 2, 1, 1},   // backslash
    {2, 2, 2, 2, 2},   // |
    {1, 1, 2, 4, 4},   // /
    {2, 2, 0, 0, 0},   // '
    {5, 2, 7, 2, 5},   // *
    {0, 2, 7, 2, 0},   // +
    {0, 3, 6, 0, 0},   // ~
    {7, 5, 5, 5, 7},   // O
    {4, 2, 1, 2, 4},   // >
    {2, 5, 2, 5, 3},   // &
    {4, 2, 0, 0, 0},   // `
  };
  static const char K[] = ".,:;ox%#@-\\|/'*+~O>&`";
  for (int i = 0; K[i]; i++) if (K[i] == c) { const uint8_t* r = R[i]; return (uint16_t)(r[0] << 12 | r[1] << 9 | r[2] << 6 | r[3] << 3 | r[4]); }
  return 0;
}

// ----------------------------------------------------------------------------- the pen: draws character cells
enum Kind { K_BODY, K_EDGE, K_LIGHT, K_SPARK };
static const char RAMP[] = ".,:;ox%#@";
static const char EDGEG[] = "#%@&";
static const char LIGHTG[] = ".:'`,";
static const char THIN[] = ".:*+";

static inline int cellAt(float x, float y) {
  int cx = (int)floorf(x / ACW), cy = (int)floorf(y / ACH);
  return (cx < 0 || cy < 0 || cx >= ACOLS || cy >= AROWS) ? -1 : cy * ACOLS + cx;
}
static inline float fogOf(float depth) { return (1 - depth) * T.fog; }

static void putCell(int ci, int cx, int cy, int id, Kind kind, const uint8_t* col, float light, float cov, float fog) {
  uint32_t h = hash3(cx, cy, id) ;
  float jit = hash01(cx, cy, (int)(now * 2.4f) + id);
  float lum = (0.3f * col[0] + 0.59f * col[1] + 0.11f * col[2]) / 255.0f;
  if (cov < 0.3f) {                                  // barely covered: a light glyph, never over a solid cell
    if (cFlag[ci] == 2 || kind == K_SPARK) return;
    cFlag[ci] = 1; cGlyph[ci] = THIN[(h >> 8) % 4]; cCol[ci] = tint(col, light, 0, fmaxf(fog, 0.0f) + 0.5f - 0.35f * cov); return;
  }
  if (kind == K_LIGHT) {
    if (cFlag[ci] == 2) return;
    cFlag[ci] = 1; cGlyph[ci] = LIGHTG[(h >> 8) % 5]; cCol[ci] = tint(col, light, 0, fog + 0.15f); return;
  }
  float shim = 1;
  if (kind == K_BODY) shim = 1 - 0.4f * T.shimmer + T.shimmer * sinf(now * 2.2f + cx * 0.9f + cy * 0.6f + id);
  cFlag[ci] = 2;
  float m = light * shim;
  cFill[ci] = tint(col, m, 0, fog);
  if (kind == K_EDGE) { cGlyph[ci] = EDGEG[(h >> 8) % 4]; cCol[ci] = tint(col, m * 1.7f, 34, fog); }
  else {
    int n = (int)sizeof(RAMP) - 1;
    int k = (int)((1 - lum * m) * (n - 0.01f)) + (int)((h >> 4) % 3) - 1;
    cGlyph[ci] = RAMP[k < 0 ? 0 : k >= n ? n - 1 : k];
    cCol[ci] = tint(col, m * 0.42f, 0, fog);
  }
  if (kind == K_BODY && jit < T.sparkle / 3) { cCol[ci] = pack(250, 250, 255); }   // a cell flashes white, like light catching it
}

// A filled ellipse (rx, ry in pixels, rotated by ang) tested at the cell centre and four more points per cell.
static void ell(float cx, float cy, float rx, float ry, float ang, const uint8_t* col, Kind kind, float depth, int id, float light = 1) {
  if (rx < 0.5f) rx = 0.5f; if (ry < 0.5f) ry = 0.5f;
  float R = fmaxf(rx, ry) + ACW, ca = cosf(ang), sa = sinf(ang), fog = fogOf(depth);
  int x0 = (int)floorf((cx - R) / ACW), x1 = (int)floorf((cx + R) / ACW), y0 = (int)floorf((cy - R) / ACH), y1 = (int)floorf((cy + R) / ACH);
  static const float OX[5] = {0.5f, 0.2f, 0.8f, 0.2f, 0.8f}, OY[5] = {0.5f, 0.2f, 0.2f, 0.8f, 0.8f};
  for (int j = y0; j <= y1; j++) for (int i = x0; i <= x1; i++) {
    if (i < 0 || j < 0 || i >= ACOLS || j >= AROWS) continue;
    int n = 0;
    for (int s = 0; s < 5; s++) {
      float dx = i * ACW + OX[s] * ACW - cx, dy = j * ACH + OY[s] * ACH - cy;
      float u = (dx * ca + dy * sa) / rx, v = (dy * ca - dx * sa) / ry;
      if (u * u + v * v <= 1) n++;
    }
    if (!n) continue;
    float cov = n / 5.0f;
    putCell(j * ACOLS + i, i, j, id, kind, col, light, n >= 2 ? 1.0f : cov, fog);
  }
}
// A capsule: the points within r pixels of the segment.
static void cap(float x0, float y0, float x1, float y1, float r, const uint8_t* col, Kind kind, float depth, int id, float light = 1) {
  float dx = x1 - x0, dy = y1 - y0, l2 = dx * dx + dy * dy + 0.001f, fog = fogOf(depth);
  float R = r + ACW;
  int a0 = (int)floorf((fminf(x0, x1) - R) / ACW), a1 = (int)floorf((fmaxf(x0, x1) + R) / ACW);
  int b0 = (int)floorf((fminf(y0, y1) - R) / ACH), b1 = (int)floorf((fmaxf(y0, y1) + R) / ACH);
  for (int j = b0; j <= b1; j++) for (int i = a0; i <= a1; i++) {
    if (i < 0 || j < 0 || i >= ACOLS || j >= AROWS) continue;
    float px = i * ACW + ACW * 0.5f, py = j * ACH + ACH * 0.5f;
    float t = clampf(((px - x0) * dx + (py - y0) * dy) / l2, 0, 1);
    float d = sqrtf((px - x0 - dx * t) * (px - x0 - dx * t) + (py - y0 - dy * t) * (py - y0 - dy * t));
    if (d <= r) putCell(j * ACOLS + i, i, j, id, kind, col, light, 1.0f, fog);
    else if (d <= r + ACW * 0.45f) putCell(j * ACOLS + i, i, j, id, kind, col, light, 0.2f, fog);
  }
}
static char lineGlyph(float ang) {
  float a = fmodf(ang + TAU * 4, PI_);   // 0..pi
  if (a < PI_ / 8 || a >= 7 * PI_ / 8) return '-';
  if (a < 3 * PI_ / 8) return '\\';
  if (a < 5 * PI_ / 8) return '|';
  return '/';
}
// A thin line of glyphs.
static void line(float x0, float y0, float x1, float y1, const uint8_t* col, float depth, char last = 0, float light = 1) {
  float fog = fogOf(depth), len = sqrtf((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
  int n = (int)fmaxf(1, ceilf(len / (ACW * 0.5f))), li = -1;
  char g = lineGlyph(atan2f(y1 - y0, x1 - x0));
  for (int s = 1; s <= n; s++) {
    int ci = cellAt(x0 + (x1 - x0) * s / n, y0 + (y1 - y0) * s / n);
    if (ci < 0 || cFlag[ci] == 2) continue;
    cFlag[ci] = 1; cGlyph[ci] = g; cCol[ci] = tint(col, light, 0, fog); li = ci;
  }
  if (last && li >= 0) cGlyph[li] = last;
}
// One solid cell with its own glyph (eyes, spots).
static void spot(float x, float y, char g, const uint8_t* fillc, const uint8_t* col, float depth) {
  int ci = cellAt(x, y); if (ci < 0) return;
  float fog = fogOf(depth);
  cFlag[ci] = 2; cFill[ci] = tint(fillc, 1, 0, fog); cCol[ci] = tint(col, 1, 0, fog); cGlyph[ci] = g;
}
static void dotc(float x, float y, char g, const uint8_t* col, float depth) {
  int ci = cellAt(x, y); if (ci < 0 || cFlag[ci] == 2) return;
  cFlag[ci] = 1; cGlyph[ci] = g; cCol[ci] = tint(col, 1, 0, fogOf(depth));
}
static void shed(float x, float y, float amt) {
  int ci = cellAt(x, y);
  if (ci >= 0) energy[ci] = fminf(1.6f, energy[ci] + amt * T.trail);
}
static void stamp(float x, float y, int radius, float amount) {
  int ox = (int)floorf(x / ACW), oy = (int)floorf(y / ACH);
  for (int j = oy - radius; j <= oy + radius; j++) for (int i = ox - radius; i <= ox + radius; i++) {
    if (i < 0 || j < 0 || i >= ACOLS || j >= AROWS) continue;
    float d = sqrtf((float)((i - ox) * (i - ox)) + (j - oy) * 1.5f * (j - oy) * 1.5f);
    if (d > radius + 0.5f) continue;
    int ci = j * ACOLS + i; energy[ci] = fminf(1.6f, energy[ci] + amount * (1 - d / (radius + 1)));
  }
}

// ----------------------------------------------------------------------------- world helpers
static float course() { return T.corner ? atan2f(-(float)ASH, (float)ASW) : -T.direction * PI_ / 180.0f; }
static float groupHeading() { return course() + 0.04f * (sinf(now * 0.13f) + 0.5f * sinf(now * 0.31f + 1.7f)); }
static float baseSize() { return 62.0f * ANIMALS[animal].scale; }
static float depthOf(float roll) { return 0.8f + 0.2f * powf(roll, 1.6f); }
static float cruise(const Cr& c) { return ANIMALS[animal].speed * (0.55f + 0.45f * c.depth) * T.speed; }
static void toW(const Cr& c, float u, float v, float& x, float& y) {
  float ca = cosf(c.heading), sa = sinf(c.heading);
  x = c.x + (u * ca - v * sa) * c.span; y = c.y + (u * sa + v * ca) * c.span;
}
static void begin_() { accx = accy = 0; }
static void steer(const Cr& c, float ang, float spd, float gain) { accx += (cosf(ang) * spd - c.vx) * gain; accy += (sinf(ang) * spd - c.vy) * gain; }
static void separate(const Cr& c, float k = 170, float reach = 0.42f) {
  if (k <= 0) return;
  for (int i = 0; i < ncr; i++) {
    const Cr& n = cr[i]; if (&n == &c || fabsf(n.depth - c.depth) > 0.2f) continue;
    float dx = c.x - n.x, dy = c.y - n.y, r = sqrtf(dx * dx + dy * dy), h = (c.span + n.span) * reach;
    if (r < h && r > 0.001f) { float l = (1 - r / h) * k; accx += dx / r * l; accy += dy / r * l; }
  }
}
static float move(Cr& c, float dt, float maxSpeed) {
  c.vx += accx * dt; c.vy += accy * dt;
  float n = sqrtf(c.vx * c.vx + c.vy * c.vy), m = maxSpeed + (now < c.startled ? 90 : 0);
  if (n > m) { c.vx *= m / n; c.vy *= m / n; n = m; }
  c.x += c.vx * dt; c.y += c.vy * dt; return n;
}
static void face(Cr& c, float dt, float rate, float target) { float a = rate * dt; c.heading += clampf(angDiff(c.heading, target), -a, a); }
static bool passed(const Cr& c, float s) {
  float co = cosf(course()), si = sinf(course());
  bool h = (co > 0.05f && c.x > ASW + s) || (co < -0.05f && c.x < -s) || (si < -0.05f && c.y < -s) || (si > 0.05f && c.y > ASH + s);
  bool l = c.x < -3 * s || c.x > ASW + 3 * s || c.y < -3 * s || c.y > ASH + 3 * s;
  return h || l;
}

static void enterCr(Cr& c) {
  switch (animal) {
    case A_KOI: { float e = c.span / 7; for (int i = 0; i < 8; i++) { c.nodes[i][0] = c.x - cosf(c.heading) * e * i; c.nodes[i][1] = c.y - sinf(c.heading) * e * i; } break; }
    case A_FROG: c.leaping = false; c.s = 0; c.vx = c.vy = 0; c.aim = groupHeading() + c.bias * 0.06f; c.heading = c.aim; c.until = now + rf(0, 1.5f); break;
    case A_CRAB: c.mode = true; c.until = now + rf(0.3f, 1.2f); c.heading = course() - c.facing * PI_ / 2; break;
    case A_DRAGON: c.m = 0; c.until = now + rf(0, 0.6f); c.aim = course(); break;
    case A_BUTTERFLY: c.flx = c.fly = 0; break;
    default: break;
  }
}
static void reenter(Cr& c) {
  float a = c.span * 0.6f, co = cosf(course()), si = sinf(course()), h = ASH * fabsf(co), l = ASW * fabsf(si);
  if (rnd() * (h + l) < h) { c.x = co >= 0 ? -a : ASW + a; c.y = rf(0, ASH); } else { c.x = rf(0, ASW); c.y = si <= 0 ? ASH + a : -a; }
  float s = cruise(c);
  c.heading = course(); c.vx = co * s; c.vy = si * s; c.bias = rf(-1, 1);
  enterCr(c);
}
static void spawn(Cr& c) {
  memset(&c, 0, sizeof c);
  c.id = nextId++; if (!nextId) nextId = 1;
  c.roll = rnd(); c.depth = depthOf(c.roll); c.span = baseSize() * c.depth * T.size;
  c.phase = rf(0, TAU); c.open = 1; c.facing = rnd() < 0.5f ? 1 : -1; c.dur = 0.5f; c.variety = (uint8_t)(hash3(c.id, 7, 3) % 4);
  reenter(c);
}
static int targetCount() {
  float n = ANIMALS[animal].count * T.density;
  int v = (int)floorf(n + 0.5f); return v < 1 ? 1 : v > MAXC ? MAXC : v;
}
static void populate(bool first) {
  int n = targetCount();
  while (ncr > n) { int i = (int)(rnd() * ncr); if (i >= ncr) i = ncr - 1; cr[i] = cr[ncr - 1]; ncr--; }
  while (ncr < n) {
    Cr& c = cr[ncr]; spawn(c);
    if (first || rnd() < 0.5f) { c.x = rf(0, ASW); c.y = rf(0, ASH); enterCr(c); }
    ncr++;
  }
}

// ----------------------------------------------------------------------------- public: set up, animal choice, tap, step
static void clearAll() { memset(energy, 0, sizeof(float) * ANC); memset(energyTmp, 0, sizeof(float) * ANC); memset(food, 0, sizeof(Food) * MAXFOOD); }
static void restyle() { setHue(T.hue); }
static void setAnimal(int a, bool keepTune = false) {
  if (!alloc()) return;
  if (a < 0 || a >= NANIMALS) a = 0;
  animal = a; if (!keepTune) T = ANIMALS[a].def;
  ncr = 0; clearAll(); restyle(); populate(true);
}
static void init() { setAnimal(0); }   // (unused on the host)

// A tap at (x, y) in display pixels: koi get food, everything else is startled and a ripple spreads.
static void startle(float x, float y) {
  if (!ready) return;
  if (animal == A_KOI) {
    int n = 7 + (int)(rnd() * 5);
    for (int k = 0; k < n; k++) {
      int slot = -1; for (int i = 0; i < MAXFOOD; i++) if (!food[i].live) { slot = i; break; }
      if (slot < 0) { slot = 0; for (int i = 1; i < MAXFOOD; i++) if (food[i].born < food[slot].born) slot = i; }
      float a = rf(0, TAU), r = 28 * sqrtf(rnd());
      food[slot] = {x + cosf(a) * r, y + sinf(a) * r, cosf(a) * rf(2, 6), sinf(a) * rf(2, 6), now, true};
      stamp(food[slot].x, food[slot].y, 1, 0.5f);
    }
    return;
  }
  stamp(x, y, 4, 1.4f);
  for (int i = 0; i < ncr; i++) {
    Cr& c = cr[i]; float dx = c.x - x, dy = c.y - y, d = sqrtf(dx * dx + dy * dy); if (d < 0.001f) { dx = 1; d = 1; }
    if (d > 70) continue;
    float r = 1 - d / 70, ux = dx / d, uy = dy / d;
    switch (animal) {
      case A_BUTTERFLY: { float k = r * 190 * c.depth; c.vx += ux * k; c.vy += uy * k; c.startled = now + rf(0.6f, 1.2f); c.glideUntil = 0; break; }
      case A_JELLY: { c.phase = floorf(c.phase / TAU) * TAU + TAU; float k = 120 * r * c.depth; c.vx += cosf(c.heading) * k; c.vy += sinf(c.heading) * k; c.startled = now + 0.8f; break; }
      case A_DRAGON: c.m = 1; c.aim = groupHeading() + c.bias * 0.06f; c.until = now + 0.25f + 0.3f * r; c.startled = c.until; break;
      case A_FROG:
        if (!c.leaping) {
          float len = c.span * 2.0f * T.k[1] * (1 + r), h = atan2f(uy, ux);
          c.leaping = true; c.s = 0; c.fx = c.x; c.fy = c.y; c.tx = c.x + cosf(h) * len; c.ty = c.y + sinf(h) * len; c.heading = h; c.dur = 0.45f; c.startled = now + c.dur;
        }
        break;
      case A_CRAB: if (T.k[2] > 0) {
        c.aim = atan2f(uy, ux) + rf(-0.35f, 0.35f); c.b = cruise(c) * (2.5f + 3 * r) * T.k[2]; c.a = now; c.startled = now + (1 + 1.5f * r) * sqrtf(T.k[2]);
        c.vx = cosf(c.aim) * c.b; c.vy = sinf(c.aim) * c.b; c.mode = true; c.until = c.startled + rf(0.3f, 1); c.alarm = 1;
      } break;
      default: { float k = r * 160 * c.depth; c.vx += ux * k; c.vy += uy * k; c.startled = now + rf(0.6f, 1.0f); break; }   // crane
    }
  }
}

static Food* nearestFood(const Cr& c, float range) {
  Food* best = nullptr; float bd = range;
  for (int i = 0; i < MAXFOOD; i++) if (food[i].live) {
    float d = sqrtf((food[i].x - c.x) * (food[i].x - c.x) + (food[i].y - c.y) * (food[i].y - c.y));
    if (d < bd) { bd = d; best = &food[i]; }
  }
  return best;
}

static void leap(Cr& c, float dir, float power) {
  float len = c.span * (1.2f + 0.8f * rnd()) * T.k[1] * power;
  c.leaping = true; c.s = 0; c.fx = c.x; c.fy = c.y; c.tx = c.x + cosf(dir) * len; c.ty = c.y + sinf(dir) * len; c.heading = dir; c.dur = 0.5f / fmaxf(0.4f, T.speed);
}

static void updateCr(Cr& c, float dt) {
  const float g = T.speed;
  float cru = cruise(c);
  switch (animal) {
    case A_BUTTERFLY: {
      begin_();
      steer(c, groupHeading() + c.bias * 0.06f, cru, 3.0f);
      float r = sqrtf(dt) * 130 * 1.3f * T.k[0] * (1 - 0.8f * c.glide) * (0.5f + 0.5f * c.depth);
      c.flx += -c.flx * 3 * dt + (rnd() * 2 - 1) * r; c.fly += -c.fly * 3 * dt + (rnd() * 2 - 1) * r;
      accx += c.flx; accy += c.fly;
      float h = fmaxf(0, -sinf(c.phase)) * (1 - c.glide);
      accx += cosf(c.heading) * h * cru * 1.4f; accy += sinf(c.heading) * h * cru * 1.4f;
      separate(c);
      float sp = move(c, dt, cru * 2.2f);
      if (passed(c, c.span)) reenter(c);
      if (sp > 6) face(c, dt, 7, atan2f(c.vy, c.vx));
      if (c.glide < 0.5f && now > c.glideUntil && sp > cru * 0.5f && rnd() < 0.35f * T.k[1] * dt) c.glideUntil = now + rf(0.5f, 1.4f);
      c.glide += ((now < c.glideUntil ? 1 : 0) - c.glide) * fminf(1, dt * 6);
      float cc = clampf(sp / (cru * 2), 0, 1);
      c.phase += dt * TAU * 2.6f * T.k[2] * (0.8f + 0.6f * cc) * (1 - 0.9f * c.glide);
      float d = powf(0.5f + 0.5f * cosf(c.phase), 0.8f);
      c.open = 0.1f + 0.9f * (d * (1 - c.glide) + 0.96f * c.glide);
      break;
    }
    case A_KOI: {
      Food* f = nearestFood(c, T.k[2]);
      float eager = f ? 0.25f + 0.75f * 0.6f : 0;
      float want = f ? atan2f(f->y - c.y, f->x - c.x) : groupHeading() + c.bias * 0.06f + T.k[0] * 0.6f * sinf(now * 0.35f + c.id * 1.7f);
      begin_(); separate(c, 120, 0.5f);
      if (accx || accy) want = atan2f(sinf(want) * cru + accy * 0.3f, cosf(want) * cru + accx * 0.3f);
      float turn = mixf(0.9f * 2.0f, 2.6f, eager) * dt;
      c.heading += clampf(angDiff(c.heading, want), -turn, turn);
      float sp = cru * mixf(0.85f + 0.25f * sinf(now * 0.5f + c.id), 1.8f, eager);
      c.vx = cosf(c.heading) * sp; c.vy = sinf(c.heading) * sp; c.x += c.vx * dt; c.y += c.vy * dt;
      c.phase += dt * (2 + sp / 25) * T.k[1];
      float seg = c.span / 7; c.nodes[0][0] = c.x; c.nodes[0][1] = c.y;
      float base = c.heading + PI_;
      for (int i = 1; i < 8; i++) {
        float p = atan2f(c.nodes[i][1] - c.nodes[i - 1][1], c.nodes[i][0] - c.nodes[i - 1][0]);
        p = base + clampf(angDiff(base, p), -0.22f, 0.22f);
        c.nodes[i][0] = c.nodes[i - 1][0] + cosf(p) * seg; c.nodes[i][1] = c.nodes[i - 1][1] + sinf(p) * seg; base = p;
      }
      if (f && sqrtf((f->x - c.x) * (f->x - c.x) + (f->y - c.y) * (f->y - c.y)) < c.span * 0.12f + 3) { f->live = false; stamp(f->x, f->y, 1, 0.7f); }
      if (passed(c, c.span * 1.3f)) reenter(c);
      break;
    }
    case A_JELLY: {
      c.phase += dt * TAU * 0.6f * T.k[0] * (0.9f + 0.2f * c.roll);
      float n = fract(c.phase / TAU);
      c.squeeze = n < 0.22f ? smooth(0, 0.22f, n) : 1 - smooth(0.22f, 1, n);
      float want = groupHeading() + c.bias * 0.06f, old = c.heading;
      c.heading += clampf(angDiff(c.heading, want), -0.6f * 3 * dt, 0.6f * 3 * dt);
      c.turn += (angDiff(old, c.heading) / dt - c.turn) * fminf(1, dt * 3);
      begin_();
      float l = n < 0.22f ? 6.2f * cru * T.k[1] : 0;
      accx += cosf(c.heading) * l - c.vx * 1.4f; accy += sinf(c.heading) * l - c.vy * 1.4f;
      separate(c, 120, 0.5f); move(c, dt, cru * 3);
      if (passed(c, c.span * 1.4f)) reenter(c);
      break;
    }
    case A_DRAGON: {
      if (now >= c.until) {
        uint8_t prev = c.m;   // 0 hover, 1 dart, 2 cruise
        c.m = prev == 0 ? 1 : prev == 1 ? (rnd() < 0.5f ? 2 : 0) : (rnd() < 0.35f ? 1 : 0);
        if (c.m == 1) { c.until = now + rf(0.15f, 0.45f); if (prev == 2) c.aim = c.heading + rf(-0.4f, 0.4f) * 0.26f; }
        else if (c.m == 2) { c.until = now + rf(1.2f, 4.5f); c.aim = groupHeading() + c.bias * 0.06f; }
        else { c.until = now + fminf(3, fmaxf(0.15f, -logf(1 - rnd() * 0.999f) * 0.7f)) * T.k[0]; c.aim = groupHeading() + rf(-1, 1) * 0.09f; }
      }
      begin_();
      if (c.m == 1) steer(c, c.aim, cru * 4 * T.k[2], 10);
      else if (c.m == 2) { c.aim += rf(-1, 1) * dt * 1.2f; c.aim += (groupHeading() - c.aim) * fminf(1, dt * 0.8f); steer(c, c.aim, cru * 1.8f, 3); }
      else { steer(c, groupHeading(), cru * 0.25f, 4); accx += cosf(now * 3 + c.id) * 20; accy += sinf(now * 4.3f + c.id * 2) * 20; }
      separate(c, 200, 0.42f); move(c, dt, cru * 4.5f * T.k[2]);
      if (passed(c, c.span)) reenter(c);
      if (c.m == 2) face(c, dt, 4, atan2f(c.vy, c.vx)); else face(c, dt, c.m == 1 ? 14 : 2.5f, c.aim);
      c.phase += dt * TAU * 7 * T.k[1] * (1.0f / 1.0f);
      break;
    }
    case A_FROG: {
      if (!c.leaping) {
        c.vx = c.vy = 0; face(c, dt, 2.5f, c.aim);
        if (now >= c.until) leap(c, c.aim, 1);
        return;
      }
      c.s += dt / c.dur;
      if (c.s >= 1) {
        c.leaping = false; c.x = c.tx; c.y = c.ty;
        c.until = now + rf(0.5f, 2.2f) / (T.k[0] * g);
        c.aim = groupHeading() + (c.bias + rf(-0.7f, 0.7f)) * 0.06f;
        stamp(c.x, c.y, 3, 0.7f * c.depth * T.trail);
        if (passed(c, c.span)) reenter(c);
        return;
      }
      c.x = mixf(c.fx, c.tx, c.s); c.y = mixf(c.fy, c.ty, c.s);
      break;
    }
    case A_CRANE: {
      begin_();
      steer(c, groupHeading() + c.bias * 0.06f, cru, 5);
      separate(c, 150, 0.42f);
      float sp = move(c, dt, cru * 2);
      if (passed(c, c.span)) reenter(c);
      if (sp > 4) face(c, dt, 2.2f, atan2f(c.vy, c.vx));
      if (c.glide < 0.5f && now > c.glideUntil && rnd() < 0.2f * T.k[1] * dt) c.glideUntil = now + rf(1.0f, 2.6f);
      c.glide += ((now < c.glideUntil ? 1 : 0) - c.glide) * fminf(1, dt * 3);
      c.phase += dt * TAU * 1.1f * T.k[0] * (1 - 0.85f * c.glide);
      break;
    }
    case A_CRAB: {
      if (now >= c.until) {
        c.mode = !c.mode || T.k[1] <= 0;
        c.until = now + (c.mode ? rf(0.5f, 1.6f) * T.k[0] : rf(0.3f, 1.4f) * T.k[1]);
      }
      bool fleeing = now < c.startled;
      float h = fleeing ? (now - c.a) / (c.startled - c.a + 0.001f) : 1, dir = fleeing ? c.aim : groupHeading() + c.bias * 0.06f;
      begin_();
      if (fleeing) steer(c, c.aim, fmaxf(cru, c.b * (1 - h * h)), 8); else steer(c, dir, c.mode ? cru : 0, 4);
      separate(c, 170, 0.42f);
      float sp = move(c, dt, fleeing ? fmaxf(cru * 2, c.b) : cru * 2);
      if (passed(c, c.span)) reenter(c);
      float want = dir - c.facing * PI_ / 2;
      float tr = (fleeing ? 10 : 3) * dt;
      c.heading += clampf(angDiff(c.heading, want), -tr, tr);
      c.gait += dt * sp * 1.0f / fmaxf(3, c.span * 0.12f);
      c.alarm = fmaxf(0, c.alarm - dt * 0.7f);
      break;
    }
  }
}

static void step(float dt) {
  if (!ready) return;
  now += dt;
  populate(false);
  for (int i = 0; i < ncr; i++) { cr[i].depth = depthOf(cr[i].roll); cr[i].span = baseSize() * cr[i].depth * T.size; }
  for (int i = 0; i < MAXFOOD; i++) if (food[i].live) {
    food[i].vx *= expf(-dt * 0.8f); food[i].vy *= expf(-dt * 0.8f); food[i].x += food[i].vx * dt; food[i].y += food[i].vy * dt;
    if (now - food[i].born > 9) food[i].live = false;
  }
  for (int i = 0; i < ncr; i++) updateCr(cr[i], dt);
}

// ----------------------------------------------------------------------------- drawing each animal
static void drawButterfly(Cr& c) {
  // Two-tone wings (blue forewings, orange hindwings) with white spots, a bright body and feelers: every part contrasts with the dark background.
  const uint8_t fore[3] = {70, 150, 255}, hind[3] = {255, 150, 50}, bodyC[3] = {240, 240, 250}, white[3] = {255, 255, 255}, dark[3] = {20, 40, 110};
  float s = c.span, op = fmaxf(0.12f, c.open), x, y, hd = c.heading + 0.06f * sinf(c.phase);
  Cr b = c; b.heading = hd;
  for (int sd = -1; sd <= 1; sd += 2) {
    toW(b, 0.16f, 0.2f * sd * op, x, y);   ell(x, y, 0.21f * s, 0.25f * s * op, hd + sd * 0.45f, fore, K_BODY, c.depth, c.id, 1.0f);
    toW(b, 0.2f, 0.3f * sd * op, x, y);    spot(x, y, 'o', dark, white, c.depth);
    toW(b, -0.14f, 0.17f * sd * op, x, y); ell(x, y, 0.17f * s, 0.18f * s * op, hd - sd * 0.5f, hind, K_BODY, c.depth, c.id, 1.0f);
    toW(b, -0.17f, 0.2f * sd * op, x, y);  dotc(x, y, '.', white, c.depth);
  }
  float x0, y0, x1, y1; toW(b, -0.24f, 0, x0, y0); toW(b, 0.22f, 0, x1, y1);
  cap(x0, y0, x1, y1, fmaxf(2.0f, 0.045f * s), bodyC, K_EDGE, c.depth, c.id, 0.9f);
  float r = 0.015f * sinf(now * 3 + c.id);
  for (int sd = -1; sd <= 1; sd += 2) { toW(b, 0.24f, 0.015f * sd, x0, y0); toW(b, 0.42f + r, (0.13f + r) * sd, x1, y1); line(x0, y0, x1, y1, bodyC, c.depth, 'o'); }
  float h = fmaxf(0, -sinf(c.phase)) * (1 - c.glide);
  for (int sd = -1; sd <= 1; sd += 2) { toW(b, 0.1f, 0.3f * sd * c.open, x, y); shed(x, y, (0.02f + 0.1f * h) * c.depth); }
}

static void drawKoi(Cr& c) {
  static const uint8_t WHITE[3] = {236, 236, 230}, ORANGE[3] = {232, 96, 40}, GOLD[3] = {244, 196, 44}, BLACK[3] = {28, 26, 30}, RED[3] = {214, 60, 44};
  float s = c.span;
  auto colorAt = [&](int i) -> const uint8_t* {
    float n = hash01(c.id, i / 2, 5);
    switch (c.variety) {
      case 0: return n > 0.55f ? ORANGE : WHITE;                       // kohaku: white with orange
      case 1: return GOLD;                                              // ogon
      case 2: return n > 0.72f ? BLACK : n > 0.4f ? ORANGE : WHITE;     // showa
      default: return n > 0.6f ? WHITE : RED;                           // red with white
    }
  };
  float wag = sinf(c.phase) * 0.55f;
  // tail fin
  float tx = c.nodes[7][0], ty = c.nodes[7][1], ta = atan2f(c.nodes[7][1] - c.nodes[6][1], c.nodes[7][0] - c.nodes[6][0]);
  ell(tx + cosf(ta + wag * 0.4f) * s * 0.1f, ty + sinf(ta + wag * 0.4f) * s * 0.1f, s * 0.13f, s * 0.07f, ta + wag, WHITE, K_LIGHT, c.depth, c.id);
  for (int i = 7; i >= 0; i--) {
    float t = i / 7.0f, w = s * 0.095f * powf(sinf(PI_ * (0.12f + 0.88f * powf(t, 0.8f))), 0.7f) * (1 - 0.45f * t);
    int j = i > 0 ? i - 1 : 0; float x0 = c.nodes[j][0], y0 = c.nodes[j][1];
    cap(x0, y0, c.nodes[i][0], c.nodes[i][1], fmaxf(1.4f, w), colorAt(i), K_BODY, c.depth, c.id);
    if (i == 1) for (int sd = -1; sd <= 1; sd += 2) {   // pectoral fins
      float a = ta; (void)a; float ha = atan2f(c.nodes[0][1] - c.nodes[2][1], c.nodes[0][0] - c.nodes[2][0]);
      float fx = c.nodes[1][0] + cosf(ha + sd * 1.5f) * s * 0.09f, fy = c.nodes[1][1] + sinf(ha + sd * 1.5f) * s * 0.09f;
      ell(fx, fy, s * 0.08f, s * 0.04f, ha + sd * (0.9f + 0.3f * sinf(c.phase * 0.7f)), WHITE, K_LIGHT, c.depth, c.id);
    }
    if (i % 3 == 0) shed(c.nodes[i][0], c.nodes[i][1], 0.03f * c.depth);
  }
  float ha = atan2f(c.nodes[0][1] - c.nodes[1][1], c.nodes[0][0] - c.nodes[1][0]);
  for (int sd = -1; sd <= 1; sd += 2) spot(c.nodes[0][0] + cosf(ha) * s * 0.03f + cosf(ha + PI_ / 2) * sd * 3.2f, c.nodes[0][1] + sinf(ha) * s * 0.03f + sinf(ha + PI_ / 2) * sd * 3.2f, 'o', BLACK, WHITE, c.depth);
}

static void drawJelly(Cr& c) {
  static const uint8_t PINK[3] = {226, 130, 255}, RIM[3] = {170, 90, 235}, TENT[3] = {190, 150, 255}, GLOW[3] = {255, 235, 255};
  float s = c.span, sq = c.squeeze, x, y;
  float n = fract(c.phase / TAU), glow = (n < 0.16f ? smooth(0, 0.16f, n) : expf(-(n - 0.16f) * 4.5f)) * T.k[1] * 0.4f;
  float b = clampf(-c.turn * 0.5f, -0.5f, 0.5f);
  int tn = 6;
  for (int i = 0; i < tn; i++) {
    float v = ((float)i / (tn - 1) - 0.5f) * 2 * 0.3f * 0.6f * (1 - 0.2f * sq);
    float len = 0.55f * T.k[2] * (0.75f + 0.35f * hash01(c.id, i, 4)) * (1 - 0.12f * sq);
    float u0 = -0.06f, px, py; toW(c, u0, v, px, py);
    for (int k = 1; k <= 5; k++) {
      float L = k / 5.0f, u1 = u0 - L * len, v1 = v + sinf(now * 2.0f + i * 0.9f + L * 5.0f - b * 3) * 0.05f * L + b * L * 0.1f;
      float qx, qy; toW(c, u1, v1, qx, qy); line(px, py, qx, qy, TENT, c.depth, 0, 0.9f - 0.3f * L); px = qx; py = qy;
    }
    float fx, fy; toW(c, u0 - len * 0.5f, v, fx, fy); shed(fx, fy, 0.02f * c.depth);
  }
  toW(c, 0.02f, 0, x, y);
  float ru = 0.17f * (1 + 0.14f * sq) * s, rv = 0.3f * (1 - 0.2f * sq) * s;
  ell(x, y, ru * 1.15f, rv * 1.12f, c.heading, RIM, K_EDGE, c.depth, c.id, 0.8f);
  ell(x, y, ru, rv, c.heading, PINK, K_BODY, c.depth, c.id, 0.85f + glow);
  toW(c, 0.06f, 0, x, y); ell(x, y, ru * 0.45f, rv * 0.55f, c.heading, GLOW, K_LIGHT, c.depth, c.id, 1.0f);
  toW(c, -0.05f, 0, x, y);
  for (int i = -1; i <= 1; i++) { float ox, oy; toW(c, -0.06f, i * 0.08f, ox, oy); ell(ox, oy, 0.05f * s, 0.05f * s, 0, PINK, K_LIGHT, c.depth, c.id, 1.2f); }
}

static void drawDragon(Cr& c) {
  // A solid bright body, a big head and four long narrow wings across it that beat.
  const uint8_t body[3] = {40, 225, 175}, head[3] = {255, 255, 255}, wing[3] = {175, 225, 255}, red[3] = {255, 110, 70}, eyeC[3] = {10, 30, 40};
  float s = c.span, beat = fabsf(cosf(c.phase)), bs = 0.6f + 0.4f * beat, x0, y0, x1, y1;
  toW(c, 0.3f, 0, x0, y0); toW(c, -0.42f, 0, x1, y1);
  for (int p = 0; p < 2; p++) for (int sd = -1; sd <= 1; sd += 2) {
    float u = 0.14f - 0.16f * p, wx, wy;
    toW(c, u, sd * 0.2f * bs, wx, wy);
    ell(wx, wy, 0.21f * s * bs, 0.065f * s, c.heading + PI_ / 2 + sd * (p ? 0.28f : -0.28f), wing, K_BODY, c.depth, c.id, 0.9f);
  }
  cap(x0, y0, x1, y1, fmaxf(2.2f, 0.04f * s), body, K_BODY, c.depth, c.id, 1.1f);
  dotc(x1, y1, '~', red, c.depth);
  toW(c, 0.33f, 0, x0, y0); spot(x0, y0, 'O', body, head, c.depth);
  toW(c, 0.36f, 0.05f, x1, y1); dotc(x1, y1, '.', eyeC, c.depth);
  float hx, hy; toW(c, 0.08f, 0, hx, hy); shed(hx, hy, 0.01f * c.depth);
}

static void drawFrog(Cr& c) {
  static const uint8_t GREEN[3] = {96, 200, 100}, DARK[3] = {40, 110, 60}, EYE[3] = {236, 242, 200}, BLK[3] = {10, 24, 14}, SHADOW[3] = {14, 30, 24};
  float air = c.leaping ? sinf(PI_ * c.s) : 0;
  float s = c.span * (1 + 0.55f * air * T.k[2] * 0.7f), x, y;
  if (c.leaping) { toW(c, 0, 0, x, y); ell(x, y, c.span * 0.2f, c.span * 0.15f, c.heading, SHADOW, K_LIGHT, c.depth, c.id, 0.6f); }
  float yoff = -c.span * 0.28f * air * T.k[2];
  Cr b = c; b.y += yoff; b.span = s;
  float leg = c.leaping ? 0.5f + 0.5f * air : 0.0f;
  for (int sd = -1; sd <= 1; sd += 2) {
    float x0, y0, x1, y1, x2, y2; toW(b, -0.08f, 0.12f * sd, x0, y0); toW(b, -0.2f - 0.15f * leg, 0.22f * sd, x1, y1); toW(b, -0.3f - 0.3f * leg, 0.16f * sd, x2, y2);
    line(x0, y0, x1, y1, DARK, c.depth, 0, 1.2f); line(x1, y1, x2, y2, DARK, c.depth, 0, 1.2f);
    toW(b, 0.12f, 0.13f * sd, x0, y0); toW(b, 0.2f, 0.2f * sd, x1, y1); line(x0, y0, x1, y1, DARK, c.depth, 0, 1.2f);
  }
  toW(b, -0.02f, 0, x, y); ell(x, y, 0.22f * s, 0.15f * s, c.heading, GREEN, K_BODY, c.depth, c.id);
  toW(b, 0.2f, 0, x, y); ell(x, y, 0.12f * s, 0.12f * s, c.heading, GREEN, K_BODY, c.depth, c.id);
  toW(b, -0.02f, 0, x, y); ell(x, y, 0.07f * s, 0.07f * s, c.heading, DARK, K_EDGE, c.depth, c.id, 0.8f);
  for (int sd = -1; sd <= 1; sd += 2) { toW(b, 0.23f, 0.08f * sd, x, y); spot(x, y, 'o', EYE, BLK, c.depth); }
}

static void drawCrane(Cr& c) {
  static const uint8_t WHITE[3] = {236, 238, 242}, TIP[3] = {40, 40, 48}, LEG[3] = {78, 78, 92}, RED[3] = {226, 36, 36}, BEAK[3] = {196, 196, 150}, GREY[3] = {170, 175, 190};
  float s = c.span, x, y, x1, y1;
  float flap = powf(0.5f + 0.5f * cosf(c.phase), 0.8f);
  float arm = fmaxf(0.12f, 0.25f + 0.75f * (flap * (1 - c.glide) + c.glide));
  if (T.k[2] > 0.5f) arm = fmaxf(0.15f, cosf(c.phase) * (1 - c.glide) + c.glide * 0.9f);
  for (int sd = -1; sd <= 1; sd += 2) { toW(c, -0.25f, 0.02f * sd, x, y); toW(c, -0.72f, 0.04f * sd + 0.02f * sinf(c.phase * 0.5f), x1, y1); line(x, y, x1, y1, LEG, c.depth, 0, 1.0f); }
  for (int sd = -1; sd <= 1; sd += 2) {
    toW(c, 0.0f, (0.08f + 0.22f * arm) * sd, x, y);
    ell(x, y, 0.2f * s, (0.06f + 0.3f * arm) * s, c.heading + sd * 0.1f, WHITE, K_BODY, c.depth, c.id, 0.95f);
    toW(c, -0.1f, (0.1f + 0.46f * arm) * sd, x, y);
    ell(x, y, 0.12f * s, (0.04f + 0.14f * arm) * s, c.heading, TIP, K_EDGE, c.depth, c.id, 0.9f);
  }
  toW(c, 0, 0, x, y); ell(x, y, 0.25f * s, 0.1f * s, c.heading, WHITE, K_BODY, c.depth, c.id);
  float nx, ny; toW(c, 0.22f, 0, nx, ny); float hx, hy; toW(c, 0.46f, 0.03f * sinf(now * 1.3f + c.id), hx, hy);
  cap(nx, ny, hx, hy, 1.6f, WHITE, K_BODY, c.depth, c.id);
  spot(hx, hy, 'o', RED, WHITE, c.depth);
  toW(c, 0.58f, 0.03f, x, y); line(hx, hy, x, y, BEAK, c.depth, '>', 1.1f);
  (void)GREY;
}

static void drawCrab(Cr& c) {
  static const uint8_t BODY[3] = {204, 82, 52}, LIGHT[3] = {232, 132, 92}, DARKR[3] = {140, 46, 32}, CLAW[3] = {214, 92, 56}, LEGC[3] = {186, 72, 44}, EYEF[3] = {255, 252, 246}, EYEB[3] = {14, 10, 10};
  float s = c.span, x, y, x1, y1, x2, y2;
  static const float LU[4] = {0.07f, -0.01f, -0.08f, -0.14f};
  for (int sd = -1; sd <= 1; sd += 2) for (int i = 0; i < 4; i++) {
    float d = c.gait + i * PI_ * 0.5f + (sd > 0 ? PI_ : 0), lift = fmaxf(0, sinf(d));
    toW(c, LU[i], 0.2f * sd, x, y); toW(c, LU[i] + 0.04f, (0.36f - 0.03f * lift) * sd, x1, y1); toW(c, LU[i] + 0.08f * cosf(d), (0.52f - 0.06f * lift) * sd, x2, y2);
    line(x, y, x1, y1, LEGC, c.depth); line(x1, y1, x2, y2, LEGC, c.depth);
    if (lift < 0.05f && cosf(d) > 0.9f) shed(x2, y2, 0.12f * c.depth);
  }
  toW(c, 0, 0, x, y); ell(x, y, 0.19f * s, 0.29f * s, c.heading, DARKR, K_EDGE, c.depth, c.id, 0.9f);
  ell(x, y, 0.15f * s, 0.25f * s, c.heading, BODY, K_BODY, c.depth, c.id);
  float a = c.alarm;
  for (int sd = -1; sd <= 1; sd += 2) {
    toW(c, 0.12f, 0.17f * sd, x, y); toW(c, 0.27f + 0.07f * a, 0.25f * sd, x1, y1); line(x, y, x1, y1, CLAW, c.depth, 0, 1.2f);
    toW(c, 0.34f + 0.08f * a, 0.2f * sd, x2, y2);
    ell(x2, y2, 0.11f * s, 0.075f * s, c.heading + sd * 0.55f, CLAW, K_BODY, c.depth, c.id, 1.0f);
    float ex, ey; toW(c, 0.2f, 0.07f * sd, ex, ey); spot(ex, ey, 'o', EYEF, EYEB, c.depth);
  }
  toW(c, 0.02f, 0, x, y); dotc(x, y, '-', LIGHT, c.depth);
}

// ----------------------------------------------------------------------------- one frame
static void diffuse(float dt) {
  float o = expf(-dt * T.trailFade);
  for (int r = 0; r < AROWS; r++) for (int h = 0; h < ACOLS; h++) {
    int l = r * ACOLS + h;
    float c = h > 0 ? energy[l - 1] : energy[l], d = h < ACOLS - 1 ? energy[l + 1] : energy[l], u = r > 0 ? energy[l - ACOLS] : energy[l], b = r < AROWS - 1 ? energy[l + ACOLS] : energy[l];
    energyTmp[l] = (energy[l] * 4 + c + d + u + b) * 0.125f * o;
  }
  memcpy(energy, energyTmp, sizeof(float) * ANC);
}

static void render(float dt) {
  BG = pack(BGR, BGG, BGB);
  if (!ready) return;
  diffuse(dt);
  memset(cFlag, 0, ANC);
  int idx[MAXC];                                     // far to near, like the original (sorted by the depth roll)
  for (int k = 0; k < ncr; k++) idx[k] = k;
  for (int a = 1; a < ncr; a++) { int v = idx[a], b = a - 1; while (b >= 0 && cr[idx[b]].roll > cr[v].roll) { idx[b + 1] = idx[b]; b--; } idx[b + 1] = v; }
  for (int k = 0; k < ncr; k++) {
    Cr& c = cr[idx[k]];
    switch (animal) {
      case A_BUTTERFLY: drawButterfly(c); break; case A_KOI: drawKoi(c); break; case A_JELLY: drawJelly(c); break;
      case A_DRAGON: drawDragon(c); break; case A_FROG: drawFrog(c); break; case A_CRANE: drawCrane(c); break; default: drawCrab(c); break;
    }
  }
  static const uint8_t PELLET[3] = {236, 200, 140};
  for (int i = 0; i < MAXFOOD; i++) if (food[i].live) dotc(food[i].x, food[i].y, 'o', PELLET, 1);
  // trail glow: a small square in the cells the animals left behind
  const uint8_t* tc = ANIMALS[animal].trail;
  for (int i = 0; i < ANC; i++) {
    cTrail[i] = 0;
    float e = energy[i];
    if (e < 0.12f || cFlag[i] == 2) continue;
    float a = clampf(e * 0.9f, 0, 1) * (0.75f + 0.25f * sinf(now * 5 + hash01(i % ACOLS, i / ACOLS, 3) * 40));
    cTrail[i] = tint(tc, 1, 0, 1 - a * 0.8f);
  }
}

}  // namespace asc
