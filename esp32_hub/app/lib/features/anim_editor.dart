import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/imaging.dart';
import '../theme.dart';

class _Frame {
  _Frame(this.rgb332, this.png);
  final Uint8List rgb332, png;
}

/// GIF / slideshow editor. The Hub keeps up to 7 frames of 80 x 64 pixels in RAM (256 colours, shown at double size).
/// The editor shows what that costs, helps fit a longer GIF, and checks the Hub's free memory before it uploads anything.
class AnimEditorScreen extends StatefulWidget {
  const AnimEditorScreen({super.key});
  @override
  State<AnimEditorScreen> createState() => _AnimEditorScreenState();
}

class _AnimEditorScreenState extends State<AnimEditorScreen> {
  List<_Frame> _frames = [];
  int _selected = 0, _playIndex = 0;
  double _delay = 150;
  bool _pingPong = false, _loading = false, _cancel = false;
  double? _progress;
  String? _error;
  String _info = '';
  Timer? _player;

  @override
  void initState() {
    super.initState();
    _restartPlayer();
  }

  @override
  void dispose() {
    _player?.cancel();
    super.dispose();
  }

  List<int> get _order => loopOrder(_frames.length, pingPong: _pingPong);

  void _restartPlayer() {
    _player?.cancel();
    if (reducedMotion(context)) return;
    _player = Timer.periodic(Duration(milliseconds: _delay.round().clamp(60, 3000)), (_) {
      if (!mounted || _frames.isEmpty) return;
      final o = _order;
      setState(() => _playIndex = (_playIndex + 1) % o.length);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restartPlayer();
  }

  Future<_Frame> _toFrame(ui.Image img) async {
    final r = await renderImage(img, 80, 64);
    return _Frame(rgbaToRgb332(r.rgba), r.png);
  }

  Future<void> _pickGif() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      setState(() { _loading = true; _error = null; });
      final codec = await ui.instantiateImageCodec(await f.readAsBytes(), targetWidth: 160);
      final n = math.min(codec.frameCount, 120);
      final out = <_Frame>[];
      var totalMs = 0;
      for (var i = 0; i < n; i++) {
        final fi = await codec.getNextFrame();
        totalMs += fi.duration.inMilliseconds;
        out.add(await _toFrame(fi.image));
        fi.image.dispose();
      }
      codec.dispose();
      if (!mounted) return;
      final per = out.isEmpty ? 100.0 : totalMs / out.length;
      setState(() {
        _frames = out;
        _selected = 0;
        _playIndex = 0;
        _delay = (per <= 0 ? 100 : per).clamp(60, 1500).toDouble();
        _info = out.length == 1 ? 'A still picture (not an animated GIF).' : '${out.length} frames read${codec.frameCount > 120 ? ' (the first 120)' : ''}.';
        _loading = false;
      });
      _restartPlayer();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'That file couldn\'t be read as a GIF or picture.'; });
    }
  }

  Future<void> _pickMany() async {
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty) return;
      setState(() { _loading = true; _error = null; });
      final out = <_Frame>[];
      for (final f in files.take(40)) {
        final codec = await ui.instantiateImageCodec(await f.readAsBytes(), targetWidth: 320);
        final fi = await codec.getNextFrame();
        out.add(await _toFrame(fi.image));
        fi.image.dispose();
        codec.dispose();
      }
      if (!mounted) return;
      setState(() { _frames = out; _selected = 0; _playIndex = 0; _delay = 2000; _info = '${out.length} photo(s) as a slideshow.'; _loading = false; });
      _restartPlayer();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'One of those pictures couldn\'t be opened.'; });
    }
  }

  void _optimize() {
    final keep = _pingPong ? 4 : animMaxFrames;
    final idx = evenlySpaced(_frames.length, keep);
    setState(() {
      _frames = [for (final i in idx) _frames[i]];
      _selected = 0;
      _playIndex = 0;
      _delay = (_delay * (idx.isEmpty ? 1 : 1)).clamp(60, 3000);
      _info = 'Reduced to ${_frames.length} frames, evenly spaced.';
    });
  }

  Future<void> _send() async {
    final hub = HubScope.read(context);
    final order = _order;
    final need = animMemory(order.length);
    final free = (hub.pingData['heap'] as num?)?.toInt();
    if (free != null && free < need + 25000) {
      setState(() => _error = 'The Hub has about ${(free / 1024).round()} KB of free memory and this animation needs about ${(need / 1024).round()} KB plus room to work. Use fewer frames, or switch to a simpler scene first.');
      return;
    }
    setState(() { _progress = 0; _error = null; _cancel = false; });
    try {
      await sendAnimationVia(
        (b) {
          if (_cancel) throw HubException(HubError.cancelled);
          return hub.send(b, timeout: const Duration(seconds: 10), idempotent: true);
        },
        [for (final i in order) _frames[i].rgb332],
        _delay.round(),
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      );
      if (mounted) toast(context, 'Playing on the Hub');
    } catch (e) {
      if (mounted && toHubException(e).kind != HubError.cancelled) setState(() => _error = 'Couldn\'t send: ${friendlyError(e)}');
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final order = _order;
    final over = order.length > animMaxFrames;
    final used = animMemory(order.length), cap = animMemory(animMaxFrames);
    final cur = _frames.isEmpty ? null : _frames[order[_playIndex % order.length]];
    return Scaffold(
      appBar: AppBar(title: const Text('Animation')),
      body: ListView(padding: Sp.page, children: [
        if (_frames.isEmpty && !_loading)
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Make an animation', style: Ty.title),
              const SizedBox(height: 6),
              const Hint('Choose a GIF, or several photos for a slideshow. The editor shrinks the frames to 80 x 64 pixels with 256 colours, which is what the Hub can hold (7 frames).'),
            ]),
          ),
        if (_loading) StateView.loading('Reading frames…', message: 'Long GIFs take a moment.'),
        if (_frames.isNotEmpty) ...[
          DisplayFrame(child: Container(color: Colors.black, child: Center(child: cur == null ? null : AspectRatio(aspectRatio: 80 / 64, child: _FrameImage(cur.png))))),
          const SizedBox(height: 6),
          Center(child: Text(_info, style: Ty.meta)),
          const SectionTitle('Frames', top: 20),
          SizedBox(
            height: 84,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: true,
              itemCount: _frames.length,
              onReorder: (a, b) => setState(() {
                if (b > a) b--;
                final f = _frames.removeAt(a);
                _frames.insert(b, f);
                _selected = b;
              }),
              itemBuilder: (_, i) => Padding(
                key: ValueKey(_frames[i]),
                padding: const EdgeInsets.only(right: 8),
                child: Stack(children: [
                  Choice(selected: _selected == i, onTap: () => setState(() => _selected = i), padding: const EdgeInsets.all(3), radius: 10, child: SizedBox(width: 80, height: 64, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _FrameImage(_frames[i].png)))),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: GestureDetector(
                      onTap: () => setState(() { _frames.removeAt(i); _selected = 0; _playIndex = 0; }),
                      child: Semantics(label: 'Remove frame ${i + 1}', button: true, child: Container(width: 22, height: 22, decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle), child: const Icon(Icons.close_rounded, size: 14))),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Hint('Drag a frame to reorder it, tap the x to remove it.'),
          const SectionTitle('Playback'),
          Panel(
            child: Column(children: [
              Row(children: [const Expanded(child: Text('Time per frame', style: Ty.bodyStrong)), Text('${_delay.round()} ms', style: Ty.body.copyWith(color: HubColors.muted))]),
              Slider(value: _delay.clamp(30, 3000), min: 30, max: 3000, onChanged: (v) => setState(() => _delay = v), onChangeEnd: (_) => _restartPlayer()),
              const Divider(height: 20),
              Row(children: [
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Ping-pong', style: Ty.bodyStrong), SizedBox(height: 2), Text('Play forwards, then backwards. Uses extra frame slots.', style: Ty.secondary)])),
                Switch(value: _pingPong, onChanged: (v) => setState(() { _pingPong = v; _playIndex = 0; })),
              ]),
              const SizedBox(height: 4),
              const Align(alignment: Alignment.centerLeft, child: Text('The Hub repeats the animation until you change scene.', style: Ty.meta)),
            ]),
          ),
          const SectionTitle('Memory on the Hub'),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: (used / cap).clamp(0.0, 1.0), minHeight: 8, color: over ? HubColors.danger : HubColors.ok, backgroundColor: HubColors.surface2)),
              const SizedBox(height: 10),
              Text('${order.length} of $animMaxFrames frames · ${(used / 1024).toStringAsFixed(1)} KB of ${(cap / 1024).toStringAsFixed(1)} KB', style: Ty.bodyStrong),
              if (over) ...[
                const SizedBox(height: 6),
                Text('That is ${order.length - animMaxFrames} too many for the Hub.', style: Ty.secondary.copyWith(color: HubColors.danger)),
                const SizedBox(height: 10),
                OutlinedButton.icon(onPressed: _optimize, icon: const Icon(Icons.auto_fix_high_rounded, size: 20), label: Text('Optimise to ${_pingPong ? 4 : animMaxFrames} frames')),
              ],
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          OutlinedButton.icon(onPressed: _loading ? null : _pickGif, icon: const Icon(Icons.gif_box_outlined), label: const Text('Choose GIF')),
          OutlinedButton.icon(onPressed: _loading ? null : _pickMany, icon: const Icon(Icons.photo_library_outlined), label: const Text('Photo slideshow')),
        ]),
        if (_frames.isNotEmpty) ...[
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: over || _progress != null || !hub.canSend ? null : _send, icon: const Icon(Icons.send_rounded), label: const Text('Send to the Hub')),
        ],
        if (_progress != null) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _progress),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _cancel = true, child: const Text('Cancel'))),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Hint(_error!, color: HubColors.danger)),
        const SizedBox(height: 12),
        const Hint('The animation is erased from the Hub\'s memory when it switches to another scene.'),
      ]),
    );
  }
}

class _FrameImage extends StatelessWidget {
  const _FrameImage(this.png);
  final Uint8List png;
  @override
  Widget build(BuildContext context) => Image.memory(png, fit: BoxFit.fill, filterQuality: FilterQuality.none, gaplessPlayback: true);
}
