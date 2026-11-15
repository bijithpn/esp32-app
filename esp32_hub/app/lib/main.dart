import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'discovery.dart';
import 'features.dart';
import 'manual.dart';
import 'phone.dart';
import 'settings.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PhoneBridge.bindWifi();
  runApp(const HubApp());
}

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
  bool _remoteSaved = false;
  int _run = 0;
  String? _connectError; // why the last board that answered could still not be opened

  /// Says what was searched, so "not found" is never a mystery.
  String get _why {
    if (_connectError != null) return _connectError!;
    final nets = Discovery.lastPrefixes;
    if (nets.isEmpty) return 'Your phone does not seem to be on a Wi-Fi network. Turn Wi-Fi on and join the same network as the board.';
    return 'Searched ${nets.map((n) => '$n.x').join(', ')}. The board was not there. Check that it is powered, and that it is on this same Wi-Fi (its screen shows an IP address when it is).';
  }

  @override
  void initState() {
    super.initState();
    _auto();
  }

  @override
  void dispose() {
    _run++; // stops a search that is still running
    super.dispose();
  }

  Future<void> _auto() async {
    final run = ++_run;
    _connectError = null;
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
      await _setupBoard(f, p);
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
    } catch (e) {
      _connectError = 'A board answered at ${f.host}, but opening it failed: ${'$e'.replaceAll('Exception: ', '')}. Tap Search again.';
      return false;
    }
  }

  Future<String?> _askToken() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This board is locked'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Hint('Enter its token. Scan the QR from the board\'s "Pair (QR)" scene to fill it in automatically.'),
          const SizedBox(height: 14),
          TextField(controller: c, autocorrect: false, decoration: const InputDecoration(labelText: 'Token')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  /// The phone is on the board's hotspot: open the Wi-Fi setup for it, and when that is done connect straight to the board.
  Future<void> _setupBoard(FoundBoard f, SharedPreferences p) async {
    if (!mounted) return;
    setState(() => _status = 'Found a new board. Let\'s get it online.');
    final found = await Navigator.of(context).push<FoundBoard>(MaterialPageRoute(builder: (_) => WifiSetupPage(api: HttpApi(f.host), boardId: f.id)));
    _skipAp = true;
    // The setup page already found the board on the home Wi-Fi: connect straight to it instead of searching again.
    if (found != null && mounted && !found.ap && await _connectTo(found, p)) return;
    if (mounted) _auto();
  }

  /// Right after joining the board's hotspot the phone may not have an address yet, so keep asking the board
  /// (192.168.4.1) for a while instead of giving up on the first try.
  Future<FoundBoard?> _waitForHotspotBoard() async {
    final run = ++_run;
    for (var i = 0; i < 20 && mounted && run == _run; i++) {
      await PhoneBridge.bindWifi(force: true);
      final f = await Discovery.probe('192.168.4.1', timeout: const Duration(seconds: 2));
      if (f != null) return f;
      await Future.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  Future<void> _scanQr() async {
    FocusScope.of(context).unfocus();
    final v = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (v == null || !mounted) return;
    final wifi = HubWifiQr.parse(v);
    if (wifi != null) {
      // The setup screen's QR: join the board's hotspot, then the normal search finds it and asks for the home Wi-Fi.
      setState(() { _phase = _Phase.searching; _status = 'Joining the board\'s Wi-Fi…'; });
      final ok = await PhoneBridge.joinWifi(wifi.ssid, wifi.pass);
      if (!mounted) return;
      if (ok) {
        _skipAp = false;
        setState(() => _status = 'Connected to the board\'s Wi-Fi. Opening setup…');
        final f = await _waitForHotspotBoard();
        if (!mounted) return;
        if (f != null) {
          await _setupBoard(f, await SharedPreferences.getInstance());
        } else {
          setState(() => _phase = _Phase.notFound);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Joined the board\'s Wi-Fi, but it did not answer. Wait a few seconds and tap Search again.')));
        }
      } else {
        setState(() => _phase = _Phase.notFound);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join automatically. Join "${wifi.ssid}" (password ${wifi.pass}) in your phone\'s Wi-Fi settings, then tap Search again.')));
      }
      return;
    }
    final info = PairInfo.parse(v);
    if (info == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('host', info.ip);
    await p.setString('token', info.token);
    await p.setString('dev_id', info.id);
    _auto();
  }

  @override
  Widget build(BuildContext context) {
    final searching = _phase == _Phase.searching;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(child: SizedBox(width: 170, child: DisplayFrame(child: FaceScreen(mood: searching ? 'thinking' : 'sad')))),
                const SizedBox(height: 28),
                Text(searching ? _status : 'Can\'t find your board', textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.2)),
                const SizedBox(height: 10),
                Text(
                  searching ? 'Keep the board powered on and your phone on the same Wi-Fi.' : _why,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: HubColors.muted, fontSize: 15, height: 1.45),
                ),
                const SizedBox(height: 28),
                if (searching)
                  ClipRRect(borderRadius: BorderRadius.circular(4), child: const LinearProgressIndicator(minHeight: 3))
                else ...[
                  FilledButton.icon(onPressed: _auto, icon: const Icon(Icons.refresh_rounded), label: const Text('Search again')),
                  const SizedBox(height: 20),
                  Group(children: [
                    Row2(icon: Icons.qr_code_scanner_rounded, title: 'Scan the board\'s QR code', sub: 'From its "Pair (QR)" screen', trailing: const Icon(Icons.chevron_right_rounded, color: HubColors.muted), onTap: _scanQr),
                    Row2(
                      icon: Icons.tune_rounded,
                      title: 'Enter the address yourself',
                      sub: 'IP address or internet (MQTT) link',
                      trailing: const Icon(Icons.chevron_right_rounded, color: HubColors.muted),
                      onTap: () async {
                        FocusScope.of(context).unfocus();
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManualConnectPage()));
                      },
                    ),
                  ]),
                  const SizedBox(height: 28),
                  const Text('Not sure what to do?', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 10),
                  const _Step('1', 'Plug in the board. You should see a face, or a SETUP screen on a new board.'),
                  const SizedBox(height: 8),
                  const _Step('2', 'On the SETUP screen, scan its QR code with the camera to join the hotspot "ESP32-Hub", then open this app again.'),
                  const SizedBox(height: 8),
                  const _Step('3', 'Pick your home Wi-Fi when the app asks. The board remembers it and reconnects by itself.'),
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
        SizedBox(width: 22, child: Text(n, style: const TextStyle(color: HubColors.text, fontWeight: FontWeight.w700, fontSize: 14, height: 1.45))),
        Expanded(child: Text(text, style: const TextStyle(color: HubColors.muted, fontSize: 14, height: 1.45))),
      ]);
}

// ---------------------------------------------------------------- WI-FI SETUP
enum _Join { form, joining }

/// Gives the board a Wi-Fi network. Works from the board's setup hotspot and also to change the network later.
/// With firmware 0.4.1+ the board tries the network while its hotspot stays up, so this page can say whether it worked
/// (wrong password, network not found, ...) instead of leaving you guessing. Pops with the board once it is back online.
class WifiSetupPage extends StatefulWidget {
  const WifiSetupPage({super.key, required this.api, required this.boardId});
  final HttpApi api;
  final String boardId;
  @override
  State<WifiSetupPage> createState() => _WifiSetupPageState();
}

class _WifiSetupPageState extends State<WifiSetupPage> {
  final _ssid = TextEditingController(), _pass = TextEditingController();
  final _ssidFocus = FocusNode();
  List<String> _nets = [];
  bool _scanning = false, _showPass = false;
  int _scanRun = 0;
  _Join _join = _Join.form;
  String? _msg;
  bool _msgIsError = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _scanRun++;
    _ssid.dispose();
    _pass.dispose();
    _ssidFocus.dispose();
    super.dispose();
  }

  /// Asks the board for the networks it sees. A scan takes a few seconds, so ask again until something comes back.
  Future<void> _scan() async {
    final run = ++_scanRun;
    setState(() => _scanning = true);
    for (var i = 0; i < 12 && mounted && run == _scanRun; i++) {
      try {
        final l = await widget.api.scanNetworks();
        if (!mounted || run != _scanRun) return;
        if (l.isNotEmpty) { setState(() => _nets = l); break; }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
    if (mounted && run == _scanRun) setState(() => _scanning = false);
  }

  void _say(String m, {bool error = false}) => setState(() { _msg = m; _msgIsError = error; });

  String _why(String? reason) {
    switch (reason) {
      case 'bad_password':
        return 'The password was not accepted. Check it and try again.';
      case 'own_hotspot':
        return 'That is the board\'s own hotspot. Choose your home Wi-Fi (the one your phone normally uses).';
      case 'not_found':
        return 'The board could not find a network with that name. Check the spelling (capital letters count), that it is a 2.4 GHz network, and that the router is close to the board.';
      default:
        return 'The board could not join in time. Check the name and password and try again.';
    }
  }

  Future<void> _connect() async {
    final ssid = _ssid.text.trim();
    if (ssid.isEmpty) { _say('Choose your Wi-Fi network first.', error: true); return; }
    FocusScope.of(context).unfocus();
    _scanRun++; // stop scanning while the board is busy joining
    setState(() { _join = _Join.joining; _scanning = false; });
    _say('Sending to the board…');
    String? newIp;
    Map<String, dynamic> r;
    try {
      r = await widget.api.wifiSet(ssid, _pass.text);
    } catch (_) {
      r = {'state': 'legacy'}; // an old board reboots before it answers: that is fine, wait for it below
    }
    if (!mounted) return;

    if (r['state'] == 'fail') {
      setState(() => _join = _Join.form);
      _say(_why('${r['reason']}'), error: true);
      _scan();
      return;
    }
    if (r['state'] == 'connecting') {
      final res = await _pollJoin(ssid);
      if (!mounted) return;
      if (res.kind == 'fail') {
        setState(() => _join = _Join.form);
        _say(_why(res.reason), error: true);
        _scan();
        return;
      }
      if (res.kind == 'ok') {
        _say('Joined "$ssid" (${res.ip}). Switching your phone back to your Wi-Fi…');
      }
      if (res.found != null) { Navigator.pop(context, res.found); return; }
      newIp = res.ip;
    } else {
      _say('The board is restarting and joining "$ssid". This takes about 20 seconds…');
    }

    // The board leaves its hotspot now. Let go of it, so the phone goes back to the home Wi-Fi where the board will be.
    await PhoneBridge.leaveHotspot();
    await Future.delayed(const Duration(seconds: 2));
    final f = await Discovery.waitFor(widget.boardId, limit: const Duration(seconds: 70), lastHost: newIp);
    if (!mounted) return;
    if (f != null) {
      Navigator.pop(context, f);
    } else {
      setState(() => _join = _Join.form);
      _say('The board is online, but your phone can\'t see it yet. Make sure the phone is back on your home Wi-Fi, then go back and tap Search again.', error: true);
    }
  }

  /// Polls the board until it says whether the join worked. If the hotspot disappears first (the board already restarted
  /// and the phone moved to the home Wi-Fi) it looks for the board on the network instead.
  Future<({String kind, String? reason, String? ip, FoundBoard? found})> _pollJoin(String ssid) async {
    final end = DateTime.now().add(const Duration(seconds: 60));
    var errors = 0;
    while (DateTime.now().isBefore(end) && mounted) {
      try {
        final s = await widget.api.wifiStatus();
        errors = 0;
        final st = s['state'];
        if (st == 'ok') {
          await PhoneBridge.leaveHotspot(); // the board is on the home Wi-Fi now: let go of its hotspot so the phone switches back
          return (kind: 'ok', reason: null, ip: '${s['ip']}', found: null);
        }
        if (st == 'fail') return (kind: 'fail', reason: '${s['reason']}', ip: null, found: null);
        _say('Connecting to "$ssid"…');
      } catch (_) {
        errors++;
        if (errors >= 3) {
          _say('Looking for the board on your Wi-Fi…');
          await for (final f in Discovery.scan(wantId: widget.boardId)) {
            if (f.ap || f.id != widget.boardId) continue;
            // The board is reachable again, but on which network? Ask it how the attempt went: after a failed try an online
            // board goes back to its old network, after a successful one it restarts (no attempt on record any more).
            try {
              final s = await HttpApi(f.host).wifiStatus();
              if (s['state'] == 'fail') return (kind: 'fail', reason: '${s['reason']}', ip: null, found: null);
              if (s['state'] == 'connecting') break; // still trying: keep polling
            } catch (_) {
              continue;
            }
            return (kind: 'ok', reason: null, ip: f.host, found: f);
          }
          errors = 0;
        }
      }
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    return (kind: 'fail', reason: 'timeout', ip: null, found: null);
  }

  @override
  Widget build(BuildContext context) {
    final joining = _join == _Join.joining;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi for your board')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
        const Hint('Choose the network your phone normally uses. The board remembers it and reconnects on its own. Only 2.4 GHz networks work.'),
        const SizedBox(height: 22),
        Row(children: [
          const Expanded(child: Text('Nearby networks', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
          if (_scanning) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          if (!_scanning) TextButton(onPressed: joining ? null : _scan, child: const Text('Scan again')),
        ]),
        const SizedBox(height: 8),
        if (_nets.isEmpty)
          Panel(child: Text(_scanning ? 'Looking for networks…' : 'No networks found. You can type the name below.', style: const TextStyle(color: HubColors.muted)))
        else
          Group(children: [
            for (final n in _nets.take(7))
              Row2(
                icon: Icons.wifi_rounded,
                title: n,
                trailing: _ssid.text == n ? const Icon(Icons.check_rounded, color: HubColors.ok) : null,
                onTap: joining ? null : () => setState(() => _ssid.text = n),
              ),
          ]),
        const SizedBox(height: 8),
        Group(children: [
          Row2(
            icon: Icons.add_rounded,
            title: 'Other network',
            sub: 'Not in the list, or hidden? Type its name and password',
            onTap: joining ? null : () { setState(() => _ssid.clear()); _ssidFocus.requestFocus(); },
          ),
        ]),
        const SizedBox(height: 20),
        TextField(controller: _ssid, focusNode: _ssidFocus, enabled: !joining, autocorrect: false, enableSuggestions: false, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Network name')),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          enabled: !joining,
          obscureText: !_showPass,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: HubColors.muted), onPressed: () => setState(() => _showPass = !_showPass)),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: joining ? null : _connect, child: Text(joining ? 'Connecting…' : 'Connect board')),
        if (joining) Padding(padding: const EdgeInsets.only(top: 16), child: ClipRRect(borderRadius: BorderRadius.circular(4), child: const LinearProgressIndicator(minHeight: 3))),
        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(_msgIsError ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 18, color: _msgIsError ? HubColors.danger : HubColors.muted),
              const SizedBox(width: 10),
              Expanded(child: Text(_msg!, style: TextStyle(color: _msgIsError ? HubColors.danger : HubColors.muted, height: 1.45, fontSize: 14))),
            ]),
          ),
      ]),
    );
  }
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

/// Preview colour of a scene on the display (used to tint the big preview when a scene has no dedicated painter).
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
  Map<String, dynamic> _stat = {}; // /api/status: Wi-Fi name and signal
  final _msg = TextEditingController();
  Timer? _timer;
  bool _online = true, _finding = false, _refreshing = false;
  int _fails = 0, _tick = 0;
  String _mood = 'auto';
  bool _notif = false, _music = false, _loc = false;

  List get _scenes => (_data['scenes'] as List).where((s) => s['id'] != 'message').toList();
  bool get _ap => _data['ap'] == true;
  String get _id => '${_data['id'] ?? ''}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
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
    if (state == AppLifecycleState.resumed) {
      PhoneBridge.bindWifi(force: _api is HttpApi);
      _refresh();
      _checkPerms();
    }
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

  /// Asks the board how it is doing. Called every few seconds, so the connection status on screen is always current.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final d = await _api.list();
      Map<String, dynamic> st = _stat;
      if (_tick++ % 3 == 0) {
        try { st = await _api.status(); } catch (_) {}
      }
      if (mounted) setState(() { _data = d; _stat = st; _online = true; _fails = 0; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _online = false; _fails++; });
      if (_fails >= 2) _findAgain();
    } finally {
      _refreshing = false;
    }
  }

  /// The board's address changed (router restarted, new IP, joined a new Wi-Fi)? Find it again by its id and carry on.
  Future<void> _findAgain() async {
    final a = _api;
    if (_finding || a is! HttpApi) return;
    setState(() => _finding = true);
    try {
      await for (final f in Discovery.scan(lastHost: a.host, wantId: _id.isEmpty ? null : _id)) {
        if (_id.isNotEmpty && f.id != _id) continue;
        if (f.ap && f.host == a.host) continue; // still the same dead hotspot address
        await _switchTo(f);
        return;
      }
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  Future<void> _switchTo(FoundBoard f) async {
    final a = _api;
    final p = await SharedPreferences.getInstance();
    await p.setString('host', f.host);
    if (!mounted) return;
    setState(() { _api = HttpApi(f.host, token: a is HttpApi ? a.token : ''); _fails = 0; });
    await PhoneSync.apply(_api, id: f.id);
    _refresh();
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
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
      builder: (ctx) => SimpleDialog(title: Text(title), children: [
        for (final e in opts.entries) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, e.value), child: Text(e.key)),
      ]),
    );
    if (v != null && await _send({'cmd': cmd, key: v})) _toast('Done');
  }

  Future<void> _confirm(String title, String cmd) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(title: Text(title), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
      ]),
    );
    if (ok == true) {
      await _send({'cmd': cmd});
      // the board restarts: go back to the start screen, which finds it again by itself
      if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartPage()));
    }
  }

  Future<void> _wifiSetup() async {
    final a = _api;
    if (a is! HttpApi) { _toast('Connect to the board first (same Wi-Fi, or its ESP32-Hub hotspot), then change its Wi-Fi.'); return; }
    final f = await Navigator.of(context).push<FoundBoard>(MaterialPageRoute(builder: (_) => WifiSetupPage(api: a, boardId: _id)));
    if (f != null && mounted) await _switchTo(f);
    _refresh();
  }

  Widget _preview(String id) {
    switch (id) {
      case 'eyes':
        return FaceScreen(mood: _mood == 'auto' ? 'normal' : _mood);
      case 'buddy':
        return const FaceScreen(mood: 'happy', talking: true);
      case 'nowplaying':
        return const MusicScreen();
      case 'bars':
        return const BarsScreen();
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

  String _signal(num rssi) => rssi > -55 ? 'strong signal' : rssi > -67 ? 'good signal' : rssi > -78 ? 'fair signal' : 'weak signal';

  Widget _status() {
    final ssid = '${_stat['ssid'] ?? ''}';
    final rssi = _stat['rssi'];
    final wifi = (!_ap && ssid.isNotEmpty) ? '$ssid${rssi is num && rssi != 0 ? '  ·  ${_signal(rssi)}' : ''}' : null;
    final Widget pill;
    if (!_online) {
      pill = StatusPill(color: HubColors.warn, label: _finding ? 'Looking for your board…' : 'Reconnecting…', pulse: true);
    } else if (_ap) {
      pill = const StatusPill(color: HubColors.warn, label: 'Setup mode · no home Wi-Fi yet');
    } else {
      pill = const StatusPill(color: HubColors.ok, label: 'Connected');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      pill,
      if (wifi != null && _online) Padding(padding: const EdgeInsets.only(top: 8, left: 2), child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.wifi_rounded, size: 15, color: HubColors.muted),
        const SizedBox(width: 6),
        Flexible(child: Text(wifi, overflow: TextOverflow.ellipsis, style: const TextStyle(color: HubColors.muted, fontSize: 13))),
      ])),
    ]);
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
                  const Text('ESP32 Hub', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
                  const SizedBox(height: 2),
                  Text('${_api.label}  ·  firmware ${_data['fw']}', style: const TextStyle(color: HubColors.muted, fontSize: 13)),
                ]),
              ),
              _menu(),
            ]),
            const SizedBox(height: 14),
            Align(alignment: Alignment.centerLeft, child: _status()),
            const SizedBox(height: 16),
            if (_ap && _online)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Panel(
                  color: HubColors.warn.withValues(alpha: 0.08),
                  borderColor: HubColors.warn.withValues(alpha: 0.35),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('The board is not on your Wi-Fi', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    const Hint('It is running its own hotspot. Give it your home Wi-Fi so it works anywhere in the house and reconnects after a power cut.'),
                    const SizedBox(height: 14),
                    FilledButton(onPressed: _wifiSetup, child: const Text('Set up Wi-Fi')),
                  ]),
                ),
              ),
            // ---- what is on the display right now
            DisplayFrame(child: AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: KeyedSubtree(key: ValueKey('$current$_mood'), child: _preview(current)))),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('On the display', style: TextStyle(color: HubColors.muted, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(_sceneName(current), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                ]),
              ),
              IconButton.outlined(
                onPressed: () async { if (await _send({'cmd': 'next'})) _refresh(); },
                icon: const Icon(Icons.skip_next_rounded),
                tooltip: 'Next scene',
                style: IconButton.styleFrom(side: const BorderSide(color: HubColors.line), minimumSize: const Size(48, 48)),
              ),
            ]),
            // ---- message
            const SectionTitle('Send a message'),
            Row(children: [
              Expanded(child: TextField(controller: _msg, maxLength: 60, textInputAction: TextInputAction.send, decoration: const InputDecoration(hintText: 'Good morning!', counterText: ''), onSubmitted: (_) => _sendMsg())),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: _sendMsg,
                style: IconButton.styleFrom(backgroundColor: HubColors.text, foregroundColor: HubColors.bg, minimumSize: const Size(54, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ]),
            // ---- mood
            const SectionTitle('Mood'),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                _MoodChip(label: 'Auto', color: HubColors.muted, selected: _mood == 'auto', onTap: () => _setMood('auto')),
                for (final m in moodOrder.skip(1)) _MoodChip(label: m, color: moodSpecs[m]!.color, selected: _mood == m, onTap: () => _setMood(m)),
              ]),
            ),
            // ---- phone features
            SectionTitle('From your phone', trailing: TextButton(onPressed: _openPerms, child: const Text('Manage'))),
            Group(children: [
              _MagicRow(icon: Icons.notifications_none_rounded, title: 'Notifications', sub: 'Pop up on the display', on: _notif, onTap: _openPerms),
              _MagicRow(icon: Icons.music_note_outlined, title: 'Music', sub: 'Shows the song that is playing', on: _music, onTap: _openPerms),
              _MagicRow(icon: Icons.place_outlined, title: 'Weather', sub: 'Uses your location', on: _loc, onTap: _openPerms),
            ]),
            // ---- scenes
            const SectionTitle('Scenes'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.5,
              children: [for (final s in _scenes) _SceneTile(scene: s as Map, active: current == s['id'], onTap: () => _openScene(s))],
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
        icon: const Icon(Icons.more_horiz_rounded),
        onSelected: (v) {
          switch (v) {
            case 'auto':
              _choose('Auto-rotate scenes', {'Off': 0, 'Every 10 s': 10, 'Every 30 s': 30, 'Every 60 s': 60}, 'auto', 'sec');
            case 'tz':
              _choose('Time zone', {'India (UTC+5:30)': 19800, 'UTC': 0, 'Dubai (UTC+4)': 14400, 'Europe (UTC+1)': 3600, 'Japan (UTC+9)': 32400, 'US East (UTC-5)': -18000, 'US West (UTC-8)': -28800}, 'tz', 'sec');
            case 'settings':
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(api: _api, data: _data, onToken: _onToken)));
            case 'pairing':
              _send({'cmd': 'pairing'}).then((ok) { if (ok) _toast('Pairing mode on for 10 minutes. On a phone, join the Wi-Fi "ESP32-Hub" (password hub12345) or scan the QR on the board.'); });
            case 'wifi':
              _wifiSetup();
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
          PopupMenuItem(value: 'pairing', child: Text('Pairing mode (hotspot)')),
          PopupMenuItem(value: 'wifi', child: Text('Change Wi-Fi')),
          PopupMenuItem(value: 'forget', child: Text('Forget Wi-Fi')),
          PopupMenuItem(value: 'reboot', child: Text('Restart board')),
          PopupMenuItem(value: 'disc', child: Text('Switch board')),
        ],
      );
}

class _MoodChip extends StatelessWidget {
  const _MoodChip({required this.label, required this.color, required this.selected, required this.onTap});
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          avatar: Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          label: Text(label[0].toUpperCase() + label.substring(1)),
          selected: selected,
          side: BorderSide(color: selected ? HubColors.text : HubColors.line),
          onSelected: (_) => onTap(),
        ),
      );
}

class _MagicRow extends StatelessWidget {
  const _MagicRow({required this.icon, required this.title, required this.sub, required this.on, required this.onTap});
  final IconData icon;
  final String title, sub;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Row2(
        icon: icon,
        iconColor: on ? HubColors.ok : HubColors.muted,
        title: title,
        sub: sub,
        onTap: onTap,
        trailing: on
            ? const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.check_rounded, size: 18, color: HubColors.ok), SizedBox(width: 4), Text('On', style: TextStyle(color: HubColors.ok, fontWeight: FontWeight.w600, fontSize: 13))])
            : const Text('Set up', style: TextStyle(color: HubColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
      );
}

class _SceneTile extends StatelessWidget {
  const _SceneTile({required this.scene, required this.active, required this.onTap});
  final Map scene;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final id = '${scene['id']}';
    final tint = Color.lerp((_tints[id] ?? const [Color(0xFF2A3350)])[0], Colors.white, 0.45)!;
    return Material(
      color: active ? HubColors.surface2 : HubColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: active ? HubColors.text.withValues(alpha: 0.5) : HubColors.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Icon(_icons[id] ?? Icons.apps_rounded, size: 22, color: tint),
            const SizedBox(width: 12),
            Expanded(child: Text('${scene['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.5))),
            if (active) const Icon(Icons.circle, size: 8, color: HubColors.ok),
          ]),
        ),
      ),
    );
  }
}
