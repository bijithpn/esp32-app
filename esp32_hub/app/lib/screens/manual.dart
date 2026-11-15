import 'package:flutter/material.dart';

import '../api.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../theme.dart';

/// Advanced fallback: connect by IP address, or through an MQTT broker when away from home.
/// The identity of whatever answers is verified first, so a wrong address can never pair a random web server.
class ManualConnectScreen extends StatefulWidget {
  const ManualConnectScreen({super.key});
  @override
  State<ManualConnectScreen> createState() => _ManualConnectScreenState();
}

class _ManualConnectScreenState extends State<ManualConnectScreen> {
  final _host = TextEditingController(), _token = TextEditingController();
  final _mHost = TextEditingController(), _mPort = TextEditingController(text: '1883');
  final _mUser = TextEditingController(), _mPass = TextEditingController();
  final _mId = TextEditingController(), _mToken = TextEditingController();
  bool _remote = false, _tls = false, _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_host, _token, _mHost, _mPort, _mUser, _mPass, _mId, _mToken]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _local() async {
    final hub = HubScope.read(context);
    final host = _host.text.trim().replaceAll(RegExp(r'^https?://'), '');
    if (host.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final f = await HttpApi(host).hello(timeout: const Duration(seconds: 3));
      if (f == null) throw HubException(HubError.wrongDevice, 'not a Hub');
      if (f.ap) {
        setState(() => _error = 'That Hub is in setup mode. Use "Add a new Hub" to give it Wi-Fi.');
        return;
      }
      final d = f.toDevice(base: hub.registry.byId(f.id));
      await hub.registry.upsert(d, select: true);
      if (_token.text.trim().isNotEmpty) await hub.registry.setToken(f.id, _token.text.trim());
      await hub.connectDevice(d);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      setState(() => _error = toHubException(e).kind == HubError.wrongDevice ? 'Something answered at $host, but it isn\'t an ESP32 Hub.' : 'No Hub answered at $host. ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _viaMqtt() async {
    final hub = HubScope.read(context);
    if ([_mHost, _mId, _mToken].any((c) => c.text.trim().isEmpty)) {
      setState(() => _error = 'Fill in the broker host, device ID and token.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final id = _mId.text.trim().toUpperCase();
    try {
      await hub.registry.saveMqtt(id, host: _mHost.text.trim(), port: int.tryParse(_mPort.text) ?? 1883, user: _mUser.text.trim(), pass: _mPass.text, tls: _tls);
      await hub.registry.setToken(id, _mToken.text.trim());
      final d = (hub.registry.byId(id) ?? HubDevice(id: id)).copyWith(host: 'mqtt', locked: true);
      await hub.registry.upsert(d, select: true);
      await hub.connectDevice(d);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {bool obscure = false, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: c, obscureText: obscure, keyboardType: type, autocorrect: false, enableSuggestions: false, decoration: InputDecoration(labelText: label)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Connect manually')),
        body: SafeArea(
          child: ListView(padding: Sp.page, children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                backgroundColor: HubColors.surface,
                selectedBackgroundColor: HubColors.surface2,
                selectedForegroundColor: HubColors.text,
                foregroundColor: HubColors.muted,
                side: const BorderSide(color: HubColors.line),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control)),
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
              _field(_host, 'Hub IP address (e.g. 192.168.1.42)', type: TextInputType.url),
              _field(_token, 'Token (only if the Hub is locked)'),
              const SizedBox(height: 4),
              FilledButton(onPressed: _busy ? null : _local, child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Connect')),
              const SizedBox(height: 16),
              const Hint('You normally never need this: the app finds the Hub by itself. The Hub\'s IP address is shown on its screen.'),
            ] else ...[
              _field(_mHost, 'MQTT broker host'),
              Row(children: [
                Expanded(child: _field(_mPort, 'Port', type: TextInputType.number)),
                const SizedBox(width: 10),
                Expanded(child: Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [const Expanded(child: Text('TLS', style: Ty.body)), Switch(value: _tls, onChanged: (v) => setState(() => _tls = v))]))),
              ]),
              _field(_mUser, 'Username (optional)'),
              _field(_mPass, 'Password (optional)', obscure: true),
              _field(_mId, 'Device ID (e.g. C224AC)'),
              _field(_mToken, 'Device token'),
              const SizedBox(height: 4),
              FilledButton(onPressed: _busy ? null : _viaMqtt, child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Connect over the internet')),
              const SizedBox(height: 16),
              const Hint('Internet mode needs MQTT switched on in the Hub (connect over Wi-Fi first: Settings > Integrations > MQTT). Use your own broker with a username, password and TLS: a public broker is visible to others. The broker password is kept in your phone\'s secure storage.'),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Hint(_error!, color: HubColors.danger)),
          ]),
        ),
      );
}
