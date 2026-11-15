import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// RGBA -> RGB565, little-endian (what the ESP32 canvas expects).
Uint8List rgbaToRgb565(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 2);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 2) {
    final v = ((rgba[i] & 0xF8) << 8) | ((rgba[i + 1] & 0xFC) << 3) | (rgba[i + 2] >> 3);
    out[o] = v & 0xFF;
    out[o + 1] = v >> 8;
  }
  return out;
}

/// RGBA -> 8-bit colour (3 bits red, 3 green, 2 blue) used for animation frames.
Uint8List rgbaToRgb332(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 4);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o++) {
    out[o] = (rgba[i] & 0xE0) | ((rgba[i + 1] & 0xE0) >> 3) | (rgba[i + 2] >> 6);
  }
  return out;
}

/// RGB332 -> RGBA (for thumbnails of frames that were already reduced).
Uint8List rgb332ToRgba(Uint8List p) {
  final out = Uint8List(p.length * 4);
  for (var i = 0; i < p.length; i++) {
    final v = p[i];
    out[i * 4] = (v & 0xE0) | ((v >> 3) & 0x1C) | ((v >> 6) & 0x03);
    out[i * 4 + 1] = ((v << 3) & 0xE0) | ((v) & 0x1C) | ((v >> 3) & 0x03);
    out[i * 4 + 2] = ((v << 6) & 0xC0) | ((v << 4) & 0x30) | ((v << 2) & 0x0C) | (v & 0x03);
    out[i * 4 + 3] = 255;
  }
  return out;
}

/// The part of an [iw] x [ih] image that fills [w] x [h] without distortion. [pan] 0..1 chooses which part when the image is
/// wider or taller than the target (0.5 = centre). [fit] true returns the whole image (the target is then letter-boxed).
Rect coverRect(int iw, int ih, int w, int h, {double pan = 0.5}) {
  final target = w / h, ratio = iw / ih;
  var sw = iw.toDouble(), sh = ih.toDouble();
  if (ratio > target) {
    sw = sh * target;
  } else {
    sh = sw / target;
  }
  return Rect.fromLTWH((iw - sw) * pan.clamp(0.0, 1.0), (ih - sh) * pan.clamp(0.0, 1.0), sw, sh);
}

/// Scales [img] to exactly [w] x [h]. Fill crops to the target shape ([pan] picks the part); fit keeps the whole picture on a black background.
Future<({Uint8List rgba, Uint8List png})> renderImage(ui.Image img, int w, int h, {bool fit = false, double pan = 0.5}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF000000));
  final paint = Paint()..filterQuality = FilterQuality.medium;
  if (fit) {
    final k = (w / img.width) < (h / img.height) ? w / img.width : h / img.height;
    final dw = img.width * k, dh = img.height * k;
    c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh), paint);
  } else {
    c.drawImageRect(img, coverRect(img.width, img.height, w, h, pan: pan), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), paint);
  }
  final out = await rec.endRecording().toImage(w, h);
  final rgba = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final png = (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  out.dispose();
  return (rgba: rgba, png: png);
}

/// Frames the board can hold: 80x64 at one byte per pixel.
const animFrameBytes = 80 * 64;
const animMaxFrames = 7;

/// Rough RAM the board needs for [frames] animation frames, in bytes (the frames themselves, no overhead).
int animMemory(int frames) => frames * animFrameBytes;

/// Picks [keep] frames spread evenly over [total] (always including the first).
List<int> evenlySpaced(int total, int keep) {
  if (total <= keep) return [for (var i = 0; i < total; i++) i];
  return [for (var k = 0; k < keep; k++) (k * total / keep).floor()];
}

/// The play order for the loop mode: forward, or forward then back without repeating the end frames (ping-pong).
List<int> loopOrder(int n, {required bool pingPong}) {
  if (!pingPong || n < 3) return [for (var i = 0; i < n; i++) i];
  return [for (var i = 0; i < n; i++) i, for (var i = n - 2; i > 0; i--) i];
}
