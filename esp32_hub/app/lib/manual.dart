import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'main.dart';
import 'phone.dart';
import 'settings.dart';
import 'theme.dart';

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
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
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
    final wifi = v == null ? null : HubWifiQr.parse(v);
    if (wifi != null) {
      setState(() { _busy = true; _error = null; });
      final ok = await PhoneBridge.joinWifi(wifi.ssid, wifi.pass);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        setState(() { _host.text = '192.168.4.1'; _remote = false; });
        await _connectLocal();
      } else {
        setState(() => _error = 'Could not join automatically. Join "${wifi.ssid}" (password ${wifi.pass}) in your phone\'s Wi-Fi settings, then tap Connect.');
      }
      return;
    }
    final info = v == null ? null : PairInfo.parse(v);
    if (info == null) return;
    setState(() { _host.text = info.ip; _token.text = info.token; _mId.text = info.id; _mToken.text = info.token; _remote = false; });
    await _connectLocal();
  }

  Widget _field(TextEditingController c, String label, {bool obscure = false, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c, obscureText: obscure, keyboardType: type, autocorrect: false,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Connect manually')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      backgroundColor: HubColors.surface,
                      selectedBackgroundColor: HubColors.surface2,
                      selectedForegroundColor: HubColors.text,
                      foregroundColor: HubColors.muted,
                      side: const BorderSide(color: HubColors.line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    segments: const [
                      ButtonSegment(value: false, label: Text('Wi-Fi'), icon: Icon(Icons.wifi_rounded)),
                      ButtonSegment(value: true, label: Text('Internet (MQTT)'), icon: Icon(Icons.cloud_outlined)),
                    ],
                    selected: {_remote},
                    onSelectionChanged: (v) => setState(() { _remote = v.first; _error = null; }),
                  ),
                  const SizedBox(height: 20),
                  if (!_remote) ...[
                    _field(_host, 'Board IP address (shown on its screen)', type: TextInputType.url),
                    _field(_token, 'Token (only if the board is locked)'),
                    const SizedBox(height: 4),
                    FilledButton(
                      onPressed: _busy ? null : _connectLocal,
                      child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Connect'),
                    ),
                    const SizedBox(height: 16),
                    Group(children: [
                      Row2(
                        icon: Icons.qr_code_scanner_rounded,
                        title: 'Scan pairing QR',
                        trailing: const Icon(Icons.chevron_right_rounded, color: HubColors.muted),
                        onTap: _busy ? null : () { FocusScope.of(context).unfocus(); _scan(); },
                      ),
                      Row2(
                        icon: Icons.bluetooth_rounded,
                        title: 'New board? Set up Wi-Fi with Bluetooth',
                        trailing: const Icon(Icons.chevron_right_rounded, color: HubColors.muted),
                        onTap: _busy ? null : () { FocusScope.of(context).unfocus(); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BleSetupPage())); },
                      ),
                    ]),
                  ] else ...[
                    _field(_mHost, 'MQTT broker host'),
                    Row(children: [
                      Expanded(child: _field(_mPort, 'Port', type: TextInputType.number)),
                      const SizedBox(width: 10),
                      Expanded(child: Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [
                        const Expanded(child: Text('TLS', style: TextStyle(fontSize: 15))),
                        Switch(value: _mTls, onChanged: (v) => setState(() => _mTls = v)),
                      ]))),
                    ]),
                    _field(_mUser, 'Username (optional)'),
                    _field(_mPass, 'Password (optional)', obscure: true),
                    _field(_mId, 'Device ID (e.g. C224AC)'),
                    _field(_mToken, 'Device token'),
                    const SizedBox(height: 4),
                    FilledButton(
                      onPressed: _busy ? null : _connectRemote,
                      child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Connect over the internet'),
                    ),
                  ],
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Hint(_error!, color: HubColors.danger)),
                  const SizedBox(height: 28),
                  Hint(_remote
                      ? 'Internet mode needs MQTT switched on in the board (connect over Wi-Fi first: Settings > Remote access). '
                          'The device ID and token are in Settings and on the board\'s Pair (QR) screen.'
                      : 'First time?\n'
                          '1. Power the board. If it has no Wi-Fi it shows SETUP.\n'
                          '2. Easiest: tap "Set up Wi-Fi with Bluetooth" above. '
                          'Or join the hotspot ESP32-Hub (password hub12345) on your phone, then open this app: it finds the board and asks for your Wi-Fi.\n'
                          '3. The board then shows its IP address.'),
                ]),
              ),
            ),
          ),
        ),
      );
}
