// ASCII animals in the app: a live preview of the same simulation the Hub runs (ascii_engine.dart), tap-to-touch, every knob
// as a slider, and "Show on the Hub". Reverse engineered from the "ascii animals" web page (pocketstudio.design).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/connection.dart';
import '../core/errors.dart';
import '../theme.dart';
import 'ascii_engine.dart';

const _prefKey = 'ascii_animals';

/// What the Hub is told to show: the animal and its whole tuning. A Hub with older firmware answers "unknown cmd".
Map<String, dynamic> asciiShowCommand(AsciiAnimal a, AsciiTune t) => {'cmd': 'ascii', 'animal': a.id, ...t.toCommand(a)};

/// A touch at (fx, fy), each 0..1 across the screen: koi are fed, everything else is startled.
Map<String, dynamic> asciiTapCommand(double fx, double fy) => {'cmd': 'ascii', 'tap': [double.parse(fx.toStringAsFixed(3)), double.parse(fy.toStringAsFixed(3))]};

/// The saved choice: which animal, and the tuning of each one. Damaged data never throws.
class AsciiSaved {
  AsciiSaved({this.animal = 'butterflies', Map<String, Map<String, double>>? tunes}) : tunes = tunes ?? {};
  String animal;
  final Map<String, Map<String, double>> tunes;

  AsciiTune tuneFor(AsciiAnimal a) {
    final t = a.defaults();
    final saved = tunes[a.id];
    if (saved != null) {
      for (final k in [...asciiCommonKnobs, ...a.knobs]) {
        final v = saved[k.key];
        if (v != null && v.isFinite) t.set(k.key, v.clamp(k.min, k.max).toDouble(), a);
      }
      final c = saved['corner'];
      if (c != null) t.corner = c != 0;
    }
    return t;
  }

  void remember(AsciiAnimal a, AsciiTune t) {
    tunes[a.id] = {for (final k in [...asciiCommonKnobs, ...a.knobs]) k.key: t.get(k.key, a), 'corner': t.corner ? 1 : 0};
  }

  Map<String, dynamic> toJson() => {'animal': animal, 'tunes': tunes};

  static AsciiSaved fromJson(Object? j) {
    final s = AsciiSaved();
    try {
      if (j is Map) {
        final a = j['animal'];
        if (a is String && asciiAnimalById(a) != null) s.animal = a;
        final t = j['tunes'];
        if (t is Map) {
          for (final e in t.entries) {
            if (e.key is String && e.value is Map) {
              s.tunes[e.key as String] = {for (final v in (e.value as Map).entries) if (v.key is String && v.value is num) v.key as String: (v.value as num).toDouble()};
            }
          }
        }
      }
    } catch (_) {}
    return s;
  }
}

Future<AsciiSaved> loadAsciiSaved() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
    if (raw != null) return AsciiSaved.fromJson(jsonDecode(raw));
  } catch (_) {}
  return AsciiSaved();
}

Future<void> saveAsciiSaved(AsciiSaved s) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_prefKey, jsonEncode(s.toJson()));
  } catch (_) {}
}

/// Owns the simulation so the screen and the painter share it.
class AsciiController extends ChangeNotifier {
  AsciiController({AsciiSaved? saved, int seed = 2463534242}) : world = AsciiWorld(seed: seed) {
    if (saved != null) {
      final a = asciiAnimalById(saved.animal);
      if (a != null) {
        world.setAnimal(asciiAnimals.indexOf(a));
        world.tune = saved.tuneFor(a);
        world.tuneChanged();
      }
    }
  }
  final AsciiWorld world;
  AsciiAnimal get animal => world.animal;
  AsciiTune get tune => world.tune;

  void chooseAnimal(AsciiAnimal a, AsciiSaved saved) {
    world.setAnimal(asciiAnimals.indexOf(a));
    world.tune = saved.tuneFor(a);
    world.tuneChanged();
    notifyListeners();
  }

  void changed() {
    world.tuneChanged();
    notifyListeners();
  }

  void reset() {
    world.tune = animal.defaults();
    world.tuneChanged();
    notifyListeners();
  }

  /// A tap at (fx, fy) as a fraction of the screen.
  void tap(double fx, double fy) => world.startle(fx.clamp(0.0, 1.0) * (asciiW - 1), fy.clamp(0.0, 1.0) * (asciiH - 1));

  double _carry = 0;
  /// Advances the simulation by [dt] seconds in steps no longer than 1/50 s, then draws the cells.
  void advance(double dt) {
    var left = dt.clamp(0.0, 0.1) + _carry;
    while (left >= 0.02) {
      world.step(0.02);
      left -= 0.02;
    }
    _carry = left;
    world.render(dt.clamp(0.001, 0.1));
  }

  /// One calm frame for reduced motion: let the animals settle into view, then draw.
  void still() {
    for (var i = 0; i < 150; i++) {
      world.step(0.02);
    }
    world.render(0.02);
  }
}

/// The animals as coloured character cells at the display's 160 x 128 proportions. Tapping calls [onTap] with the position as
/// a 0..1 fraction of the screen and startles (or feeds) the animals on the phone at once.
class AsciiAnimalsView extends StatefulWidget {
  const AsciiAnimalsView({super.key, required this.controller, this.onTap, this.interactive = true});
  final AsciiController controller;
  final void Function(double fx, double fy)? onTap;
  final bool interactive;
  @override
  State<AsciiAnimalsView> createState() => _AsciiAnimalsViewState();
}

class _AsciiAnimalsViewState extends State<AsciiAnimalsView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<int> _frame = ValueNotifier(0);
  Duration _last = Duration.zero;
  bool _still = false;

  void _tick(Duration t) {
    final dt = _last == Duration.zero ? 0.016 : (t - _last).inMicroseconds / 1e6;
    _last = t;
    widget.controller.advance(dt);
    _frame.value++;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = reducedMotion(context);
    if (_still) {
      _ticker.stop();
      _last = Duration.zero;
      widget.controller.still();
      _frame.value++;
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(AsciiAnimalsView old) {
    super.didUpdateWidget(old);
    if (_still) {
      widget.controller.still();
      _frame.value++;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _tap(Offset p, Size size) {
    final fx = (p.dx / size.width).clamp(0.0, 1.0), fy = (p.dy / size.height).clamp(0.0, 1.0);
    HapticFeedback.selectionClick();
    widget.controller.tap(fx, fy);
    if (_still) {
      widget.controller.still();
      _frame.value++;
    }
    widget.onTap?.call(fx, fy);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            final painter = CustomPaint(size: size, painter: AsciiAnimalsPainter(widget.controller.world, _frame));
            if (!widget.interactive) return painter;
            return Semantics(
              button: true,
              label: 'The animals. Tap to startle them, or to feed the koi.',
              child: GestureDetector(
                key: const ValueKey('ascii-touch'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _tap(d.localPosition, size),
                child: ExcludeSemantics(child: painter),
              ),
            );
          },
        ),
      );
}

/// Draws the grid first, then the cell arrays: each solid cell is a tile with a 3 x 5 pixel glyph (the Hub's own font), thin cells are
/// just a glyph, trail cells a small square. Everything is drawn in the display's 160 x 128 pixels and scaled up.
class AsciiAnimalsPainter extends CustomPainter {
  AsciiAnimalsPainter(this.world, Listenable repaint) : super(repaint: repaint);
  final AsciiWorld world;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / asciiW, sy = size.height / asciiH;
    final p = Paint()..isAntiAlias = false;
    p.color = Color(asciiColor565(world.bg));
    canvas.drawRect(Offset.zero & size, p);
    final g = world.tune.grid;
    if (g > 0.01) {
      p.color = Color.fromARGB(255, (6 + 14 * g).clamp(0, 255).toInt(), (8 + 17 * g).clamp(0, 255).toInt(), (16 + 26 * g).clamp(0, 255).toInt());
      for (var x = 0; x < asciiW; x += asciiCellW) {
        canvas.drawRect(Rect.fromLTWH(x * sx, 0, sx.clamp(1.0, 99.0), size.height), p);
      }
      for (var y = 0; y < asciiH; y += asciiCellH) {
        canvas.drawRect(Rect.fromLTWH(0, y * sy, size.width, sy.clamp(1.0, 99.0)), p);
      }
    }
    for (var i = 0; i < asciiCells; i++) {
      final cx = (i % asciiCols) * asciiCellW, cy = (i ~/ asciiCols) * asciiCellH, f = world.flag[i];
      if (f == 0) {
        final t = world.trailCol[i];
        if (t != 0) {
          p.color = Color(asciiColor565(t));
          if (world.energy[i] > 0.6) {
            canvas.drawRect(Rect.fromLTWH(cx * sx, (cy + 1) * sy, 4 * sx, 4 * sy), p);
          } else {
            canvas.drawRect(Rect.fromLTWH((cx + 1) * sx, (cy + 2) * sy, 2 * sx, 2 * sy), p);
          }
        }
        continue;
      }
      if (f == 2) {
        p.color = Color(asciiColor565(world.fill[i]));
        canvas.drawRect(Rect.fromLTWH((cx + 1) * sx, (cy + 1) * sy, (asciiCellW - 1) * sx, (asciiCellH - 1) * sy), p);
      }
      final bits = asciiGlyphBits(world.glyph[i]);
      if (bits == 0) continue;
      p.color = Color(asciiColor565(world.col[i]));
      for (var r = 0; r < 5; r++) {
        for (var c = 0; c < 3; c++) {
          if (bits & (1 << ((4 - r) * 3 + (2 - c))) != 0) canvas.drawRect(Rect.fromLTWH((cx + 1 + c) * sx, (cy + 1 + r) * sy, sx, sy), p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(AsciiAnimalsPainter old) => old.world != world;
}

/// Small non-interactive version for the scene library and dashboard.
class AsciiPreview extends StatefulWidget {
  const AsciiPreview({super.key});
  @override
  State<AsciiPreview> createState() => _AsciiPreviewState();
}

class _AsciiPreviewState extends State<AsciiPreview> {
  AsciiController? _c;
  @override
  void initState() {
    super.initState();
    loadAsciiSaved().then((s) {
      if (mounted) setState(() => _c = AsciiController(saved: s));
    });
  }

  @override
  Widget build(BuildContext context) => ColoredBox(color: const Color(0xFF060810), child: _c == null ? null : AsciiAnimalsView(controller: _c!, interactive: false));
}

// ------------------------------------------------------------------------------------------------ the screen
class AsciiScreen extends StatefulWidget {
  const AsciiScreen({super.key});
  @override
  State<AsciiScreen> createState() => _AsciiScreenState();
}

class _AsciiScreenState extends State<AsciiScreen> {
  AsciiController? _c;
  final AsciiSaved _saved = AsciiSaved();
  bool _live = false;      // the Hub is showing the animals, so changes and touches are sent to it
  bool _sending = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    loadAsciiSaved().then((s) {
      if (!mounted) return;
      _saved.animal = s.animal;
      _saved.tunes.addAll(s.tunes);
      setState(() => _c = AsciiController(saved: _saved));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _c?.dispose();
    super.dispose();
  }

  void _persist() {
    final c = _c!;
    _saved.animal = c.animal.id;
    _saved.remember(c.animal, c.tune);
    saveAsciiSaved(_saved);
  }

  void _choose(AsciiAnimal a) {
    final c = _c!;
    if (a.id == c.animal.id) return;
    HapticFeedback.selectionClick();
    _saved.remember(c.animal, c.tune);
    c.chooseAnimal(a, _saved);
    _persist();
    setState(() {});
    if (_live) _sendNow();
  }

  void _tuned(String key, double v, {bool end = false}) {
    final c = _c!;
    c.tune.set(key, v, c.animal);
    c.changed();
    setState(() {});
    if (end) _persist();
    if (_live) {
      _debounce?.cancel();
      _debounce = Timer(Duration(milliseconds: end ? 30 : 250), _sendTune);
    }
  }

  void _corner(bool v) {
    final c = _c!;
    c.tune.corner = v;
    c.changed();
    setState(() {});
    _persist();
    if (_live) _sendTune();
  }

  void _reset() {
    final c = _c!;
    HapticFeedback.selectionClick();
    c.reset();
    _persist();
    setState(() {});
    if (_live) _sendTune();
  }

  /// Quiet: when the Hub is not reachable the phone still shows the animals.
  void _sendTune() {
    final hub = HubScope.read(context);
    if (!hub.canSend || _c == null) return;
    hub.trySend({'cmd': 'ascii', ..._c!.tune.toCommand(_c!.animal)}, dedupeKey: 'ascii-tune');
  }

  void _touchHub(double fx, double fy) {
    if (!_live) return;
    final hub = HubScope.read(context);
    if (!hub.canSend) return;
    hub.trySend(asciiTapCommand(fx, fy), dedupeKey: 'ascii-tap');
  }

  Future<void> _sendNow() async {
    final hub = HubScope.read(context);
    final c = _c!;
    setState(() => _sending = true);
    try {
      final r = await hub.send(asciiShowCommand(c.animal, c.tune), idempotent: true, timeout: const Duration(seconds: 6));
      if (r['ok'] != true) {
        final msg = '${r['error'] ?? ''}';
        if (msg.contains('unknown cmd')) throw const AsciiNeedsUpdate();
        throw HubException(HubError.deviceError, msg.isEmpty ? 'device error' : msg, '${r['errorCode'] ?? ''}');
      }
      if (mounted) {
        setState(() => _live = true);
        toast(context, '${c.animal.label} is on the Hub. Tap the screen to play with both.');
      }
    } on AsciiNeedsUpdate {
      if (mounted) toast(context, 'Update the Hub firmware to show the animals');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send: ${friendlyError(e)}');
    }
    if (mounted) setState(() => _sending = false);
  }

  Widget _slider(AsciiKnob k) {
    final c = _c!, a = c.animal;
    final v = c.tune.get(k.key, a).clamp(k.min, k.max).toDouble();
    final divisions = ((k.max - k.min) / k.step).round().clamp(1, 600);
    final digits = k.step >= 1 ? 0 : (k.step >= 0.05 ? 2 : 2);
    return Semantics(
      label: '${k.label}. ${k.hint}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(k.label, style: Ty.bodyStrong)), Text(v.toStringAsFixed(digits), style: Ty.body.copyWith(color: HubColors.muted))]),
        Slider(key: ValueKey('ascii-${k.key}'), value: v, min: k.min, max: k.max, divisions: divisions, onChanged: (x) => _tuned(k.key, x), onChangeEnd: (x) => _tuned(k.key, x, end: true)),
        Text(k.hint, style: Ty.meta.copyWith(color: HubColors.muted)),
        const SizedBox(height: 10),
      ]),
    );
  }

  Widget _group(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 8, bottom: 8), child: Text(title, style: Ty.title)),
          ...children,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ASCII animals'),
        actions: [TextButton(key: const ValueKey('ascii-reset'), onPressed: c == null ? null : _reset, child: const Text('Reset'))],
      ),
      body: c == null
          ? StateView.loading('Loading the animals')
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(children: [
                  DisplayFrame(child: ColoredBox(color: const Color(0xFF060810), child: AsciiAnimalsView(controller: c, onTap: _touchHub))),
                  const SizedBox(height: 8),
                  Hint(c.animal.id == 'koi' ? 'Tap the water to drop food. The koi swim to it.' : 'Tap the screen: they startle. ${_live ? 'The Hub reacts too.' : 'Show it on the Hub to touch both.'}'),
                ]),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  key: const ValueKey('ascii-animals'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: asciiAnimals.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final a = asciiAnimals[i];
                    return Choice(
                      key: ValueKey('ascii-animal-${a.id}'),
                      selected: a.id == c.animal.id,
                      onTap: () => _choose(a),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      radius: Rad.control,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: Color(0xFF000000 | a.swatch), shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text(a.label, style: Ty.body),
                      ]),
                    );
                  },
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('ascii-controls'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    _group(c.animal.label, [for (final k in c.animal.knobs) _slider(k)]),
                    _group('Movement', [
                      for (final k in asciiCommonKnobs.where((k) => const ['density', 'speed', 'size'].contains(k.key))) _slider(k),
                      SwitchListTile(
                        key: const ValueKey('ascii-corner'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Corner to corner', style: Ty.bodyStrong),
                        subtitle: Text('Cross from the bottom-left to the top-right. Turn off to set the direction yourself.', style: Ty.meta.copyWith(color: HubColors.muted)),
                        value: c.tune.corner,
                        onChanged: _corner,
                      ),
                      if (!c.tune.corner) _slider(asciiCommonKnobs.firstWhere((k) => k.key == 'direction')),
                    ]),
                    _group('Look', [for (final k in asciiCommonKnobs.where((k) => const ['trail', 'trailFade', 'hue', 'sparkle', 'fog', 'shimmer', 'grid'].contains(k.key))) _slider(k)]),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('ascii-show'),
                      onPressed: _sending || !hub.canSend ? null : _sendNow,
                      icon: const Icon(Icons.send_rounded, size: 20),
                      label: Text(hub.canSend ? (_live ? 'Send again' : 'Show on the Hub') : 'Connect a Hub to show it'),
                    ),
                  ),
                ),
              ),
            ]),
    );
  }
}

class AsciiNeedsUpdate implements Exception {
  const AsciiNeedsUpdate();
  @override
  String toString() => 'Update the Hub firmware to show the animals';
}
