import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/connection.dart';
import '../theme.dart';

/// Music: what is playing on the phone and manual entry.
/// What the phone exposes depends on the music app, so every field can be empty and the screen copes with that.
class MusicPage extends StatefulWidget {
  const MusicPage({super.key});
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> with WidgetsBindingObserver {
  Timer? _poll;
  NowPlaying? _np;
  bool _access = true, _config = false, _manualPlaying = true;
  String _lastDelivery = '';
  final _title = TextEditingController(), _artist = TextEditingController(), _dur = TextEditingController(text: '240');

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
    _title.dispose();
    _artist.dispose();
    _dur.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
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
        DisplayFrame(child: n == null ? const ColoredBox(color: Colors.black, child: Center(child: Text('Nothing playing', style: Ty.meta))) : MusicScreen(title: n.title, artist: n.artist, playing: n.playing, hue: (n.title.hashCode % 360).abs().toDouble())),
        const SizedBox(height: 8),
        const Center(child: Text('Illustration of the display', style: Ty.meta)),
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
