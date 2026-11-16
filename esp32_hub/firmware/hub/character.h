// Muse character scene. The character is rendered by the real Muse pixel renderer from the muse-gadget project
// (muse_pixel.c, ported unchanged): its own body, ears, tails, eyes, blushes, outfits and expressions, drawn in code on a
// 64 x 64 pixel grid and shown at 2x. Nothing here is a stored picture.
//   {"cmd":"char","character":"kitty","coat":"rose","outfit":"crown"}   (every field optional)   {"cmd":"char"} just shows it.
//   {"cmd":"char","touch":"head","petting":false}   makes it react to a touch from the phone.
// The choice is kept in flash. Like the real Muse, the character does one of its own little gestures every few seconds.
// Included from scenes2.h before the scene table.
#pragma once

#include "muse_pixel.h"
#include "muse_character_behavior.h"

static const char* const CH_CHARS[] = {"muse", "kitty", "bunny", "bear", "panda", "robot", "chick"};
static const char* const CH_COATS[] = {"cream", "rose", "mint", "night", "sky", "sunset", "lavender", "gold", "snow", "ocean", "cherry", "forest"};
static const char* const CH_OUTFITS[] = {"none", "bow", "scarf", "crown", "glasses", "hat", "star", "flower", "headphones", "bowtie", "shades", "party", "sprout", "halo"};
#define CH_NCHARS MUSE_CHARACTER_COUNT
#define CH_NCOATS MUSE_COAT_COUNT
#define CH_NOUTFITS MUSE_ACCESSORY_COUNT

static uint8_t chChar = 0, chCoat = 0, chOut = 0;

// A touch from the phone makes the character react for a few seconds, overriding its idle gesture.
static float chReactT0 = -100, chReactDur = 0;
static muse_emotion_t chReactEmo = MUSE_EMOTION_NEUTRAL;
static bool chReactLove = false;
static bool chLoaded = false;

static int chIndex(const char* const* names, int n, const char* s) {
  for (int i = 0; i < n; i++) if (!strcmp(names[i], s)) return i;
  return -1;
}

// Which gesture the character is doing at time t: calm for ~6 s, then one of its four own gestures for ~4.5 s.
static void chPose(float t, muse_pose_t* p) {
  memset(p, 0, sizeof *p);
  p->mode = MUSE_MODE_IDLE;
  p->t = t; p->mode_t = t;
  p->companion.character = (muse_character_t)chChar;
  p->companion.coat = (muse_coat_t)chCoat;
  p->companion.accessory = (muse_accessory_t)chOut;
  p->companion.personality = MUSE_PERSONALITY_WARM;
  p->companion.intensity = 1; p->companion.speed = 1; p->companion.frequency = 1;
  p->emotion = MUSE_EMOTION_NEUTRAL; p->blend = MUSE_EMOTION_NEUTRAL;
  const float period = 10.5f, calm = 6.0f;
  float u = fmodf(t, period);
  if (t >= chReactT0 && t < chReactT0 + chReactDur) {
    p->emotion = chReactEmo;
    p->emotion_t = t - chReactT0;
    if (chReactLove) { p->happy = 1; p->affection_t = p->emotion_t; }   // the same state the real Muse uses for a pet
  } else if (t > 3 && u >= calm) {
    p->emotion = muse_character_idle((muse_character_t)chChar, (unsigned)(t / period));
    p->emotion_t = u - calm;
  }
}

// Draws the Muse into the canvas: the 64 x 64 grid blown up 2x, centred on the 160 x 128 screen.
static void chRender(float t, uint16_t* dst, int stride) {
  muse_pose_t p;
  chPose(t, &p);
  muse_pixel_render(&p);
  muse_pixel_scale(dst + 16, stride, 0, 127, 0, 127);
}

#ifndef CH_HOST
void chLoad() {
  if (chLoaded) return;
  chLoaded = true;
  uint8_t b[3];
  if (prefs.getBytes("chl", b, 3) == 3 && b[0] < CH_NCHARS && b[1] < CH_NCOATS && b[2] < CH_NOUTFITS) { chChar = b[0]; chCoat = b[1]; chOut = b[2]; }
}
#else
static void chLoad() {}
#endif

// ---------- notifications: the character reads them out ----------
// Layout (160 x 128): a speech bubble across the top with the app badge, name, title and text; the character below it on the
// left (the 64 x 64 grid at 1x) looking at it; a little callout and the time left on the right.
extern String msgApp, msgTitle, msgText;
extern uint32_t msgStartMs, msgTtlMs;
extern uint16_t appColor(const String& app);

void charMessageBegin() {
  chLoad();
  if (muse_pixel_init()) muse_pixel_set_size(64);
}

// The character's reaction: a notification surprises it, then it reads with big curious eyes; a plain message makes it
// talk, then wave hello. Everything comes from the real renderer's own expressions.
static void chMsgPose(float t, float ts, bool notif, muse_pose_t* p) {
  chPose(t, p);
  p->emotion = MUSE_EMOTION_NEUTRAL; p->emotion_t = 0; p->happy = 0;
  if (notif) {
    p->emotion = ts < 1.4f ? MUSE_EMOTION_SURPRISED : MUSE_EMOTION_CURIOUS;
    p->emotion_t = ts < 1.4f ? ts : ts - 1.4f;
  } else if (ts < 2.5f) {
    p->mode = MUSE_MODE_SPEAKING; p->mode_t = ts;
    float lv = 0.5f + 0.5f * sinf(t * 11.0f);
    p->level = lv * lv;
  } else {
    p->emotion = MUSE_EMOTION_GREETING; p->emotion_t = ts - 2.5f;
  }
}

// Returns false if the character cannot be drawn (no memory): the caller then draws the plain card instead.
bool charMessageFrame(float xoff) {
  if (!muse_pixel_init()) return false;
  uint32_t now = millis();
  float t = now / 1000.0f, ts = (now - msgStartMs) / 1000.0f;
  bool notif = msgApp.length() > 0;
  uint16_t ac = notif ? appColor(msgApp) : rgb(110, 190, 255);
  const uint16_t card = rgb(17, 22, 40), edge = rgb(40, 52, 86), muted = rgb(110, 120, 150);
  const int ox = (int)xoff;

  cv.fillScreen(0);
  // the character, 1x, bottom left
  muse_pose_t pose;
  chMsgPose(t, ts, notif, &pose);
  muse_pixel_render(&pose);
  muse_pixel_scale(cv.getBuffer() + 68 * W + 4, W, 0, 63, 0, 59);

  // speech bubble across the top, sliding in from the right, with a tail to the character's head
  cv.fillRoundRect(4 + ox, 3, W - 8, 72, 9, card);
  cv.drawRoundRect(4 + ox, 3, W - 8, 72, 9, edge);
  cv.fillTriangle(28 + ox, 73, 44 + ox, 73, 30 + ox, 82, card);
  cv.drawLine(28 + ox, 74, 30 + ox, 82, edge); cv.drawLine(44 + ox, 74, 30 + ox, 82, edge);
  cv.drawFastHLine(29 + ox, 73, 15, card);
  cv.fillRoundRect(4 + ox, 3, 5, 72, 2, ac);
  cv.setTextWrap(false);
  int y = 33;
  if (notif) {
    int bx = 24 + ox, by = 19;
    if (ts < 1.2f) cv.drawCircle(bx, by, 10 + (int)(ts * 10) % 4, ac);   // a ring pulses as it arrives
    cv.fillCircle(bx, by, 10, ac);
    String initial = msgApp.substring(0, 1); initial.toUpperCase();
    cv.setTextSize(2); cv.setTextColor(rgb(10, 12, 24)); cv.setCursor(bx - 5, by - 7); cv.print(initial);
    cv.setTextSize(1);
    cv.setTextColor(rgb(235, 240, 255)); cv.setCursor(40 + ox, 11); cv.print(msgApp.substring(0, 14));
    cv.setTextColor(muted); cv.setCursor(40 + ox, 22); cv.print(now - msgStartMs < 60000 ? "now" : "earlier");
    int bell = ts < 1.5f ? (int)(sinf(ts * 22) * 2) : 0, ex = W - 20 + ox;      // the bell rings at first
    cv.fillRoundRect(ex - 4 + bell, 11, 9, 8, 3, rgb(255, 214, 110));
    cv.fillRect(ex - 6 + bell, 18, 13, 2, rgb(255, 214, 110));
    cv.fillCircle(ex + bell, 22, 2, rgb(255, 214, 110));
  } else {
    y = 10;                                                                  // plain message: text only
  }
  String lines[5];
  if (notif && msgTitle.length()) {
    int n = wrapText(msgTitle, 22, 1, lines);
    cv.setTextColor(rgb(255, 255, 255)); if (n) { cv.setCursor(14 + ox, y); cv.print(lines[0]); }
    y += 11;
  }
  // short plain messages are shown big, like the old speech bubble; notifications and long text stay small
  int size = (!notif && msgText.length() <= 22) ? 2 : 1;
  int lh = size == 1 ? 10 : 18, cpl = 132 / (6 * size);
  int room = max(1, (72 - 8 * size - y) / lh + 1);
  String body[6];
  int n = wrapText(msgText, cpl, min(room, 5), body);
  cv.setTextSize(size); cv.setTextColor(rgb(175, 186, 215));
  if (!notif) cv.setTextColor(rgb(240, 244, 255));
  for (int i = 0; i < n; i++) { cv.setCursor(14 + ox, y + i * lh); cv.print(body[i]); }
  cv.setTextSize(1);

  // a small callout from the character, then the time left
  if (ox < 40) {
    const char* say = notif ? (ts < 1.4f ? "Ooh!" : "Psst...") : (ts < 2.5f ? "..." : "Hi!");
    int tw = strlen(say) * 6;
    int px = 84, py = 92;
    cv.fillRoundRect(px, py, tw + 14, 18, 8, ac);
    cv.fillTriangle(px, py + 11, px + 2, py + 6, px - 7, py + 16, ac);
    cv.setTextSize(1); cv.setTextColor(rgb(10, 12, 24)); cv.setCursor(px + 7, py + 5); cv.print(say);
  }
  if (msgTtlMs) {
    float left = 1.0f - min(1.0f, (float)(now - msgStartMs) / msgTtlMs);
    cv.fillRoundRect(80, 120, 72, 3, 1, rgb(30, 38, 64));
    int w = (int)(72 * left);
    if (w > 0) cv.fillRoundRect(80, 120, w, 3, 1, ac);
  }
  return true;
}

#ifndef CH_HOST
// How the character answers a touch, using the real Muse behaviour tables: each character has its own reply to a tap on
// head / cheek / hand / belly; poking too many times in a row makes it dizzy; stroking is petting.
static uint32_t chTapAt[16];
static int chTapN = 0;
static bool chTouch(const char* zoneName, bool petting) {
  static const char* const Z[] = {"head", "cheek", "hand", "belly"};
  int zi = chIndex(Z, 4, zoneName);
  if (zi < 0) return false;
  muse_touch_zone_t zone = (muse_touch_zone_t)zi;
  uint32_t now = millis();
  float t = now / 1000.0f;
  muse_emotion_t e;
  float dur = 3.6f;
  bool love = false;
  if (petting) {
    e = MUSE_EMOTION_LOVE; love = true; dur = 4.0f;
    chTapN = 0;
  } else {
    int keep = 0;                                   // taps in the last 2.5 s
    for (int i = 0; i < chTapN; i++) if (now - chTapAt[i] < 2500) chTapAt[keep++] = chTapAt[i];
    chTapN = keep;
    if (chTapN < 16) chTapAt[chTapN++] = now;
    if (chTapN >= muse_dizzy_taps(MUSE_PERSONALITY_WARM)) { e = MUSE_EMOTION_DIZZY; dur = 5.0f; chTapN = 0; }
    else {
      e = muse_tap_reply((muse_character_t)chChar, zone);
      if (e == MUSE_EMOTION_NEUTRAL) e = zone == MUSE_TOUCH_HEAD ? MUSE_EMOTION_LOVE : zone == MUSE_TOUCH_CHEEK ? MUSE_EMOTION_SHY : zone == MUSE_TOUCH_HAND ? MUSE_EMOTION_GREETING : MUSE_EMOTION_LAUGH;
      love = e == MUSE_EMOTION_LOVE;
    }
  }
  chReactEmo = e; chReactT0 = t; chReactDur = dur; chReactLove = love;
  return true;
}

// {"cmd":"char","touch":"head|cheek|hand|belly","petting":false} makes the character react; the other fields choose its look.
bool charCmd(JsonDocument& d, JsonDocument& r) {
  chLoad();
  if (d["touch"].is<const char*>()) {
    if (!chTouch(d["touch"], d["petting"] | false)) { r["ok"] = false; r["error"] = "unknown touch zone"; return true; }
    gotoScene("char");
    return true;
  }
  struct F { const char* key; const char* const* names; int n; const char* err; };
  const F fields[] = {
    {"character", CH_CHARS, CH_NCHARS, "unknown character"},
    {"coat", CH_COATS, CH_NCOATS, "unknown coat"},
    {"outfit", CH_OUTFITS, CH_NOUTFITS, "unknown outfit"},
  };
  uint8_t next[3] = {chChar, chCoat, chOut};
  for (int i = 0; i < 3; i++) {
    if (!d[fields[i].key].is<const char*>()) continue;
    int k = chIndex(fields[i].names, fields[i].n, d[fields[i].key]);
    if (k < 0) { r["ok"] = false; r["error"] = fields[i].err; return true; }
    next[i] = (uint8_t)k;
  }
  if (next[0] != chChar || next[1] != chCoat || next[2] != chOut) prefs.putBytes("chl", next, 3);
  chChar = next[0]; chCoat = next[1]; chOut = next[2];
  gotoScene("char");
  return true;
}

void char_begin(JsonVariantConst) {
  chLoad();
  muse_pixel_init();
  muse_pixel_set_size(128);
}
void char_frame() {
  cv.fillScreen(0);
  chRender(millis() / 1000.0f, cv.getBuffer(), W);
}
#endif
