import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'main.dart';
import 'settings.dart';

// ---------------------------------------------------------------- CONNECT
class ManualConnectPage extends StatefulWidget {
  const ManualConnectPage({super.key});
  @override
  State<ManualConnectPage> createState() => _ManualConnectPageState();
}

class _ManualConnectPageState extends State<ManualConnectPage> {
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
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => HomePage(api: api, initial: data)), (r) => r.isFirst);
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
      if (data['id'] != null) { _mId.text = data['id'].toString(); await p.setString('mq_id', _mId.text); await p.setString('dev_id', _mId.text); }
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
        appBar: AppBar(title: const Text('Connect manually')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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

