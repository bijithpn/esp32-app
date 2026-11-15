import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../core/bridge.dart';
import '../core/command_queue.dart';
import '../core/connection.dart';
import '../fft.dart';
import '../theme.dart';

/// Music: what is playing on the phone, an equaliser preview, a microphone visualiser and manual entry.
/// What the phone exposes depends on the music app, so every field can be empty and the screen copes with that.
class MusicPage extends StatefulWidget {
  const MusicPage({super.key});
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> with WidgetsBindingObserver {
  Timer? _poll, _demoTimer;
  NowPlaying? _np;
  bool _access = true, _config = false, _demo = false, _mic = false, _inFlight = false, _manualPlaying = true;
  double _phase = 0;
  String _lastDelivery = '';
  final _title = TextEditingController(), _artist = TextEditingController(), _dur = TextEditingController(text: '240');

  // microphone visualizer
  final _rec = AudioRecorder();
  final _spec = Spectrum();
  StreamSubscription<Uint8List>? _micSub;
  final List<double> _buf = [];
  int _lastSend = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _demoTimer?.cancel();
    _micSub?.cancel();
    _rec.dispose();
    _title.dispose();
    _artist.dispose();
    _dur.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
    if (state != AppLifecycleState.resumed && _mic) _toggleMic(false); // never keep the microphone open in the background
  }

  Future<void> _refresh() async {
    final b = Bridge.current;
    final access = await b.notificationAccess();
    final np = access ? await b.nowPlaying() : null;
    final cfg = await b.getConfig();
    if (!mounted) return;
    setState(() {
      _access = access;
      _np = np;
      _config = cfg['media'] == true;
      _lastDelivery = '${cfg['lastDelivery'] ?? ''}';
    });
  }

  String get _syncText {
    if (!_config) return 'Sync to the Hub is off';
    final p = _lastDelivery.split('|');
    if (p.length < 3) return 'Waiting for the first song';
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(int.tryParse(p[0]) ?? 0));
    final when = ago.inSeconds < 60 ? 'just now' : '${ago.inMinutes} min ago';
    return p[1] == '1' ? 'Synced to the Hub · $when' : 'Last send failed ($when): ${_why(p[2])}';
  }

  String _why(String c) => switch (c) {
        'stale' => 'it was too old to show',
        'offline' => 'the Hub is offline',
        'token' => 'the token was refused',
        'rate' => 'the Hub asked to slow down',
        _ => 'the Hub didn\'t answer',
      };

  // ---------------------------------------------------------------- demo + microphone
  void _toggleDemo(bool on) {
    final hub = HubScope.read(context);
    _demoTimer?.cancel();
    setState(() => _demo = on);
    if (!on) return;
    if (_mic) _toggleMic(false);
    _demoTimer = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (_inFlight || !hub.canSend) return;
      _phase += 0.25;
      final v = [for (var i = 0; i < 16; i++) (140 + 110 * math.sin(_phase * (1 + i * 0.07) + i * 0.8) * math.cos(_phase * 0.6 + i * 0.3)).clamp(8, 255).round()];
      _stream(hub, v);
    });
  }

  void _stream(ConnectionManager hub, List<num> bands) {
    _inFlight = true;
    hub.send({'cmd': 'bands', 'v': bands}, dedupeKey: 'bands', retries: 0, timeout: const Duration(seconds: 2), priority: CmdPriority.low).catchError((_) => <String, dynamic>{}).whenComplete(() => _inFlight = false);
  }

  Future<void> _toggleMic(bool on) async {
    if (!on) {
      await _micSub?.cancel();
      _micSub = null;
      try {
        await _rec.stop();
      } catch (_) {}
      if (mounted) setState(() => _mic = false);
      return;
    }
    if (!await _rec.hasPermission()) {
      if (mounted) toast(context, 'Microphone permission is needed. You can allow it in the app settings.');
      return;
    }
    if (_demo) _toggleDemo(false);
    try {
      final stream = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 22050, numChannels: 1));
      _buf.clear();
      _micSub = stream.listen(_onAudio);
      if (mounted) setState(() => _mic = true);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t start the microphone.');
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
      if (_buf.length > 2048) _buf.removeRange(0, _buf.length - 512); // drop old audio, keep only the latest
      return;
    }
    _lastSend = now;
    final bands = _spec.process(_buf);
    _buf.removeRange(0, _buf.length - 512);
    _stream(HubScope.read(context), bands);
  }

  Future<void> _showManual() async {
    final ok = await HubScope.read(context).trySend(
      {'cmd': 'nowplaying', 'title': _title.text, 'artist': _artist.text, 'dur': int.tryParse(_dur.text) ?? 0, 'pos': 0, 'playing': _manualPlaying},
      onError: (m) => toast(context, m),
    );
    if (ok && mounted) toast(context, 'Showing on the Hub');
  }

  Future<void> _pushCurrent() async {
    final n = _np;
    if (n == null) return;
    await HubScope.read(context).trySend({'cmd': 'nowplaying', 'title': n.title, 'artist': n.artist, 'dur': n.durSec, 'pos': n.posSec, 'playing': n.playing}, onError: (m) => toast(context, m));
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final n = _np;
    return Scaffold(
      appBar: AppBar(title: const Text('Music')),
      body: ListView(padding: Sp.page, children: [
        if (!_access)
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Show the song that\'s playing', style: Ty.title),
              const SizedBox(height: 6),
              const Hint('Android only shares song details with apps that have notification access. Allow it once and the Hub follows your music automatically.'),
              const SizedBox(height: 12),
              FilledButton(onPressed: Bridge.current.openNotificationSettings, child: const Text('Allow access')),
            ]),
          )
        else
          _NowCard(np: n, syncText: _syncText, onPush: n == null || !hub.canSend ? null : _pushCurrent),
        const SectionTitle('On the Hub'),
        DisplayFrame(child: n == null ? const BarsScreen() : MusicScreen(title: n.title, artist: n.artist, playing: n.playing, hue: (n.title.hashCode % 360).abs().toDouble())),
        const SizedBox(height: 8),
        const Center(child: Text('Illustration of the display', style: Ty.meta)),
        const SectionTitle('Visualiser'),
        Group(children: [
          _Sw(title: 'Microphone', sub: 'Listens through the phone and shows the sound spectrum. Stops when you leave the app.', value: _mic, onChanged: hub.canSend ? _toggleMic : null),
          _Sw(title: 'Demo animation', sub: 'A made-up spectrum, no microphone needed', value: _demo, onChanged: hub.canSend ? _toggleDemo : null),
        ]),
        const SizedBox(height: 8),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Enter a track by hand', style: Ty.bodyStrong),
            children: [
              TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title')),
              const SizedBox(height: 10),
              TextField(controller: _artist, decoration: const InputDecoration(labelText: 'Artist')),
              const SizedBox(height: 10),
              TextField(controller: _dur, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Length (seconds)')),
              Row(children: [const Expanded(child: Text('Playing', style: Ty.body)), Switch(value: _manualPlaying, onChanged: (v) => setState(() => _manualPlaying = v))]),
              FilledButton(onPressed: hub.canSend ? _showManual : null, child: const Text('Show on the Hub')),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ]),
    );
  }
}

class _NowCard extends StatelessWidget {
  const _NowCard({required this.np, required this.syncText, required this.onPush});
  final NowPlaying? np;
  final String syncText;
  final VoidCallback? onPush;
  @override
  Widget build(BuildContext context) {
    final n = np;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: 84, height: 84, child: n?.art != null ? Image.memory(n!.art!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => const _NoArt()) : const _NoArt()),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: n == null
                ? const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Nothing playing', style: Ty.title), SizedBox(height: 4), Text('Start a song in any music app.', style: Ty.secondary)])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Ty.title),
                    const SizedBox(height: 2),
                    Text(n.artist.isEmpty ? (n.app.isEmpty ? 'Unknown artist' : n.app) : n.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Ty.secondary),
                    const SizedBox(height: 8),
                    StatusPill(color: n.playing ? HubColors.ok : HubColors.muted, label: n.playing ? 'Playing' : 'Paused'),
                  ]),
          ),
        ]),
        if (n != null && n.durSec > 0) ...[
          const SizedBox(height: 14),
          ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: (n.posSec / n.durSec).clamp(0.0, 1.0), minHeight: 4, backgroundColor: HubColors.surface2)),
          const SizedBox(height: 6),
          Row(children: [Text(_t(n.posSec), style: Ty.meta), const Spacer(), Text(_t(n.durSec), style: Ty.meta)]),
        ],
        const SizedBox(height: 10),
        Row(children: [Expanded(child: Text(syncText, style: Ty.meta)), if (onPush != null) TextButton(onPressed: onPush, child: const Text('Show on Hub'))]),
      ]),
    );
  }

  String _t(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class _NoArt extends StatelessWidget {
  const _NoArt();
  @override
  Widget build(BuildContext context) => Container(color: HubColors.surface2, child: const Icon(Icons.music_note_rounded, color: HubColors.muted, size: 32));
}

class _Sw extends StatelessWidget {
  const _Sw({required this.title, required this.sub, required this.value, required this.onChanged});
  final String title, sub;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Ty.bodyStrong), const SizedBox(height: 2), Text(sub, style: Ty.secondary)])),
          Switch(value: value, onChanged: onChanged),
        ]),
      );
}
