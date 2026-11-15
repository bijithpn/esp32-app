// "Now playing": generated album art (a sleeve in a colour taken from the song, with a spinning record),
// live equaliser, scrolling title, progress bar. The phone sends title / artist / position; the board
// draws everything else. Included from scenes2.h.
#pragma once

String npTitle = "", npArtist = "";
bool npHas = false;
uint32_t npDur = 0, npPos = 0, npSince = 0, npF = 0, npPauseAt = 0; bool npPlaying = false;
int npPrev = -1;                 // scene to return to when the music stops
float npBar[8] = {0};
float npHue = 200;

void npSet(const String& title, const String& artist, uint32_t dur, uint32_t pos, bool playing) {
  String t = asciify(title), a = asciify(artist);
  if (t != npTitle || a != npArtist) {
    uint32_t h = 5381; String k = t + "|" + a;
    for (size_t i = 0; i < k.length(); i++) h = h * 33 + (uint8_t)k[i];
    npHue = (float)(h % 360);
  }
  npTitle = t; npArtist = a; npDur = dur; npPos = pos; npPlaying = playing; npSince = millis();
  npHas = t.length() > 0;
  npPauseAt = playing ? 0 : millis();
}

void np_begin(JsonVariantConst) { npF = 0; }

void np_frame() {
  uint32_t now = millis(); npF++;
  cv.fillScreen(rgb(8, 9, 16));
  if (!npHas) {                                   // nothing playing yet: friendly idle screen
    int cx = W / 2, cy = 48;
    uint16_t c = hsv(200 + (npF % 120), 0.5f, 1.0f);
    float bob = sinf(npF * 0.12f) * 3;
    cv.fillCircle(cx - 8, cy + 14 + (int)bob, 7, c); cv.fillCircle(cx + 14, cy + 8 + (int)bob, 7, c);
    cv.fillRect(cx - 3, cy - 12 + (int)bob, 3, 27, c); cv.fillRect(cx + 19, cy - 18 + (int)bob, 3, 27, c);
    cv.fillTriangle(cx - 3, cy - 12 + (int)bob, cx + 22, cy - 18 + (int)bob, cx + 22, cy - 11 + (int)bob, c);
    cv.setTextSize(1); cv.setTextWrap(false);
    cv.setTextColor(rgb(235, 240, 255)); cv.setCursor(38, 88); cv.print("Play a song on");
    cv.setTextColor(rgb(130, 140, 175)); cv.setCursor(14, 100); cv.print("your phone and it will");
    cv.setCursor(53, 110); cv.print("show here");
    return;
  }
  uint32_t pos = npPlaying ? npPos + (now - npSince) / 1000 : npPos;
  if (npDur && pos > npDur) pos = npDur;
  uint16_t c1 = hsv(npHue, 0.75f, 1.0f), c2 = hsv(npHue + 40, 0.8f, 0.8f), glow = hsv(npHue, 0.7f, 0.16f);
  // soft glow behind the art
  cv.fillRoundRect(2, 2, W - 4, 58, 10, glow);

  // --- record peeking out of the sleeve ---
  int vx = 64, vy = 32, vr = 25;
  cv.fillCircle(vx, vy, vr, rgb(14, 14, 20));
  cv.drawCircle(vx, vy, vr, rgb(48, 48, 64));
  cv.drawCircle(vx, vy, vr - 5, rgb(28, 28, 38)); cv.drawCircle(vx, vy, vr - 9, rgb(28, 28, 38)); cv.drawCircle(vx, vy, vr - 13, rgb(28, 28, 38));
  float ang = npPlaying ? npF * 0.16f : 0.6f;
  for (int k = 0; k < 2; k++) {                    // two sheen arcs, they spin with the record
    float a = ang + k * 3.14159f;
    for (int r = 11; r < vr - 2; r++) {
      float spread = 0.32f;
      cv.drawPixel(vx + (int)(cosf(a) * r), vy + (int)(sinf(a) * r), rgb(70, 72, 96));
      cv.drawPixel(vx + (int)(cosf(a + spread) * r), vy + (int)(sinf(a + spread) * r), rgb(44, 46, 64));
    }
  }
  cv.fillCircle(vx, vy, 9, c1);
  cv.fillCircle(vx + (int)(cosf(ang) * 5), vy + (int)(sinf(ang) * 5), 1, rgb(8, 9, 16));
  cv.fillCircle(vx, vy, 2, rgb(8, 9, 16));

  // --- sleeve: vertical gradient in the song colour, big initial ---
  int sx = 8, sy = 8, sw = 46, sh = 46;
  for (int y = 0; y < sh; y++) {
    float k = (float)y / sh;
    cv.drawFastHLine(sx, sy + y, sw, hsv(npHue + k * 50, 0.78f, 1.0f - k * 0.38f));
  }
  cv.drawRoundRect(sx - 1, sy - 1, sw + 2, sh + 2, 3, rgb(8, 9, 16));
  cv.drawRect(sx, sy, sw, sh, rgb(255, 255, 255) & 0x7BEF);
  String ini = npTitle.substring(0, 1); ini.toUpperCase();
  cv.setTextSize(3); cv.setTextColor(rgb(255, 255, 255)); cv.setCursor(sx + sw / 2 - 9, sy + sh / 2 - 11); cv.print(ini);
  if (!npPlaying) {                                // pause glyph over the sleeve
    cv.fillRoundRect(sx + 14, sy + 14, 7, 18, 2, rgb(255, 255, 255)); cv.fillRoundRect(sx + 26, sy + 14, 7, 18, 2, rgb(255, 255, 255));
  }

  // --- equaliser ---
  for (int i = 0; i < 8; i++) {
    float target = npPlaying ? 0.22f + 0.78f * fabsf(sinf(npF * (0.11f + i * 0.037f) + i * 1.7f) * cosf(npF * 0.05f + i)) : 0.06f;
    npBar[i] += (target - npBar[i]) * 0.35f;
    int bh = (int)(npBar[i] * 44), bx = 100 + i * 7;
    cv.fillRoundRect(bx, 54 - bh, 5, max(2, bh), 2, hsv(npHue + i * 12, 0.8f, 1.0f));
  }

  // --- text ---
  cv.setTextSize(1); cv.setTextWrap(false);
  int pulse = npPlaying ? (int)((sinf(now * 0.008f) + 1) * 1.2f) : 0;
  cv.fillCircle(8, 69, 2 + pulse, npPlaying ? c1 : rgb(110, 110, 130));
  cv.setTextColor(npPlaying ? c1 : rgb(130, 135, 160)); cv.setCursor(16, 65); cv.print(npPlaying ? "NOW PLAYING" : "PAUSED");
  int tw = npTitle.length() * 12;
  cv.setTextSize(2); cv.setTextColor(rgb(255, 255, 255));
  if (tw > W - 12) {
    int period = tw + 40, x = 6 - (int)((npF * 2) % period);
    cv.setCursor(x, 76); cv.print(npTitle);
    cv.setCursor(x + period, 76); cv.print(npTitle);
  } else { cv.setCursor(6, 76); cv.print(npTitle); }
  cv.fillRect(0, 76, 4, 16, rgb(8, 9, 16));        // keeps the marquee from touching the left edge
  cv.setTextSize(1); cv.setTextColor(hsv(npHue, 0.35f, 1.0f)); cv.setCursor(6, 95); cv.print(npArtist.substring(0, 25));
  // progress
  int px = 6, pw = W - 12, py = 109;
  cv.fillRoundRect(px, py, pw, 4, 2, rgb(34, 38, 58));
  if (npDur) {
    int fw = max(4, (int)((float)pw * pos / npDur));
    cv.fillRoundRect(px, py, fw, 4, 2, c1);
    cv.fillCircle(px + fw, py + 2, 3, rgb(255, 255, 255));
  }
  cv.setTextColor(rgb(120, 128, 160));
  cv.setCursor(6, 117); cv.printf("%u:%02u", (unsigned)(pos / 60), (unsigned)(pos % 60));
  if (npDur) { cv.setCursor(W - 6 - 6 * 5, 117); cv.printf("%u:%02u", (unsigned)(npDur / 60), (unsigned)(npDur % 60)); }
}
