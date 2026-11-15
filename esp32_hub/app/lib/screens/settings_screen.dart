import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api.dart';
import '../core/app_prefs.dart';
import '../core/backup.dart';
import '../core/bridge.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../theme.dart';
import '../version.dart';
import '../features/music.dart';
import '../features/weather.dart';
import 'devices.dart';
import 'diagnostics.dart';
import 'firmware.dart';
import 'history.dart';
import 'notifications.dart';
import 'pairing.dart';
import 'schedule.dart';
import 'welcome.dart';

/// Settings, grouped once: Device, Connectivity, Security, Integrations, Application. Nothing appears in two places.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic> _caps = {};
  Map<String, dynamic> _status = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final hub = HubScope.read(context);
    final a = hub.api;
    try {
      if (a is HttpApi) {
        final c = await a.capabilities();
        final s = await a.status();
        if (mounted) setState(() { _caps = c; _status = s; });
      } else if (a != null) {
        final s = await a.status();
        if (mounted) setState(() => _status = s);
      }
    } catch (_) {
      // an older firmware has no capabilities endpoint: the rows just show less
    }
  }

  Future<void> _confirm(String title, String text, String action, Future<void> Function() run, {bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action, style: TextStyle(color: danger ? HubColors.danger : null)))],
      ),
    );
    if (ok == true) await run();
  }

  Future<void> _pairingMode() async {
    final hub = HubScope.read(context);
    final ok = await hub.trySend({'cmd': 'pairing', 'sec': 600}, idempotent: true, onError: (m) => toast(context, m));
    if (ok && mounted) toast(context, 'Pairing mode is on for 10 minutes. The Hub\'s screen shows the Wi-Fi QR and its code.');
  }

  String _signal(num? rssi) => rssi == null || rssi == 0 ? '' : rssi > -55 ? 'Strong signal' : rssi > -67 ? 'Good signal' : rssi > -78 ? 'Fair signal' : 'Weak signal';

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final d = hub.device;
    final can = hub.canSend;
    final display = _caps['display'] as Map?;
    final rssi = (hub.pingData['rssi'] ?? _status['rssi']) as num?;
    final ssid = '${_status['ssid'] ?? ''}';
    final locked = hub.data['lock'] == true;
    Widget go(Widget page) => chevron;
    void push(Widget page) => Navigator.of(context).push(hubRoute(page));
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: Sp.page, children: [
        const SectionTitle('Device', top: 0),
        Group(children: [
          Row2(icon: Icons.badge_outlined, title: 'Name', sub: d?.name ?? '—', trailing: go(const SizedBox()), onTap: d == null ? null : () => DevicesScreen.rename(context, hub, d).then((_) => setState(() {}))),
          Row2(icon: Icons.system_update_alt_rounded, title: 'Firmware', sub: d?.fw.isEmpty ?? true ? 'Unknown' : '${d!.fw} · tap to check for updates', trailing: chevron, onTap: () => push(const FirmwareScreen())),
          Row2(icon: Icons.tv_rounded, title: 'Display', sub: display == null ? 'ST7735S · 160 × 128 landscape' : '${display['driver']} · ${display['width']} × ${display['height']} · backlight fixed on'),
          Row2(icon: Icons.schedule_rounded, title: 'Schedule', sub: 'Show scenes at set times', trailing: chevron, onTap: () => push(const ScheduleScreen())),
          Row2(icon: Icons.monitor_heart_outlined, title: 'Diagnostics', sub: 'Memory, signal, connection test, logs', trailing: chevron, onTap: () => push(const DiagnosticsScreen())),
          Row2(icon: Icons.restart_alt_rounded, title: 'Restart Hub', onTap: can ? () => _confirm('Restart the Hub?', 'It restarts in a few seconds and the app reconnects by itself.', 'Restart', () async { await hub.trySend({'cmd': 'reboot'}, onError: (m) => toast(context, m)); }) : null),
        ]),
        const SectionTitle('Connectivity'),
        Group(children: [
          Row2(icon: Icons.wifi_rounded, title: ssid.isEmpty ? 'Wi-Fi' : ssid, sub: [_signal(rssi), if (d != null && d.host.isNotEmpty && d.host != 'mqtt') d.host].where((e) => e.isNotEmpty).join(' · ')),
          Row2(
            icon: Icons.swap_horiz_rounded,
            title: 'Change network',
            sub: 'The Hub tries the new network first and keeps the old one if it fails',
            trailing: chevron,
            onTap: can && hub.api is HttpApi && d != null
                ? () async {
                    final f = await (hub.api as HttpApi).hello();
                    if (f == null || !context.mounted) return;
                    push(PairingScreen(onlineBoard: f, token: hub.api!.isLocal ? (hub.api as HttpApi).token : ''));
                  }
                : null,
          ),
          Row2(icon: Icons.wifi_tethering_rounded, title: 'Pairing mode', sub: 'Show the setup Wi-Fi on the Hub for 10 minutes', onTap: can ? _pairingMode : null),
          Row2(icon: Icons.wifi_off_rounded, title: 'Forget Wi-Fi', sub: 'The Hub restarts in setup mode', titleColor: HubColors.danger, onTap: can ? () => _confirm('Forget the Wi-Fi?', 'The Hub restarts in setup mode and this phone loses it until you set it up again.', 'Forget', () async { await hub.trySend({'cmd': 'forget'}, onError: (m) => toast(context, m)); }, danger: true) : null),
          Row2(icon: Icons.history_rounded, title: 'Connection history', trailing: chevron, onTap: () => push(const HistoryScreen())),
        ]),
        const SectionTitle('Security'),
        Group(children: [
          Row2(icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded, iconColor: locked ? HubColors.ok : HubColors.warn, title: 'Lock and token', sub: locked ? 'Locked: commands need this phone\'s token' : 'Not locked: anyone on your Wi-Fi can control the Hub', trailing: chevron, onTap: can ? () => push(const SecurityScreen()) : null),
          Row2(icon: Icons.devices_rounded, title: 'Paired Hubs', sub: '${hub.registry.devices.length} on this phone', trailing: chevron, onTap: () => push(const DevicesScreen())),
        ]),
        const SectionTitle('Integrations'),
        Group(children: [
          Row2(icon: Icons.notifications_none_rounded, title: 'Notifications', trailing: chevron, onTap: () => push(const NotificationsScreen())),
          Row2(icon: Icons.music_note_outlined, title: 'Music', trailing: chevron, onTap: () => push(const MusicPage())),
          Row2(icon: Icons.wb_cloudy_outlined, title: 'Weather', trailing: chevron, onTap: () => push(const WeatherPage())),
          Row2(icon: Icons.cloud_outlined, title: 'Remote access (MQTT)', sub: hub.data['mqtt'] == true ? 'On' : 'Off', trailing: chevron, onTap: d == null ? null : () => push(const MqttScreen())),
        ]),
        const SectionTitle('Application'),
        Group(children: [
          Row2(icon: Icons.bolt_rounded, title: 'Dashboard shortcuts', trailing: chevron, onTap: () => push(const QuickActionsScreen())),
          Row2(icon: Icons.save_alt_rounded, title: 'Backup and restore', sub: 'Presets and shortcuts, never secrets', trailing: chevron, onTap: () => push(const BackupScreen())),
          Row2(icon: Icons.verified_user_outlined, title: 'Permissions', trailing: chevron, onTap: () => push(const PermissionsScreen())),
          Row2(icon: Icons.add_circle_outline_rounded, title: 'Add another Hub', trailing: chevron, onTap: () => push(const WelcomeScreen(addMode: true))),
          Row2(icon: Icons.info_outline_rounded, title: 'About', sub: 'Version $appVersion', trailing: chevron, onTap: () => push(const AboutScreen())),
        ]),
      ]),
    );
  }
}

// ======================================================================= security
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  bool _reveal = false, _busy = false;
  String _token = '';

  @override
  void initState() {
    super.initState();
    final hub = HubScope.read(context);
    final id = hub.device?.id;
    if (id != null) hub.registry.token(id).then((t) => mounted ? setState(() => _token = t) : null);
  }

  Future<void> _run(Future<void> Function(ConnectionManager hub) f) async {
    final hub = HubScope.read(context);
    setState(() => _busy = true);
    try {
      await f(hub);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _lock(bool on) => _run((hub) async {
        final r = await hub.send({'cmd': 'lock', 'on': on});
        if (on && r['token'] is String) {
          await hub.adoptToken(r['token'] as String);
          _token = r['token'] as String;
        }
        await hub.refreshData();
        if (mounted) toast(context, on ? 'Locked. The token is stored securely on this phone.' : 'Unlocked');
      });

  Future<void> _rotate() => _run((hub) async {
        final r = await hub.send({'cmd': 'token'});
        if (r['token'] is String) {
          await hub.adoptToken(r['token'] as String);
          _token = r['token'] as String;
        }
        if (mounted) toast(context, 'New token created. Other phones need the new one.');
      });

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final locked = hub.data['lock'] == true;
    final shown = _token.isEmpty ? '—' : (_reveal ? _token : '•' * 16);
    return Scaffold(
      appBar: AppBar(title: const Text('Lock and token')),
      body: ListView(padding: Sp.page, children: [
        Panel(
          child: Row(children: [
            Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded, color: locked ? HubColors.ok : HubColors.warn),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(locked ? 'Locked' : 'Not locked', style: Ty.title), Text(locked ? 'Only phones with the token can control the Hub or update it.' : 'Anyone on your Wi-Fi can control the Hub and update its firmware.', style: Ty.secondary)])),
          ]),
        ),
        const SizedBox(height: 16),
        if (locked || _token.isNotEmpty)
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Token on this phone', style: Ty.meta),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: Text(shown, style: Ty.mono)),
                IconButton(tooltip: _reveal ? 'Hide' : 'Show', onPressed: _token.isEmpty ? null : () => setState(() => _reveal = !_reveal), icon: Icon(_reveal ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 20)),
                IconButton(
                  tooltip: 'Copy',
                  onPressed: _token.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: _token));
                          if (context.mounted) toast(context, 'Token copied. Clear it from the clipboard after use.');
                        },
                  icon: const Icon(Icons.copy_rounded, size: 20),
                ),
              ]),
            ]),
          ),
        const SizedBox(height: 16),
        if (!locked) FilledButton.icon(onPressed: _busy ? null : () => _lock(true), icon: const Icon(Icons.lock_outline_rounded), label: const Text('Lock with a token')),
        if (locked) ...[
          OutlinedButton.icon(onPressed: _busy ? null : _rotate, icon: const Icon(Icons.autorenew_rounded), label: const Text('Create a new token')),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _busy ? null : () => _lock(false), icon: const Icon(Icons.lock_open_rounded), label: const Text('Unlock')),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _busy ? null : () => hub.trySend({'cmd': 'pair'}, onError: (m) => toast(context, m)), icon: const Icon(Icons.qr_code_2_rounded), label: const Text('Show pairing QR on the Hub')),
          const SizedBox(height: 6),
          const Hint('The QR on the Hub\'s screen carries the token. Only show it to someone you trust standing in front of the Hub.'),
        ],
        const SectionTitle('What this protects, and what it does not'),
        const Hint('The Hub talks to the app over plain HTTP on your Wi-Fi. The token decides who may send commands, but the traffic itself is not encrypted: someone who can see your Wi-Fi traffic could read it. Keep your Wi-Fi password private, use WPA2, and do not expose the Hub to the internet. Remote access (MQTT) is only as private as the broker you choose.'),
      ]),
    );
  }
}

// ======================================================================= MQTT
class MqttScreen extends StatefulWidget {
  const MqttScreen({super.key});
  @override
  State<MqttScreen> createState() => _MqttScreenState();
}

class _MqttScreenState extends State<MqttScreen> {
  final _host = TextEditingController(), _port = TextEditingController(text: '1883'), _user = TextEditingController(), _pass = TextEditingController();
  bool _tls = false, _busy = false;

  @override
  void initState() {
    super.initState();
    final hub = HubScope.read(context);
    final id = hub.device?.id;
    if (id != null) {
      hub.registry.mqttConfig(id).then((c) {
        if (c == null || !mounted) return;
        setState(() { _host.text = c.host; _port.text = '${c.port}'; _user.text = c.user; _pass.text = c.pass; _tls = c.tls; });
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _apply(bool on) async {
    final hub = HubScope.read(context);
    final id = hub.device?.id;
    if (id == null) return;
    if (on && _host.text.trim().isEmpty) {
      toast(context, 'Enter the broker host first.');
      return;
    }
    setState(() => _busy = true);
    try {
      await hub.registry.saveMqtt(id, host: _host.text.trim(), port: int.tryParse(_port.text) ?? 1883, user: _user.text.trim(), pass: _pass.text, tls: _tls);
      await hub.send({'cmd': 'mqtt', 'on': on, 'host': _host.text.trim(), 'port': int.tryParse(_port.text) ?? 1883, 'user': _user.text.trim(), 'pass': _pass.text, 'tls': _tls});
      await hub.refreshData();
      if (mounted) toast(context, on ? 'MQTT is on. The Hub connects within a minute.' : 'MQTT is off.');
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final on = hub.data['mqtt'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Remote access (MQTT)')),
      body: ListView(padding: Sp.page, children: [
        const Hint('Control the Hub from anywhere through an MQTT broker you choose. The Hub connects out to the broker, so no port forwarding is needed. Every command carries the Hub\'s token. The broker password is stored in your phone\'s secure storage.'),
        const SizedBox(height: 16),
        StatusPill(color: on ? HubColors.ok : HubColors.muted, label: on ? 'On in the Hub' : 'Off'),
        const SizedBox(height: 16),
        TextField(controller: _host, autocorrect: false, decoration: const InputDecoration(labelText: 'Broker host')),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
          const SizedBox(width: 12),
          Expanded(child: Row(children: [const Expanded(child: Text('TLS', style: Ty.body)), Switch(value: _tls, onChanged: (v) => setState(() => _tls = v))])),
        ]),
        const SizedBox(height: 10),
        TextField(controller: _user, autocorrect: false, decoration: const InputDecoration(labelText: 'Username (optional)')),
        const SizedBox(height: 10),
        TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional)')),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: FilledButton(onPressed: _busy || !hub.canSend ? null : () => _apply(true), child: const Text('Turn on'))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton(onPressed: _busy || !hub.canSend ? null : () => _apply(false), child: const Text('Turn off'))),
        ]),
        const SizedBox(height: 16),
        const Hint('A public broker can be read by others and the Hub does not verify its TLS certificate. Use your own broker with a username, password and TLS for anything but testing.', color: HubColors.warn),
      ]),
    );
  }
}

// ======================================================================= shortcuts
class QuickActionsScreen extends StatelessWidget {
  const QuickActionsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final prefs = PrefsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard shortcuts')),
      body: ListView(padding: Sp.page, children: [
        const Hint('Choose up to 6 one-tap shortcuts for the dashboard.'),
        const SizedBox(height: 16),
        Group(children: [
          for (final q in quickActionLibrary)
            CheckboxListTile(
              value: prefs.quickIds.contains(q.id),
              title: Text(q.label, style: Ty.bodyStrong),
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (v) {
                final next = [...prefs.quickIds];
                if (v == true) {
                  if (next.length >= 6) {
                    toast(context, 'Up to 6 shortcuts.');
                    return;
                  }
                  next.add(q.id);
                } else {
                  next.remove(q.id);
                }
                prefs.setQuick(next);
              },
            ),
        ]),
      ]),
    );
  }
}

// ======================================================================= backup
class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  Future<void> _restore(BuildContext context) async {
    final hub = HubScope.read(context);
    final prefs = PrefsScope.read(context);
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from a backup'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Hint('Paste the backup text. It is checked completely before anything changes.'),
          const SizedBox(height: 10),
          TextField(controller: c, maxLines: 6, decoration: const InputDecoration(hintText: '{ "schema": 1, … }')),
        ]),
        actions: [
          TextButton(onPressed: () async => c.text = (await Clipboard.getData('text/plain'))?.text ?? c.text, child: const Text('Paste')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Restore')),
        ],
      ),
    );
    c.dispose();
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    try {
      final msg = await Backup.restore(text, prefs, hub.registry);
      hub.deviceChanged();
      if (context.mounted) toast(context, msg);
    } on FormatException catch (e) {
      if (context.mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.read(context);
    final prefs = PrefsScope.read(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup and restore')),
      body: ListView(padding: Sp.page, children: [
        const Hint('Saves your presets, dashboard shortcuts, notification privacy choices, Hub names and favourite scenes as text. Tokens, passwords, API keys and Wi-Fi details are never included, so a backup is safe to keep but cannot pair a Hub by itself.'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: Backup.export(prefs, hub.registry)));
            if (context.mounted) toast(context, 'Backup copied. Paste it somewhere safe.');
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy backup'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: () => _restore(context), icon: const Icon(Icons.restore_rounded), label: const Text('Restore from text')),
      ]),
    );
  }
}

// ======================================================================= permissions
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});
  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  bool _notif = false, _battery = false;
  PermissionStatus _loc = PermissionStatus.denied, _cam = PermissionStatus.denied, _mic = PermissionStatus.denied;

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
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final n = await Bridge.current.notificationAccess();
    final b = await Bridge.current.battery();
    final l = await Permission.locationWhenInUse.status, c = await Permission.camera.status, m = await Permission.microphone.status;
    if (mounted) setState(() { _notif = n; _battery = b.ignoring; _loc = l; _cam = c; _mic = m; });
  }

  Widget _row(IconData icon, String title, String why, bool on, VoidCallback act, {String off = 'Allow'}) => Row2(
        icon: icon,
        title: title,
        sub: why,
        iconColor: on ? HubColors.ok : HubColors.muted,
        trailing: on ? const StatusPill(color: HubColors.ok, label: 'Allowed') : TextButton(onPressed: act, child: Text(off)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Permissions')),
        body: ListView(padding: Sp.page, children: [
          const Hint('Each permission is optional and used for one thing only.'),
          const SizedBox(height: 16),
          Group(children: [
            _row(Icons.notifications_none_rounded, 'Notification access', 'Mirror notifications and follow the music that is playing', _notif, Bridge.current.openNotificationSettings),
            _row(Icons.place_outlined, 'Location', 'Weather where you are. Approximate, only sent to your Hub', _loc.isGranted, () async {
              final s = await Permission.locationWhenInUse.request();
              if (s.isPermanentlyDenied) await openAppSettings();
              _load();
            }),
            _row(Icons.photo_camera_outlined, 'Camera', 'Only to scan the Hub\'s QR code', _cam.isGranted, () async {
              final s = await Permission.camera.request();
              if (s.isPermanentlyDenied) await openAppSettings();
              _load();
            }),
            _row(Icons.mic_none_rounded, 'Microphone', 'Only for the music visualiser, only while that screen is open', _mic.isGranted, () async {
              final s = await Permission.microphone.request();
              if (s.isPermanentlyDenied) await openAppSettings();
              _load();
            }),
            _row(Icons.battery_saver_rounded, 'Battery optimisation', 'Exempting the app makes background delivery more reliable', _battery, Bridge.current.openBatterySettings, off: 'Open'),
          ]),
          const SizedBox(height: 16),
          const Hint('Joining the Hub\'s setup Wi-Fi uses Android\'s own approval dialog and needs no location permission. The app does not use Bluetooth.'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: openAppSettings, child: const Text('Open Android app settings')),
        ]),
      );
}

// ======================================================================= about
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('About')),
        body: ListView(padding: Sp.page, children: [
          Group(children: [
            const Row2(title: 'ESP32 Hub app', trailing: Text(appVersion, style: Ty.title)),
            const Row2(title: 'Built with firmware', trailing: Text(bundledFirmware, style: Ty.title)),
            const Row2(title: 'API version', trailing: Text('$apiVersionWanted', style: Ty.title)),
          ]),
          const SectionTitle('Security notes'),
          const Hint('Local control uses HTTP on your Wi-Fi (not encrypted). Secrets (tokens, broker password, Anthropic key) are kept in the Android Keystore and never written to logs. The Hub\'s setup network has a different password on every Hub, shown on its screen. Notification text goes only to your Hub. Firmware updates are checked by size, header and MD5, not by digital signature.'),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: () => showLicensePage(context: context, applicationName: 'ESP32 Hub', applicationVersion: appVersion), child: const Text('Open-source licences')),
        ]),
      );
}
