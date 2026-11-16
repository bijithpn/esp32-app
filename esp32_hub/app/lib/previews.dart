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
      case 'eyes':
        return FaceScreen(mood: mood == 'auto' ? 'normal' : mood);
      case 'char':
        return const CharacterPreview();
      case 'ascii':
        return const AsciiPreview();
      case 'buddy':
        return const FaceScreen(mood: 'happy', talking: true);
      case 'nowplaying':
        return const MusicScreen();
      case 'bars':
        return const BarsScreen();
      case 'weather':
        return const WeatherScreen();
      case 'message':
        return const MuseNotifPreview();
      case 'plasma':
        return Live(paint: _plasma);
      case 'stars':
        return Live(paint: _stars);
      case 'matrix':
        return Live(paint: _matrix);
      case 'life':
        return Live(paint: _life);
      case 'mandel':
        return Live(paint: _mandel);
      case 'bounce':
        return Live(paint: _bounce);
      case 'clock':
        return Live(paint: _clock);
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

void _plasma(Canvas c, Size s, double t) {
  _bg(c, s);
  const nx = 32, ny = 26;
  final w = s.width / nx, h = s.height / ny;
  final p = Paint();
  for (var y = 0; y < ny; y++) {
    for (var x = 0; x < nx; x++) {
      final v = math.sin(x * 0.35 + t * 0.9) + math.sin(y * 0.3 + t * 0.7) + math.sin((x + y) * 0.2 + t * 0.5);
      p.color = HSVColor.fromAHSV(1, ((v + 3) / 6 * 300 + t * 20) % 360, 0.75, 0.85).toColor();
      c.drawRect(Rect.fromLTWH(x * w, y * h, w + 0.5, h + 0.5), p);
    }
  }
}

void _stars(Canvas c, Size s, double t) {
  _bg(c, s, const Color(0xFF03040C));
  final p = Paint();
  for (var i = 0; i < 70; i++) {
    final a = i * 2.399, sp = 0.25 + (i % 7) * 0.09;
    final z = ((t * sp + i * 0.137) % 1.0);
    final r = z * z * s.width * 0.75;
    final o = Offset(s.width / 2 + math.cos(a) * r, s.height / 2 + math.sin(a) * r * 0.8);
    p.color = Colors.white.withValues(alpha: (z * 1.3).clamp(0.0, 1.0));
    c.drawCircle(o, 0.4 + z * 1.6, p);
  }
}

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

void _life(Canvas c, Size s, double t) {
  _bg(c, s);
  const nx = 40, ny = 32;
  final w = s.width / nx, h = s.height / ny;
  final gen = (t * 2.5).floor();
  final p = Paint()..color = const Color(0xFF5EE0C4);
  for (var y = 0; y < ny; y++) {
    for (var x = 0; x < nx; x++) {
      final hsh = ((x * 73856093) ^ (y * 19349663) ^ (gen * 83492791)) & 0xFFFF;
      if (hsh % 100 < 26) c.drawRect(Rect.fromLTWH(x * w + 0.5, y * h + 0.5, w - 1, h - 1), p);
    }
  }
}

List<int>? _mandelCache;
void _mandel(Canvas c, Size s, double t) {
  const nx = 48, ny = 38;
  _mandelCache ??= [
    for (var y = 0; y < ny; y++)
      for (var x = 0; x < nx; x++) _mandelIter(-2.2 + x * 3.2 / nx, -1.2 + y * 2.4 / ny),
  ];
  _bg(c, s);
  final w = s.width / nx, h = s.height / ny;
  final p = Paint();
  for (var y = 0; y < ny; y++) {
    for (var x = 0; x < nx; x++) {
      final it = _mandelCache![y * nx + x];
      if (it >= 24) continue;
      p.color = HSVColor.fromAHSV(1, (it * 14 + t * 30) % 360, 0.8, 0.5 + it / 48).toColor();
      c.drawRect(Rect.fromLTWH(x * w, y * h, w + 0.5, h + 0.5), p);
    }
  }
}

int _mandelIter(double cr, double ci) {
  var zr = 0.0, zi = 0.0, i = 0;
  while (i < 24 && zr * zr + zi * zi < 4) {
    final n = zr * zr - zi * zi + cr;
    zi = 2 * zr * zi + ci;
    zr = n;
    i++;
  }
  return i;
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

void _clock(Canvas c, Size s, double t) {
  _bg(c, s);
  final u = s.width / 160;
  final o = Offset(s.width / 2, s.height / 2);
  final r = 52 * u;
  c.drawCircle(o, r, Paint()..color = const Color(0xFF10141F));
  c.drawCircle(o, r, Paint()..color = const Color(0xFF3C4766)..style = PaintingStyle.stroke..strokeWidth = 2 * u);
  for (var i = 0; i < 12; i++) {
    final a = i * math.pi / 6;
    c.drawLine(o + Offset(math.sin(a), -math.cos(a)) * (r - 6 * u), o + Offset(math.sin(a), -math.cos(a)) * (r - 1.5 * u), Paint()..color = HubColors.muted..strokeWidth = 1.5 * u);
  }
  final n = DateTime.now();
  void hand(double a, double len, double w, Color col) => c.drawLine(o, o + Offset(math.sin(a), -math.cos(a)) * len, Paint()..color = col..strokeWidth = w..strokeCap = StrokeCap.round);
  hand((n.hour % 12 + n.minute / 60) * math.pi / 6, r * 0.5, 3 * u, Colors.white);
  hand((n.minute + n.second / 60) * math.pi / 30, r * 0.78, 2.2 * u, Colors.white);
  hand((n.second) * math.pi / 30, r * 0.85, 1.2 * u, const Color(0xFFFF6E6E));
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
