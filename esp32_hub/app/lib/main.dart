import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'features.dart';
import 'settings.dart';

void main() => runApp(const HubApp());

// ---------------------------------------------------------------- APP
class HubApp extends StatelessWidget {
  const HubApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ESP32 Hub',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF00B8D4), useMaterial3: true, brightness: Brightness.dark),
        home: const ConnectPage(),
      );
}

// ---------------------------------------------------------------- CONNECT
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _host = TextEditingController(), _token = TextEditingController();
  final _mHost = TextEditingController(), _mPort = TextEditingController(text: '1883');
  final _mUser = TextEditingController(), _mPass = TextEditingController();
  final _mId = TextEditingController(), _mToken = TextEditingController();
  bool _mTls = false, _remote = false, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _host.text = p.getString('host') ?? '';
    _token.text = p.getString('token') ?? '';
    _mHost.text = p.getString('mq_host') ?? '';
    _mPort.text = p.getString('mq_port') ?? '1883';
    _mUser.text = p.getString('mq_user') ?? '';
    _mPass.text = p.getString('mq_pass') ?? '';
    _mId.text = p.getString('mq_id') ?? '';
    _mToken.text = p.getString('mq_token') ?? '';
    _mTls = p.getBool('mq_tls') ?? false;
    _remote = p.getBool('remote') ?? false;
    if (mounted) setState(() {});
  }

  void _open(Api api, Map<String, dynamic> data) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => HomePage(api: api, initial: data)));
  }

  Future<String?> _askToken() async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This board is locked'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter its token (Settings > Security in the app that locked it, or scan the QR from the board\'s "Pair (QR)" scene).'),
          TextField(controller: c, autocorrect: false, decoration: const InputDecoration(labelText: 'Token')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _connectLocal() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      var token = _token.text.trim();
      var api = HttpApi(host, token: token);
      final data = await api.list();
      if (data['lock'] == true && data['ap'] != true) {
        if (token.isEmpty || !await api.checkAuth()) {
          final t = await _askToken();
          if (t == null || t.isEmpty) { setState(() => _busy = false); return; }
          token = t;
          api = HttpApi(host, token: t);
          if (!await api.checkAuth()) throw Exception('Wrong token');
          _token.text = t;
        }
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('host', host);
      await p.setString('token', token);
      await p.setBool('remote', false);
      if (data['id'] != null) { _mId.text = data['id'].toString(); await p.setString('mq_id', _mId.text); }
      if (token.isNotEmpty) { _mToken.text = token; await p.setString('mq_token', token); }
      if (mounted) _open(api, data);
    } catch (e) {
      setState(() => _error = 'Could not connect to $host.\n$e\nCheck the IP shown on the display and that your phone is on the same Wi-Fi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectRemote() async {
    if (_mHost.text.trim().isEmpty || _mId.text.trim().isEmpty || _mToken.text.trim().isEmpty) {
      setState(() => _error = 'Fill in the broker host, device ID and token.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    MqttApi? api;
    try {
      api = MqttApi(MqttConfig(
        host: _mHost.text.trim(), port: int.tryParse(_mPort.text) ?? 1883, user: _mUser.text.trim(), pass: _mPass.text,
        tls: _mTls, deviceId: _mId.text.trim().toUpperCase(), token: _mToken.text.trim(),
      ));
      await api.connect();
      final data = await api.list();
      final p = await SharedPreferences.getInstance();
      await p.setString('mq_host', _mHost.text.trim());
      await p.setString('mq_port', _mPort.text.trim());
      await p.setString('mq_user', _mUser.text.trim());
      await p.setString('mq_pass', _mPass.text);
      await p.setBool('mq_tls', _mTls);
      await p.setString('mq_id', _mId.text.trim().toUpperCase());
      await p.setString('mq_token', _mToken.text.trim());
      await p.setBool('remote', true);
      if (mounted) _open(api, data);
    } catch (e) {
      await api?.close();
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    final info = v == null ? null : PairInfo.parse(v);
    if (info == null) return;
    setState(() { _host.text = info.ip; _token.text = info.token; _mId.text = info.id; _mToken.text = info.token; _remote = false; });
    await _connectLocal();
  }

  Widget _field(TextEditingController c, String label, {bool obscure = false, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c, obscureText: obscure, keyboardType: type, autocorrect: false,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Icon(Icons.memory, size: 64, color: Color(0xFF00B8D4)),
                  const SizedBox(height: 8),
                  Text('ESP32 Hub', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineLarge),
                  const SizedBox(height: 20),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Wi-Fi (local)'), icon: Icon(Icons.wifi)),
                      ButtonSegment(value: true, label: Text('Remote (MQTT)'), icon: Icon(Icons.cloud)),
                    ],
                    selected: {_remote},
                    onSelectionChanged: (v) => setState(() { _remote = v.first; _error = null; }),
                  ),
                  const SizedBox(height: 16),
                  if (!_remote) ...[
                    _field(_host, 'Device IP address (shown on the display)', type: TextInputType.url),
                    _field(_token, 'Token (only if the board is locked)'),
                    FilledButton.icon(
                      onPressed: _busy ? null : _connectLocal,
                      icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link),
                      label: const Text('Connect'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(onPressed: _busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan pairing QR')),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BleSetupPage())),
                      icon: const Icon(Icons.bluetooth),
                      label: const Text('New board? Set up Wi-Fi with Bluetooth'),
                    ),
                  ] else ...[
                    _field(_mHost, 'MQTT broker host'),
                    Row(children: [
                      Expanded(child: _field(_mPort, 'Port', type: TextInputType.number)),
                      const SizedBox(width: 10),
                      Expanded(child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('TLS'), value: _mTls, onChanged: (v) => setState(() => _mTls = v))),
                    ]),
                    _field(_mUser, 'Username (optional)'),
                    _field(_mPass, 'Password (optional)', obscure: true),
                    _field(_mId, 'Device ID (e.g. C224AC)'),
                    _field(_mToken, 'Device token'),
                    FilledButton.icon(
                      onPressed: _busy ? null : _connectRemote,
                      icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_done),
                      label: const Text('Connect remotely'),
                    ),
                  ],
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(_remote
                          ? 'Remote mode needs MQTT switched on in the board (connect locally first: Settings > Remote access). '
                              'The device ID and token are in Settings and on the board\'s Pair (QR) scene.'
                          : 'First time?\n'
                              '1. Power the board. The screen shows "SETUP MODE".\n'
                              '2. Easiest: tap "Set up Wi-Fi with Bluetooth" above. '
                              'Or join the Wi-Fi  ESP32-Hub  (password hub12345), enter 192.168.4.1 here and use the menu > Wi-Fi setup.\n'
                              '3. The display then shows its IP address. Enter it here.'),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------- HOME
const _icons = <String, IconData>{
  'eyes': Icons.remove_red_eye,
  'bounce': Icons.sports_basketball,
  'matrix': Icons.code,
  'stars': Icons.auto_awesome,
  'plasma': Icons.gradient,
  'clock': Icons.access_time,
  'name': Icons.badge,
  'message': Icons.chat_bubble,
  'info': Icons.info,
  'life': Icons.grid_on,
  'mandel': Icons.filter_vintage,
  'weather': Icons.wb_cloudy,
  'pet': Icons.pets,
  'pomo': Icons.timer,
  'ping': Icons.network_check,
  'buddy': Icons.smart_toy,
  'bars': Icons.equalizer,
  'nowplaying': Icons.music_note,
  'canvas': Icons.brush,
  'anim': Icons.animation,
  'pair': Icons.qr_code_2,
};

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api, required this.initial});
  final Api api;
  final Map<String, dynamic> initial;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Api _api = widget.api;
  late Map<String, dynamic> _data = widget.initial;
  final _msg = TextEditingController();
  Timer? _timer;
  bool _online = true;

  List get _scenes => (_data['scenes'] as List).where((s) => s['id'] != 'message').toList();
  bool get _ap => _data['ap'] == true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api.close();
    _msg.dispose();
    super.dispose();
  }

  // After locking or changing the token, keep talking to the board with the new token.
  void _onToken(String t) {
    final a = _api;
    if (a is HttpApi) setState(() => _api = HttpApi(a.host, token: t));
  }

  Future<void> _refresh() async {
    try {
      final d = await _api.list();
      if (mounted) setState(() { _data = d; _online = true; });
    } catch (_) {
      if (mounted) setState(() => _online = false);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _send(Map<String, dynamic> body) async {
    try {
      final r = await _api.cmd(body);
      if (r['ok'] != true) { _toast('Device: ${r['error'] ?? 'error'}'); return false; }
      setState(() => _online = true);
      return true;
    } on LockedException {
      _toast('The board is locked. Disconnect and reconnect with its token.');
      return false;
    } catch (_) {
      setState(() => _online = false);
      _toast('Device not reachable');
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
    if (args.isEmpty) {
      if (await _send({'cmd': 'scene', 'id': scene['id']})) setState(() => _data['scene'] = scene['id']);
      return;
    }
    final values = <String, dynamic>{};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(builder: (ctx, set) {
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(scene['name'], style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final a in args) ...[
              if (a['type'] == 'choice')
                Wrap(spacing: 8, children: [
                  for (final o in a['options'])
                    ChoiceChip(
                      label: Text(o.toString()),
                      selected: values[a['key']] == o,
                      onSelected: (_) => set(() => values[a['key']] = o),
                    ),
                ])
              else
                TextField(
                  maxLength: a['max'] ?? 16,
                  decoration: InputDecoration(labelText: a['key'], border: const OutlineInputBorder()),
                  onChanged: (v) => values[a['key']] = v,
                ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (await _send({'cmd': 'scene', 'id': scene['id'], 'args': values})) {
                    setState(() => _data['scene'] = scene['id']);
                  }
                },
                child: const Text('Start'),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  Future<void> _sendMsg() async {
    final t = _msg.text.trim();
    if (t.isEmpty) return;
    if (await _send({'cmd': 'msg', 'text': t, 'ttl': 10})) {
      if (!mounted) return;
      _msg.clear();
      FocusScope.of(context).unfocus();
      _toast('Sent to display');
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

  Future<void> _wifiDialog() async {
    final ssid = TextEditingController(), pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wi-Fi setup'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ssid, decoration: const InputDecoration(labelText: 'Network name (2.4 GHz)')),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save & reboot')),
        ],
      ),
    );
    if (ok == true && ssid.text.trim().isNotEmpty) {
      try {
        await _api.wifi(ssid.text.trim(), pass.text);
      } catch (_) {}
      _toast('Saved. Rejoin your home Wi-Fi, then reconnect using the IP on the display.');
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _confirm(String title, String cmd) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(title: Text(title), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
      ]),
    );
    if (ok == true) {
      await _send({'cmd': cmd});
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = _data['scene'];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ESP32 Hub'),
          Text('${_data['ip']}  ·  fw ${_data['fw']}', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          Icon(Icons.circle, size: 12, color: _online ? Colors.greenAccent : Colors.redAccent),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'auto':
                  _choose('Auto-rotate scenes', {'Off': 0, 'Every 10 s': 10, 'Every 30 s': 30, 'Every 60 s': 60}, 'auto', 'sec');
                case 'tz':
                  _choose('Time zone', {'India (UTC+5:30)': 19800, 'UTC': 0, 'Dubai (UTC+4)': 14400, 'Europe (UTC+1)': 3600,
                      'Japan (UTC+9)': 32400, 'US East (UTC-5)': -18000, 'US West (UTC-8)': -28800}, 'tz', 'sec');
                case 'settings':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SettingsPage(api: _api, data: _data, onToken: _onToken)));
                case 'wifi':
                  _wifiDialog();
                case 'forget':
                  _confirm('Forget Wi-Fi and reboot into setup mode?', 'forget');
                case 'reboot':
                  _confirm('Reboot the board?', 'reboot');
                case 'disc':
                  Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'auto', child: Text('Auto-rotate')),
              PopupMenuItem(value: 'tz', child: Text('Time zone')),
              PopupMenuItem(value: 'wifi', child: Text('Wi-Fi setup')),
              PopupMenuItem(value: 'forget', child: Text('Forget Wi-Fi')),
              PopupMenuItem(value: 'reboot', child: Text('Reboot')),
              PopupMenuItem(value: 'disc', child: Text('Disconnect')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_ap)
            Card(
              color: cs.tertiaryContainer,
              child: ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: const Text('Setup mode'),
                subtitle: const Text('The board is not on your Wi-Fi yet.'),
                trailing: FilledButton(onPressed: _wifiDialog, child: const Text('Set up')),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Send a message', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _msg,
                      maxLength: 60,
                      decoration: const InputDecoration(hintText: 'Good morning!', border: OutlineInputBorder(), counterText: ''),
                      onSubmitted: (_) => _sendMsg(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(onPressed: _sendMsg, icon: const Icon(Icons.send)),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text('Scenes', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              for (final s in _scenes)
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _openScene(s as Map),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: current == s['id'] ? cs.primaryContainer : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                      border: current == s['id'] ? Border.all(color: cs.primary, width: 2) : null,
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(_icons[s['id']] ?? Icons.apps, size: 32),
                      const SizedBox(height: 8),
                      Text(s['name'], textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ),
            ],
          ),
        ]),
      ),
    );
  }
}
