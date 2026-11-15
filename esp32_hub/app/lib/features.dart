import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'fft.dart';
import 'phone.dart';
import 'theme.dart';

/// Scenes that get their own screen in the app instead of the generic start button.
Widget? specialPage(String id, Api api) {
  switch (id) {
    case 'pomo':
      return PomodoroPage(api: api);
    case 'pet':
      return PetPage(api: api);
    case 'weather':
      return WeatherPage(api: api);
    case 'buddy':
      return BuddyPage(api: api);
    case 'canvas':
      return CanvasPage(api: api);
    case 'anim':
      return CanvasPage(api: api, initialTab: 2);
    case 'bars':
    case 'nowplaying':
      return MediaPage(api: api);
  }
  return null;
}

/// Sends a command and shows a snackbar if it fails. Returns true on success.
Future<bool> send(BuildContext context, Api api, Map<String, dynamic> body) async {
  try {
    final r = await api.cmd(body);
    if (r['ok'] != true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Device: ${r['error'] ?? 'error'}')));
      return false;
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Device not reachable')));
    }
    return false;
  }
}

Widget _pad(List<Widget> children) => ListView(padding: const EdgeInsets.all(16), children: children);

// ---------------------------------------------------------------- POMODORO
class PomodoroPage extends StatefulWidget {
  const PomodoroPage({super.key, required this.api});
  final Api api;
  @override
  State<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends State<PomodoroPage> {
  double _work = 25, _brk = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => send(context, widget.api, {'cmd': 'pomo', 'action': 'show'}));
  }

  Future<void> _act(String a) =>
      send(context, widget.api, {'cmd': 'pomo', 'action': a, 'work': _work.round(), 'brk': _brk.round()});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Pomodoro')),
        body: _pad([
          Text('Focus: ${_work.round()} min'),
          Slider(value: _work, min: 5, max: 60, divisions: 11, onChanged: (v) => setState(() => _work = v)),
          Text('Break: ${_brk.round()} min'),
          Slider(value: _brk, min: 1, max: 30, divisions: 29, onChanged: (v) => setState(() => _brk = v)),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.icon(onPressed: () => _act('start'), icon: const Icon(Icons.play_arrow), label: const Text('Start')),
            FilledButton.tonalIcon(onPressed: () => _act('pause'), icon: const Icon(Icons.pause), label: const Text('Pause')),
            OutlinedButton.icon(onPressed: () => _act('skip'), icon: const Icon(Icons.skip_next), label: const Text('Skip')),
            OutlinedButton.icon(onPressed: () => _act('reset'), icon: const Icon(Icons.restart_alt), label: const Text('Reset')),
          ]),
          const SizedBox(height: 16),
          const Text('Changing the sliders applies the new length to the current timer when it is not running.'),
        ]),
      );
}

// ---------------------------------------------------------------- PET
class PetPage extends StatefulWidget {
  const PetPage({super.key, required this.api});
  final Api api;
  @override
  State<PetPage> createState() => _PetPageState();
}

class _PetPageState extends State<PetPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => send(context, widget.api, {'cmd': 'pet', 'action': 'show'}));
  }

  Widget _b(IconData i, String label, String a) => FilledButton.tonalIcon(
      onPressed: () => send(context, widget.api, {'cmd': 'pet', 'action': a}), icon: Icon(i), label: Text(label));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Pixel Pet')),
        body: _pad([
          const Text('Look after the cat on the screen. It gets hungry over time (about 1% per minute), and feeding it makes it happy.'),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 10, children: [
            _b(Icons.set_meal, 'Feed', 'feed'),
            _b(Icons.sports_esports, 'Play', 'play'),
            _b(Icons.favorite, 'Pat', 'pat'),
            _b(Icons.bedtime, 'Sleep', 'sleep'),
            _b(Icons.wb_sunny, 'Wake', 'wake'),
          ]),
        ]),
      );
}

// ---------------------------------------------------------------- WEATHER
class WeatherPage extends StatefulWidget {
  const WeatherPage({super.key, required this.api});
  final Api api;
  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  static const cities = <String, List<double>>{
    'Delhi': [28.61, 77.21], 'Mumbai': [19.08, 72.88], 'Bengaluru': [12.97, 77.59], 'Kochi': [9.93, 76.27],
    'Chennai': [13.08, 80.27], 'Kolkata': [22.57, 88.36], 'Dubai': [25.20, 55.27], 'London': [51.51, -0.13],
    'New York': [40.71, -74.0], 'Singapore': [1.35, 103.82],
  };
  final _lat = TextEditingController(), _lon = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => send(context, widget.api, {'cmd': 'scene', 'id': 'weather'}));
  }

  Future<void> _set(double lat, double lon) => send(context, widget.api, {'cmd': 'loc', 'lat': lat, 'lon': lon});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Weather')),
        body: _pad([
          const DisplayFrame(child: WeatherScreen()),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async {
              final ok = await PhoneSync.sendLocation(widget.api);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Weather set to your location' : 'Allow location first (Phone magic on the home screen)')));
            },
            icon: const Icon(Icons.my_location_rounded),
            label: const Text('Use my location'),
          ),
          const SizedBox(height: 16),
          const Text('Or pick a city. The board fetches weather from Open-Meteo (no key needed) every 10 minutes.'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in cities.entries)
              ActionChip(label: Text(e.key), onPressed: () => _set(e.value[0], e.value[1])),
          ]),
          const SizedBox(height: 20),
          Text('Custom location', style: Theme.of(context).textTheme.titleMedium),
          Row(children: [
            Expanded(child: TextField(controller: _lat, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitude'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _lon, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitude'))),
          ]),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              final la = double.tryParse(_lat.text), lo = double.tryParse(_lon.text);
              if (la != null && lo != null) _set(la, lo);
            },
            child: const Text('Use this location'),
          ),
        ]),
      );
}

// ---------------------------------------------------------------- AI BUDDY
class BuddyPage extends StatefulWidget {
  const BuddyPage({super.key, required this.api});
  final Api api;
  @override
  State<BuddyPage> createState() => _BuddyPageState();
}

class _BuddyPageState extends State<BuddyPage> {
  final _in = TextEditingController();
  final _key = TextEditingController();
  final List<Map<String, String>> _chat = [];
  bool _busy = false, _hasKey = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final k = p.getString('anthropic_key') ?? '';
      if (mounted) setState(() { _key.text = k; _hasKey = k.isNotEmpty; });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => send(context, widget.api, {'cmd': 'say', 'text': 'Hi! I am Pixel. Ask me anything!', 'mood': 'excited'}));
  }

  Future<void> _saveKey() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('anthropic_key', _key.text.trim());
    setState(() => _hasKey = _key.text.trim().isNotEmpty);
    if (mounted) Navigator.pop(context);
  }

  void _keyDialog() => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Anthropic API key'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'sk-ant-...')),
            const SizedBox(height: 8),
            const Text('Stored only on this phone and sent only to api.anthropic.com. It is never sent to the board.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: _saveKey, child: const Text('Save'))],
        ),
      );

  Future<void> _say(String text, [String? mood]) => send(context, widget.api, {'cmd': 'say', 'text': text, if (mood != null) 'mood': mood});

  Future<void> _ask() async {
    final q = _in.text.trim();
    if (q.isEmpty) return;
    if (!_hasKey) { _keyDialog(); return; }
    setState(() { _chat.add({'role': 'user', 'content': q}); _busy = true; });
    _in.clear();
    try {
      final hist = _chat.length > 8 ? _chat.sublist(_chat.length - 8) : _chat;
      final r = await http
          .post(Uri.parse('https://api.anthropic.com/v1/messages'),
              headers: {'x-api-key': _key.text.trim(), 'anthropic-version': '2023-06-01', 'content-type': 'application/json'},
              body: jsonEncode({
                'model': 'claude-haiku-5-5',
                'max_tokens': 200,
                'system': 'You are Pixel, a cute, warm, expressive little desk robot shown on a small 160x128 screen. '
                    'Start every reply with exactly one mood tag in square brackets, chosen from: [happy] [love] [excited] [surprised] [wink] [thinking] [sleepy] [sad] [angry] [normal]. '
                    'Pick the one that matches how you feel about what you say. Then reply in plain text, at most 140 characters, friendly and playful, no markdown, no emoji.',
                'messages': hist,
              }))
          .timeout(const Duration(seconds: 30));
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (r.statusCode != 200) throw Exception(body['error']?['message'] ?? 'HTTP ${r.statusCode}');
      var text = (body['content'] as List).map((c) => c['text'] ?? '').join().trim();
      String? mood;
      final tag = RegExp(r'^\[(\w+)\]\s*').firstMatch(text);
      if (tag != null) {
        mood = tag.group(1)!.toLowerCase();
        text = text.substring(tag.end);
      }
      setState(() => _chat.add({'role': 'assistant', 'content': text}));
      if (mounted) await _say(text, mood);
    } catch (e) {
      setState(() => _chat.add({'role': 'assistant', 'content': 'Error: $e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('AI Buddy'), actions: [IconButton(icon: Icon(_hasKey ? Icons.key : Icons.key_off), onPressed: _keyDialog)]),
        body: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(12), children: [
              if (_chat.isEmpty) const Text('Ask a question and the answer appears on the display with a talking face. Set your API key with the key icon, or use "Say" to just show your own text.'),
              for (final m in _chat)
                Align(
                  alignment: m['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                  child: Card(
                    color: m['role'] == 'user' ? Theme.of(context).colorScheme.primaryContainer : null,
                    child: Padding(padding: const EdgeInsets.all(10), child: Text(m['content'] ?? '')),
                  ),
                ),
              if (_busy) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
            ]),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(children: [
                Expanded(child: TextField(controller: _in, decoration: const InputDecoration(hintText: 'Type here...', border: OutlineInputBorder()), onSubmitted: (_) => _ask())),
                const SizedBox(width: 8),
                IconButton.outlined(tooltip: 'Say this text', onPressed: () { final t = _in.text.trim(); if (t.isNotEmpty) { _say(t); _in.clear(); } }, icon: const Icon(Icons.record_voice_over)),
                IconButton.filled(tooltip: 'Ask AI', onPressed: _busy ? null : _ask, icon: const Icon(Icons.send)),
              ]),
            ),
          ),
        ]),
      );
}

// ---------------------------------------------------------------- CANVAS (draw + photo)
Uint8List rgbaToRgb565(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 2);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 2) {
    final v = ((rgba[i] & 0xF8) << 8) | ((rgba[i + 1] & 0xFC) << 3) | (rgba[i + 2] >> 3);
    out[o] = v & 0xFF;          // little-endian, matches the ESP32
    out[o + 1] = v >> 8;
  }
  return out;
}

/// 8-bit colour (3 bits red, 3 green, 2 blue) used for animation frames.
Uint8List rgbaToRgb332(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 4);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o++) {
    out[o] = (rgba[i] & 0xE0) | ((rgba[i + 1] & 0xE0) >> 3) | (rgba[i + 2] >> 6);
  }
  return out;
}

/// Center-crops [img] to the aspect of [w]x[h], scales it to exactly that size and returns raw RGBA plus a PNG preview.
Future<({Uint8List rgba, Uint8List png})> renderCover(ui.Image img, int w, int h) async {
  final target = w / h, ratio = img.width / img.height;
  double sw = img.width.toDouble(), sh = img.height.toDouble();
  if (ratio > target) {
    sw = sh * target;
  } else {
    sh = sw / target;
  }
  final src = Rect.fromLTWH((img.width - sw) / 2, (img.height - sh) / 2, sw, sh);
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(img, src, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.medium);
  final out = await rec.endRecording().toImage(w, h);
  final rgba = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final png = (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  out.dispose();
  return (rgba: rgba, png: png);
}

class CanvasPage extends StatelessWidget {
  const CanvasPage({super.key, required this.api, this.initialTab = 0});
  final Api api;
  final int initialTab;
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        initialIndex: initialTab,
        child: Scaffold(
          appBar: AppBar(title: const Text('Canvas'), bottom: const TabBar(tabs: [Tab(text: 'Draw'), Tab(text: 'Photo'), Tab(text: 'Animation')])),
          body: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [DrawTab(api: api), PhotoTab(api: api), AnimTab(api: api)]),
        ),
      );
}

class DrawTab extends StatefulWidget {
  const DrawTab({super.key, required this.api});
  final Api api;
  @override
  State<DrawTab> createState() => _DrawTabState();
}

class _DrawTabState extends State<DrawTab> {
  static const gw = 40, gh = 32;
  static const palette = <Color>[
    Colors.black, Colors.white, Colors.red, Colors.orange, Colors.yellow, Colors.green,
    Colors.cyan, Colors.blue, Colors.purple, Colors.pink, Color(0xFF8B5A2B), Colors.grey,
  ];
  final List<Color> _cells = List.filled(gw * gh, Colors.black);
  Color _color = Colors.red;
  double? _progress;

  void _paint(Offset p, Size s) {
    final x = (p.dx / s.width * gw).floor(), y = (p.dy / s.height * gh).floor();
    if (x < 0 || y < 0 || x >= gw || y >= gh) return;
    setState(() => _cells[y * gw + x] = _color);
  }

  Future<void> _sendIt() async {
    final rgba = Uint8List(160 * 128 * 4);
    for (var y = 0; y < 128; y++) {
      for (var x = 0; x < 160; x++) {
        final c = _cells[(y ~/ 4) * gw + (x ~/ 4)];
        final i = (y * 160 + x) * 4;
        rgba[i] = (c.r * 255).round(); rgba[i + 1] = (c.g * 255).round(); rgba[i + 2] = (c.b * 255).round(); rgba[i + 3] = 255;
      }
    }
    setState(() => _progress = 0);
    try {
      await widget.api.sendFrame(rgbaToRgb565(rgba), onProgress: (p) => setState(() => _progress = p));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) => _pad([
        AspectRatio(
          aspectRatio: 160 / 128,
          child: LayoutBuilder(builder: (ctx, c) {
            final size = Size(c.maxWidth, c.maxHeight);
            return GestureDetector(
              onPanStart: (d) => _paint(d.localPosition, size),
              onPanUpdate: (d) => _paint(d.localPosition, size),
              onTapDown: (d) => _paint(d.localPosition, size),
              child: CustomPaint(size: size, painter: _GridPainter(_cells, gw, gh)),
            );
          }),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in palette)
            GestureDetector(
              onTap: () => setState(() => _color = c),
              child: Container(
                width: 34, height: 34,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: _color == c ? Colors.cyanAccent : Colors.white24, width: _color == c ? 3 : 1)),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          OutlinedButton.icon(onPressed: () => setState(() => _cells.fillRange(0, _cells.length, Colors.black)), icon: const Icon(Icons.delete_outline), label: const Text('Clear')),
          const SizedBox(width: 10),
          Expanded(child: FilledButton.icon(onPressed: _progress == null ? _sendIt : null, icon: const Icon(Icons.send), label: const Text('Send to display'))),
        ]),
        if (_progress != null) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(value: _progress)),
      ]);
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.cells, this.gw, this.gh);
  final List<Color> cells;
  final int gw, gh;
  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / gw, ch = size.height / gh;
    final p = Paint();
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        p.color = cells[y * gw + x];
        canvas.drawRect(Rect.fromLTWH(x * cw, y * ch, cw + 0.5, ch + 0.5), p);
      }
    }
    canvas.drawRect(Offset.zero & size, Paint()..style = PaintingStyle.stroke..color = Colors.white24);
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => true;
}

class PhotoTab extends StatefulWidget {
  const PhotoTab({super.key, required this.api});
  final Api api;
  @override
  State<PhotoTab> createState() => _PhotoTabState();
}

class _PhotoTabState extends State<PhotoTab> {
  Uint8List? _rgba, _preview;
  double? _progress;
  String? _error;

  Future<void> _pick() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 640);
      final img = (await codec.getNextFrame()).image;
      // center-crop to the display's 160:128 ratio
      final target = 160 / 128, ratio = img.width / img.height;
      double sw = img.width.toDouble(), sh = img.height.toDouble();
      if (ratio > target) { sw = sh * target; } else { sh = sw / target; }
      final src = Rect.fromLTWH((img.width - sw) / 2, (img.height - sh) / 2, sw, sh);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(img, src, const Rect.fromLTWH(0, 0, 160, 128), Paint()..filterQuality = FilterQuality.medium);
      final out = await rec.endRecording().toImage(160, 128);
      final raw = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final png = (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      setState(() { _rgba = raw; _preview = png; _error = null; });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _sendIt() async {
    setState(() => _progress = 0);
    try {
      await widget.api.sendFrame(rgbaToRgb565(_rgba!), onProgress: (p) => setState(() => _progress = p));
    } catch (e) {
      setState(() => _error = 'Send failed: $e');
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) => _pad([
        const Text('Pick a photo. It is cropped to the display shape (160x128) and sent in a few strips.'),
        const SizedBox(height: 12),
        if (_preview != null)
          AspectRatio(aspectRatio: 160 / 128, child: Image.memory(_preview!, fit: BoxFit.fill, filterQuality: FilterQuality.none)),
        const SizedBox(height: 12),
        Row(children: [
          OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.photo_library), label: const Text('Choose photo')),
          const SizedBox(width: 10),
          Expanded(child: FilledButton.icon(onPressed: (_rgba == null || _progress != null) ? null : _sendIt, icon: const Icon(Icons.send), label: const Text('Send to display'))),
        ]),
        if (_progress != null) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(value: _progress)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]);
}

// ---------------------------------------------------------------- ANIMATION (GIF / slideshow)
class AnimTab extends StatefulWidget {
  const AnimTab({super.key, required this.api});
  final Api api;
  @override
  State<AnimTab> createState() => _AnimTabState();
}

class _AnimTabState extends State<AnimTab> {
  static const maxFrames = 7;           // what the board can hold in RAM
  List<Uint8List> _frames = [];
  Uint8List? _preview;
  double _delay = 150;
  double? _progress;
  String? _error;
  String _info = '';

  Future<List<ui.Image>> _decode(Uint8List bytes, {int maxSource = 150}) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
    final out = <ui.Image>[];
    final n = math.min(codec.frameCount, maxSource);
    for (var i = 0; i < n; i++) {
      out.add((await codec.getNextFrame()).image);
    }
    codec.dispose();
    return out;
  }

  Future<void> _pickGif() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
      final n = math.min(codec.frameCount, 150);
      final imgs = <ui.Image>[];
      var totalMs = 0;
      for (var i = 0; i < n; i++) {
        final fi = await codec.getNextFrame();
        imgs.add(fi.image);
        totalMs += fi.duration.inMilliseconds;
      }
      final want = math.min(maxFrames, imgs.length);
      final frames = <Uint8List>[];
      Uint8List? preview;
      for (var k = 0; k < want; k++) {
        final r = await renderCover(imgs[(k * imgs.length / want).floor()], 80, 64);
        frames.add(rgbaToRgb332(r.rgba));
        preview ??= r.png;
      }
      // each frame we keep stands for imgs.length/want source frames
      final per = imgs.isEmpty ? 100.0 : totalMs / imgs.length;
      final delay = (per * imgs.length / want).clamp(60, 1500).toDouble();
      for (final i in imgs) { i.dispose(); }
      codec.dispose();
      setState(() {
        _frames = frames; _preview = preview; _delay = delay; _error = null;
        _info = 'Using ${frames.length} of ${imgs.length} frame(s)${imgs.length == 1 ? ' (not an animated GIF)' : ''}.';
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _pickMany() async {
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty) return;
      final frames = <Uint8List>[];
      Uint8List? preview;
      for (final f in files.take(maxFrames)) {
        final imgs = await _decode(await f.readAsBytes(), maxSource: 1);
        if (imgs.isEmpty) continue;
        final r = await renderCover(imgs.first, 80, 64);
        frames.add(rgbaToRgb332(r.rgba));
        preview ??= r.png;
        imgs.first.dispose();
      }
      setState(() {
        _frames = frames; _preview = preview; _delay = 2000; _error = null;
        _info = '${frames.length} photo(s) as a slideshow${files.length > maxFrames ? ' (first $maxFrames only)' : ''}.';
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _sendIt() async {
    setState(() { _progress = 0; _error = null; });
    try {
      await widget.api.sendAnimation(_frames, _delay.round(), onProgress: (p) => setState(() => _progress = p));
    } catch (e) {
      setState(() => _error = 'Send failed: $e');
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) => _pad([
        const Text('Choose an animated GIF, or several photos for a slideshow. Frames are shrunk to 80x64 pixels with 256 colours '
            '(up to 7 frames fit in the board\'s memory) and shown at double size. The animation is erased from the board when you switch scene.'),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: [
          OutlinedButton.icon(onPressed: _pickGif, icon: const Icon(Icons.gif_box), label: const Text('Choose GIF')),
          OutlinedButton.icon(onPressed: _pickMany, icon: const Icon(Icons.photo_library), label: const Text('Photo slideshow')),
        ]),
        if (_preview != null) ...[
          const SizedBox(height: 12),
          AspectRatio(aspectRatio: 80 / 64, child: Image.memory(_preview!, fit: BoxFit.fill, filterQuality: FilterQuality.none)),
          const SizedBox(height: 4),
          Text(_info),
          Text('Delay between frames: ${_delay.round()} ms'),
          Slider(value: _delay.clamp(30, 3000), min: 30, max: 3000, onChanged: (v) => setState(() => _delay = v)),
          FilledButton.icon(onPressed: _progress != null ? null : _sendIt, icon: const Icon(Icons.send), label: const Text('Send to display')),
        ],
        if (_progress != null) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(value: _progress)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]);
}

// ---------------------------------------------------------------- MEDIA (bars + now playing)
class MediaPage extends StatefulWidget {
  const MediaPage({super.key, required this.api});
  final Api api;
  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  Timer? _t;
  bool _demo = false, _playing = true, _mic = false, _inFlight = false;
  double _phase = 0;
  final _title = TextEditingController(text: 'Midnight City'), _artist = TextEditingController(text: 'M83'), _dur = TextEditingController(text: '243');

  // microphone visualizer
  final _rec = AudioRecorder();
  final _spec = Spectrum();
  StreamSubscription<Uint8List>? _micSub;
  final List<double> _buf = [];
  int _lastSend = 0;

  @override
  void dispose() {
    _t?.cancel();
    _micSub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

  void _toggleDemo(bool on) {
    _t?.cancel();
    setState(() => _demo = on);
    if (!on) return;
    if (_mic) _toggleMic(false);
    _t = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (_inFlight) return;
      _phase += 0.25;
      final v = [
        for (var i = 0; i < 16; i++)
          (140 + 110 * math.sin(_phase * (1 + i * 0.07) + i * 0.8) * math.cos(_phase * 0.6 + i * 0.3)).clamp(8, 255).round(),
      ];
      _inFlight = true;
      widget.api.cmd({'cmd': 'bands', 'v': v}).catchError((_) => <String, dynamic>{}).whenComplete(() => _inFlight = false);
    });
  }

  Future<void> _toggleMic(bool on) async {
    if (!on) {
      await _micSub?.cancel();
      _micSub = null;
      try { await _rec.stop(); } catch (_) {}
      if (mounted) setState(() => _mic = false);
      return;
    }
    if (!await _rec.hasPermission()) {
      _toast('Microphone permission is needed');
      return;
    }
    if (_demo) _toggleDemo(false);
    try {
      final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 22050, numChannels: 1));
      _buf.clear();
      _micSub = stream.listen(_onAudio);
      if (mounted) setState(() => _mic = true);
    } catch (e) {
      _toast('Could not start the microphone: $e');
    }
  }

  void _onAudio(Uint8List chunk) {
    final bd = ByteData.sublistView(chunk);
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      _buf.add(bd.getInt16(i, Endian.little).toDouble());
    }
    if (_buf.length < 512) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSend < 70 || _inFlight) {
      if (_buf.length > 2048) _buf.removeRange(0, _buf.length - 512);   // drop old audio, keep only the latest
      return;
    }
    _lastSend = now;
    final bands = _spec.process(_buf);              // uses the newest 512 samples
    _buf.removeRange(0, _buf.length - 512);
    _inFlight = true;
    widget.api.cmd({'cmd': 'bands', 'v': bands}).catchError((_) => <String, dynamic>{}).whenComplete(() => _inFlight = false);
  }

  Future<void> _np() => send(context, widget.api, {
        'cmd': 'nowplaying', 'title': _title.text, 'artist': _artist.text,
        'dur': int.tryParse(_dur.text) ?? 0, 'pos': 0, 'playing': _playing,
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Music')),
        body: _pad([
          Card(
            child: Column(children: [
              SwitchListTile(
                title: const Text('Microphone visualizer'),
                subtitle: const Text('Listens through the phone microphone and shows the sound spectrum on the display. Play music near the phone.'),
                value: _mic,
                onChanged: _toggleMic,
              ),
              SwitchListTile(
                title: const Text('Demo animation'),
                subtitle: const Text('Streams a fake spectrum (no microphone needed)'),
                value: _demo,
                onChanged: _toggleDemo,
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Text('Now playing (manual)', style: Theme.of(context).textTheme.titleMedium),
          TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title')),
          TextField(controller: _artist, decoration: const InputDecoration(labelText: 'Artist')),
          TextField(controller: _dur, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Length (seconds)')),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Playing'), value: _playing, onChanged: (v) => setState(() => _playing = v)),
          FilledButton.icon(onPressed: _np, icon: const Icon(Icons.music_note), label: const Text('Show on display')),
          const SizedBox(height: 16),
          const Text('To show the song that is really playing on your phone, open Phone magic on the home screen (it needs Notification access).', style: TextStyle(fontSize: 12)),
        ]),
      );
}
