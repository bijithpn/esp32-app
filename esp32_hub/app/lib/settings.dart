import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'phone.dart';
import 'theme.dart';

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

/// Full-screen QR scanner with a viewfinder. Returns the scanned "hub://pair..." text.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final MobileScannerController _ctl = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false, _torch = false;
  bool? _camOk;
  String? _warn;

  @override
  void initState() {
    super.initState();
    _askCamera();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _askCamera() async {
    final st = await Permission.camera.request();
    if (mounted) setState(() => _camOk = st.isGranted);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v == null) continue;
      if (PairInfo.parse(v) != null || HubWifiQr.parse(v) != null) {
        _done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(v);
        return;
      }
      if (_warn == null) {
        setState(() => _warn = 'That QR code is not from an ESP32 Hub board.');
        Future.delayed(const Duration(seconds: 3), () { if (mounted) setState(() => _warn = null); });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false, // an open keyboard must never squash the camera view
      body: SafeArea(
        top: false,
        bottom: false,
        child: _camOk == null
            ? const Center(child: CircularProgressIndicator())
            : _camOk == false
                ? _noCamera()
                : LayoutBuilder(builder: (context, c) {
                    final box = (c.biggest.shortestSide * 0.68).clamp(200.0, 320.0);
                    return SizedBox(
                      width: c.maxWidth,
                      height: c.maxHeight,
                      child: Stack(fit: StackFit.expand, children: [
                        MobileScanner(controller: _ctl, onDetect: _onDetect, fit: BoxFit.cover, errorBuilder: (ctx, e) => _noCamera(error: true)),
                        // dark overlay with a clear square in the middle
                        CustomPaint(painter: _ViewfinderPainter(box)),
                        _ScanLine(box: box),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                              child: Row(children: [
                                IconButton(style: IconButton.styleFrom(backgroundColor: Colors.black54), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                                const Spacer(),
                                IconButton(
                                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                  onPressed: () { _ctl.toggleTorch(); setState(() => _torch = !_torch); },
                                  icon: Icon(_torch ? Icons.flash_on_rounded : Icons.flash_off_rounded),
                                ),
                              ]),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 0,
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 20),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                if (_warn != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: StatusPill(color: HubColors.warn, label: _warn!)),
                                const Panel(
                                  color: Color(0xE6101215),
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                    Text('Scan the code on your board', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                                    SizedBox(height: 6),
                                    Text('Scan the QR on a new board\'s SETUP screen, or the "Pair (QR)" scene. Hold the phone about 20 cm from the screen.',
                                        textAlign: TextAlign.center, style: TextStyle(color: HubColors.muted, fontSize: 13, height: 1.4)),
                                  ]),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ]),
                    );
                  }),
      ),
    );
  }

  Widget _noCamera({bool error = false}) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.no_photography_outlined, size: 48, color: HubColors.muted),
            const SizedBox(height: 18),
            Text(error ? 'The camera did not start' : 'Camera access is needed', textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Hint('Only to read the QR code on your board. Nothing is recorded or sent anywhere.'),
            const SizedBox(height: 24),
            FilledButton(onPressed: openAppSettings, child: const Text('Open settings')),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _askCamera, child: const Text('Try again')),
            const SizedBox(height: 6),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ]),
        ),
      );
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter(this.box);
  final double box;
  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: box, height: box), const Radius.circular(24));
    final dim = Path()..addRect(Offset.zero & size)..addRRect(r)..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.62));
    final p = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round;
    const l = 34.0;
    final b = r.outerRect;
    for (final c in [
      [b.topLeft, const Offset(l, 0), const Offset(0, l)],
      [b.topRight, const Offset(-l, 0), const Offset(0, l)],
      [b.bottomLeft, const Offset(l, 0), const Offset(0, -l)],
      [b.bottomRight, const Offset(-l, 0), const Offset(0, -l)],
    ]) {
      canvas.drawLine(c[0], c[0] + c[1], p);
      canvas.drawLine(c[0], c[0] + c[2], p);
    }
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => old.box != box;
}

/// A line that sweeps up and down inside the viewfinder.
class _ScanLine extends StatelessWidget {
  const _ScanLine({required this.box});
  final double box;
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final top = size.height * 0.42 - box / 2 + 12, h = box - 24;
        final k = (math.sin(t * 2.2) + 1) / 2;
        final y = top + k * h;
        c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(size.width / 2 - box / 2 + 14, y - 1.5, box - 28, 3), const Radius.circular(2)),
          Paint()..color = Colors.white.withValues(alpha: 0.85),
        );
      });
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

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionTitle(title),
          Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
        ]),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 96, child: Text(k, style: const TextStyle(color: HubColors.muted, fontSize: 14))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 14))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final locked = _d['lock'] == true;
    final mqttOn = _d['mqtt'] == true;
    final id = _d['id'] ?? '?';
    final ap = _d['ap'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
        _section('Board', [
          _kv('ID', '$id'),
          _kv('Firmware', '${_d['fw']}'),
          _kv('Address', '${_d['ip']}'),
          _kv('Wi-Fi', ap ? 'Not connected (setup hotspot)' : 'Connected'),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: () => _run({'cmd': 'pair'}), icon: const Icon(Icons.qr_code_2_rounded), label: const Text('Show pairing QR on display')),
        ]),
        _section('Security', [
          Hint(locked ? 'Locked: the board only accepts commands that carry the token.' : 'Not locked: anyone on your Wi-Fi can control the board and update its firmware.'),
          const SizedBox(height: 10),
          if (_token.isNotEmpty)
            Row(children: [
              Expanded(child: SelectableText('Token: $_token', style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
              IconButton(icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () { Clipboard.setData(ClipboardData(text: _token)); _toast('Token copied'); }),
            ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!locked) FilledButton.icon(onPressed: () => _lock(true), icon: const Icon(Icons.lock_outline_rounded), label: const Text('Lock with token')),
            if (locked) OutlinedButton.icon(onPressed: () => _lock(false), icon: const Icon(Icons.lock_open_rounded), label: const Text('Unlock')),
            OutlinedButton.icon(onPressed: _newToken, icon: const Icon(Icons.refresh_rounded), label: const Text('New token')),
          ]),
        ]),
        _section('Remote access (MQTT)', [
          const Hint('Control the board from anywhere through an MQTT broker. The board connects out to the broker, so no port forwarding is needed. Commands always carry the device token.'),
          const SizedBox(height: 14),
          TextField(controller: _mHost, decoration: const InputDecoration(labelText: 'Broker host')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: _mPort, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
            const SizedBox(width: 12),
            Expanded(child: Row(children: [
              const Expanded(child: Text('TLS', style: TextStyle(fontSize: 15))),
              Switch(value: _mTls, onChanged: (v) => setState(() => _mTls = v)),
            ])),
          ]),
          const SizedBox(height: 10),
          TextField(controller: _mUser, decoration: const InputDecoration(labelText: 'Username (optional)')),
          const SizedBox(height: 10),
          TextField(controller: _mPass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional)')),
          const SizedBox(height: 12),
          Hint('Status on the board: ${mqttOn ? 'enabled' : 'off'}'),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(onPressed: () => _mqtt(true), child: const Text('Enable on board')),
            OutlinedButton(onPressed: () => _mqtt(false), child: const Text('Disable')),
          ]),
          const SizedBox(height: 12),
          Hint('To connect remotely use Connect > Internet (MQTT) with device ID "$id" and the token above. A public broker is visible to others: use your own broker with a username, password and TLS for anything but testing.'),
        ]),
        const SectionTitle('Phone'),
        Group(children: [
          Row2(
            icon: Icons.notifications_none_rounded,
            title: 'Notifications, music and weather',
            sub: 'What your phone shares with the board',
            trailing: const Icon(Icons.chevron_right_rounded, color: HubColors.muted),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PermissionsPage(api: widget.api))),
          ),
        ]),
      ]),
    );
  }
}
