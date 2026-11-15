// Expressive robot face, shared by the "Robot Eyes" scene and the "AI Buddy" scene.
// 12 moods. Every number (eye size, lids, cheeks, mouth, colour) glides to its new value, so a change of
// mood is a smooth animation instead of a jump. Included from scenes.h (after hsv() and rgb()).
#pragma once

// ---- text helpers (the display font is ASCII only) ----
// Turns UTF-8 from phones into plain ASCII: curly quotes, dashes, bullets are mapped, emoji and other symbols dropped.
String asciify(const String& in) {
  String out; out.reserve(in.length());
  const uint8_t* p = (const uint8_t*)in.c_str();
  while (*p) {
    uint8_t c = *p;
    if (c < 0x80) { out += (c == '\n' || c == '\r' || c == '\t') ? ' ' : (char)(c < 32 ? ' ' : c); p++; continue; }
    int n = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
    uint32_t cp = (n == 4) ? (c & 7) : (n == 3) ? (c & 15) : (n == 2) ? (c & 31) : 0;
    int k = 1;
    for (; k < n && (p[k] & 0xC0) == 0x80; k++) cp = (cp << 6) | (p[k] & 63);
    p += k;
    if (cp == 0x2018 || cp == 0x2019) out += '\'';
    else if (cp == 0x201C || cp == 0x201D) out += '"';
    else if (cp == 0x2013 || cp == 0x2014) out += '-';
    else if (cp == 0x2026) out += "...";
    else if (cp == 0x2022 || cp == 0xB7) out += '*';
    else if (cp >= 0xC0 && cp <= 0xC5) out += 'A'; else if (cp >= 0xE0 && cp <= 0xE5) out += 'a';
    else if (cp >= 0xC8 && cp <= 0xCB) out += 'E'; else if (cp >= 0xE8 && cp <= 0xEB) out += 'e';
    else if (cp >= 0xD2 && cp <= 0xD6) out += 'O'; else if (cp >= 0xF2 && cp <= 0xF6) out += 'o';
    else if (cp >= 0xD9 && cp <= 0xDC) out += 'U'; else if (cp >= 0xF9 && cp <= 0xFC) out += 'u';
    // everything else (emoji, symbols, other scripts) is dropped
  }
  // collapse runs of spaces
  String r; r.reserve(out.length()); bool sp = true;
  for (size_t i = 0; i < out.length(); i++) { char c = out[i]; if (c == ' ') { if (sp) continue; sp = true; } else sp = false; r += c; }
  r.trim();
  return r;
}

// Word-wraps text into at most maxLines lines of maxChars. Returns the number of lines; adds ".." if text was cut.
int wrapText(const String& s, int maxChars, int maxLines, String* out) {
  int n = 0, len = s.length(), i = 0;
  String line;
  bool cut = false;
  while (i < len) {
    int j = i; while (j < len && s[j] != ' ') j++;
    String w = s.substring(i, j);
    i = j + 1;
    while ((int)w.length() > maxChars) {                   // a word longer than a line: hard-break it
      if (line.length()) { if (n >= maxLines) { cut = true; break; } out[n++] = line; line = ""; }
      if (n >= maxLines) { cut = true; break; }
      out[n++] = w.substring(0, maxChars); w = w.substring(maxChars);
    }
    if (cut) break;
    if (!w.length()) continue;
    if ((int)(line.length() + (line.length() ? 1 : 0) + w.length()) <= maxChars) { if (line.length()) line += ' '; line += w; }
    else {
      if (n >= maxLines) { cut = true; break; }
      out[n++] = line; line = w;
    }
  }
  if (!cut && line.length()) { if (n < maxLines) out[n++] = line; else cut = true; }
  if (cut && n > 0) { String& l = out[n - 1]; if ((int)l.length() > maxChars - 2) l = l.substring(0, maxChars - 2); l += ".."; }
  return n;
}

enum Mood { M_NORMAL, M_HAPPY, M_SLEEPY, M_ANGRY, M_SAD, M_LOVE, M_SURPRISED, M_WINK, M_THINK, M_EXCITED, M_DIZZY, M_SLEEP, M_COUNT };
const char* const MOOD_NAMES[M_COUNT] = {"normal", "happy", "sleepy", "angry", "sad", "love", "surprised", "wink", "thinking", "excited", "dizzy", "sleeping"};

struct FaceT { float w, h, tIn, tOut, cheek, mouth, mOpen; uint8_t r, g, b; };
//                w   h   lidIn lidOut cheek mouth mOpen   colour
const FaceT FT[M_COUNT] = {
  {40, 54, 0.00f, 0.00f, 0.00f,  0.40f, 0.00f,  60, 220, 255},   // normal
  {42, 46, 0.00f, 0.00f, 0.50f,  1.00f, 0.35f,  90, 245, 190},   // happy
  {42, 50, 0.52f, 0.44f, 0.00f,  0.00f, 0.10f, 150, 140, 255},   // sleepy
  {42, 50, 0.62f, 0.04f, 0.00f, -0.70f, 0.00f, 255,  90,  70},   // angry
  {38, 52, 0.00f, 0.60f, 0.00f, -0.85f, 0.00f,  90, 150, 255},   // sad
  {44, 46, 0.00f, 0.00f, 0.00f,  1.00f, 0.25f, 255, 100, 170},   // love
  {36, 64, 0.00f, 0.00f, 0.00f,  0.00f, 0.85f, 200, 245, 255},   // surprised
  {42, 52, 0.00f, 0.00f, 0.00f,  0.85f, 0.20f, 255, 200,  90},   // wink
  {40, 52, 0.28f, 0.00f, 0.00f,  0.05f, 0.00f, 190, 130, 255},   // thinking
  {44, 56, 0.00f, 0.00f, 0.20f,  1.00f, 0.60f, 255, 225,  70},   // excited
  {40, 50, 0.00f, 0.00f, 0.00f,  0.00f, 0.00f, 160, 255,  80},   // dizzy
  {42, 50, 0.00f, 0.00f, 0.00f,  0.10f, 0.00f, 150, 140, 255},   // sleeping
};

int fMood = M_NORMAL;
float fW = 40, fH = 54, fTin = 0, fTout = 0, fCheek = 0, fMouth = 0.4f, fMopen = 0, fR = 60, fG = 220, fB = 255;
static const uint16_t FACE_BG = ((4 & 0xF8) << 8) | ((6 & 0xFC) << 3) | (16 >> 3);

inline uint16_t dimC(float r, float g, float b, float k) { return rgb((int)(r * k), (int)(g * k), (int)(b * k)); }

int moodFromName(const char* n) {
  for (int i = 0; i < M_COUNT; i++) if (!strcmp(n, MOOD_NAMES[i])) return i;
  if (!strcmp(n, "sleep")) return M_SLEEP;
  if (!strcmp(n, "think")) return M_THINK;
  return -1;
}

void faceSet(int m) { if (m >= 0 && m < M_COUNT) fMood = m; }
void faceSnap() {   // jump straight to the current mood (no glide)
  const FaceT& t = FT[fMood];
  fW = t.w; fH = t.h; fTin = t.tIn; fTout = t.tOut; fCheek = t.cheek; fMouth = t.mouth; fMopen = t.mOpen; fR = t.r; fG = t.g; fB = t.b;
}
void faceStep() {
  const FaceT& t = FT[fMood];
  const float k = 0.2f;
  fW += (t.w - fW) * k; fH += (t.h - fH) * k; fTin += (t.tIn - fTin) * k; fTout += (t.tOut - fTout) * k;
  fCheek += (t.cheek - fCheek) * k; fMouth += (t.mouth - fMouth) * k; fMopen += (t.mOpen - fMopen) * k;
  fR += (t.r - fR) * k; fG += (t.g - fG) * k; fB += (t.b - fB) * k;
}

// ---- small shapes ----
void fHeart(int x, int y, int s, uint16_t c) {
  cv.fillCircle(x - s / 2, y, s / 2 + 1, c); cv.fillCircle(x + s / 2, y, s / 2 + 1, c);
  cv.fillTriangle(x - s - 1, y + 1, x + s + 1, y + 1, x, y + s + 3, c);
}
void fSpark(int x, int y, int r, uint16_t c) {
  cv.drawFastHLine(x - r, y, 2 * r + 1, c); cv.drawFastVLine(x, y - r, 2 * r + 1, c);
  if (r > 3) { cv.drawPixel(x - 1, y - 1, c); cv.drawPixel(x + 1, y - 1, c); cv.drawPixel(x - 1, y + 1, c); cv.drawPixel(x + 1, y + 1, c); }
}
void fArcC(int x, int y, int w, int up, int th, uint16_t c) {
  int hh = max(3, w / 4);
  for (int dx = -w / 2; dx <= w / 2; dx++) {
    float u = (float)dx / (w / 2.0f);
    int dy = (int)(-up * (1 - u * u) * hh);
    cv.fillRect(x + dx, y + dy, 1, th, c);
  }
}

// ---- mouth ----
void faceMouth(int cx, int my, float s, float open, uint16_t lip) {
  float m = fMouth;
  int mw = (int)((13 + 8 * fabsf(m) + 6 * open) * s);
  if (mw < 4) mw = 4;
  float bend = m * 7 * s;
  for (int dx = -mw; dx <= mw; dx++) {
    float u = (float)dx / mw, sh = 1 - u * u;
    int yA = my + (int)(bend * sh);
    if (open > 0.04f) {
      int hh = (int)(open * 14 * s * sqrtf(sh));
      if (hh > 0) cv.drawFastVLine(cx + dx, yA, hh, rgb(60, 10, 30));
      if (open > 0.3f && hh > 4 * s) cv.drawFastVLine(cx + dx, yA + hh - (int)(3 * s), (int)(3 * s) + 1, rgb(255, 120, 130));   // tongue
      cv.drawPixel(cx + dx, yA + hh, lip);
    }
    cv.fillRect(cx + dx, yA, 1, max(1, (int)(2 * s + 0.5f)), lip);
  }
}

// ---- the face ----
// cx,cy: centre between the eyes. s: scale (1 = full screen). open: blink factor 0..1.
// talk: -1 = use the mood's mouth, otherwise mouth opening 0..1. lx,ly: where the eyes look (-12..12).
void faceDraw(int cx, int cy, float s, float open, float talk, float lx, float ly) {
  uint32_t t = millis();
  uint16_t col = rgb((int)fR, (int)fG, (int)fB);
  uint16_t glow = dimC(fR, fG, fB, 0.17f);
  uint16_t dark = dimC(fR, fG, fB, 0.2f);
  float ew = fW * s, eh = fH * s * open;
  if (eh < 3 * s + 1) eh = 3 * s + 1;
  int gap = (int)(41 * s);
  for (int i = -1; i <= 1; i += 2) {
    int ecx = cx + i * gap + (int)(lx * s * 0.6f), ecy = cy + (int)(ly * s * 0.6f);
    int top = ecy - (int)eh / 2, bot = ecy + (int)eh / 2;
    int iw = (int)ew;
    bool closedArc = (fMood == M_SLEEP) || (fMood == M_WINK && i == 1);
    if (closedArc) {
      fArcC(ecx, ecy + (fMood == M_SLEEP ? -2 : 3) * s, iw, fMood == M_SLEEP ? -1 : 1, max(2, (int)(3 * s)), col);
    } else if (fMood == M_LOVE) {
      float pul = 1 + 0.1f * sinf(t * 0.012f);
      int hs = (int)(ew * 0.30f * pul);
      fHeart(ecx, ecy - hs / 2, hs, col);
      cv.fillCircle(ecx - hs, ecy - hs / 2 - 2, max(1, (int)(2 * s)), rgb(255, 230, 240));
    } else if (fMood == M_DIZZY) {
      int rad = iw / 2;
      cv.drawCircle(ecx, ecy, rad, glow);
      float a0 = t * 0.011f * (i < 0 ? 1 : -1);
      for (int k = 0; k < 46; k++) {
        float a = a0 + k * 0.42f, r = k * rad / 46.0f;
        cv.fillRect(ecx + (int)(cosf(a) * r), ecy + (int)(sinf(a) * r), 2, 2, col);
      }
    } else {
      int rr = (int)(min(ew, eh) * 0.34f);
      cv.fillRoundRect(ecx - iw / 2 - 3, top - 3, iw + 6, (int)eh + 6, rr + 3, glow);
      cv.fillRoundRect(ecx - iw / 2, top, iw, (int)eh, rr, col);
      if (eh > 14 * s) {   // iris + two highlights: this is what makes the eyes feel alive
        float pr = ew * (fMood == M_SURPRISED ? 0.17f : 0.27f);
        int ix = ecx + (int)(lx * s * 0.45f), iy = ecy + (int)(ly * s * 0.45f);
        cv.fillCircle(ix, iy, (int)pr, dark);
        cv.fillCircle(ix - (int)(pr * 0.35f), iy - (int)(pr * 0.4f), max(2, (int)(pr * 0.36f)), rgb(255, 255, 255));
        cv.fillCircle(ix + (int)(pr * 0.4f), iy + (int)(pr * 0.45f), max(1, (int)(pr * 0.16f)), rgb(220, 240, 255));
      }
      // top lid (angry / sad / sleepy / thinking): a slanted cover
      float tl = (i < 0 ? fTout : fTin) * eh, tr = (i < 0 ? fTin : fTout) * eh;
      if (tl > 0.5f || tr > 0.5f) {
        int x0 = ecx - iw / 2 - 4, x1 = ecx + iw / 2 + 4;
        cv.fillTriangle(x0, top - 5, x1, top - 5, x1, top + (int)tr, FACE_BG);
        cv.fillTriangle(x0, top - 5, x1, top + (int)tr, x0, top + (int)tl, FACE_BG);
      }
      // cheek (bottom lid pushed up): the happy "dome"
      if (fCheek > 0.02f) {
        int r = (int)(ew * 0.78f);
        cv.fillCircle(ecx, bot - (int)(fCheek * eh) + r, r, FACE_BG);
      }
    }
    // blush
    if (fMood == M_HAPPY || fMood == M_LOVE || fMood == M_EXCITED || fMood == M_WINK)
      cv.fillRoundRect(ecx - (int)(9 * s), cy + (int)(32 * s), (int)(18 * s), max(2, (int)(6 * s)), 3, rgb(150, 55, 90));
    // sad tear
    if (fMood == M_SAD && i == 1) {
      int ty = bot + ((t / 55) % 34) - 2;
      if (ty < H - 2) cv.fillCircle(ecx + (int)(ew * 0.25f), ty, max(1, (int)(2.5f * s)), rgb(110, 170, 255));
    }
  }

  float mo = talk >= 0 ? talk : fMopen;
  float saveM = fMouth;
  if (talk >= 0 && fMouth < 0.2f) fMouth = 0.3f;     // talking: keep the mouth friendly unless the mood is negative
  faceMouth(cx, cy + (int)(43 * s), s, mo, dimC(255, 130, 160, 1.0f));
  fMouth = saveM;

  // mood extras
  int fx = cx + (int)(52 * s), fy = cy - (int)(40 * s);
  switch (fMood) {
    case M_THINK: {
      int ph = (t / 300) % 4;
      for (int k = 0; k < 3; k++) if (k < ph) cv.fillCircle(cx + (int)((38 + k * 9) * s), cy - (int)((34 + k * 8) * s), max(1, (int)((2 + k) * s)), rgb(190, 130, 255));
      if (ph == 3) { cv.setTextSize(max(1, (int)(2 * s + 0.5f))); cv.setTextColor(rgb(220, 190, 255)); cv.setCursor(cx + (int)(56 * s), cy - (int)(56 * s)); cv.print("?"); }
    } break;
    case M_SLEEP: {
      for (int k = 0; k < 3; k++) {
        int ph = (int)((t / 40 + k * 28) % 84);
        int zx = fx - 4 + ph / 3, zy = cy - (int)(10 * s) - ph / 2;
        cv.setTextSize(k == 0 ? 1 : 2 - (k == 2)); cv.setTextColor(dimC(190, 180, 255, 1.0f - ph / 120.0f));
        cv.setCursor(zx, zy); cv.print("z");
      }
    } break;
    case M_EXCITED: {
      int r1 = 2 + (t / 120) % 4, r2 = 2 + ((t / 120) + 2) % 4;
      fSpark(cx - (int)(66 * s), cy - (int)(34 * s), (int)(r1 * s) + 1, rgb(255, 240, 120));
      fSpark(cx + (int)(66 * s), cy - (int)(30 * s), (int)(r2 * s) + 1, rgb(255, 240, 120));
      fSpark(cx + (int)(60 * s), cy + (int)(30 * s), (int)(r1 * s) + 1, rgb(255, 200, 90));
    } break;
    case M_LOVE: {
      for (int k = 0; k < 2; k++) {
        int ph = (int)((t / 35 + k * 40) % 80);
        fHeart(cx + (int)((k ? -48 : 48) * s), cy + (int)(10 * s) - ph / 2, max(2, (int)(4 * s)), rgb(255, 90, 150));
      }
    } break;
    case M_ANGRY: {
      int p = (t / 200) % 2;
      uint16_t c = rgb(255, 70, 50);
      cv.drawLine(fx - 4, fy - 4 + p, fx - 1, fy - 1 + p, c); cv.drawLine(fx + 4, fy - 4 + p, fx + 1, fy - 1 + p, c);
      cv.drawLine(fx - 4, fy + 4 - p, fx - 1, fy + 1 - p, c); cv.drawLine(fx + 4, fy + 4 - p, fx + 1, fy + 1 - p, c);
    } break;
    case M_SURPRISED: {
      uint16_t c = rgb(200, 245, 255);
      for (int k = -1; k <= 1; k++) cv.drawLine(cx + (int)(k * 14 * s), cy - (int)(43 * s), cx + (int)(k * 20 * s), cy - (int)(52 * s), c);
    } break;
    case M_DIZZY: {
      for (int k = 0; k < 3; k++) {
        float a = t * 0.006f + k * 2.094f;
        cv.fillCircle(cx + (int)(cosf(a) * 30 * s), cy - (int)(41 * s) + (int)(sinf(a) * 6 * s), max(1, (int)(2 * s)), rgb(255, 240, 100));
      }
    } break;
    default: break;
  }
}

// ============================ ROBOT EYES ============================
bool eyeAuto = true;
float eLx = 0, eLy = 0, eTx = 0, eTy = 0;
uint32_t eNextLook = 0, eNextMood = 0, eBlinkT = 0, eNextBlink = 0;
int eBlinkDir = 0;           // 0 idle, 1 closing, -1 opening
float eOpen = 1;
int eWake = 0;               // wake-up animation frames

void eyesSetMood(const String& m) {
  if (m == "auto") { eyeAuto = true; eNextMood = 0; return; }
  int i = moodFromName(m.c_str());
  if (i >= 0) { eyeAuto = false; faceSet(i); }
}

void eyes_begin(JsonVariantConst a) {
  if (a["mood"].is<const char*>()) eyesSetMood(a["mood"].as<String>());
  eNextLook = eNextMood = 0; eNextBlink = millis() + 1500; eBlinkDir = 0; eOpen = 0.08f; eWake = 0;
  if (eyeAuto) faceSet(M_NORMAL);
  faceSnap();
}

static const uint8_t AUTO_MOODS[] = {M_NORMAL, M_NORMAL, M_HAPPY, M_NORMAL, M_LOVE, M_THINK, M_NORMAL, M_SURPRISED, M_WINK, M_EXCITED, M_NORMAL, M_SLEEPY, M_HAPPY, M_DIZZY, M_NORMAL, M_SAD, M_ANGRY};

void eyes_frame() {
  uint32_t now = millis();
  if (eyeAuto && now > eNextMood) {
    uint8_t m = AUTO_MOODS[random(sizeof AUTO_MOODS)];
    if (fMood == M_SLEEPY && random(3) == 0) m = M_SLEEP;
    faceSet(m);
    eNextMood = now + (m == M_NORMAL ? random(3500, 7000) : random(2800, 5200));
  }
  // where to look
  if (now > eNextLook) {
    switch (fMood) {
      case M_THINK: eTx = random(4, 12); eTy = -random(5, 9); break;
      case M_SLEEPY: case M_SAD: eTx = random(-6, 7); eTy = random(3, 8); break;
      case M_SLEEP: case M_DIZZY: case M_LOVE: eTx = 0; eTy = 0; break;
      default: eTx = random(-12, 13); eTy = random(-6, 7);
    }
    eNextLook = now + random(900, 2800);
  }
  eLx += (eTx - eLx) * 0.3f; eLy += (eTy - eLy) * 0.3f;
  // blink: close fast, open a bit slower
  if (eBlinkDir == 0 && now > eNextBlink && fMood != M_SLEEP) { eBlinkDir = 1; }
  if (eBlinkDir == 1) { eOpen -= 0.34f; if (eOpen <= 0.05f) { eOpen = 0.05f; eBlinkDir = -1; } }
  else if (eBlinkDir == -1) { eOpen += 0.22f; if (eOpen >= 1) { eOpen = 1; eBlinkDir = 0; eNextBlink = now + random(1800, 5200); if (random(5) == 0) eNextBlink = now + 180; } }
  else if (eWake < 20) { eWake++; eOpen = min(1.0f, eOpen + 0.07f); }    // eyes open after the scene starts
  float baseOpen = (fMood == M_SLEEPY) ? 0.8f : 1.0f;
  float breathe = 1 + 0.025f * sinf(now * 0.004f);
  faceStep();
  cv.fillScreen(FACE_BG);
  faceDraw(W / 2, H / 2 - 8 + (int)(sinf(now * 0.003f) * 1.5f), 1.0f, min(eOpen, baseOpen) * breathe, -1, eLx, eLy);
}

// ============================ AI BUDDY ============================
// A talking face. The app (or any client) sends {"cmd":"say","text":"..","mood":"happy"}; without "mood" the
// face picks one from the words. Text is typed out in a speech bubble while the mouth moves.
#define BUDDY_MAXLINES 24
String buddyText = "Hi! I'm your buddy.";
String bLines[BUDDY_MAXLINES]; int bN = 0;
uint32_t buddyStart = 0, buddyF = 0;
int buddyMood = M_HAPPY;

int inferMood(String t) {
  t.toLowerCase();
  auto has = [&](const char* w) { return t.indexOf(w) >= 0; };
  if (has("love") || has("<3") || has("adore") || has("miss you")) return M_LOVE;
  if (has("sorry") || has("sad") || has("unfortunately") || has("can't") || has("cannot") || has("lost") || has("miss")) return M_SAD;
  if (has("angry") || has("hate") || has("error") || has("wrong") || has("fail") || has("stop")) return M_ANGRY;
  if (has("wow") || has("whoa") || has("really?!") || has("incredible") || has("amazing")) return M_SURPRISED;
  if (has("sleep") || has("tired") || has("good night") || has("goodnight") || has("yawn")) return M_SLEEPY;
  if (has("congrat") || has("yay") || has("awesome") || has("great") || has("haha") || has("lol") || has("party")) return M_EXCITED;
  if (has("hmm") || has("think") || has("maybe") || has("not sure") || t.endsWith("?")) return M_THINK;
  if (t.endsWith("!")) return M_EXCITED;
  return M_HAPPY;
}

void buddyWrap() { bN = wrapText(buddyText, 24, BUDDY_MAXLINES, bLines); }
void buddySay(const String& raw, int mood = -1) {
  buddyText = asciify(raw);
  if (buddyText.length() > 480) buddyText = buddyText.substring(0, 480);
  if (!buddyText.length()) buddyText = "...";
  buddyMood = mood >= 0 ? mood : inferMood(buddyText);
  buddyStart = millis();
  buddyWrap();
}
void buddy_begin(JsonVariantConst) { buddyF = 0; buddyStart = millis(); buddyWrap(); faceSet(buddyMood); faceSnap(); }
void buddy_frame() {
  uint32_t now = millis(); buddyF++;
  // pages of 5 lines; each page types out, then holds
  const int perPage = 5;
  int pages = max(1, (bN + perPage - 1) / perPage);
  uint32_t durs[(BUDDY_MAXLINES + perPage - 1) / perPage + 1], total = 0;
  int pageChars[(BUDDY_MAXLINES + perPage - 1) / perPage + 1];
  for (int p = 0; p < pages; p++) {
    int c = 0;
    for (int l = p * perPage; l < min(bN, (p + 1) * perPage); l++) c += bLines[l].length();
    pageChars[p] = c; durs[p] = c * 38 + 2600; total += durs[p];
  }
  uint32_t el = (now - buddyStart);
  bool firstRound = el < total;
  el %= total;
  int page = 0;
  while (page < pages - 1 && el >= durs[page]) { el -= durs[page]; page++; }
  int revealed = el / 38;
  bool talking = firstRound && revealed < pageChars[page];

  faceSet(talking || firstRound ? buddyMood : M_HAPPY);
  faceStep();
  float open = ((buddyF % 85) < 4) ? 0.1f : 1.0f;
  float mouth = talking ? (0.15f + 0.85f * fabsf(sinf(now * 0.021f)) * (0.6f + 0.4f * sinf(now * 0.0071f))) : -1;
  cv.fillScreen(FACE_BG);
  // antenna with a bulb that glows in the mood colour: this is what makes the buddy recognisable
  uint16_t col = rgb((int)fR, (int)fG, (int)fB);
  cv.drawFastVLine(W / 2, 3, 6, rgb(70, 80, 110));
  int br = 2 + (int)(1.5f * (1 + sinf(now * 0.008f)) / 2 + (talking ? 1 : 0));
  cv.fillCircle(W / 2, 3, br, col);
  faceDraw(W / 2, 31, 0.56f, open, mouth, sinf(now * 0.0017f) * 5, sinf(now * 0.0011f) * 2);
  // speech bubble
  cv.fillRoundRect(2, 66, W - 4, 60, 7, rgb(16, 22, 42));
  cv.drawRoundRect(2, 66, W - 4, 60, 7, dimC(fR, fG, fB, 0.55f));
  cv.fillTriangle(W / 2 - 5, 66, W / 2 + 5, 66, W / 2, 61, rgb(16, 22, 42));
  cv.setTextSize(1); cv.setTextWrap(false); cv.setTextColor(rgb(235, 240, 255));
  int left = talking ? revealed : 100000;
  for (int l = page * perPage, row = 0; l < min(bN, (page + 1) * perPage); l++, row++) {
    String ln = bLines[l];
    if ((int)ln.length() > left) ln = ln.substring(0, max(0, left));
    left -= bLines[l].length();
    cv.setCursor(8, 72 + row * 10); cv.print(ln);
    if (left <= 0) break;
  }
  if (pages > 1) { cv.setTextColor(rgb(100, 110, 140)); cv.setCursor(W - 30, 56); cv.printf("%d/%d", page + 1, pages); }
}
