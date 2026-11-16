import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core/catalog.dart';
import 'features/ascii_animals.dart';
import 'features/character.dart';
import 'theme.dart';

/// App-side illustration of a scene at the display's 160x128 proportions.
/// These are drawn from shared scene colours and motion, NOT a live framebuffer: the Hub does not stream its screen, so the
/// preview shows what the scene looks like, and the real state (current scene, mood, timer) comes from the Hub's own data.
class ScenePreview extends StatelessWidget {
  const ScenePreview({super.key, required this.id, this.mood = 'normal'});
  final String id;
  final String mood;

  @override
  Widget build(BuildContext context) {
    switch (id) {
      case 'char':
        return const CharacterPreview();
      case 'ascii':
        return const AsciiPreview();
      case 'nowplaying':
        return const MusicScreen();
      case 'weather':
        return const WeatherScreen();
      case 'message':
        return const MuseNotifPreview();
      case 'matrix':
        return Live(paint: _matrix);
      case 'bounce':
        return Live(paint: _bounce);
      case 'name':
        return Live(paint: _name);
      case 'pet':
        return Live(paint: _pet);
      case 'pomo':
        return Live(paint: _pomo);
      case 'ping':
        return Live(paint: _ping);
      case 'canvas':
        return Live(paint: _canvas);
      case 'anim':
        return Live(paint: _anim);
      case 'pair':
      case 'info':
        return Live(paint: _qr);
      default:
        return GradientScreen(icon: sceneInfo(id).icon, a: const Color(0xFF2A3350), b: const Color(0xFF10141F));
    }
  }
}

void _bg(Canvas c, Size s, [Color col = HubColors.screen]) => c.drawRect(Offset.zero & s, Paint()..color = col);

void _matrix(Canvas c, Size s, double t) {
  _bg(c, s, const Color(0xFF030A05));
  final u = s.width / 160;
  for (var i = 0; i < 20; i++) {
    final x = (4 + i * 8) * u;
    final head = ((t * (18 + (i * 7) % 22) + i * 31) % 190) - 20;
    for (var k = 0; k < 9; k++) {
      final y = (head - k * 9) * u;
      final a = (1 - k / 9).clamp(0.0, 1.0);
      c.drawRect(Rect.fromLTWH(x, y, 4 * u, 6 * u), Paint()..color = (k == 0 ? const Color(0xFFD7FFE0) : const Color(0xFF2CD65B)).withValues(alpha: a * 0.9));
    }
  }
}

void _bounce(Canvas c, Size s, double t) {
  _bg(c, s);
  final u = s.width / 160;
  final bw = 56 * u, bh = 26 * u;
  double tri(double v, double max) {
    final m = v % (2 * max);
    return m < max ? m : 2 * max - m;
  }
  final x = tri(t * 38 * u, s.width - bw), y = tri(t * 27 * u, s.height - bh);
  final col = HSVColor.fromAHSV(1, ((x / 40).floor() * 70 + (y / 30).floor() * 50) % 360.0, 0.7, 1).toColor();
  c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, bw, bh), Radius.circular(6 * u)), Paint()..color = col);
  _paintText(c, 'HUB', Offset(x + bw / 2, y + 5 * u), 15 * u, HubColors.onPrimary, center: true);
}

void _name(Canvas c, Size s, double t) {
  _bg(c, s);
  final u = s.width / 160;
  const text = 'HELLO';
  for (var i = 0; i < text.length; i++) {
    final y = s.height / 2 - 14 * u + math.sin(t * 4 + i * 0.8) * 10 * u;
    _paintText(c, text[i], Offset(24 * u + i * 28 * u, y), 26 * u, HSVColor.fromAHSV(1, (i * 60 + t * 60) % 360, 0.65, 1).toColor(), center: true);
  }
}

void _pet(Canvas c, Size s, double t) {
  _bg(c, s, const Color(0xFF14110F));
  final u = s.width / 160;
  final o = Offset(s.width / 2, s.height * 0.58 + math.sin(t * 2) * 1.5 * u);
  final fur = Paint()..color = const Color(0xFFE9A55B);
  c.drawOval(Rect.fromCenter(center: o + Offset(0, 14 * u), width: 70 * u, height: 40 * u), fur);
  c.drawCircle(o - Offset(0, 10 * u), 22 * u, fur);
  for (final k in [-1, 1]) {
    c.drawPath(Path()..moveTo(o.dx + k * 8 * u, o.dy - 28 * u)..lineTo(o.dx + k * 22 * u, o.dy - 46 * u)..lineTo(o.dx + k * 24 * u, o.dy - 20 * u)..close(), fur);
  }
  final blink = (t % 3.2) > 3.05;
  for (final k in [-1, 1]) {
    if (blink) {
      c.drawLine(o + Offset(k * 9 * u - 3 * u, -12 * u), o + Offset(k * 9 * u + 3 * u, -12 * u), Paint()..color = Colors.black..strokeWidth = 1.5 * u);
    } else {
      c.drawCircle(o + Offset(k * 9 * u, -12 * u), 2.6 * u, Paint()..color = Colors.black);
    }
  }
  c.drawCircle(o + Offset(0, -5 * u), 1.8 * u, Paint()..color = const Color(0xFFE77D7D));
  c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(6 * u, 6 * u, 62 * u, 6 * u), Radius.circular(3 * u)), Paint()..color = const Color(0xFF50DC78));
}

void _pomo(Canvas c, Size s, double t) {
  _bg(c, s, const Color(0xFF120A0A));
  final u = s.width / 160;
  final o = Offset(s.width / 2, s.height / 2);
  final r = 42 * u;
  c.drawCircle(o, r, Paint()..color = const Color(0xFF2A1515)..style = PaintingStyle.stroke..strokeWidth = 8 * u);
  c.drawArc(Rect.fromCircle(center: o, radius: r), -math.pi / 2, 2 * math.pi * ((t * 0.04) % 1), false, Paint()..color = const Color(0xFFFF6A5A)..style = PaintingStyle.stroke..strokeWidth = 8 * u..strokeCap = StrokeCap.round);
  _paintText(c, '24:10', o - Offset(0, 9 * u), 19 * u, Colors.white, center: true);
}

void _ping(Canvas c, Size s, double t) {
  _bg(c, s, const Color(0xFF050E0A));
  final u = s.width / 160;
  final path = Path();
  for (var i = 0; i <= 40; i++) {
    final x = 8 * u + i * 3.6 * u;
    final y = s.height * 0.6 - (math.sin(i * 0.5 + t * 3) * 0.5 + 0.5) * 38 * u - (i % 11 == 0 ? 14 * u : 0);
    i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
  }
  c.drawPath(path, Paint()..color = const Color(0xFF5CE0A0)..style = PaintingStyle.stroke..strokeWidth = 2 * u);
  _paintText(c, '23 ms', Offset(8 * u, 8 * u), 14 * u, Colors.white);
}

void _canvas(Canvas c, Size s, double t) {
  _bg(c, s);
  const nx = 40, ny = 32;
  final w = s.width / nx, h = s.height / ny;
  final p = Paint();
  for (var y = 0; y < ny; y++) {
    for (var x = 0; x < nx; x++) {
      final d = (x - 20).abs() + (y - 16).abs();
      if (d < 14 && (d + (t * 3).floor()) % 3 != 0) {
        p.color = HSVColor.fromAHSV(1, (d * 24.0) % 360, 0.7, 1).toColor();
        c.drawRect(Rect.fromLTWH(x * w, y * h, w, h), p);
      }
    }
  }
}

void _anim(Canvas c, Size s, double t) {
  _bg(c, s);
  final f = (t * 4).floor() % 7;
  final u = s.width / 160;
  c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: s.center(Offset.zero), width: 80 * u * 1.4, height: 64 * u * 1.4), Radius.circular(6 * u)), Paint()..color = const Color(0xFF1B2030));
  c.drawCircle(s.center(Offset.zero) + Offset(math.cos(f * 0.9) * 26 * u, math.sin(f * 0.9) * 16 * u), 10 * u, Paint()..color = HSVColor.fromAHSV(1, f * 50.0, 0.7, 1).toColor());
  for (var i = 0; i < 7; i++) {
    c.drawCircle(Offset(s.width / 2 - 24 * u + i * 8 * u, s.height - 10 * u), 2 * u, Paint()..color = i == f ? Colors.white : HubColors.line);
  }
}

void _qr(Canvas c, Size s, double t) {
  _bg(c, s, const Color(0xFF060812));
  final u = s.width / 160;
  final box = 90 * u;
  c.drawRect(Rect.fromLTWH(6 * u, (s.height - box) / 2, box, box), Paint()..color = Colors.white);
  final p = Paint()..color = Colors.black;
  const n = 21;
  final cell = (box - 12 * u) / n;
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final finder = (x < 7 && y < 7) || (x > 13 && y < 7) || (x < 7 && y > 13);
      final on = finder ? (x % 6 == 0 || y % 6 == 0 || (x % 6 > 1 && x % 6 < 5 && y % 6 > 1 && y % 6 < 5 && x < 7 && y < 7)) : (((x * 7 + y * 13) ^ (x * y)) % 3 == 0);
      if (on) c.drawRect(Rect.fromLTWH(6 * u + 6 * u + x * cell, (s.height - box) / 2 + 6 * u + y * cell, cell, cell), p);
    }
  }
  _paintText(c, 'PAIR', Offset(104 * u, 30 * u), 11 * u, HubColors.accent);
  _paintText(c, 'Scan to', Offset(104 * u, 58 * u), 9 * u, Colors.white);
  _paintText(c, 'join', Offset(104 * u, 70 * u), 9 * u, Colors.white);
}

void _paintText(Canvas c, String s, Offset at, double size, Color col, {bool center = false}) {
  final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(color: col, fontSize: size, fontWeight: FontWeight.w700, height: 1)), textDirection: TextDirection.ltr)..layout();
  tp.paint(c, center ? at - Offset(tp.width / 2, 0) : at);
}
