import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

// ---------------------------------------------------------------------------------- phone bridge
/// Talks to the Android code (HubNotificationService) that mirrors notifications and "now playing".
class PhoneBridge {
  static const _ch = MethodChannel('esp32hub/bridge');

  static Future<bool> isGranted() async {
    try {
      return (await _ch.invokeMethod<bool>('isGranted')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openSettings');
    } catch (_) {}
  }

  static Future<void> setConfig({required String host, required String token, required bool mirror, required bool media, required String ignore}) async {
    try {
      await _ch.invokeMethod('setConfig', {'host': host, 'token': token, 'mirror': mirror, 'media': media, 'ignore': ignore});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> getConfig() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('getConfig');
      return m ?? {};
    } catch (_) {
      return {};
    }
  }
}

// ---------------------------------------------------------------------------------- QR pairing
/// What the board's "Pair (QR)" scene encodes: hub://pair?id=C224AC&t=TOKEN&ip=IP
class PairInfo {
  PairInfo(this.id, this.token, this.ip);
  final String id, token, ip;

  static PairInfo? parse(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || u.scheme != 'hub') return null;
    final id = u.queryParameters['id'], t = u.queryParameters['t'], ip = u.queryParameters['ip'];
    if (id == null || t == null || ip == null) return null;
    return PairInfo(id, t, ip);
  }
}

/// Opens the camera and returns the scanned text.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan the QR on the display')),
        body: Column(children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                if (_done) return;
                final v = capture.barcodes.firstOrNull?.rawValue;
                if (v != null && v.startsWith('hub://')) {
                  _done = true;
                  Navigator.of(context).pop(v);
                }
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('On the board: open the "Pair (QR)" scene (app: tap Pair on the Settings screen, or the web page: Show pairing QR).'),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------------- SETTINGS
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.api, required this.data, required this.onToken});
  final Api api;
  final Map<String, dynamic> data;

  /// Called when the lock token changes, so the app can reconnect with the new token.
  final void Function(String token) onToken;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Map<String, dynamic> _d = widget.data;
  String _token = '';
  final _mHost = TextEditingController(), _mPort = TextEditingController(text: '1883');
  final _mUser = TextEditingController(), _mPass = TextEditingController();
  bool _mTls = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _token = p.getString('token') ?? '';
        _mHost.text = p.getString('mq_host') ?? '';
        _mPort.text = p.getString('mq_port') ?? '1883';
        _mUser.text = p.getString('mq_user') ?? '';
        _mPass.text = p.getString('mq_pass') ?? '';
        _mTls = p.getBool('mq_tls') ?? false;
      });
    });
  }

  void _toast(String m) => ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _refresh() async {
    try {
      final d = await widget.api.list();
      if (mounted) setState(() => _d = d);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _run(Map<String, dynamic> body) async {
    try {
      final r = await widget.api.cmd(body);
      if (r['ok'] != true) {
        _toast('Device: ${r['error'] ?? 'error'}');
        return null;
      }
      return r;
    } on LockedException {
      _toast('Locked: reconnect with the token');
    } catch (e) {
      _toast('Failed: $e');
    }
    return null;
  }

  Future<void> _saveToken(String t) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('token', t);
    setState(() => _token = t);
    widget.onToken(t);
  }

  Future<void> _lock(bool on) async {
    final r = await _run({'cmd': 'lock', 'on': on});
    if (r == null) return;
    if (on && r['token'] is String) {
      await _saveToken(r['token'] as String);
      _toast('Locked. Keep the token safe.');
    }
    await _refresh();
  }

  Future<void> _newToken() async {
    final r = await _run({'cmd': 'token'});
    if (r != null && r['token'] is String) {
      await _saveToken(r['token'] as String);
      _toast('New token created. Old one no longer works.');
    }
  }

  Future<void> _mqtt(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('mq_host', _mHost.text.trim());
    await p.setString('mq_port', _mPort.text.trim());
    await p.setString('mq_user', _mUser.text.trim());
    await p.setString('mq_pass', _mPass.text);
    await p.setBool('mq_tls', _mTls);
    if (on && _mHost.text.trim().isEmpty) {
      _toast('Enter the broker host first');
      return;
    }
    final r = await _run({
      'cmd': 'mqtt', 'on': on, 'host': _mHost.text.trim(), 'port': int.tryParse(_mPort.text) ?? 1883,
      'user': _mUser.text.trim(), 'pass': _mPass.text, 'tls': _mTls,
    });
    if (r != null) _toast(on ? 'MQTT enabled. The board connects within a minute.' : 'MQTT disabled');
    await _refresh();
  }

  Future<void> _ble(bool on) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(on ? 'Enable Bluetooth setup?' : 'Disable Bluetooth?'),
        content: const Text('The board will reboot. While Bluetooth is on the board has about 70 KB less free memory, '
            'so photo animations and weather may not work. It is meant for first-time Wi-Fi setup only.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reboot')),
        ],
      ),
    );
    if (ok == true) {
      await _run({'cmd': 'ble', 'on': on});
      _toast('Rebooting...');
    }
  }

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final locked = _d['lock'] == true;
    final mqttOn = _d['mqtt'] == true;
    final id = _d['id'] ?? '?';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _section('Device', [
          Text('ID: $id'),
          Text('Firmware: ${_d['fw']}'),
          Text('Address: ${_d['ip']}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(onPressed: () => _run({'cmd': 'pair'}), icon: const Icon(Icons.qr_code_2), label: const Text('Show pairing QR on display')),
          ]),
        ]),
        _section('Security', [
          Text(locked ? 'Locked: the board only accepts commands with the token.' : 'Not locked: anyone on your Wi-Fi can control the board and update its firmware.'),
          const SizedBox(height: 8),
          if (_token.isNotEmpty)
            Row(children: [
              Expanded(child: SelectableText('Token: $_token', style: const TextStyle(fontFamily: 'monospace'))),
              IconButton(icon: const Icon(Icons.copy), onPressed: () { Clipboard.setData(ClipboardData(text: _token)); _toast('Token copied'); }),
            ]),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!locked) FilledButton.icon(onPressed: () => _lock(true), icon: const Icon(Icons.lock), label: const Text('Lock with token')),
            if (locked) OutlinedButton.icon(onPressed: () => _lock(false), icon: const Icon(Icons.lock_open), label: const Text('Unlock')),
            OutlinedButton.icon(onPressed: _newToken, icon: const Icon(Icons.refresh), label: const Text('New token')),
          ]),
        ]),
        _section('Remote access (MQTT)', [
          const Text('Control the board from anywhere through an MQTT broker. The board connects out to the broker, so no port forwarding is needed. '
              'Commands must carry the device token (always required over MQTT).'),
          TextField(controller: _mHost, decoration: const InputDecoration(labelText: 'Broker host (e.g. broker.hivemq.com or your server)')),
          Row(children: [
            Expanded(child: TextField(controller: _mPort, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
            const SizedBox(width: 12),
            Expanded(child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('TLS'), value: _mTls, onChanged: (v) => setState(() => _mTls = v))),
          ]),
          TextField(controller: _mUser, decoration: const InputDecoration(labelText: 'Username (optional)')),
          TextField(controller: _mPass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional)')),
          const SizedBox(height: 8),
          Text('Status on the board: ${mqttOn ? 'enabled' : 'off'}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(onPressed: () => _mqtt(true), child: const Text('Enable on board')),
            OutlinedButton(onPressed: () => _mqtt(false), child: const Text('Disable')),
          ]),
          const SizedBox(height: 8),
          Text('To connect remotely: Connect screen > Remote (MQTT), with device ID "$id" and the token above.', style: const TextStyle(fontSize: 12)),
          const Text('Tip: a public broker is visible to others. Use your own broker, a username/password and TLS for anything but testing.', style: TextStyle(fontSize: 12)),
        ]),
        _section('Bluetooth', [
          Text('Bluetooth setup on the board: ${_d['ble'] == true ? 'on' : 'off'}'),
          const Text('Used to give a new board its Wi-Fi without a browser. On a board with no Wi-Fi saved it is on automatically.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: () => _ble(true), child: const Text('Enable (reboots)')),
            OutlinedButton(onPressed: () => _ble(false), child: const Text('Disable (reboots)')),
          ]),
        ]),
        _section('Phone', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_active),
            title: const Text('Phone sync'),
            subtitle: const Text('Mirror notifications and show the song that is playing'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhoneSyncPage(api: widget.api))),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------- PHONE SYNC
class PhoneSyncPage extends StatefulWidget {
  const PhoneSyncPage({super.key, required this.api});
  final Api api;
  @override
  State<PhoneSyncPage> createState() => _PhoneSyncPageState();
}

class _PhoneSyncPageState extends State<PhoneSyncPage> with WidgetsBindingObserver {
  bool _granted = false, _mirror = false, _media = false;
  final _ignore = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();      // back from Android settings
  }

  Future<void> _load() async {
    final g = await PhoneBridge.isGranted();
    final c = await PhoneBridge.getConfig();
    if (!mounted) return;
    setState(() {
      _granted = g;
      _mirror = c['mirror'] == true;
      _media = c['media'] == true;
      _ignore.text = (c['ignore'] as String?) ?? '';
    });
  }

  Future<void> _save() async {
    final a = widget.api;
    await PhoneBridge.setConfig(
      host: a is HttpApi ? a.host : '',
      token: a is HttpApi ? a.token : '',
      mirror: _mirror,
      media: _media,
      ignore: _ignore.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Phone sync')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (!widget.api.isLocal)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('You are connected through MQTT. Phone sync sends to the board over your local Wi-Fi, so connect to the board by its IP address for this to work.'),
              ),
            ),
          Card(
            child: ListTile(
              leading: Icon(_granted ? Icons.check_circle : Icons.warning_amber, color: _granted ? Colors.greenAccent : Colors.orangeAccent),
              title: Text(_granted ? 'Notification access granted' : 'Notification access needed'),
              subtitle: const Text('Android requires you to allow this app in "Notification access". It is used only to read notifications and the current song, and send them to your board.'),
              trailing: FilledButton(onPressed: PhoneBridge.openSettings, child: Text(_granted ? 'Open' : 'Allow')),
            ),
          ),
          SwitchListTile(
            title: const Text('Mirror notifications'),
            subtitle: const Text('New notifications appear as a card on the display'),
            value: _mirror,
            onChanged: (v) { setState(() => _mirror = v); _save(); },
          ),
          SwitchListTile(
            title: const Text('Show now playing'),
            subtitle: const Text('Title, artist and progress of the current song (any music app)'),
            value: _media,
            onChanged: (v) { setState(() => _media = v); _save(); },
          ),
          TextField(
            controller: _ignore,
            decoration: const InputDecoration(labelText: 'Ignore apps containing (comma separated)', hintText: 'bank, otp, messages'),
            onSubmitted: (_) => _save(),
            onEditingComplete: _save,
          ),
          const SizedBox(height: 8),
          const Text('Tip: add banking and OTP apps here so their notifications never reach the display.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              await _save();
              try {
                await widget.api.cmd({'cmd': 'notify', 'app': 'ESP32 Hub', 'title': 'Test', 'text': 'Notification mirroring works!'});
              } catch (_) {}
            },
            icon: const Icon(Icons.send),
            label: const Text('Send a test notification'),
          ),
          const SizedBox(height: 16),
          const Text('Works in the background once enabled, even when this app is closed, as long as the phone is on the same Wi-Fi as the board.', style: TextStyle(fontSize: 12)),
        ]),
      );
}

// ---------------------------------------------------------------------------------- BLE SETUP
/// Gives a new board its Wi-Fi over Bluetooth (no hotspot or browser needed).
class BleSetupPage extends StatefulWidget {
  const BleSetupPage({super.key});
  @override
  State<BleSetupPage> createState() => _BleSetupPageState();
}

class _BleSetupPageState extends State<BleSetupPage> {
  static final _svc = Uuid.parse('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final _cmdChr = Uuid.parse('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final _infoChr = Uuid.parse('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  final _ble = FlutterReactiveBle();
  final Map<String, DiscoveredDevice> _found = {};
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  bool _scanning = false, _connected = false, _busy = false;
  String? _deviceId, _msg;
  Map<String, dynamic>? _info;
  final _ssid = TextEditingController(), _pass = TextEditingController(), _token = TextEditingController();

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  QualifiedCharacteristic _q(Uuid chr) => QualifiedCharacteristic(serviceId: _svc, characteristicId: chr, deviceId: _deviceId!);

  Future<bool> _permissions() async {
    final res = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    final scanOk = res[Permission.bluetoothScan]?.isGranted ?? false;
    final connOk = res[Permission.bluetoothConnect]?.isGranted ?? false;
    final locOk = res[Permission.locationWhenInUse]?.isGranted ?? false;
    // Android 12+ needs scan + connect; Android 11 and older need location instead
    return (scanOk && connOk) || locOk;
  }

  Future<void> _scan() async {
    if (!await _permissions()) {
      setState(() => _msg = 'Bluetooth permission was denied. Allow "Nearby devices" for this app in Android settings.');
      return;
    }
    await _scanSub?.cancel();
    setState(() { _found.clear(); _msg = null; _scanning = true; });
    _scanSub = _ble.scanForDevices(withServices: [_svc], scanMode: ScanMode.lowLatency, requireLocationServicesEnabled: false).listen(
      (d) { if (mounted) setState(() => _found[d.id] = d); },
      onError: (e) { if (mounted) setState(() { _msg = 'Scan failed: $e (is Bluetooth on?)'; _scanning = false; }); },
    );
    Future.delayed(const Duration(seconds: 10), () async {
      await _scanSub?.cancel();
      if (mounted) setState(() { _scanning = false; if (_found.isEmpty) _msg = 'No board found. It must be in setup mode (the screen says SETUP MODE) and within a few metres.'; });
    });
  }

  Future<void> _connect(DiscoveredDevice d) async {
    await _scanSub?.cancel();
    setState(() { _busy = true; _msg = 'Connecting to ${d.name}...'; _scanning = false; });
    _connSub?.cancel();
    _connSub = _ble.connectToDevice(id: d.id, connectionTimeout: const Duration(seconds: 15)).listen((u) async {
      if (u.connectionState == DeviceConnectionState.connected) {
        _deviceId = d.id;
        try {
          await _ble.requestMtu(deviceId: d.id, mtu: 247);
        } catch (_) {}
        await _readInfo();
        if (mounted) setState(() { _connected = true; _busy = false; _msg = null; });
      } else if (u.connectionState == DeviceConnectionState.disconnected && mounted) {
        setState(() { _connected = false; _busy = false; });
      }
    }, onError: (e) { if (mounted) setState(() { _busy = false; _msg = 'Connection failed: $e'; }); });
  }

  Future<Map<String, dynamic>?> _readInfo() async {
    try {
      final raw = await _ble.readCharacteristic(_q(_infoChr));
      final m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      if (mounted) setState(() => _info = m);
      return m;
    } catch (_) {
      return null;
    }
  }

  Future<void> _provision() async {
    final ssid = _ssid.text.trim();
    if (ssid.isEmpty) { setState(() => _msg = 'Enter the Wi-Fi name'); return; }
    setState(() { _busy = true; _msg = 'Sending...'; });
    final payload = {'ssid': ssid, 'pass': _pass.text, if (_token.text.trim().isNotEmpty) 't': _token.text.trim()};
    try {
      await _ble.writeCharacteristicWithResponse(_q(_cmdChr), value: utf8.encode(jsonEncode(payload)));
      await Future.delayed(const Duration(milliseconds: 800));
      final info = await _readInfo();      // may fail if the board already rebooted: that is fine
      final last = info?['last'];
      if (last is Map && last['ok'] == false) {
        setState(() { _busy = false; _msg = 'Board said: ${last['error']}'; });
      } else {
        setState(() { _busy = false; _msg = 'Saved. The board is restarting and joining "$ssid". Its IP address appears on its screen. '
            'Rejoin your Wi-Fi, then connect by that IP.'; });
      }
    } catch (e) {
      setState(() { _busy = false; _msg = 'Could not send: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Bluetooth Wi-Fi setup')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (!_connected) ...[
            const Text('Power the board. If it has no Wi-Fi saved, its screen shows SETUP MODE and Bluetooth is on. Then tap Scan.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: (_scanning || _busy) ? null : _scan,
              icon: _scanning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.bluetooth_searching),
              label: Text(_scanning ? 'Scanning...' : 'Scan'),
            ),
            for (final d in _found.values)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.memory),
                  title: Text(d.name.isEmpty ? d.id : d.name),
                  subtitle: Text('signal ${d.rssi} dBm'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _connect(d),
                ),
              ),
          ] else ...[
            Card(child: ListTile(leading: const Icon(Icons.bluetooth_connected), title: Text('Connected: ${_info?['id'] ?? ''}'), subtitle: Text('mode ${_info?['mode']}  ·  fw ${_info?['fw']}'))),
            const SizedBox(height: 8),
            TextField(controller: _ssid, decoration: const InputDecoration(labelText: 'Wi-Fi name (2.4 GHz)'), autocorrect: false),
            TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Wi-Fi password')),
            if (_info?['lock'] == true) TextField(controller: _token, decoration: const InputDecoration(labelText: 'Device token (board is locked)')),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _busy ? null : _provision, icon: const Icon(Icons.wifi), label: const Text('Send Wi-Fi to the board')),
          ],
          if (_msg != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_msg!)),
        ]),
      );
}
