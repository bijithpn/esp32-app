// ASCII animals scene: butterflies, koi, jellyfish, dragonflies, frogs, cranes and crabs drawn as coloured character cells,
// reverse engineered from the "ascii animals" web page (see ascii_engine.h for the simulation and renderer).
//   {"cmd":"ascii","animal":"koi"}                         choose the animal (its own default tuning)
//   {"cmd":"ascii","density":1.5,"speed":0.8,"size":1,"trail":1,"trailFade":0.5,"hue":40,"sparkle":0.1,"fog":0.4,
//    "shimmer":0.3,"grid":1,"corner":true,"direction":49,"flutter":1}   tuning (every field optional; the last key is the animal's own knob)
//   {"cmd":"ascii","tap":[0.5,0.4]}                        a touch from the phone at (x, y) as a 0..1 fraction of the screen:
//                                                          koi are fed, everything else is startled
//   {"cmd":"ascii","reset":true}                           back to the animal's defaults
// The choice and tuning are kept in flash. Included from scenes2.h before the scene table.
#pragma once

#include "ascii_engine.h"

static bool ascLoaded = false;
static uint32_t ascLast = 0;

// What is stored: a version byte, the animal and the whole tuning.
struct AscSaved { uint8_t ver, animal, pad[2]; asc::Tune t; };

static void ascSave() {
#ifndef ASC_HOST
  AscSaved s; memset(&s, 0, sizeof s);
  s.ver = 2; s.animal = (uint8_t)asc::animal; s.t = asc::T;
  prefs.putBytes("asc", &s, sizeof s);
#endif
}
static void ascLoad() {
  if (ascLoaded) return;
  ascLoaded = true;
  asc::setAnimal(0);
#ifndef ASC_HOST
  AscSaved s;
  if (prefs.getBytes("asc", &s, sizeof s) == sizeof s && s.ver == 2 && s.animal < asc::NANIMALS) {
    asc::setAnimal(s.animal);
    asc::Tune& t = asc::T;
    t = s.t;
    // guard against damaged data: every value is clamped to the range the app offers
    t.density = asc::clampf(t.density, 0.1f, 4); t.speed = asc::clampf(t.speed, 0.1f, 3); t.size = asc::clampf(t.size, 0.3f, 2.5f);
    t.trail = asc::clampf(t.trail, 0, 4); t.trailFade = asc::clampf(t.trailFade, 0.05f, 6); t.hue = asc::clampf(t.hue, -180, 180);
    t.sparkle = asc::clampf(t.sparkle, 0, 0.5f); t.fog = asc::clampf(t.fog, 0, 1); t.shimmer = asc::clampf(t.shimmer, 0, 1);
    t.direction = asc::clampf(t.direction, 0, 360); t.grid = asc::clampf(t.grid, 0, 4);
    for (int k = 0; k < 3; k++) t.k[k] = asc::clampf(t.k[k], asc::ANIMALS[s.animal].kmin[k], asc::ANIMALS[s.animal].kmax[k]);
    asc::populate(true); asc::restyle();
  }
#endif
}

// Draws one glyph of the 3 x 5 font into the cell at (x, y).
static void ascGlyph(int x, int y, char ch, uint16_t col) {
  uint16_t b = asc::glyphBits(ch);
  for (int r = 0; r < 5; r++) for (int c = 0; c < 3; c++) if (b & (1 << ((4 - r) * 3 + (2 - c)))) cv.drawPixel(x + c, y + r, col);
}

// The grid first (faint lines on the cell edges, like the web page), then the trail, then the animals.
static void ascDraw() {
  using namespace asc;
  cv.fillScreen(BG);
  if (!ready) { cv.setTextSize(1); cv.setTextColor(0xFFFF); cv.setCursor(30, 60); cv.print("no memory"); return; }
  if (T.grid > 0.01f) {
    uint16_t gc = pack(BGR + 14 * T.grid, BGG + 17 * T.grid, BGB + 26 * T.grid);
    for (int x = 0; x < ASW; x += ACW) cv.drawFastVLine(x, 0, ASH, gc);
    for (int y = 0; y < ASH; y += ACH) cv.drawFastHLine(0, y, ASW, gc);
  }
  for (int i = 0; i < ANC; i++) {
    int x = (i % ACOLS) * ACW, y = (i / ACOLS) * ACH;
    if (cTrail[i] && !cFlag[i]) { cv.fillRect(x + 1, y + 2, 2, 2, cTrail[i]); if (energy[i] > 0.6f) cv.fillRect(x, y + 1, 4, 4, cTrail[i]); }
    if (!cFlag[i]) continue;
    if (cFlag[i] == 2) cv.fillRect(x + 1, y + 1, ACW - 1, ACH - 1, cFill[i]);
    ascGlyph(x + 1, y + 1, cGlyph[i], cCol[i]);
  }
}

void ascii_begin(JsonVariantConst) {
  ascLoad();
  ascLast = millis();
}
void ascii_frame() {
  uint32_t t = millis();
  float dt = (t - ascLast) / 1000.0f; ascLast = t;
  if (dt > 0.1f) dt = 0.1f;
  int steps = dt > 0.025f ? 2 : 1;
  for (int i = 0; i < steps; i++) asc::step(dt / steps);
  asc::render(dt);
  ascDraw();
}

#ifndef ASC_HOST
// {"cmd":"ascii", ...} see the top of this file. Unknown animals are refused; numbers are clamped to the ranges the app offers.
bool asciiCmd(JsonDocument& d, JsonDocument& r) {
  using namespace asc;
  ascLoad();
  bool changed = false;
  if (d["animal"].is<const char*>()) {
    const char* want = d["animal"];
    int k = -1;
    for (int i = 0; i < NANIMALS; i++) if (!strcmp(ANIMALS[i].id, want)) k = i;
    if (k < 0) { r["ok"] = false; r["error"] = "unknown animal"; return true; }
    if (k != animal) { setAnimal(k); changed = true; }
  }
  if (d["reset"] | false) { T = ANIMALS[animal].def; ncr = 0; populate(true); restyle(); changed = true; }
  struct F { const char* key; float* v; float lo, hi; };
  const Animal& A = ANIMALS[animal];
  const F fields[] = {
    {"density", &T.density, 0.1f, 4}, {"speed", &T.speed, 0.1f, 3}, {"size", &T.size, 0.3f, 2.5f}, {"trail", &T.trail, 0, 4},
    {"trailFade", &T.trailFade, 0.05f, 6}, {"hue", &T.hue, -180, 180}, {"sparkle", &T.sparkle, 0, 0.5f}, {"fog", &T.fog, 0, 1},
    {"shimmer", &T.shimmer, 0, 1}, {"direction", &T.direction, 0, 360}, {"grid", &T.grid, 0, 4},
    {A.knobKey[0], &T.k[0], A.kmin[0], A.kmax[0]}, {A.knobKey[1], &T.k[1], A.kmin[1], A.kmax[1]}, {A.knobKey[2], &T.k[2], A.kmin[2], A.kmax[2]},
  };
  for (const F& f : fields) {
    if (!d[f.key].is<float>() && !d[f.key].is<int>()) continue;
    float v = clampf((float)d[f.key], f.lo, f.hi);
    if (v != *f.v) { *f.v = v; changed = true; }
  }
  if (d["corner"].is<bool>() && (bool)d["corner"] != T.corner) { T.corner = d["corner"]; changed = true; }
  restyle();
  if (changed) { populate(false); ascSave(); }
  if (d["tap"].is<JsonArray>() && d["tap"].size() >= 2) {
    float fx = clampf((float)d["tap"][0], 0, 1), fy = clampf((float)d["tap"][1], 0, 1);
    startle(fx * (ASW - 1), fy * (ASH - 1));
  }
  gotoScene("ascii");
  return true;
}
#endif
