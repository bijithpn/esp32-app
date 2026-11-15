import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Design tokens. One calm dark palette, one accent, soft surfaces, generous spacing.
class HubColors {
  static const bg = Color(0xFF080B14);
  static const surface = Color(0xFF111726);
  static const surface2 = Color(0xFF182036);
  static const line = Color(0xFF232C47);
  static const text = Color(0xFFEAF0FF);
  static const muted = Color(0xFF8793B2);
  static const accent = Color(0xFF3CDCFF);
  static const pink = Color(0xFFFF6AA2);
  static const ok = Color(0xFF50E68C);
  static const warn = Color(0xFFFFBE50);
  static const danger = Color(0xFFFF6B6B);
  static const screen = Color(0xFF040610); // the colour of the TFT background
}

ThemeData buildHubTheme() {
  const cs = ColorScheme.dark(
    primary: HubColors.accent,
    onPrimary: Color(0xFF031318),
    secondary: HubColors.pink,
    surface: HubColors.surface,
    onSurface: HubColors.text,
    error: HubColors.danger,
    surfaceContainerHigh: HubColors.surface2,
    primaryContainer: Color(0xFF0F3441),
    onPrimaryContainer: HubColors.text,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: cs, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: HubColors.bg,
    appBarTheme: const AppBarTheme(backgroundColor: HubColors.bg, elevation: 0, scrolledUnderElevation: 0, centerTitle: false),
    textTheme: base.textTheme.apply(bodyColor: HubColors.text, displayColor: HubColors.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        side: const BorderSide(color: HubColors.line),
        foregroundColor: HubColors.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: HubColors.surface2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: HubColors.accent, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: HubColors.surface2,
      contentTextStyle: const TextStyle(color: HubColors.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: const DividerThemeData(color: HubColors.line, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? HubColors.bg : HubColors.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? HubColors.accent : HubColors.surface2),
    ),
  );
}

// ------------------------------------------------------------------------------------------ widgets

/// A soft rounded surface.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color, this.onTap, this.borderColor});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: color ?? HubColors.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), border: Border.all(color: borderColor ?? HubColors.line)),
            child: child,
          ),
        ),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
        child: Row(children: [
          Expanded(child: Text(title.toUpperCase(), style: const TextStyle(color: HubColors.muted, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Small status pill: a coloured dot and a label.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.color, required this.label, this.pulse = false});
  final Color color;
  final String label;
  final bool pulse;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          pulse ? _Pulse(color: color) : Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.color});
  final Color color;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 2 + 8 * _c.value, spreadRadius: 3 * _c.value)]),
        ),
      );
}

/// The board's screen, drawn as a bezel. Everything inside is painted at the real 160x128 proportions.
class DisplayFrame extends StatelessWidget {
  const DisplayFrame({super.key, required this.child, this.radius = 18});
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFF1B2133),
          borderRadius: BorderRadius.circular(radius + 6),
          border: Border.all(color: const Color(0xFF2B3552)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 24, offset: const Offset(0, 10))],
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(radius - 4), child: AspectRatio(aspectRatio: 160 / 128, child: child)),
      );
}

/// Runs a painter against a clock (seconds) so previews animate like the real screen.
class Live extends StatefulWidget {
  const Live({super.key, required this.paint});
  final void Function(Canvas canvas, Size size, double t) paint;
  @override
  State<Live> createState() => _LiveState();
}

class _LiveState extends State<Live> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3600))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(painter: _FnPainter(widget.paint, _c.value * 3600), size: Size.infinite),
      );
}

class _FnPainter extends CustomPainter {
  _FnPainter(this.fn, this.t);
  final void Function(Canvas, Size, double) fn;
  final double t;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    fn(canvas, size, t);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FnPainter old) => true;
}

// ------------------------------------------------------------------------------------------ the face

class MoodSpec {
  const MoodSpec(this.w, this.h, this.tIn, this.tOut, this.cheek, this.mouth, this.mOpen, this.color);
  final double w, h, tIn, tOut, cheek, mouth, mOpen;
  final Color color;
}

/// Same numbers as the firmware (face.h), so the app shows what the board will show.
const moodSpecs = <String, MoodSpec>{
  'normal': MoodSpec(40, 54, 0, 0, 0, 0.4, 0, Color(0xFF3CDCFF)),
  'happy': MoodSpec(42, 46, 0, 0, 0.5, 1, 0.35, Color(0xFF5AF5BE)),
  'sleepy': MoodSpec(42, 50, 0.52, 0.44, 0, 0, 0.1, Color(0xFF968CFF)),
  'angry': MoodSpec(42, 50, 0.62, 0.04, 0, -0.7, 0, Color(0xFFFF5A46)),
  'sad': MoodSpec(38, 52, 0, 0.6, 0, -0.85, 0, Color(0xFF5A96FF)),
  'love': MoodSpec(44, 46, 0, 0, 0, 1, 0.25, Color(0xFFFF64AA)),
  'surprised': MoodSpec(36, 64, 0, 0, 0, 0, 0.85, Color(0xFFC8F5FF)),
  'wink': MoodSpec(42, 52, 0, 0, 0, 0.85, 0.2, Color(0xFFFFC85A)),
  'thinking': MoodSpec(40, 52, 0.28, 0, 0, 0.05, 0, Color(0xFFBE82FF)),
  'excited': MoodSpec(44, 56, 0, 0, 0.2, 1, 0.6, Color(0xFFFFE146)),
  'dizzy': MoodSpec(40, 50, 0, 0, 0, 0, 0, Color(0xFFA0FF50)),
  'sleeping': MoodSpec(42, 50, 0, 0, 0, 0.1, 0, Color(0xFF968CFF)),
};

const moodOrder = ['normal', 'happy', 'love', 'excited', 'surprised', 'wink', 'thinking', 'sleepy', 'sleeping', 'sad', 'angry', 'dizzy'];

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// Draws the face centred at (cx, cy). `s` = 1 is the full 160x128 screen scaled by `unit` pixels per screen pixel.
void paintFace(Canvas c, String mood, double cx, double cy, double unit, double t, {double s = 1, double talk = -1}) {
  final m = moodSpecs[mood] ?? moodSpecs['normal']!;
  final u = unit * s;
  final col = m.color;
  final glow = _mix(HubColors.screen, col, 0.17);
  final dark = _mix(Colors.black, col, 0.2);
  final ph = t % 4.2;
  var open = 1.0;
  if (ph > 4.0) open = ((ph - 4.1).abs() / 0.1).clamp(0.08, 1.0);
  if (mood == 'sleepy') open *= 0.85;
  final lx = math.sin(t * 0.9) * 5, ly = math.sin(t * 0.6) * 2.5;
  final ew = m.w * u;
  var eh = m.h * u * open;
  if (eh < 3 * u + 1) eh = 3 * u + 1;
  final gap = 41 * u;
  final bg = Paint()..color = HubColors.screen;
  for (final i in [-1, 1]) {
    final ex = cx + i * gap + lx * u * 0.6, ey = cy + ly * u * 0.6;
    final top = ey - eh / 2, bot = ey + eh / 2;
    final closed = mood == 'sleeping' || (mood == 'wink' && i == 1);
    if (closed) {
      final p = Path();
      final up = mood == 'sleeping' ? -1 : 1;
      final hh = math.max(3.0, ew / 4);
      for (var k = 0; k <= 20; k++) {
        final uu = (k / 20) * 2 - 1;
        final x = ex + uu * ew / 2, y = ey + (mood == 'sleeping' ? -2 : 3) * u - up * (1 - uu * uu) * hh;
        if (k == 0) {
          p.moveTo(x, y);
        } else {
          p.lineTo(x, y);
        }
      }
      c.drawPath(p, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 3 * u..strokeCap = StrokeCap.round);
    } else if (mood == 'love') {
      final hs = ew * 0.34 * (1 + 0.1 * math.sin(t * 12));
      _heart(c, ex, ey - hs * 0.3, hs, col);
    } else if (mood == 'dizzy') {
      final rad = ew / 2;
      c.drawCircle(Offset(ex, ey), rad, Paint()..color = glow..style = PaintingStyle.stroke..strokeWidth = 1.5);
      final p = Path();
      final a0 = t * 11 * (i < 0 ? 1 : -1);
      for (var k = 0; k < 46; k++) {
        final a = a0 + k * 0.42, r = k * rad / 46;
        final x = ex + math.cos(a) * r, y = ey + math.sin(a) * r;
        if (k == 0) {
          p.moveTo(x, y);
        } else {
          p.lineTo(x, y);
        }
      }
      c.drawPath(p, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2 * u);
    } else {
      final rr = math.min(ew, eh) * 0.34;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(ex, ey), width: ew + 6 * u, height: eh + 6 * u), Radius.circular(rr + 3 * u)), Paint()..color = glow);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(ex, ey), width: ew, height: eh), Radius.circular(rr)), Paint()..color = col);
      if (eh > 14 * u) {
        final pr = ew * (mood == 'surprised' ? 0.17 : 0.27);
        final ix = ex + lx * u * 0.45, iy = ey + ly * u * 0.45;
        c.drawCircle(Offset(ix, iy), pr, Paint()..color = dark);
        c.drawCircle(Offset(ix - pr * 0.35, iy - pr * 0.4), math.max(2, pr * 0.36), Paint()..color = Colors.white);
        c.drawCircle(Offset(ix + pr * 0.4, iy + pr * 0.45), math.max(1, pr * 0.16), Paint()..color = const Color(0xFFDCF0FF));
      }
      final tl = (i < 0 ? m.tOut : m.tIn) * eh, tr = (i < 0 ? m.tIn : m.tOut) * eh;
      if (tl > 0.5 || tr > 0.5) {
        final x0 = ex - ew / 2 - 4, x1 = ex + ew / 2 + 4;
        c.drawPath(Path()..moveTo(x0, top - 5)..lineTo(x1, top - 5)..lineTo(x1, top + tr)..lineTo(x0, top + tl)..close(), bg);
      }
      if (m.cheek > 0.02) {
        final r = ew * 0.78;
        c.drawCircle(Offset(ex, bot - m.cheek * eh + r), r, bg);
      }
    }
    if (const ['happy', 'love', 'excited', 'wink'].contains(mood)) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(ex, cy + 35 * u), width: 18 * u, height: 6 * u), Radius.circular(3 * u)), Paint()..color = const Color(0xFF96375A));
    }
  }
  // mouth
  final my = cy + 43 * u;
  var mouth = m.mouth;
  final open2 = talk >= 0 ? talk : m.mOpen;
  if (talk >= 0 && mouth < 0.2) mouth = 0.3;
  final mw = (13 + 8 * mouth.abs() + 6 * open2) * u;
  final bend = mouth * 7 * u;
  final lip = Paint()..color = const Color(0xFFFF82A0)..style = PaintingStyle.stroke..strokeWidth = math.max(1.5, 2 * u)..strokeCap = StrokeCap.round;
  final line = Path();
  for (var k = 0; k <= 24; k++) {
    final uu = (k / 24) * 2 - 1;
    final x = cx + uu * mw, y = my + bend * (1 - uu * uu);
    if (k == 0) {
      line.moveTo(x, y);
    } else {
      line.lineTo(x, y);
    }
  }
  if (open2 > 0.04) {
    final inner = Path()..addPath(line, Offset.zero);
    final lower = Path();
    for (var k = 24; k >= 0; k--) {
      final uu = (k / 24) * 2 - 1;
      lower.lineTo(cx + uu * mw, my + bend * (1 - uu * uu) + open2 * 14 * u * math.sqrt(math.max(0, 1 - uu * uu)));
    }
    inner.addPath(lower, Offset.zero);
    c.drawPath(inner, Paint()..color = const Color(0xFF3C0A1E));
  }
  c.drawPath(line, lip);
  // a few mood extras so the preview matches the board
  switch (mood) {
    case 'sleeping':
      for (var k = 0; k < 3; k++) {
        final p = ((t * 25 + k * 28) % 84);
        _text(c, 'z', cx + 40 * u + p / 3 * unit, cy - 10 * u - p / 2 * unit, (8 + k * 4) * unit, col.withValues(alpha: (1 - p / 120).clamp(0.2, 1)));
      }
    case 'excited':
      _spark(c, cx - 66 * u, cy - 34 * u, (3 + (t * 8) % 4) * u, const Color(0xFFFFF078));
      _spark(c, cx + 66 * u, cy - 30 * u, (3 + (t * 8 + 2) % 4) * u, const Color(0xFFFFF078));
    case 'love':
      for (var k = 0; k < 2; k++) {
        final p = (t * 28 + k * 40) % 80;
        _heart(c, cx + (k == 0 ? 48 : -48) * u, cy + 10 * u - p / 2 * unit, 4 * u, const Color(0xFFFF5A96));
      }
    case 'thinking':
      final n = (t * 3).floor() % 4;
      for (var k = 0; k < 3; k++) {
        if (k < n) c.drawCircle(Offset(cx + (38 + k * 9) * u, cy - (34 + k * 8) * u), (2 + k) * u, Paint()..color = const Color(0xFFBE82FF));
      }
    case 'sad':
      final ty = cy + 28 * u + ((t * 18) % 34) * unit;
      c.drawCircle(Offset(cx + gap + ew * 0.25, ty), 2.5 * u, Paint()..color = const Color(0xFF6EAAFF));
    default:
      break;
  }
}

void _heart(Canvas c, double x, double y, double s, Color col) {
  final p = Paint()..color = col;
  c.drawCircle(Offset(x - s / 2, y), s / 2 + 1, p);
  c.drawCircle(Offset(x + s / 2, y), s / 2 + 1, p);
  c.drawPath(Path()..moveTo(x - s - 1, y + 1)..lineTo(x + s + 1, y + 1)..lineTo(x, y + s + 3)..close(), p);
}

void _spark(Canvas c, double x, double y, double r, Color col) {
  final p = Paint()..color = col..strokeWidth = 2;
  c.drawLine(Offset(x - r, y), Offset(x + r, y), p);
  c.drawLine(Offset(x, y - r), Offset(x, y + r), p);
}

void _text(Canvas c, String s, double x, double y, double size, Color col, {FontWeight w = FontWeight.w700, TextAlign align = TextAlign.left, double maxW = 400}) {
  final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(color: col, fontSize: size, fontWeight: w, height: 1.0)), textDirection: TextDirection.ltr, textAlign: align, maxLines: 1, ellipsis: '…')..layout(maxWidth: maxW);
  tp.paint(c, Offset(align == TextAlign.center ? x - tp.width / 2 : x, y));
}

// ------------------------------------------------------------------------------------------ previews of what the board shows

/// A face on the board's screen.
class FaceScreen extends StatelessWidget {
  const FaceScreen({super.key, required this.mood, this.talking = false});
  final String mood;
  final bool talking;
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final u = size.width / 160;
        c.drawRect(Offset.zero & size, Paint()..color = HubColors.screen);
        paintFace(c, mood, size.width / 2, size.height / 2 - 8 * u, u, t, talk: talking ? (math.sin(t * 14).abs() * 0.8) : -1);
      });
}

/// A notification card as the board draws it.
class NotifScreen extends StatelessWidget {
  const NotifScreen({super.key, this.app = 'WhatsApp', this.title = 'Mom', this.body = 'Dinner is ready, come home soon!', this.color = const Color(0xFF25D366)});
  final String app, title, body;
  final Color color;
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final u = size.width / 160;
        c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF060812));
        final loop = t % 5;
        final p = (loop / 0.5).clamp(0.0, 1.0);
        final ease = 1 - math.pow(1 - p, 3).toDouble();
        final ox = (1 - ease) * size.width;
        final card = RRect.fromRectAndRadius(Rect.fromLTWH(4 * u + ox, 4 * u, 152 * u, 120 * u), Radius.circular(9 * u));
        c.drawRRect(card, Paint()..color = const Color(0xFF111628));
        c.drawRRect(card, Paint()..color = const Color(0xFF283456)..style = PaintingStyle.stroke..strokeWidth = u);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(4 * u + ox, 4 * u, 5 * u, 120 * u), Radius.circular(2 * u)), Paint()..color = color);
        c.drawCircle(Offset(24 * u + ox, 23 * u), 11 * u, Paint()..color = color);
        _text(c, app.isEmpty ? '!' : app[0].toUpperCase(), 24 * u + ox, 15 * u, 15 * u, const Color(0xFF0A0C18), align: TextAlign.center);
        _text(c, app, 42 * u + ox, 12 * u, 9.5 * u, HubColors.text, w: FontWeight.w600);
        _text(c, 'now', 42 * u + ox, 24 * u, 8.5 * u, HubColors.muted, w: FontWeight.w500);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(138 * u + ox, 14 * u, 9 * u, 8 * u), Radius.circular(3 * u)), Paint()..color = const Color(0xFFFFD66E));
        c.drawLine(Offset(14 * u + ox, 38 * u), Offset(146 * u + ox, 38 * u), Paint()..color = const Color(0xFF283456));
        _text(c, title, 14 * u + ox, 44 * u, 10 * u, Colors.white, maxW: 130 * u);
        final tp = TextPainter(text: TextSpan(text: body, style: TextStyle(color: const Color(0xFFAFBAD7), fontSize: 8.6 * u, height: 1.25)), textDirection: TextDirection.ltr, maxLines: 4)..layout(maxWidth: 130 * u);
        tp.paint(c, Offset(14 * u + ox, 59 * u));
        final left = (1 - (loop / 5)).clamp(0.0, 1.0);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(14 * u + ox, 112 * u, 132 * u, 3 * u), Radius.circular(u)), Paint()..color = const Color(0xFF1E2640));
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(14 * u + ox, 112 * u, 132 * u * left, 3 * u), Radius.circular(u)), Paint()..color = color);
      });
}

/// Now-playing as the board draws it: sleeve, spinning record, equaliser, scrolling title.
class MusicScreen extends StatelessWidget {
  const MusicScreen({super.key, this.title = 'Midnight City', this.artist = 'M83', this.hue = 285, this.playing = true});
  final String title, artist;
  final double hue;
  final bool playing;
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final u = size.width / 160;
        c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF080910));
        final c1 = HSVColor.fromAHSV(1, hue % 360, 0.75, 1).toColor();
        final glow = HSVColor.fromAHSV(1, hue % 360, 0.7, 0.16).toColor();
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(2 * u, 2 * u, 156 * u, 58 * u), Radius.circular(10 * u)), Paint()..color = glow);
        final vc = Offset(64 * u, 32 * u);
        c.drawCircle(vc, 25 * u, Paint()..color = const Color(0xFF0E0E14));
        for (final r in [25.0, 20.0, 16.0, 12.0]) {
          c.drawCircle(vc, r * u, Paint()..color = const Color(0xFF30303F)..style = PaintingStyle.stroke..strokeWidth = u);
        }
        final ang = playing ? t * 4.5 : 0.6;
        for (var k = 0; k < 2; k++) {
          final a = ang + k * math.pi;
          c.drawLine(vc + Offset(math.cos(a), math.sin(a)) * 11 * u, vc + Offset(math.cos(a), math.sin(a)) * 23 * u, Paint()..color = const Color(0xFF464860)..strokeWidth = 1.5 * u);
        }
        c.drawCircle(vc, 9 * u, Paint()..color = c1);
        c.drawCircle(vc + Offset(math.cos(ang), math.sin(ang)) * 5 * u, u, Paint()..color = const Color(0xFF080910));
        c.drawCircle(vc, 2 * u, Paint()..color = const Color(0xFF080910));
        final sleeve = Rect.fromLTWH(8 * u, 8 * u, 46 * u, 46 * u);
        c.drawRRect(RRect.fromRectAndRadius(sleeve, Radius.circular(2 * u)), Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [HSVColor.fromAHSV(1, hue % 360, 0.78, 1).toColor(), HSVColor.fromAHSV(1, (hue + 50) % 360, 0.78, 0.62).toColor()]).createShader(sleeve));
        _text(c, title.isEmpty ? '♪' : title[0].toUpperCase(), 31 * u, 21 * u, 26 * u, Colors.white, align: TextAlign.center);
        for (var i = 0; i < 8; i++) {
          final v = playing ? (0.22 + 0.78 * (math.sin(t * (6.5 + i * 2.2) + i * 1.7) * math.cos(t * 3 + i)).abs()) : 0.06;
          final bh = v * 44 * u;
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH((100 + i * 7) * u, 54 * u - bh, 5 * u, math.max(2 * u, bh)), Radius.circular(2 * u)), Paint()..color = HSVColor.fromAHSV(1, (hue + i * 12) % 360, 0.8, 1).toColor());
        }
        c.drawCircle(Offset(8 * u, 69 * u), 2.4 * u, Paint()..color = c1);
        _text(c, playing ? 'NOW PLAYING' : 'PAUSED', 16 * u, 64 * u, 7.5 * u, c1);
        _text(c, title, 6 * u, 76 * u, 15 * u, Colors.white, maxW: 150 * u);
        _text(c, artist, 6 * u, 95 * u, 8.5 * u, HSVColor.fromAHSV(1, hue % 360, 0.35, 1).toColor());
        final prog = ((t * 0.02) % 1.0);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(6 * u, 109 * u, 148 * u, 4 * u), Radius.circular(2 * u)), Paint()..color = const Color(0xFF22263A));
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(6 * u, 109 * u, 148 * u * prog, 4 * u), Radius.circular(2 * u)), Paint()..color = c1);
        c.drawCircle(Offset(6 * u + 148 * u * prog, 111 * u), 3 * u, Paint()..color = Colors.white);
      });
}

/// Weather as the board draws it.
class WeatherScreen extends StatelessWidget {
  const WeatherScreen({super.key, this.temp = '28', this.place = 'Your location'});
  final String temp, place;
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final u = size.width / 160;
        c.drawRect(Offset.zero & size, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0E2A55), Color(0xFF060812)]).createShader(Offset.zero & size));
        final sc = Offset(48 * u, 52 * u);
        c.drawCircle(sc, 20 * u, Paint()..color = const Color(0x33FFD25A));
        for (var k = 0; k < 10; k++) {
          final a = k * math.pi / 5 + t * 0.5;
          c.drawLine(sc + Offset(math.cos(a), math.sin(a)) * 24 * u, sc + Offset(math.cos(a), math.sin(a)) * 31 * u, Paint()..color = const Color(0xFFFFD25A)..strokeWidth = 2.5 * u..strokeCap = StrokeCap.round);
        }
        c.drawCircle(sc, 16 * u, Paint()..color = const Color(0xFFFFD25A));
        final cx = 66 * u + math.sin(t * 0.8) * 4 * u;
        final cl = Paint()..color = const Color(0xFFDDE7FF);
        c.drawCircle(Offset(cx, 62 * u), 11 * u, cl);
        c.drawCircle(Offset(cx + 14 * u, 56 * u), 14 * u, cl);
        c.drawCircle(Offset(cx + 30 * u, 63 * u), 10 * u, cl);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx - 8 * u, 62 * u, 46 * u, 11 * u), Radius.circular(5 * u)), cl);
        _text(c, '$temp°', 100 * u, 24 * u, 30 * u, Colors.white);
        _text(c, 'Sunny', 102 * u, 58 * u, 9 * u, const Color(0xFFAFBAD7), w: FontWeight.w500);
        _text(c, place, 8 * u, 104 * u, 9 * u, HubColors.accent, w: FontWeight.w600, maxW: 144 * u);
      });
}

/// A small icon-only preview used when a scene has no dedicated painter.
class GradientScreen extends StatelessWidget {
  const GradientScreen({super.key, required this.icon, required this.a, required this.b});
  final IconData icon;
  final Color a, b;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b])),
        child: Center(child: Icon(icon, size: 44, color: Colors.white.withValues(alpha: 0.9))),
      );
}
