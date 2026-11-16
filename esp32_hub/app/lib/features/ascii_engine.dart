// ASCII animals: the same simulation and character-cell renderer the Hub runs (firmware/hub/ascii_engine.h), in Dart, so the
// app can show the animals live and the tuning means the same thing on both. Both were written from the "ascii animals" web
// page (pocketstudio.design): a flock with depth (far = smaller and fainter), steering with separation, a pointer startle, a
// glowing trail that diffuses and fades, and every animal drawn as coloured character cells (a tile plus a glyph).
// No Flutter import: this file only does the maths and fills the cell arrays that [AsciiAnimalsPainter] draws.
import 'dart:math' as math;
import 'dart:typed_data';

const int asciiW = 160, asciiH = 128, asciiCellW = 6, asciiCellH = 8, asciiCols = 27, asciiRows = 16, asciiCells = asciiCols * asciiRows;
const int _maxCr = 12, _maxFood = 24;
const double _pi = math.pi, _tau = math.pi * 2;

/// One tuning value the app offers: id, label, range and what it does (the hint the web page gives).
class AsciiKnob {
  const AsciiKnob(this.key, this.label, this.min, this.max, this.hint, {this.step = 0.05});
  final String key, label, hint;
  final double min, max, step;
}

/// The knobs every animal has (the web page's Movement and Look groups, trimmed to what a 160 x 128 screen can show).
const asciiCommonKnobs = <AsciiKnob>[
  AsciiKnob('density', 'Density', 0.1, 4, 'How many are on screen.'),
  AsciiKnob('speed', 'Speed', 0.1, 3, 'How fast they travel.'),
  AsciiKnob('size', 'Size', 0.3, 2.5, 'How big they are.'),
  AsciiKnob('trail', 'Trail', 0, 4, 'How much they leave behind: scales, ripples, footprints or glow.'),
  AsciiKnob('trailFade', 'Trail fade', 0.05, 6, 'How quickly that trail fades. Lower lingers longer.'),
  AsciiKnob('hue', 'Hue shift (°)', -180, 180, 'Turns the animal\'s colour around the colour wheel, in degrees.', step: 1),
  AsciiKnob('sparkle', 'Sparkle', 0, 0.5, 'How often cells flash white, like light catching scales or wings.', step: 0.01),
  AsciiKnob('fog', 'Distance fade', 0, 1, 'How much far-away ones fade into the background.', step: 0.01),
  AsciiKnob('shimmer', 'Shimmer', 0, 1, 'How much surfaces roll brighter and darker as the animal turns.', step: 0.01),
  AsciiKnob('direction', 'Direction (°)', 0, 360, 'Which way they travel: 0 is right, 90 is up. Used when Corner to corner is off.', step: 1),
];

class AsciiTune {
  AsciiTune({this.density = 1, this.speed = 1, this.size = 1, this.trail = 1, this.trailFade = 0.5, this.hue = 0, this.sparkle = 0.12, this.fog = 0.3, this.shimmer = 0.3, this.direction = 49, this.corner = true, List<double>? k}) : k = k ?? [1, 1, 1];
  double density, speed, size, trail, trailFade, hue, sparkle, fog, shimmer, direction;
  bool corner;
  List<double> k;

  AsciiTune copy() => AsciiTune(density: density, speed: speed, size: size, trail: trail, trailFade: trailFade, hue: hue, sparkle: sparkle, fog: fog, shimmer: shimmer, direction: direction, corner: corner, k: List.of(k));

  double get(String key, AsciiAnimal a) {
    switch (key) {
      case 'density': return density;
      case 'speed': return speed;
      case 'size': return size;
      case 'trail': return trail;
      case 'trailFade': return trailFade;
      case 'hue': return hue;
      case 'sparkle': return sparkle;
      case 'fog': return fog;
      case 'shimmer': return shimmer;
      case 'direction': return direction;
    }
    final i = a.knobs.indexWhereKey(key);
    return i < 0 ? 0 : k[i];
  }

  void set(String key, double v, AsciiAnimal a) {
    switch (key) {
      case 'density': density = v; return;
      case 'speed': speed = v; return;
      case 'size': size = v; return;
      case 'trail': trail = v; return;
      case 'trailFade': trailFade = v; return;
      case 'hue': hue = v; return;
      case 'sparkle': sparkle = v; return;
      case 'fog': fog = v; return;
      case 'shimmer': shimmer = v; return;
      case 'direction': direction = v; return;
    }
    final i = a.knobs.indexWhereKey(key);
    if (i >= 0) k[i] = v;
  }

  /// The JSON the Hub's `ascii` command takes for the whole tuning.
  Map<String, dynamic> toCommand(AsciiAnimal a) => {
        'density': _r(density), 'speed': _r(speed), 'size': _r(size), 'trail': _r(trail), 'trailFade': _r(trailFade), 'hue': _r(hue),
        'sparkle': _r(sparkle), 'fog': _r(fog), 'shimmer': _r(shimmer), 'direction': _r(direction), 'corner': corner,
        for (var i = 0; i < 3; i++) a.knobs[i].key: _r(k[i]),
      };
  static double _r(double v) => (v * 1000).roundToDouble() / 1000;
}

extension on List<AsciiKnob> {
  int indexWhereKey(String key) => indexWhere((k) => k.key == key);
}

class AsciiAnimal {
  const AsciiAnimal(this.id, this.label, this.swatch, this.knobs, this.count, this.scale, this.speed, this.trail, this._def);
  final String id, label;
  final int swatch;          // 0xRRGGBB
  final List<AsciiKnob> knobs;
  final double count, scale, speed;
  final List<int> trail;
  final List<double> _def;   // density, speed, size, trail, trailFade, hue, sparkle, fog, shimmer, k0, k1, k2
  AsciiTune defaults() => AsciiTune(density: _def[0], speed: _def[1], size: _def[2], trail: _def[3], trailFade: _def[4], hue: _def[5], sparkle: _def[6], fog: _def[7], shimmer: _def[8], k: [_def[9], _def[10], _def[11]]);
}

const asciiAnimals = <AsciiAnimal>[
  AsciiAnimal('butterflies', 'Butterfly', 0x3287FF, [
    AsciiKnob('flutter', 'Flutter', 0, 3, 'How much their path zigzags.'),
    AsciiKnob('glide', 'Glide', 0, 4, 'How often they stop flapping and glide with wings held flat.'),
    AsciiKnob('flapRate', 'Flap rate', 0.2, 3, 'How fast their wings beat.'),
  ], 4, 1.0, 28, [96, 156, 255], [1, 1, 1, 1.5, 0.4, 0, 0.12, 0.45, 0.3, 0.6, 1.5, 1.0]),
  AsciiAnimal('koi', 'Koi', 0xF4C42C, [
    AsciiKnob('meander', 'Meander', 0, 3, 'How much they weave in lazy S-curves.'),
    AsciiKnob('tailBeat', 'Tail beat', 0.2, 3, 'How fast and wide the tail swishes.'),
    AsciiKnob('foodRange', 'Food range', 0, 200, 'How close a koi has to be to notice food you drop. Tap the screen to drop some.', step: 5),
  ], 4, 1.15, 16, [110, 170, 220], [1, 1, 1, 1, 0.5, 0, 0.12, 0.35, 0.3, 1, 1, 90]),
  AsciiAnimal('jellyfish', 'Jellyfish', 0xE678FF, [
    AsciiKnob('pulseRate', 'Pulse rate', 0.2, 3, 'How often the bell pulses.'),
    AsciiKnob('pulsePower', 'Pulse power', 0.2, 3, 'How hard each pulse pushes, and how much it glows.'),
    AsciiKnob('tentacles', 'Tentacles', 0.3, 2, 'How long the tentacles trail.'),
  ], 4, 1.1, 12, [190, 130, 255], [1, 1, 1, 1, 0.5, 0, 0.18, 0.3, 0.3, 1, 1, 1]),
  AsciiAnimal('dragonflies', 'Dragonfly', 0x32DC78, [
    AsciiKnob('hover', 'Hover time', 0, 3, 'How long they hang in the air between darts.'),
    AsciiKnob('cruising', 'Cruising', 0, 1, 'How often they cruise instead of hovering.'),
    AsciiKnob('dart', 'Dart speed', 0.3, 3, 'How fast they dart.'),
  ], 5, 0.85, 32, [120, 232, 150], [1, 1, 1, 0.6, 1.2, 0, 0.18, 0.3, 0.3, 1.3, 0.5, 1.5]),
  AsciiAnimal('frogs', 'Frog', 0x60E882, [
    AsciiKnob('hop', 'How often', 0.2, 3, 'How often they hop.'),
    AsciiKnob('leap', 'Leap length', 0.4, 2.5, 'How far each leap goes.'),
    AsciiKnob('height', 'Leap height', 0.2, 2.5, 'How high they jump.'),
  ], 4, 0.95, 34, [150, 220, 170], [1, 1, 1, 1, 0.8, 0, 0.12, 0.3, 0.2, 1, 1, 1]),
  AsciiAnimal('cranes', 'Crane', 0xECEEF2, [
    AsciiKnob('wingbeat', 'Wingbeat', 0.2, 3, 'How fast the wings beat.'),
    AsciiKnob('glide', 'Glide', 0, 3, 'How often they glide with wings held out.'),
    AsciiKnob('foldFlap', 'Folding flap', 0, 1, 'A deeper, folding wingbeat.', step: 1),
  ], 2, 1.0, 24, [200, 210, 225], [1, 1, 1, 0, 1, 0, 0.04, 0.26, 0.1, 1, 1, 0]),
  AsciiAnimal('crabs', 'Crab', 0xCC5234, [
    AsciiKnob('burst', 'Burst length', 0.2, 3, 'How long they scuttle.'),
    AsciiKnob('rest', 'Pause length', 0, 3, 'How long they stop between bursts.'),
    AsciiKnob('scare', 'Scare', 0, 1.5, 'How fast they run from a tap.'),
  ], 5, 0.8, 28, [206, 178, 136], [1, 1, 1, 0.6, 1, 0, 0.03, 0.25, 0.1, 1, 1, 0.55]),
];

AsciiAnimal? asciiAnimalById(String id) {
  for (final a in asciiAnimals) {
    if (a.id == id) return a;
  }
  return null;
}

// --------------------------------------------------------------------------------------------- creature and food
class _Cr {
  double x = 0, y = 0, vx = 0, vy = 0, heading = 0, bias = 0, depth = 1, span = 0, roll = 0, phase = 0, startled = 0;
  double a = 0, b = 0, until = 0, aim = 0, fx = 0, fy = 0, tx = 0, ty = 0, s = 0, dur = 0.5, glide = 0, glideUntil = 0, open = 1, flx = 0, fly = 0, alarm = 0, gait = 0, squeeze = 0, turn = 0;
  final Float64List nodes = Float64List(16);
  int facing = 1, m = 0, variety = 0, id = 0;
  bool mode = false, leaping = false;
}

class _Food {
  double x = 0, y = 0, vx = 0, vy = 0, born = 0;
  bool live = false;
}

enum _Kind { body, edge, light, spark }

const _ramp = '.,:;ox%#@', _edgeG = '#%@&', _lightG = ".:'`,", _thin = '.:*+';
const _bgR = 6, _bgG = 8, _bgB = 16;

double _clamp(double v, double a, double b) => v < a ? a : (v > b ? b : v);
double _mix(double a, double b, double t) => a + (b - a) * t;
double _fract(double v) => v - v.floorToDouble();
double _smooth(double a, double b, double v) {
  final t = _clamp((v - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
}

double _angDiff(double a, double b) {
  var s = (b - a) % _tau;
  if (s > _pi) s -= _tau;
  if (s < -_pi) s += _tau;
  return s;
}

int _hash3(int a, int b, int c) {
  var i = ((a & 0xFFFFFFFF) * 374761393) ^ ((b & 0xFFFFFFFF) * 668265263) ^ ((c & 0xFFFFFFFF) * 1442695041);
  i &= 0xFFFFFFFF;
  i = ((i ^ (i >> 13)) * 1274126177) & 0xFFFFFFFF;
  i ^= i >> 16;
  return i & 0xFFFFFFFF;
}

double _hash01(int a, int b, int c) => _hash3(a, b, c) / 4294967296.0;

/// RGB565, the same packing the Hub uses.
int _pack(double r, double g, double b) {
  final R = _clamp(r, 0, 255).toInt(), G = _clamp(g, 0, 255).toInt(), B = _clamp(b, 0, 255).toInt();
  return ((R & 0xF8) << 8) | ((G & 0xFC) << 3) | (B >> 3);
}

/// 0xAARRGGBB for an RGB565 value.
int asciiColor565(int v) {
  final r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
  return 0xFF000000 | ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2);
}

const _inkC = [30, 30, 42];

/// The simulation and the cell buffers. Call [step] then [render] every frame; the painter reads the arrays.
class AsciiWorld {
  AsciiWorld({int seed = 2463534242}) : _rng = seed == 0 ? 1 : seed & 0xFFFFFFFF {
    setAnimal(0);
  }

  int animalIndex = 0;
  AsciiAnimal get animal => asciiAnimals[animalIndex];
  AsciiTune tune = asciiAnimals[0].defaults();
  double time = 0;
  int count = 0;

  // what is drawn
  final Uint8List flag = Uint8List(asciiCells);          // 0 empty, 1 thin (glyph only), 2 solid (tile + glyph)
  final Uint16List glyph = Uint16List(asciiCells);
  final Uint16List fill = Uint16List(asciiCells), col = Uint16List(asciiCells), trailCol = Uint16List(asciiCells);
  final Float32List energy = Float32List(asciiCells);
  final Float32List _energyTmp = Float32List(asciiCells);
  final int bg = _pack(_bgR.toDouble(), _bgG.toDouble(), _bgB.toDouble());

  final List<_Cr> _cr = List.generate(_maxCr, (_) => _Cr());
  final List<_Food> _food = List.generate(_maxFood, (_) => _Food());
  int _rng;
  int _nextId = 1;
  double _ax = 0, _ay = 0;
  final List<double> _hue = List.filled(9, 0);
  bool _hueOn = false;

  double _rnd() {
    _rng ^= (_rng << 13) & 0xFFFFFFFF;
    _rng ^= _rng >> 17;
    _rng ^= (_rng << 5) & 0xFFFFFFFF;
    _rng &= 0xFFFFFFFF;
    return (_rng >> 8) / 16777216.0;
  }

  double _rf(double a, double b) => a + _rnd() * (b - a);

  // ------------------------------------------------------------------------------------------- colour
  void _setHue(double deg) {
    final a = deg * _pi / 180, c = math.cos(a), s = math.sin(a);
    _hue[0] = 0.213 + c * 0.787 - s * 0.213; _hue[1] = 0.715 - c * 0.715 - s * 0.715; _hue[2] = 0.072 - c * 0.072 + s * 0.928;
    _hue[3] = 0.213 - c * 0.213 + s * 0.143; _hue[4] = 0.715 + c * 0.285 + s * 0.140; _hue[5] = 0.072 - c * 0.072 - s * 0.283;
    _hue[6] = 0.213 - c * 0.213 - s * 0.787; _hue[7] = 0.715 - c * 0.715 + s * 0.715; _hue[8] = 0.072 + c * 0.928 + s * 0.072;
    _hueOn = deg % 360 != 0;
  }

  int _tint(List<int> c, double mul, double add, double f) {
    var r = c[0].toDouble(), g = c[1].toDouble(), b = c[2].toDouble();
    if (_hueOn) {
      final R = _hue[0] * r + _hue[1] * g + _hue[2] * b, G = _hue[3] * r + _hue[4] * g + _hue[5] * b, B = _hue[6] * r + _hue[7] * g + _hue[8] * b;
      r = R; g = G; b = B;
    }
    r = r * mul + add; g = g * mul + add; b = b * mul + add;
    r += (_bgR - r) * f; g += (_bgG - g) * f; b += (_bgB - b) * f;
    return _pack(r, g, b);
  }

  /// Applies the current tuning that needs recomputing (the hue matrix). Call after changing [tune].
  void restyle() => _setHue(tune.hue);

  // ------------------------------------------------------------------------------------------- pen
  int _cellAt(double x, double y) {
    final cx = (x / asciiCellW).floor(), cy = (y / asciiCellH).floor();
    return (cx < 0 || cy < 0 || cx >= asciiCols || cy >= asciiRows) ? -1 : cy * asciiCols + cx;
  }

  double _fogOf(double depth) => (1 - depth) * tune.fog;

  void _putCell(int ci, int cx, int cy, int id, _Kind kind, List<int> c, double light, double cov, double fogv) {
    final h = _hash3(cx, cy, id);
    final jit = _hash01(cx, cy, (time * 2.4).toInt() + id);
    final lum = (0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]) / 255.0;
    if (cov < 0.6) {
      if (flag[ci] == 2 || kind == _Kind.spark) return;
      flag[ci] = 1; glyph[ci] = _thin.codeUnitAt((h >> 8) % 4); col[ci] = _tint(c, light, 0, math.max(fogv, 0) + 0.5 - 0.35 * cov);
      return;
    }
    if (kind == _Kind.light) {
      if (flag[ci] == 2) return;
      flag[ci] = 1; glyph[ci] = _lightG.codeUnitAt((h >> 8) % 5); col[ci] = _tint(c, light, 0, fogv + 0.15);
      return;
    }
    var shim = 1.0;
    if (kind == _Kind.body) shim = 1 - 0.4 * tune.shimmer + tune.shimmer * math.sin(time * 2.2 + cx * 0.9 + cy * 0.6 + id);
    flag[ci] = 2;
    final m = light * shim;
    fill[ci] = _tint(c, m, 0, fogv);
    if (kind == _Kind.edge) {
      glyph[ci] = _edgeG.codeUnitAt((h >> 8) % 4); col[ci] = _tint(c, m * 1.7, 34, fogv);
    } else {
      final n = _ramp.length;
      var k = ((1 - lum * m) * (n - 0.01)).toInt() + ((h >> 4) % 3) - 1;
      k = k < 0 ? 0 : (k >= n ? n - 1 : k);
      glyph[ci] = _ramp.codeUnitAt(k); col[ci] = _tint(c, m * 0.42, 0, fogv);
    }
    if (kind == _Kind.body && jit < tune.sparkle / 3) col[ci] = _pack(250, 250, 255);
  }

  static const _ox = [0.5, 0.2, 0.8, 0.2, 0.8], _oy = [0.5, 0.2, 0.2, 0.8, 0.8];

  void _ell(double cx, double cy, double rx, double ry, double ang, List<int> c, _Kind kind, double depth, int id, [double light = 1]) {
    if (rx < 0.5) rx = 0.5;
    if (ry < 0.5) ry = 0.5;
    final r = math.max(rx, ry) + asciiCellW, ca = math.cos(ang), sa = math.sin(ang), fogv = _fogOf(depth);
    final x0 = ((cx - r) / asciiCellW).floor(), x1 = ((cx + r) / asciiCellW).floor(), y0 = ((cy - r) / asciiCellH).floor(), y1 = ((cy + r) / asciiCellH).floor();
    for (var j = y0; j <= y1; j++) {
      for (var i = x0; i <= x1; i++) {
        if (i < 0 || j < 0 || i >= asciiCols || j >= asciiRows) continue;
        var n = 0;
        var centre = false;
        for (var s = 0; s < 5; s++) {
          final dx = i * asciiCellW + _ox[s] * asciiCellW - cx, dy = j * asciiCellH + _oy[s] * asciiCellH - cy;
          final u = (dx * ca + dy * sa) / rx, v = (dy * ca - dx * sa) / ry;
          if (u * u + v * v <= 1) {
            n++;
            if (s == 0) centre = true;
          }
        }
        if (n == 0) continue;
        final cov = n / 5.0;
        _putCell(j * asciiCols + i, i, j, id, kind, c, light, centre && cov >= 0.6 ? 1.0 : cov, fogv);
      }
    }
  }

  void _cap(double x0, double y0, double x1, double y1, double r, List<int> c, _Kind kind, double depth, int id, [double light = 1]) {
    final dx = x1 - x0, dy = y1 - y0, l2 = dx * dx + dy * dy + 0.001, fogv = _fogOf(depth), rr = r + asciiCellW;
    final a0 = ((math.min(x0, x1) - rr) / asciiCellW).floor(), a1 = ((math.max(x0, x1) + rr) / asciiCellW).floor();
    final b0 = ((math.min(y0, y1) - rr) / asciiCellH).floor(), b1 = ((math.max(y0, y1) + rr) / asciiCellH).floor();
    for (var j = b0; j <= b1; j++) {
      for (var i = a0; i <= a1; i++) {
        if (i < 0 || j < 0 || i >= asciiCols || j >= asciiRows) continue;
        final px = i * asciiCellW + asciiCellW * 0.5, py = j * asciiCellH + asciiCellH * 0.5;
        final t = _clamp(((px - x0) * dx + (py - y0) * dy) / l2, 0, 1);
        final d = math.sqrt((px - x0 - dx * t) * (px - x0 - dx * t) + (py - y0 - dy * t) * (py - y0 - dy * t));
        if (d <= r) {
          _putCell(j * asciiCols + i, i, j, id, kind, c, light, 1, fogv);
        } else if (d <= r + asciiCellW * 0.45) {
          _putCell(j * asciiCols + i, i, j, id, kind, c, light, 0.4, fogv);
        }
      }
    }
  }

  int _lineGlyph(double ang) {
    final a = (ang + _tau * 4) % _pi;
    if (a < _pi / 8 || a >= 7 * _pi / 8) return 0x2D; // -
    if (a < 3 * _pi / 8) return 0x5C;                 // \
    if (a < 5 * _pi / 8) return 0x7C;                 // |
    return 0x2F;                                      // /
  }

  void _line(double x0, double y0, double x1, double y1, List<int> c, double depth, {String? last, double light = 1}) {
    final fogv = _fogOf(depth), len = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
    final n = math.max(1, (len / (asciiCellW * 0.5)).ceil());
    var li = -1;
    final g = _lineGlyph(math.atan2(y1 - y0, x1 - x0));
    for (var s = 1; s <= n; s++) {
      final ci = _cellAt(x0 + (x1 - x0) * s / n, y0 + (y1 - y0) * s / n);
      if (ci < 0 || flag[ci] == 2) continue;
      flag[ci] = 1; glyph[ci] = g; col[ci] = _tint(c, light, 0, fogv); li = ci;
    }
    if (last != null && li >= 0) glyph[li] = last.codeUnitAt(0);
  }

  void _spot(double x, double y, String g, List<int> fillc, List<int> c, double depth) {
    final ci = _cellAt(x, y);
    if (ci < 0) return;
    final fogv = _fogOf(depth);
    flag[ci] = 2; fill[ci] = _tint(fillc, 1, 0, fogv); col[ci] = _tint(c, 1, 0, fogv); glyph[ci] = g.codeUnitAt(0);
  }

  void _dot(double x, double y, String g, List<int> c, double depth) {
    final ci = _cellAt(x, y);
    if (ci < 0 || flag[ci] == 2) return;
    flag[ci] = 1; glyph[ci] = g.codeUnitAt(0); col[ci] = _tint(c, 1, 0, _fogOf(depth));
  }

  void _shed(double x, double y, double amt) {
    final ci = _cellAt(x, y);
    if (ci >= 0) energy[ci] = math.min(1.6, energy[ci] + amt * tune.trail);
  }

  void _stamp(double x, double y, int radius, double amount) {
    final ox = (x / asciiCellW).floor(), oy = (y / asciiCellH).floor();
    for (var j = oy - radius; j <= oy + radius; j++) {
      for (var i = ox - radius; i <= ox + radius; i++) {
        if (i < 0 || j < 0 || i >= asciiCols || j >= asciiRows) continue;
        final d = math.sqrt(((i - ox) * (i - ox)) + (j - oy) * 1.4 * (j - oy) * 1.4);
        if (d > radius + 0.5) continue;
        final ci = j * asciiCols + i;
        energy[ci] = math.min(1.6, energy[ci] + amount * (1 - d / (radius + 1)));
      }
    }
  }

  // ------------------------------------------------------------------------------------------- world helpers
  double get _course => tune.corner ? math.atan2(-asciiH.toDouble(), asciiW.toDouble()) : -tune.direction * _pi / 180;
  double get _group => _course + 0.04 * (math.sin(time * 0.13) + 0.5 * math.sin(time * 0.31 + 1.7));
  double get _base => 58.0 * animal.scale;
  double _depthOf(double roll) => 0.6 + 0.4 * math.pow(roll, 1.6);
  double _cruise(_Cr c) => animal.speed * (0.55 + 0.45 * c.depth) * tune.speed;

  (double, double) _toW(_Cr c, double u, double v) {
    final ca = math.cos(c.heading), sa = math.sin(c.heading);
    return (c.x + (u * ca - v * sa) * c.span, c.y + (u * sa + v * ca) * c.span);
  }

  void _begin() { _ax = 0; _ay = 0; }
  void _steer(_Cr c, double ang, double spd, double gain) {
    _ax += (math.cos(ang) * spd - c.vx) * gain;
    _ay += (math.sin(ang) * spd - c.vy) * gain;
  }

  void _separate(_Cr c, [double k = 170, double reach = 0.42]) {
    if (k <= 0) return;
    for (var i = 0; i < count; i++) {
      final n = _cr[i];
      if (identical(n, c) || (n.depth - c.depth).abs() > 0.2) continue;
      final dx = c.x - n.x, dy = c.y - n.y, r = math.sqrt(dx * dx + dy * dy), h = (c.span + n.span) * reach;
      if (r < h && r > 0.001) {
        final l = (1 - r / h) * k;
        _ax += dx / r * l; _ay += dy / r * l;
      }
    }
  }

  double _move(_Cr c, double dt, double maxSpeed) {
    c.vx += _ax * dt; c.vy += _ay * dt;
    var n = math.sqrt(c.vx * c.vx + c.vy * c.vy);
    final m = maxSpeed + (time < c.startled ? 90 : 0);
    if (n > m) { c.vx *= m / n; c.vy *= m / n; n = m; }
    c.x += c.vx * dt; c.y += c.vy * dt;
    return n;
  }

  void _face(_Cr c, double dt, double rate, double target) {
    final a = rate * dt;
    c.heading += _clamp(_angDiff(c.heading, target), -a, a);
  }

  bool _passed(_Cr c, double s) {
    final co = math.cos(_course), si = math.sin(_course);
    final h = (co > 0.05 && c.x > asciiW + s) || (co < -0.05 && c.x < -s) || (si < -0.05 && c.y < -s) || (si > 0.05 && c.y > asciiH + s);
    final l = c.x < -3 * s || c.x > asciiW + 3 * s || c.y < -3 * s || c.y > asciiH + 3 * s;
    return h || l;
  }

  void _enter(_Cr c) {
    switch (animalIndex) {
      case 1:
        final e = c.span / 7;
        for (var i = 0; i < 8; i++) {
          c.nodes[i * 2] = c.x - math.cos(c.heading) * e * i;
          c.nodes[i * 2 + 1] = c.y - math.sin(c.heading) * e * i;
        }
      case 4:
        c.leaping = false; c.s = 0; c.vx = 0; c.vy = 0; c.aim = _group + c.bias * 0.06; c.heading = c.aim; c.until = time + _rf(0, 1.5);
      case 6:
        c.mode = true; c.until = time + _rf(0.3, 1.2); c.heading = _course - c.facing * _pi / 2;
      case 3:
        c.m = 0; c.until = time + _rf(0, 0.6); c.aim = _course;
      case 0:
        c.flx = 0; c.fly = 0;
    }
  }

  void _reenter(_Cr c) {
    final a = c.span * 0.6, co = math.cos(_course), si = math.sin(_course), h = asciiH * co.abs(), l = asciiW * si.abs();
    if (_rnd() * (h + l) < h) {
      c.x = co >= 0 ? -a : asciiW + a; c.y = _rf(0, asciiH.toDouble());
    } else {
      c.x = _rf(0, asciiW.toDouble()); c.y = si <= 0 ? asciiH + a : -a;
    }
    final s = _cruise(c);
    c.heading = _course; c.vx = co * s; c.vy = si * s; c.bias = _rf(-1, 1);
    _enter(c);
  }

  void _spawn(_Cr c) {
    c.id = _nextId++;
    if (_nextId > 65535) _nextId = 1;
    c.x = c.y = c.vx = c.vy = c.heading = c.phase = c.startled = 0;
    c.a = c.b = c.until = c.aim = c.fx = c.fy = c.tx = c.ty = c.s = c.glide = c.glideUntil = c.flx = c.fly = c.alarm = c.gait = c.squeeze = c.turn = 0;
    c.nodes.fillRange(0, 16, 0);
    c.m = 0; c.mode = false; c.leaping = false;
    c.roll = _rnd(); c.depth = _depthOf(c.roll); c.span = _base * c.depth * tune.size;
    c.phase = _rf(0, _tau); c.open = 1; c.facing = _rnd() < 0.5 ? 1 : -1; c.dur = 0.5; c.variety = _hash3(c.id, 7, 3) % 4;
    _reenter(c);
  }

  int get targetCount => (animal.count * tune.density).round().clamp(1, _maxCr);

  void _populate(bool first) {
    final n = targetCount;
    while (count > n) {
      var i = (_rnd() * count).floor();
      if (i >= count) i = count - 1;
      final t = _cr[i]; _cr[i] = _cr[count - 1]; _cr[count - 1] = t;
      count--;
    }
    while (count < n) {
      final c = _cr[count];
      _spawn(c);
      if (first || _rnd() < 0.5) {
        c.x = _rf(0, asciiW.toDouble()); c.y = _rf(0, asciiH.toDouble());
        _enter(c);
      }
      count++;
    }
  }

  /// Changes the animal. Its own default tuning is used unless [keepTune].
  void setAnimal(int a, {bool keepTune = false}) {
    animalIndex = (a < 0 || a >= asciiAnimals.length) ? 0 : a;
    if (!keepTune) tune = animal.defaults();
    count = 0;
    energy.fillRange(0, asciiCells, 0);
    _energyTmp.fillRange(0, asciiCells, 0);
    for (final f in _food) { f.live = false; }
    restyle();
    _populate(true);
  }

  /// Tells the world the tuning changed (creature count, hue).
  void tuneChanged() {
    restyle();
    _populate(false);
  }

  // ------------------------------------------------------------------------------------------- touch
  /// A tap at (x, y) in display pixels: koi get food, everything else is startled and a ripple spreads.
  void startle(double x, double y) {
    if (animalIndex == 1) {
      final n = 7 + (_rnd() * 5).floor();
      for (var k = 0; k < n; k++) {
        var slot = _food.indexWhere((f) => !f.live);
        if (slot < 0) {
          slot = 0;
          for (var i = 1; i < _maxFood; i++) { if (_food[i].born < _food[slot].born) slot = i; }
        }
        final a = _rf(0, _tau), r = 28 * math.sqrt(_rnd());
        _food[slot]
          ..x = x + math.cos(a) * r
          ..y = y + math.sin(a) * r
          ..vx = math.cos(a) * _rf(2, 6)
          ..vy = math.sin(a) * _rf(2, 6)
          ..born = time
          ..live = true;
        _stamp(_food[slot].x, _food[slot].y, 1, 0.5);
      }
      return;
    }
    _stamp(x, y, 3, 1.4);
    for (var i = 0; i < count; i++) {
      final c = _cr[i];
      var dx = c.x - x, dy = c.y - y, d = math.sqrt(dx * dx + dy * dy);
      if (d < 0.001) { dx = 1; d = 1; }
      if (d > 70) continue;
      final r = 1 - d / 70, ux = dx / d, uy = dy / d;
      switch (animalIndex) {
        case 0:
          final k = r * 190 * c.depth;
          c.vx += ux * k; c.vy += uy * k; c.startled = time + _rf(0.6, 1.2); c.glideUntil = 0;
        case 2:
          c.phase = (c.phase / _tau).floorToDouble() * _tau + _tau;
          final k = 120 * r * c.depth;
          c.vx += math.cos(c.heading) * k; c.vy += math.sin(c.heading) * k; c.startled = time + 0.8;
        case 3:
          c.m = 1; c.aim = _group + c.bias * 0.06; c.until = time + 0.25 + 0.3 * r; c.startled = c.until;
        case 4:
          if (!c.leaping) {
            final len = c.span * 2.0 * tune.k[1] * (1 + r), h = math.atan2(uy, ux);
            c.leaping = true; c.s = 0; c.fx = c.x; c.fy = c.y; c.tx = c.x + math.cos(h) * len; c.ty = c.y + math.sin(h) * len; c.heading = h; c.dur = 0.45; c.startled = time + c.dur;
          }
        case 6:
          if (tune.k[2] > 0) {
            c.aim = math.atan2(uy, ux) + _rf(-0.35, 0.35); c.b = _cruise(c) * (2.5 + 3 * r) * tune.k[2]; c.a = time; c.startled = time + (1 + 1.5 * r) * math.sqrt(tune.k[2]);
            c.vx = math.cos(c.aim) * c.b; c.vy = math.sin(c.aim) * c.b; c.mode = true; c.until = c.startled + _rf(0.3, 1); c.alarm = 1;
          }
        default:
          final k = r * 160 * c.depth;
          c.vx += ux * k; c.vy += uy * k; c.startled = time + _rf(0.6, 1.0);
      }
    }
  }

  _Food? _nearestFood(_Cr c, double range) {
    _Food? best;
    var bd = range;
    for (final f in _food) {
      if (!f.live) continue;
      final d = math.sqrt((f.x - c.x) * (f.x - c.x) + (f.y - c.y) * (f.y - c.y));
      if (d < bd) { bd = d; best = f; }
    }
    return best;
  }

  void _leap(_Cr c, double dir, double power) {
    final len = c.span * (1.2 + 0.8 * _rnd()) * tune.k[1] * power;
    c.leaping = true; c.s = 0; c.fx = c.x; c.fy = c.y; c.tx = c.x + math.cos(dir) * len; c.ty = c.y + math.sin(dir) * len; c.heading = dir; c.dur = 0.5 / math.max(0.4, tune.speed);
  }

  // ------------------------------------------------------------------------------------------- behaviour
  void _update(_Cr c, double dt) {
    final k = tune.k, cru = _cruise(c);
    switch (animalIndex) {
      case 0:
        _begin();
        _steer(c, _group + c.bias * 0.06, cru, 3.0);
        final r = math.sqrt(dt) * 130 * 1.3 * k[0] * (1 - 0.8 * c.glide) * (0.5 + 0.5 * c.depth);
        c.flx += -c.flx * 3 * dt + (_rnd() * 2 - 1) * r; c.fly += -c.fly * 3 * dt + (_rnd() * 2 - 1) * r;
        _ax += c.flx; _ay += c.fly;
        final h = math.max(0, -math.sin(c.phase)) * (1 - c.glide);
        _ax += math.cos(c.heading) * h * cru * 1.4; _ay += math.sin(c.heading) * h * cru * 1.4;
        _separate(c);
        final sp = _move(c, dt, cru * 2.2);
        if (_passed(c, c.span)) _reenter(c);
        if (sp > 6) _face(c, dt, 7, math.atan2(c.vy, c.vx));
        if (c.glide < 0.5 && time > c.glideUntil && sp > cru * 0.5 && _rnd() < 0.35 * k[1] * dt) c.glideUntil = time + _rf(0.5, 1.4);
        c.glide += ((time < c.glideUntil ? 1 : 0) - c.glide) * math.min(1, dt * 6);
        final cc = _clamp(sp / (cru * 2), 0, 1);
        c.phase += dt * _tau * 2.6 * k[2] * (0.8 + 0.6 * cc) * (1 - 0.9 * c.glide);
        final d = math.pow(0.5 + 0.5 * math.cos(c.phase), 0.8);
        c.open = 0.1 + 0.9 * (d * (1 - c.glide) + 0.96 * c.glide);
      case 1:
        final f = _nearestFood(c, k[2]);
        final eager = f != null ? 0.25 + 0.75 * 0.6 : 0.0;
        var want = f != null ? math.atan2(f.y - c.y, f.x - c.x) : _group + c.bias * 0.06 + k[0] * 0.6 * math.sin(time * 0.35 + c.id * 1.7);
        _begin();
        _separate(c, 120, 0.5);
        if (_ax != 0 || _ay != 0) want = math.atan2(math.sin(want) * cru + _ay * 0.3, math.cos(want) * cru + _ax * 0.3);
        final turn = _mix(0.9 * 2.0, 2.6, eager) * dt;
        c.heading += _clamp(_angDiff(c.heading, want), -turn, turn);
        final sp = cru * _mix(0.85 + 0.25 * math.sin(time * 0.5 + c.id), 1.8, eager);
        c.vx = math.cos(c.heading) * sp; c.vy = math.sin(c.heading) * sp; c.x += c.vx * dt; c.y += c.vy * dt;
        c.phase += dt * (2 + sp / 25) * k[1];
        final seg = c.span / 7;
        c.nodes[0] = c.x; c.nodes[1] = c.y;
        var base = c.heading + _pi;
        for (var i = 1; i < 8; i++) {
          var p = math.atan2(c.nodes[i * 2 + 1] - c.nodes[i * 2 - 1], c.nodes[i * 2] - c.nodes[i * 2 - 2]);
          p = base + _clamp(_angDiff(base, p), -0.22, 0.22);
          c.nodes[i * 2] = c.nodes[i * 2 - 2] + math.cos(p) * seg; c.nodes[i * 2 + 1] = c.nodes[i * 2 - 1] + math.sin(p) * seg; base = p;
        }
        if (f != null && math.sqrt((f.x - c.x) * (f.x - c.x) + (f.y - c.y) * (f.y - c.y)) < c.span * 0.12 + 3) { f.live = false; _stamp(f.x, f.y, 1, 0.7); }
        if (_passed(c, c.span * 1.3)) _reenter(c);
      case 2:
        c.phase += dt * _tau * 0.6 * k[0] * (0.9 + 0.2 * c.roll);
        final n = _fract(c.phase / _tau);
        c.squeeze = n < 0.22 ? _smooth(0, 0.22, n) : 1 - _smooth(0.22, 1, n);
        final want = _group + c.bias * 0.06, old = c.heading;
        c.heading += _clamp(_angDiff(c.heading, want), -0.6 * 3 * dt, 0.6 * 3 * dt);
        c.turn += (_angDiff(old, c.heading) / dt - c.turn) * math.min(1, dt * 3);
        _begin();
        final l = n < 0.22 ? 6.2 * cru * k[1] : 0.0;
        _ax += math.cos(c.heading) * l - c.vx * 1.4; _ay += math.sin(c.heading) * l - c.vy * 1.4;
        _separate(c, 120, 0.5);
        _move(c, dt, cru * 3);
        if (_passed(c, c.span * 1.4)) _reenter(c);
      case 3:
        if (time >= c.until) {
          final prev = c.m; // 0 hover, 1 dart, 2 cruise
          c.m = prev == 0 ? 1 : (prev == 1 ? (_rnd() < 0.5 ? 2 : 0) : (_rnd() < 0.35 ? 1 : 0));
          if (c.m == 1) {
            c.until = time + _rf(0.15, 0.45);
            if (prev == 2) c.aim = c.heading + _rf(-0.4, 0.4) * 0.26;
          } else if (c.m == 2) {
            c.until = time + _rf(1.2, 4.5); c.aim = _group + c.bias * 0.06;
          } else {
            c.until = time + math.min(3, math.max(0.15, -math.log(1 - _rnd() * 0.999) * 0.7)) * k[0]; c.aim = _group + _rf(-1, 1) * 0.09;
          }
        }
        _begin();
        if (c.m == 1) {
          _steer(c, c.aim, cru * 4 * k[2], 10);
        } else if (c.m == 2) {
          c.aim += _rf(-1, 1) * dt * 1.2;
          c.aim += (_group - c.aim) * math.min(1, dt * 0.8);
          _steer(c, c.aim, cru * 1.8, 3);
        } else {
          _steer(c, _group, cru * 0.25, 4);
          _ax += math.cos(time * 3 + c.id) * 20; _ay += math.sin(time * 4.3 + c.id * 2) * 20;
        }
        _separate(c, 200, 0.42);
        _move(c, dt, cru * 4.5 * k[2]);
        if (_passed(c, c.span)) _reenter(c);
        if (c.m == 2) {
          _face(c, dt, 4, math.atan2(c.vy, c.vx));
        } else {
          _face(c, dt, c.m == 1 ? 14 : 2.5, c.aim);
        }
        c.phase += dt * _tau * 7 * k[1];
      case 4:
        if (!c.leaping) {
          c.vx = 0; c.vy = 0;
          _face(c, dt, 2.5, c.aim);
          if (time >= c.until) _leap(c, c.aim, 1);
          return;
        }
        c.s += dt / c.dur;
        if (c.s >= 1) {
          c.leaping = false; c.x = c.tx; c.y = c.ty;
          c.until = time + _rf(0.5, 2.2) / (k[0] * tune.speed);
          c.aim = _group + (c.bias + _rf(-0.7, 0.7)) * 0.06;
          _stamp(c.x, c.y, 2, 0.7 * c.depth * tune.trail);
          if (_passed(c, c.span)) _reenter(c);
          return;
        }
        c.x = _mix(c.fx, c.tx, c.s); c.y = _mix(c.fy, c.ty, c.s);
      case 5:
        _begin();
        _steer(c, _group + c.bias * 0.06, cru, 5);
        _separate(c, 150, 0.42);
        final sp = _move(c, dt, cru * 2);
        if (_passed(c, c.span)) _reenter(c);
        if (sp > 4) _face(c, dt, 2.2, math.atan2(c.vy, c.vx));
        if (c.glide < 0.5 && time > c.glideUntil && _rnd() < 0.2 * k[1] * dt) c.glideUntil = time + _rf(1.0, 2.6);
        c.glide += ((time < c.glideUntil ? 1 : 0) - c.glide) * math.min(1, dt * 3);
        c.phase += dt * _tau * 1.1 * k[0] * (1 - 0.85 * c.glide);
      default:
        if (time >= c.until) {
          c.mode = !c.mode || k[1] <= 0;
          c.until = time + (c.mode ? _rf(0.5, 1.6) * k[0] : _rf(0.3, 1.4) * k[1]);
        }
        final fleeing = time < c.startled;
        final h = fleeing ? (time - c.a) / (c.startled - c.a + 0.001) : 1.0, dir = fleeing ? c.aim : _group + c.bias * 0.06;
        _begin();
        if (fleeing) {
          _steer(c, c.aim, math.max(cru, c.b * (1 - h * h)), 8);
        } else {
          _steer(c, dir, c.mode ? cru : 0, 4);
        }
        _separate(c, 170, 0.42);
        final sp = _move(c, dt, fleeing ? math.max(cru * 2, c.b) : cru * 2);
        if (_passed(c, c.span)) _reenter(c);
        final want = dir - c.facing * _pi / 2, tr = (fleeing ? 10 : 3) * dt;
        c.heading += _clamp(_angDiff(c.heading, want), -tr, tr);
        c.gait += dt * sp * 1.0 / math.max(3, c.span * 0.12);
        c.alarm = math.max(0, c.alarm - dt * 0.7);
    }
  }

  /// Moves the world on by [dt] seconds.
  void step(double dt) {
    time += dt;
    _populate(false);
    for (var i = 0; i < count; i++) {
      _cr[i].depth = _depthOf(_cr[i].roll);
      _cr[i].span = _base * _cr[i].depth * tune.size;
    }
    for (final f in _food) {
      if (!f.live) continue;
      f.vx *= math.exp(-dt * 0.8); f.vy *= math.exp(-dt * 0.8); f.x += f.vx * dt; f.y += f.vy * dt;
      if (time - f.born > 9) f.live = false;
    }
    for (var i = 0; i < count; i++) { _update(_cr[i], dt); }
  }

  // ------------------------------------------------------------------------------------------- drawing each animal
  void _butterfly(_Cr c) {
    const dark = [22, 28, 62], wing = [78, 159, 255], hi = [236, 240, 255], edge2 = [30, 50, 120];
    final s = c.span, op = math.max(0.1, c.open), hd = c.heading + 0.06 * math.sin(c.phase), light = 0.6 + 0.4 * c.open;
    final b = _Cr()..x = c.x..y = c.y..span = s..heading = hd;
    for (var sd = -1; sd <= 1; sd += 2) {
      var p = _toW(b, 0.12, 0.2 * sd * op);
      _ell(p.$1, p.$2, 0.3 * s, 0.27 * s * op, hd + sd * 0.35, dark, _Kind.edge, c.depth, c.id, light);
      _ell(p.$1, p.$2, 0.22 * s, 0.2 * s * op, hd + sd * 0.35, wing, _Kind.body, c.depth, c.id, light);
      p = _toW(b, -0.14, 0.15 * sd * op);
      _ell(p.$1, p.$2, 0.2 * s, 0.17 * s * op, hd - sd * 0.5, dark, _Kind.edge, c.depth, c.id, light);
      _ell(p.$1, p.$2, 0.14 * s, 0.11 * s * op, hd - sd * 0.5, edge2, _Kind.body, c.depth, c.id, light);
      p = _toW(b, 0.2, 0.28 * sd * op);
      _dot(p.$1, p.$2, '.', hi, c.depth);
    }
    final p0 = _toW(b, -0.2, 0), p1 = _toW(b, 0.22, 0);
    _cap(p0.$1, p0.$2, p1.$1, p1.$2, math.max(1.2, 0.035 * s), _inkC, _Kind.edge, c.depth, c.id);
    final r = 0.012 * math.sin(time * 3 + c.id);
    for (var sd = -1; sd <= 1; sd += 2) {
      final a = _toW(b, 0.22, 0.01 * sd), e = _toW(b, 0.4 + r, (0.12 + r) * sd);
      _line(a.$1, a.$2, e.$1, e.$2, _inkC, c.depth, last: s > 36 ? 'o' : null, light: 1.6);
    }
    final h = math.max(0, -math.sin(c.phase)) * (1 - c.glide);
    for (var sd = -1; sd <= 1; sd += 2) {
      final p = _toW(b, 0.1, 0.3 * sd * c.open);
      _shed(p.$1, p.$2, (0.02 + 0.1 * h) * c.depth);
    }
  }

  void _koi(_Cr c) {
    const white = [236, 236, 230], orange = [232, 96, 40], gold = [244, 196, 44], black = [28, 26, 30], red = [214, 60, 44];
    final s = c.span, n = c.nodes;
    List<int> colorAt(int i) {
      final v = _hash01(c.id, i ~/ 2, 5);
      switch (c.variety) {
        case 0: return v > 0.55 ? orange : white;
        case 1: return gold;
        case 2: return v > 0.72 ? black : (v > 0.4 ? orange : white);
        default: return v > 0.6 ? white : red;
      }
    }
    final wag = math.sin(c.phase) * 0.55;
    final ta = math.atan2(n[15] - n[13], n[14] - n[12]);
    _ell(n[14] + math.cos(ta + wag * 0.4) * s * 0.1, n[15] + math.sin(ta + wag * 0.4) * s * 0.1, s * 0.13, s * 0.07, ta + wag, white, _Kind.light, c.depth, c.id);
    for (var i = 7; i >= 0; i--) {
      final t = i / 7.0, w = s * 0.095 * math.pow(math.sin(_pi * (0.12 + 0.88 * math.pow(t, 0.8))), 0.7) * (1 - 0.45 * t);
      final j = i > 0 ? i - 1 : 0;
      _cap(n[j * 2], n[j * 2 + 1], n[i * 2], n[i * 2 + 1], math.max(1.4, w), colorAt(i), _Kind.body, c.depth, c.id);
      if (i == 1) {
        for (var sd = -1; sd <= 1; sd += 2) {
          final ha = math.atan2(n[1] - n[5], n[0] - n[4]);
          _ell(n[2] + math.cos(ha + sd * 1.5) * s * 0.09, n[3] + math.sin(ha + sd * 1.5) * s * 0.09, s * 0.08, s * 0.04, ha + sd * (0.9 + 0.3 * math.sin(c.phase * 0.7)), white, _Kind.light, c.depth, c.id);
        }
      }
      if (i % 3 == 0) _shed(n[i * 2], n[i * 2 + 1], 0.03 * c.depth);
    }
    final ha = math.atan2(n[1] - n[3], n[0] - n[2]);
    for (var sd = -1; sd <= 1; sd += 2) {
      _spot(n[0] + math.cos(ha) * s * 0.03 + math.cos(ha + _pi / 2) * sd * 3.2, n[1] + math.sin(ha) * s * 0.03 + math.sin(ha + _pi / 2) * sd * 3.2, 'o', black, white, c.depth);
    }
  }

  void _jelly(_Cr c) {
    const pink = [226, 130, 255], rim = [170, 90, 235], tent = [190, 150, 255], glowC = [255, 235, 255];
    final s = c.span, sq = c.squeeze, k = tune.k;
    final n = _fract(c.phase / _tau), glow = (n < 0.16 ? _smooth(0, 0.16, n) : math.exp(-(n - 0.16) * 4.5)) * k[1] * 0.4;
    final b = _clamp(-c.turn * 0.5, -0.5, 0.5);
    const tn = 6;
    for (var i = 0; i < tn; i++) {
      final v = (i / (tn - 1) - 0.5) * 2 * 0.3 * 0.6 * (1 - 0.2 * sq);
      final len = 0.55 * k[2] * (0.75 + 0.35 * _hash01(c.id, i, 4)) * (1 - 0.12 * sq);
      const u0 = -0.06;
      var p = _toW(c, u0, v);
      for (var j = 1; j <= 5; j++) {
        final L = j / 5.0, u1 = u0 - L * len, v1 = v + math.sin(time * 2.0 + i * 0.9 + L * 5.0 - b * 3) * 0.05 * L + b * L * 0.1;
        final q = _toW(c, u1, v1);
        _line(p.$1, p.$2, q.$1, q.$2, tent, c.depth, light: 0.9 - 0.3 * L);
        p = q;
      }
      final f = _toW(c, u0 - len * 0.5, v);
      _shed(f.$1, f.$2, 0.02 * c.depth);
    }
    var p = _toW(c, 0.02, 0);
    final ru = 0.17 * (1 + 0.14 * sq) * s, rv = 0.3 * (1 - 0.2 * sq) * s;
    _ell(p.$1, p.$2, ru * 1.15, rv * 1.12, c.heading, rim, _Kind.edge, c.depth, c.id, 0.8);
    _ell(p.$1, p.$2, ru, rv, c.heading, pink, _Kind.body, c.depth, c.id, 0.85 + glow);
    p = _toW(c, 0.06, 0);
    _ell(p.$1, p.$2, ru * 0.45, rv * 0.55, c.heading, glowC, _Kind.light, c.depth, c.id, 1.0);
    for (var i = -1; i <= 1; i++) {
      final o = _toW(c, -0.06, i * 0.08);
      _ell(o.$1, o.$2, 0.05 * s, 0.05 * s, 0, pink, _Kind.light, c.depth, c.id, 1.2);
    }
  }

  void _dragon(_Cr c) {
    const body = [50, 200, 130], head = [40, 160, 110], wing = [226, 236, 214], red = [236, 120, 70];
    final s = c.span, beat = math.cos(c.phase).abs();
    final p0 = _toW(c, 0.2, 0), p1 = _toW(c, -0.32, 0);
    final perp = c.m == 1 ? 0.1 : 0.3;
    for (var sd = -1; sd <= 1; sd += 2) {
      for (var p = 0; p < 2; p++) {
        final u = 0.1 - p * 0.1, w = _toW(c, u, 0.02 * sd);
        final sp = (0.15 + 0.15 * beat * (p == 1 ? 0.8 : 1)) * s;
        final cx = w.$1 + (-math.sin(c.heading) * sd) * sp * 0.5, cy = w.$2 + (math.cos(c.heading) * sd) * sp * 0.5;
        _ell(cx, cy, 0.09 * s, sp * 0.5 + 1, c.heading + sd * (0.12 + perp * 0.2) * (p == 1 ? -1 : 1), wing, _Kind.light, c.depth, c.id, 0.9);
      }
    }
    _cap(p0.$1, p0.$2, p1.$1, p1.$2, math.max(1.0, 0.03 * s), body, _Kind.edge, c.depth, c.id);
    _dot(p1.$1, p1.$2, '~', red, c.depth);
    _spot(p0.$1 + math.cos(c.heading) * 2, p0.$2 + math.sin(c.heading) * 2, 'O', head, wing, c.depth);
    final h = _toW(c, 0.08, 0);
    _shed(h.$1, h.$2, 0.01 * c.depth);
  }

  void _frog(_Cr c) {
    const green = [96, 200, 100], dark = [40, 110, 60], eye = [236, 242, 200], blk = [10, 24, 14], shadow = [14, 30, 24];
    final air = c.leaping ? math.sin(_pi * c.s) : 0.0, k = tune.k;
    final s = c.span * (1 + 0.55 * air * k[2] * 0.7);
    if (c.leaping) {
      final p = _toW(c, 0, 0);
      _ell(p.$1, p.$2, c.span * 0.2, c.span * 0.15, c.heading, shadow, _Kind.light, c.depth, c.id, 0.6);
    }
    final b = _Cr()..x = c.x..y = c.y - c.span * 0.28 * air * k[2]..span = s..heading = c.heading;
    final leg = c.leaping ? 0.5 + 0.5 * air : 0.0;
    for (var sd = -1; sd <= 1; sd += 2) {
      final a = _toW(b, -0.08, 0.12 * sd), m = _toW(b, -0.2 - 0.15 * leg, 0.22 * sd), e = _toW(b, -0.3 - 0.3 * leg, 0.16 * sd);
      _line(a.$1, a.$2, m.$1, m.$2, dark, c.depth, light: 1.2);
      _line(m.$1, m.$2, e.$1, e.$2, dark, c.depth, light: 1.2);
      final f0 = _toW(b, 0.12, 0.13 * sd), f1 = _toW(b, 0.2, 0.2 * sd);
      _line(f0.$1, f0.$2, f1.$1, f1.$2, dark, c.depth, light: 1.2);
    }
    var p = _toW(b, -0.02, 0);
    _ell(p.$1, p.$2, 0.22 * s, 0.15 * s, c.heading, green, _Kind.body, c.depth, c.id);
    final hd = _toW(b, 0.2, 0);
    _ell(hd.$1, hd.$2, 0.12 * s, 0.12 * s, c.heading, green, _Kind.body, c.depth, c.id);
    _ell(p.$1, p.$2, 0.07 * s, 0.07 * s, c.heading, dark, _Kind.edge, c.depth, c.id, 0.8);
    for (var sd = -1; sd <= 1; sd += 2) {
      final e = _toW(b, 0.23, 0.08 * sd);
      _spot(e.$1, e.$2, 'o', eye, blk, c.depth);
    }
  }

  void _crane(_Cr c) {
    const white = [236, 238, 242], tip = [40, 40, 48], leg = [78, 78, 92], red = [226, 36, 36], beak = [196, 196, 150];
    final s = c.span;
    final flap = math.pow(0.5 + 0.5 * math.cos(c.phase), 0.8).toDouble();
    var arm = math.max(0.12, 0.25 + 0.75 * (flap * (1 - c.glide) + c.glide));
    if (tune.k[2] > 0.5) arm = math.max(0.15, math.cos(c.phase) * (1 - c.glide) + c.glide * 0.9);
    for (var sd = -1; sd <= 1; sd += 2) {
      final a = _toW(c, -0.25, 0.02 * sd), e = _toW(c, -0.72, 0.04 * sd + 0.02 * math.sin(c.phase * 0.5));
      _line(a.$1, a.$2, e.$1, e.$2, leg, c.depth, light: 1.0);
    }
    for (var sd = -1; sd <= 1; sd += 2) {
      var p = _toW(c, 0.0, (0.08 + 0.22 * arm) * sd);
      _ell(p.$1, p.$2, 0.2 * s, (0.06 + 0.3 * arm) * s, c.heading + sd * 0.1, white, _Kind.body, c.depth, c.id, 0.95);
      p = _toW(c, -0.1, (0.1 + 0.46 * arm) * sd);
      _ell(p.$1, p.$2, 0.12 * s, (0.04 + 0.14 * arm) * s, c.heading, tip, _Kind.edge, c.depth, c.id, 0.9);
    }
    final bd = _toW(c, 0, 0);
    _ell(bd.$1, bd.$2, 0.25 * s, 0.1 * s, c.heading, white, _Kind.body, c.depth, c.id);
    final nk = _toW(c, 0.22, 0), hd = _toW(c, 0.46, 0.03 * math.sin(time * 1.3 + c.id));
    _cap(nk.$1, nk.$2, hd.$1, hd.$2, 1.6, white, _Kind.body, c.depth, c.id);
    _spot(hd.$1, hd.$2, 'o', red, white, c.depth);
    final bk = _toW(c, 0.58, 0.03);
    _line(hd.$1, hd.$2, bk.$1, bk.$2, beak, c.depth, last: '>', light: 1.1);
  }

  void _crab(_Cr c) {
    const body = [204, 82, 52], light = [232, 132, 92], darkr = [140, 46, 32], claw = [214, 92, 56], legc = [186, 72, 44], eyef = [255, 252, 246], eyeb = [14, 10, 10];
    const lu = [0.07, -0.01, -0.08, -0.14];
    final s = c.span;
    for (var sd = -1; sd <= 1; sd += 2) {
      for (var i = 0; i < 4; i++) {
        final d = c.gait + i * _pi * 0.5 + (sd > 0 ? _pi : 0), lift = math.max(0, math.sin(d));
        final a = _toW(c, lu[i], 0.2 * sd), m = _toW(c, lu[i] + 0.04, (0.36 - 0.03 * lift) * sd), e = _toW(c, lu[i] + 0.08 * math.cos(d), (0.52 - 0.06 * lift) * sd);
        _line(a.$1, a.$2, m.$1, m.$2, legc, c.depth);
        _line(m.$1, m.$2, e.$1, e.$2, legc, c.depth);
        if (lift < 0.05 && math.cos(d) > 0.9) _shed(e.$1, e.$2, 0.12 * c.depth);
      }
    }
    var p = _toW(c, 0, 0);
    _ell(p.$1, p.$2, 0.19 * s, 0.29 * s, c.heading, darkr, _Kind.edge, c.depth, c.id, 0.9);
    _ell(p.$1, p.$2, 0.15 * s, 0.25 * s, c.heading, body, _Kind.body, c.depth, c.id);
    final al = c.alarm;
    for (var sd = -1; sd <= 1; sd += 2) {
      final a = _toW(c, 0.12, 0.17 * sd), m = _toW(c, 0.27 + 0.07 * al, 0.25 * sd), t = _toW(c, 0.34 + 0.08 * al, 0.2 * sd);
      _line(a.$1, a.$2, m.$1, m.$2, claw, c.depth, light: 1.2);
      _ell(t.$1, t.$2, 0.11 * s, 0.075 * s, c.heading + sd * 0.55, claw, _Kind.body, c.depth, c.id, 1.0);
      final ey = _toW(c, 0.2, 0.07 * sd);
      _spot(ey.$1, ey.$2, 'o', eyef, eyeb, c.depth);
    }
    p = _toW(c, 0.02, 0);
    _dot(p.$1, p.$2, '-', light, c.depth);
  }

  void _diffuse(double dt) {
    final o = math.exp(-dt * tune.trailFade);
    for (var r = 0; r < asciiRows; r++) {
      for (var h = 0; h < asciiCols; h++) {
        final l = r * asciiCols + h;
        final c = h > 0 ? energy[l - 1] : energy[l], d = h < asciiCols - 1 ? energy[l + 1] : energy[l];
        final u = r > 0 ? energy[l - asciiCols] : energy[l], b = r < asciiRows - 1 ? energy[l + asciiCols] : energy[l];
        _energyTmp[l] = (energy[l] * 4 + c + d + u + b) * 0.125 * o;
      }
    }
    energy.setRange(0, asciiCells, _energyTmp);
  }

  /// Fills the cell arrays for the current state.
  void render(double dt) {
    _diffuse(dt);
    flag.fillRange(0, asciiCells, 0);
    final idx = List<int>.generate(count, (i) => i)..sort((a, b) => _cr[a].roll.compareTo(_cr[b].roll));
    for (final k in idx) {
      final c = _cr[k];
      switch (animalIndex) {
        case 0: _butterfly(c);
        case 1: _koi(c);
        case 2: _jelly(c);
        case 3: _dragon(c);
        case 4: _frog(c);
        case 5: _crane(c);
        default: _crab(c);
      }
    }
    const pellet = [236, 200, 140];
    for (final f in _food) {
      if (f.live) _dot(f.x, f.y, 'o', pellet, 1);
    }
    for (var i = 0; i < asciiCells; i++) {
      trailCol[i] = 0;
      final e = energy[i];
      if (e < 0.12 || flag[i] == 2) continue;
      final a = _clamp(e * 0.9, 0, 1) * (0.75 + 0.25 * math.sin(time * 5 + _hash01(i % asciiCols, i ~/ asciiCols, 3) * 40));
      trailCol[i] = _tint(animal.trail, 1, 0, 1 - a * 0.8);
    }
  }
}
