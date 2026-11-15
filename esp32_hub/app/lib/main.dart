import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'discovery.dart';
import 'features.dart';
import 'manual.dart';
import 'phone.dart';
import 'settings.dart';
import 'theme.dart';

void main() => runApp(const HubApp());

// ---------------------------------------------------------------- APP
class HubApp extends StatelessWidget {
  const HubApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ESP32 Hub',
        debugShowCheckedModeBanner: false,
        theme: buildHubTheme(),
        home: const StartPage(),
      );
}

// ---------------------------------------------------------------- START: finds the board by itself
enum _Phase { searching, notFound }

class StartPage extends StatefulWidget {
  const StartPage({super.key});
  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  _Phase _phase = _Phase.searching;
  bool _skipAp = false;
  String _status = 'Looking for your board…';
  bool _remoteSaved = false, _busy = false;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _auto();
  }

  Future<void> _auto() async {
    final run = ++_run;
    setState(() { _phase = _Phase.searching; _status = 'Looking for your board…'; });
    final p = await SharedPreferences.getInstance();
    final lastHost = p.getString('host') ?? '';
    final lastId = p.getString('dev_id');
    _remoteSaved = (p.getBool('remote') ?? false) && (p.getString('mq_host') ?? '').isNotEmpty;
    await for (final f in Discovery.scan(lastHost: lastHost, wantId: lastId)) {
      if (!mounted || run != _run) return;
      if (await _connectTo(f, p)) return;
    }
    if (!mounted || run != _run) return;
    if (_remoteSaved) {
      setState(() => _status = 'Not on this Wi-Fi. Trying the internet link…');
      if (await _connectRemote(p)) return;
    }
    if (mounted && run == _run) setState(() => _phase = _Phase.notFound);
  }

  Future<bool> _connectRemote(SharedPreferences p) async {
    MqttApi? api;
    try {
      api = MqttApi(MqttConfig(
        host: p.getString('mq_host') ?? '', port: int.tryParse(p.getString('mq_port') ?? '') ?? 1883, user: p.getString('mq_user') ?? '',
        pass: p.getString('mq_pass') ?? '', tls: p.getBool('mq_tls') ?? false, deviceId: p.getString('mq_id') ?? '', token: p.getString('mq_token') ?? '',
      ));
      await api.connect();
      final data = await api.list();
      if (!mounted) return true;
      _open(api, data);
      return true;
    } catch (_) {
      await api?.close();
      return false;
    }
  }

  void _open(Api api, Map<String, dynamic> data) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => HomePage(api: api, initial: data)));
  }

  /// Connects to a board that was found. Returns true when the screen has moved on.
  Future<bool> _connectTo(FoundBoard f, SharedPreferences p) async {
    if (f.ap) {
      if (_skipAp) return false;
      // The phone is on the board's own hotspot: this board still needs Wi-Fi. Do it right here.
      if (!mounted) return true;
      setState(() => _status = 'Found a new board. Let\'s get it online.');
      final api = HttpApi(f.host);
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => WifiSetupPage(api: api, boardId: f.id)));
      _skipAp = true;
      if (mounted) _auto();
      return true;
    }
    setState(() => _status = 'Found it! Connecting…');
    var token = p.getString('token') ?? '';
    var api = HttpApi(f.host, token: token);
    try {
      var data = await api.list();
      if (data['lock'] == true) {
        if (token.isEmpty || !await api.checkAuth()) {
          final t = await _askToken();
          if (t == null || t.isEmpty) return false;
          token = t;
          api = HttpApi(f.host, token: t);
          if (!await api.checkAuth()) throw Exception('Wrong token');
          data = await api.list();
        }
      }
      await p.setString('host', f.host);
      await p.setString('token', token);
      await p.setString('dev_id', f.id);
      await p.setString('mq_id', f.id);
      if (token.isNotEmpty) await p.setString('mq_token', token);
      await p.setBool('remote', false);
      if (!mounted) return true;
      _open(api, data);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _askToken() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HubColors.surface,
        title: const Text('This board is locked'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Enter its token. Scan the QR from the board\'s "Pair (QR)" scene to fill it in automatically.', style: TextStyle(color: HubColors.muted)),
          const SizedBox(height: 12),
          TextField(controller: c, autocorrect: false, decoration: const InputDecoration(labelText: 'Token')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _scanQr() async {
    final v = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    final info = v == null ? null : PairInfo.parse(v);
    if (info == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('host', info.ip);
    await p.setString('token', info.token);
    await p.setString('dev_id', info.id);
    _auto();
  }

  Future<void> _bleSetup() async {
    final f = await Navigator.of(context).push<FoundBoard>(MaterialPageRoute(builder: (_) => const BleSetupPage()));
    if (f != null && mounted) {
      final p = await SharedPreferences.getInstance();
      await _connectTo(f, p);
    } else if (mounted) {
      _auto();
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = _phase == _Phase.searching;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  height: 230,
                  child: Stack(alignment: Alignment.center, children: [
                    if (searching) const Positioned.fill(child: _Radar()),
                    SizedBox(width: 190, child: DisplayFrame(child: FaceScreen(mood: searching ? 'thinking' : 'sad'))),
                  ]),
                ),
                const SizedBox(height: 20),
                Text(searching ? _status : 'I can\'t find your board', textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.2)),
                const SizedBox(height: 10),
                Text(
                  searching ? 'Make sure the board is powered on and your phone is on the same Wi-Fi.' : 'It needs to be powered on, with your phone on the same Wi-Fi network.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: HubColors.muted, fontSize: 15, height: 1.45),
                ),
                const SizedBox(height: 28),
                if (!searching) ...[
                  FilledButton.icon(onPressed: _busy ? null : _auto, icon: const Icon(Icons.refresh_rounded), label: const Text('Search again')),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(onPressed: _bleSetup, icon: const Icon(Icons.bluetooth_rounded), label: const Text('New board? Set up Wi-Fi')),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(onPressed: _scanQr, icon: const Icon(Icons.qr_code_scanner_rounded), label: const Text('Scan QR'))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManualConnectPage()));
                        },
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Manual'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 22),
                  const Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _Step('1', 'Plug in the board. The screen shows its face.'),
                      SizedBox(height: 10),
                      _Step('2', 'A brand-new board shows a QR code. Scan it with your camera to join its Wi-Fi, then open this app.'),
                      SizedBox(height: 10),
                      _Step('3', 'Pick your home Wi-Fi here. After that it reconnects by itself every time.'),
                    ]),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final String n, text;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 24, height: 24, alignment: Alignment.center, decoration: BoxDecoration(color: HubColors.accent.withValues(alpha: 0.16), shape: BoxShape.circle), child: Text(n, style: const TextStyle(color: HubColors.accent, fontWeight: FontWeight.w700, fontSize: 13))),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(color: HubColors.muted, fontSize: 14, height: 1.4))),
      ]);
}

/// Rings that grow outward from the board while it is being searched for.
class _Radar extends StatelessWidget {
  const _Radar();
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final centre = size.center(Offset.zero);
        for (var k = 0; k < 3; k++) {
          final p = ((t * 0.5) + k / 3) % 1.0;
          c.drawCircle(centre, 70 + p * 70, Paint()..color = HubColors.accent.withValues(alpha: (1 - p) * 0.35)..style = PaintingStyle.stroke..strokeWidth = 2);
        }
      });
}

// ---------------------------------------------------------------- WI-FI SETUP (board in setup mode)
class WifiSetupPage extends StatefulWidget {
  const WifiSetupPage({super.key, required this.api, required this.boardId});
  final HttpApi api;
  final String boardId;
  @override
  State<WifiSetupPage> createState() => _WifiSetupPageState();
}

class _WifiSetupPageState extends State<WifiSetupPage> {
  final _ssid = TextEditingController(), _pass = TextEditingController();
  List<String> _nets = [];
  bool _scanning = true, _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    for (var i = 0; i < 6; i++) {
      try {
        final r = await http.get(Uri.parse('http://${widget.api.host}/api/scan')).timeout(const Duration(seconds: 4));
        final l = (jsonDecode(r.body) as List).map((e) => '$e').toSet().toList();
        if (l.isNotEmpty) { if (mounted) setState(() => _nets = l); break; }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _save() async {
    final ssid = _ssid.text.trim();
    if (ssid.isEmpty) { setState(() => _msg = 'Choose your Wi-Fi network first.'); return; }
    setState(() { _busy = true; _msg = 'Sending to the board…'; });
    try {
      await widget.api.wifi(ssid, _pass.text);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _msg = 'The board is restarting and joining "$ssid". This takes about 20 seconds…');
    final f = await Discovery.waitFor(widget.boardId, limit: const Duration(seconds: 75));
    if (!mounted) return;
    if (f != null) {
      Navigator.pop(context);
    } else {
      setState(() { _busy = false; _msg = 'Not found yet. Check the password and that your phone is back on your home Wi-Fi, then try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Connect your board to Wi-Fi')),
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
          const Text('Pick the Wi-Fi network your phone normally uses (2.4 GHz). The board remembers it and reconnects on its own.', style: TextStyle(color: HubColors.muted, height: 1.45)),
          const SizedBox(height: 16),
          if (_scanning && _nets.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final n in _nets.take(8))
                  ListTile(
                    leading: const Icon(Icons.wifi_rounded, color: HubColors.accent),
                    title: Text(n),
                    trailing: _ssid.text == n ? const Icon(Icons.check_circle_rounded, color: HubColors.ok) : null,
                    onTap: _busy ? null : () => setState(() => _ssid.text = n),
                  ),
                if (_nets.isEmpty) const ListTile(title: Text('No networks found. Type the name below.', style: TextStyle(color: HubColors.muted))),
              ]),
            ),
          const SizedBox(height: 14),
          TextField(controller: _ssid, autocorrect: false, decoration: const InputDecoration(labelText: 'Network name')),
          const SizedBox(height: 10),
          TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Connecting…' : 'Connect board')),
          if (_msg != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_msg!, style: const TextStyle(color: HubColors.muted, height: 1.45))),
        ]),
      );
}

// ---------------------------------------------------------------- HOME
const _icons = <String, IconData>{
  'eyes': Icons.remove_red_eye_rounded,
  'bounce': Icons.sports_basketball_rounded,
  'matrix': Icons.code_rounded,
  'stars': Icons.auto_awesome_rounded,
  'plasma': Icons.gradient_rounded,
  'clock': Icons.schedule_rounded,
  'name': Icons.badge_rounded,
  'message': Icons.chat_bubble_rounded,
  'info': Icons.info_rounded,
  'life': Icons.grid_on_rounded,
  'mandel': Icons.filter_vintage_rounded,
  'weather': Icons.wb_cloudy_rounded,
  'pet': Icons.pets_rounded,
  'pomo': Icons.timer_rounded,
  'ping': Icons.network_check_rounded,
  'buddy': Icons.smart_toy_rounded,
  'bars': Icons.equalizer_rounded,
  'nowplaying': Icons.music_note_rounded,
  'canvas': Icons.brush_rounded,
  'anim': Icons.animation_rounded,
  'pair': Icons.qr_code_2_rounded,
};

const _tints = <String, List<Color>>{
  'eyes': [Color(0xFF0B3C4D), Color(0xFF0A1A28)],
  'bounce': [Color(0xFF4A2A63), Color(0xFF1B1030)],
  'matrix': [Color(0xFF0B3D1E), Color(0xFF04110A)],
  'stars': [Color(0xFF1C2155), Color(0xFF080A1C)],
  'plasma': [Color(0xFF6B2A6E), Color(0xFF1C2A6E)],
  'clock': [Color(0xFF2A3350), Color(0xFF10141F)],
  'name': [Color(0xFF6E2A52), Color(0xFF241028)],
  'life': [Color(0xFF1E4B52), Color(0xFF0A1A1E)],
  'mandel': [Color(0xFF5A3A12), Color(0xFF1A1004)],
  'weather': [Color(0xFF14407A), Color(0xFF0A1A33)],
  'pet': [Color(0xFF6B3A2A), Color(0xFF241210)],
  'pomo': [Color(0xFF6B2A2A), Color(0xFF241010)],
  'ping': [Color(0xFF1E4B3A), Color(0xFF0A1A14)],
  'buddy': [Color(0xFF2A4A6B), Color(0xFF101A28)],
  'bars': [Color(0xFF5A2A6B), Color(0xFF1C1030)],
  'nowplaying': [Color(0xFF6B2A5A), Color(0xFF241020)],
  'canvas': [Color(0xFF2A6B5A), Color(0xFF10241E)],
  'anim': [Color(0xFF6B5A2A), Color(0xFF241E10)],
  'pair': [Color(0xFF3A3A4A), Color(0xFF14141C)],
};

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api, required this.initial});
  final Api api;
  final Map<String, dynamic> initial;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late Api _api = widget.api;
  late Map<String, dynamic> _data = widget.initial;
  final _msg = TextEditingController();
  Timer? _timer;
  bool _online = true, _finding = false;
  int _fails = 0;
  String _mood = 'auto';
  bool _notif = false, _music = false, _loc = false;

  List get _scenes => (_data['scenes'] as List).where((s) => s['id'] != 'message').toList();
  bool get _ap => _data['ap'] == true;
  String get _id => '${_data['id'] ?? ''}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _api.close();
    _msg.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) { _refresh(); _checkPerms(); }
  }

  Future<void> _startup() async {
    await PhoneSync.apply(_api, id: _id);
    PhoneSync.autoConfigure(_api);
    await _checkPerms();
    final p = await SharedPreferences.getInstance();
    if (!(p.getBool('onboarded') ?? false) && mounted && !_ap) {
      await p.setBool('onboarded', true);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PermissionsPage(api: _api, firstRun: true)));
      _checkPerms();
    }
  }

  Future<void> _checkPerms() async {
    final n = await PhoneBridge.isGranted();
    final c = await PhoneBridge.getConfig();
    final l = await Permission.locationWhenInUse.isGranted;
    if (mounted) setState(() { _notif = n && c['mirror'] == true; _music = n && c['media'] == true; _loc = l; });
  }

  // After locking or changing the token, keep talking to the board with the new token.
  void _onToken(String t) {
    final a = _api;
    if (a is HttpApi) {
      setState(() => _api = HttpApi(a.host, token: t));
      PhoneSync.apply(_api, id: _id);
    }
  }

  Future<void> _refresh() async {
    try {
      final d = await _api.list();
      if (mounted) setState(() { _data = d; _online = true; _fails = 0; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _online = false; _fails++; });
      if (_fails >= 2) _findAgain();
    }
  }

  /// The board's address changed (router restarted, new IP)? Find it again by its id and carry on.
  Future<void> _findAgain() async {
    final a = _api;
    if (_finding || a is! HttpApi) return;
    _finding = true;
    try {
      await for (final f in Discovery.scan(lastHost: a.host, wantId: _id.isEmpty ? null : _id)) {
        if (f.ap) continue;
        if (_id.isNotEmpty && f.id != _id) continue;
        final p = await SharedPreferences.getInstance();
        await p.setString('host', f.host);
        if (!mounted) return;
        setState(() => _api = HttpApi(f.host, token: a.token));
        await PhoneSync.apply(_api, id: f.id);
        _fails = 0;
        _refresh();
        return;
      }
    } finally {
      _finding = false;
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _send(Map<String, dynamic> body) async {
    try {
      final r = await _api.cmd(body);
      if (r['ok'] != true) { _toast('Board: ${r['error'] ?? 'error'}'); return false; }
      if (mounted) setState(() => _online = true);
      return true;
    } on LockedException {
      _toast('The board is locked. Reconnect with its token.');
      return false;
    } catch (_) {
      if (mounted) setState(() => _online = false);
      _toast('Board not reachable');
      return false;
    }
  }

  Future<void> _openScene(Map scene) async {
    final page = specialPage(scene['id'] as String, _api);
    if (page != null) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      _refresh();
      return;
    }
    final args = (scene['args'] as List?) ?? [];
    if (args.isEmpty || scene['id'] == 'eyes') {
      if (await _send({'cmd': 'scene', 'id': scene['id'], if (scene['id'] == 'eyes') 'args': {'mood': _mood}})) setState(() => _data['scene'] = scene['id']);
      return;
    }
    final values = <String, dynamic>{};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: HubColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(22, 22, 22, 22 + MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(builder: (ctx, set) {
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(scene['name'], style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final a in args) ...[
              if (a['type'] == 'choice')
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final o in a['options'])
                    ChoiceChip(label: Text(o.toString()), selected: values[a['key']] == o, onSelected: (_) => set(() => values[a['key']] = o)),
                ])
              else
                TextField(maxLength: a['max'] ?? 16, decoration: InputDecoration(labelText: a['key']), onChanged: (v) => values[a['key']] = v),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (await _send({'cmd': 'scene', 'id': scene['id'], 'args': values})) setState(() => _data['scene'] = scene['id']);
                },
                child: const Text('Start'),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  Future<void> _setMood(String m) async {
    setState(() => _mood = m);
    if (await _send({'cmd': 'mood', 'mood': m})) setState(() => _data['scene'] = 'eyes');
  }

  Future<void> _sendMsg() async {
    final t = _msg.text.trim();
    if (t.isEmpty) return;
    if (await _send({'cmd': 'msg', 'text': t, 'ttl': 10})) {
      if (!mounted) return;
      _msg.clear();
      FocusScope.of(context).unfocus();
      _toast('Sent to the display');
    }
  }

  Future<void> _choose(String title, Map<String, int> opts, String cmd, String key) async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(backgroundColor: HubColors.surface, title: Text(title), children: [
        for (final e in opts.entries) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, e.value), child: Text(e.key)),
      ]),
    );
    if (v != null && await _send({'cmd': cmd, key: v})) _toast('Done');
  }

  Future<void> _confirm(String title, String cmd) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(backgroundColor: HubColors.surface, title: Text(title), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
      ]),
    );
    if (ok == true) {
      await _send({'cmd': cmd});
      if (mounted) Navigator.of(context).pop();
    }
  }

  Widget _preview(String id) {
    switch (id) {
      case 'eyes':
        return FaceScreen(mood: _mood == 'auto' ? 'normal' : _mood);
      case 'buddy':
        return const FaceScreen(mood: 'happy', talking: true);
      case 'nowplaying':
      case 'bars':
        return const MusicScreen();
      case 'weather':
        return const WeatherScreen();
      case 'message':
        return const NotifScreen();
      default:
        final t = _tints[id] ?? const [Color(0xFF2A3350), Color(0xFF10141F)];
        return GradientScreen(icon: _icons[id] ?? Icons.apps_rounded, a: t[0], b: t[1]);
    }
  }

  String _sceneName(String id) {
    for (final s in (_data['scenes'] as List)) {
      if (s['id'] == id) return '${s['name']}';
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final current = '${_data['scene']}';
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 40), children: [
            // ---- header
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('ESP32 Hub', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  const SizedBox(height: 2),
                  Text('${_api.label}  ·  fw ${_data['fw']}', style: const TextStyle(color: HubColors.muted, fontSize: 13)),
                ]),
              ),
              _menu(),
            ]),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: _online
                  ? const StatusPill(color: HubColors.ok, label: 'Connected')
                  : StatusPill(color: HubColors.warn, label: _finding ? 'Finding your board…' : 'Reconnecting…', pulse: true),
            ),
            const SizedBox(height: 18),
            if (_ap)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Panel(
                  color: HubColors.warn.withValues(alpha: 0.1),
                  borderColor: HubColors.warn.withValues(alpha: 0.4),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WifiSetupPage(api: _api as HttpApi, boardId: _id))),
                  child: const Row(children: [
                    Icon(Icons.wifi_tethering_rounded, color: HubColors.warn),
                    SizedBox(width: 12),
                    Expanded(child: Text('This board is not on your Wi-Fi yet. Tap to set it up.', style: TextStyle(height: 1.35))),
                    Icon(Icons.chevron_right_rounded),
                  ]),
                ),
              ),
            // ---- what is on the display right now
            DisplayFrame(child: AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: KeyedSubtree(key: ValueKey('$current$_mood'), child: _preview(current)))),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('ON THE DISPLAY', style: TextStyle(color: HubColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                  const SizedBox(height: 3),
                  Text(_sceneName(current), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                ]),
              ),
              IconButton.filledTonal(onPressed: () async { if (await _send({'cmd': 'next'})) _refresh(); }, icon: const Icon(Icons.skip_next_rounded), tooltip: 'Next scene'),
            ]),
            // ---- message
            const SectionTitle('Send a message'),
            Row(children: [
              Expanded(child: TextField(controller: _msg, maxLength: 60, decoration: const InputDecoration(hintText: 'Good morning!', counterText: ''), onSubmitted: (_) => _sendMsg())),
              const SizedBox(width: 10),
              IconButton.filled(onPressed: _sendMsg, style: IconButton.styleFrom(minimumSize: const Size(52, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), icon: const Icon(Icons.arrow_upward_rounded)),
            ]),
            // ---- mood
            const SectionTitle('How should it feel?'),
            SizedBox(
              height: 96,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                _MoodChip(label: 'Auto', mood: 'normal', selected: _mood == 'auto', onTap: () => _setMood('auto')),
                for (final m in moodOrder.skip(1)) _MoodChip(label: m, mood: m, selected: _mood == m, onTap: () => _setMood(m)),
              ]),
            ),
            // ---- phone magic
            SectionTitle('Phone magic', trailing: TextButton(onPressed: _openPerms, child: const Text('Set up'))),
            Panel(
              padding: EdgeInsets.zero,
              onTap: _openPerms,
              child: Column(children: [
                _MagicRow(icon: Icons.notifications_active_rounded, title: 'Notifications', sub: 'Pop up on the display', on: _notif),
                const Divider(),
                _MagicRow(icon: Icons.music_note_rounded, title: 'Music', sub: 'Shows the song that is playing', on: _music),
                const Divider(),
                _MagicRow(icon: Icons.place_rounded, title: 'Weather', sub: 'Uses your location', on: _loc),
              ]),
            ),
            // ---- scenes
            const SectionTitle('Scenes'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.25,
              children: [for (final s in _scenes) _SceneTile(scene: s as Map, active: current == s['id'], preview: _preview('${s['id']}'), onTap: () => _openScene(s))],
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _openPerms() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PermissionsPage(api: _api)));
    _checkPerms();
  }

  Widget _menu() => PopupMenuButton<String>(
        color: HubColors.surface2,
        icon: const Icon(Icons.more_horiz_rounded),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (v) {
          switch (v) {
            case 'auto':
              _choose('Auto-rotate scenes', {'Off': 0, 'Every 10 s': 10, 'Every 30 s': 30, 'Every 60 s': 60}, 'auto', 'sec');
            case 'tz':
              _choose('Time zone', {'India (UTC+5:30)': 19800, 'UTC': 0, 'Dubai (UTC+4)': 14400, 'Europe (UTC+1)': 3600, 'Japan (UTC+9)': 32400, 'US East (UTC-5)': -18000, 'US West (UTC-8)': -28800}, 'tz', 'sec');
            case 'settings':
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(api: _api, data: _data, onToken: _onToken)));
            case 'wifi':
              if (_api is HttpApi) Navigator.of(context).push(MaterialPageRoute(builder: (_) => WifiSetupPage(api: _api as HttpApi, boardId: _id)));
            case 'forget':
              _confirm('Forget Wi-Fi and restart the board in setup mode?', 'forget');
            case 'reboot':
              _confirm('Restart the board?', 'reboot');
            case 'disc':
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartPage()));
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'settings', child: Text('Settings')),
          PopupMenuItem(value: 'auto', child: Text('Auto-rotate')),
          PopupMenuItem(value: 'tz', child: Text('Time zone')),
          PopupMenuItem(value: 'wifi', child: Text('Change Wi-Fi')),
          PopupMenuItem(value: 'forget', child: Text('Forget Wi-Fi')),
          PopupMenuItem(value: 'reboot', child: Text('Restart board')),
          PopupMenuItem(value: 'disc', child: Text('Switch board')),
        ],
      );
}

class _MoodChip extends StatelessWidget {
  const _MoodChip({required this.label, required this.mood, required this.selected, required this.onTap});
  final String label, mood;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: GestureDetector(
          onTap: onTap,
          child: Column(children: [
            Container(
              width: 80,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: selected ? HubColors.accent : HubColors.line, width: selected ? 2 : 1)),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: AspectRatio(aspectRatio: 160 / 128, child: label == 'Auto' ? const _AutoFace() : _StillFace(mood: mood))),
            ),
            const SizedBox(height: 6),
            Text(label[0].toUpperCase() + label.substring(1), style: TextStyle(fontSize: 12, color: selected ? HubColors.accent : HubColors.muted, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

/// A face frozen in one frame (cheap: painted once, not animated) for the mood picker.
class _StillFace extends StatelessWidget {
  const _StillFace({required this.mood});
  final String mood;
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _StillPainter(mood), size: Size.infinite);
}

class _StillPainter extends CustomPainter {
  _StillPainter(this.mood);
  final String mood;
  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 160;
    canvas.drawRect(Offset.zero & size, Paint()..color = HubColors.screen);
    paintFace(canvas, mood, size.width / 2, size.height / 2 - 8 * u, u, 1.0);
  }

  @override
  bool shouldRepaint(_StillPainter old) => old.mood != mood;
}

class _AutoFace extends StatelessWidget {
  const _AutoFace();
  @override
  Widget build(BuildContext context) => Container(
        color: HubColors.screen,
        child: const Center(child: Icon(Icons.auto_awesome_rounded, color: HubColors.accent, size: 26)),
      );
}

class _MagicRow extends StatelessWidget {
  const _MagicRow({required this.icon, required this.title, required this.sub, required this.on});
  final IconData icon;
  final String title, sub;
  final bool on;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: (on ? HubColors.ok : HubColors.accent).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 21, color: on ? HubColors.ok : HubColors.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(color: HubColors.muted, fontSize: 13)),
            ]),
          ),
          Text(on ? 'On' : 'Set up', style: TextStyle(color: on ? HubColors.ok : HubColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      );
}

class _SceneTile extends StatelessWidget {
  const _SceneTile({required this.scene, required this.active, required this.preview, required this.onTap});
  final Map scene;
  final bool active;
  final Widget preview;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: HubColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? HubColors.accent : HubColors.line, width: active ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(15), child: SizedBox.expand(child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox(width: 160, height: 128, child: preview))))),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 5),
              child: Row(children: [
                Expanded(child: Text('${scene['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
                if (active) const Icon(Icons.circle, size: 8, color: HubColors.ok),
              ]),
            ),
          ]),
        ),
      );
}
