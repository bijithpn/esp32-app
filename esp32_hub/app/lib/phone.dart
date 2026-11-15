import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'theme.dart';

// ---------------------------------------------------------------------------------- phone bridge
/// Talks to the Android code (HubNotificationService, MainActivity) that mirrors notifications,
/// follows the music that is playing and reads the phone's location.
class PhoneBridge {
  static const _ch = MethodChannel('esp32hub/bridge');

  static Future<bool> isGranted() async {
    try {
      return (await _ch.invokeMethod<bool>('isGranted')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// If the phone is on a Wi-Fi that has no internet (such as the board's own hotspot) Android may send app traffic over
  /// mobile data instead, and then 192.168.4.1 can never be reached. This pins the app to that Wi-Fi. Returns true if it did.
  static Future<bool> bindWifi({bool force = false}) async {
    try {
      return (await _ch.invokeMethod<bool>('bindWifi', {'force': force})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Joins a Wi-Fi network (Android 10+ shows one confirm dialog) and pins the app to it. Used for the board's hotspot QR.
  static Future<bool> joinWifi(String ssid, String pass) async {
    try {
      return (await _ch.invokeMethod<bool>('joinWifi', {'ssid': ssid, 'pass': pass})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Boards found by Android's own mDNS lookup (their IP addresses). Fast and needs no network scanning.
  static Future<List<String>> mdnsFind({int timeoutMs = 2500}) async {
    try {
      final l = await _ch.invokeListMethod<String>('mdnsFind', {'timeoutMs': timeoutMs});
      return l ?? [];
    } catch (_) {
      return [];
    }
  }

  /// Lets go of the board's hotspot (joined from its QR code) so the phone returns to its normal Wi-Fi.
  static Future<void> leaveHotspot() async {
    try {
      await _ch.invokeMethod('leaveHotspot');
    } catch (_) {}
  }

  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openSettings');
    } catch (_) {}
  }

  static Future<void> setConfig({required String host, required String token, required bool mirror, required bool media, required String ignore, String id = ''}) async {
    try {
      await _ch.invokeMethod('setConfig', {'host': host, 'token': token, 'mirror': mirror, 'media': media, 'ignore': ignore, 'id': id});
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

  /// Last known location of the phone (needs the location permission), or null.
  static Future<({double lat, double lon})?> location() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('getLocation');
      if (m == null || m['lat'] == null || m['lon'] == null) return null;
      return (lat: (m['lat'] as num).toDouble(), lon: (m['lon'] as num).toDouble());
    } catch (_) {
      return null;
    }
  }
}

/// The Wi-Fi QR code shown on a board in setup mode: WIFI:T:WPA;S:ESP32-Hub;P:hub12345;;
class HubWifiQr {
  HubWifiQr(this.ssid, this.pass);
  final String ssid, pass;

  static HubWifiQr? parse(String text) {
    final t = text.trim();
    if (!t.toUpperCase().startsWith('WIFI:')) return null;
    String? field(String k) {
      final m = RegExp('(?:^|;)$k:((?:\\\\.|[^;\\\\])*)').firstMatch(t.substring(5));
      return m?.group(1)?.replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!);
    }
    final ssid = field('S');
    if (ssid == null || !ssid.startsWith('ESP32-Hub')) return null; // only the board's own hotspot
    return HubWifiQr(ssid, field('P') ?? '');
  }
}

/// Keeps the phone-side helpers pointed at the board, and configures the board from the phone.
class PhoneSync {
  /// Tell the background service where the board is (it keeps working when this app is closed).
  static Future<void> apply(Api api, {String id = ''}) async {
    if (api is! HttpApi) return;
    final c = await PhoneBridge.getConfig();
    await PhoneBridge.setConfig(
      host: api.host,
      token: api.token,
      mirror: c['mirror'] == true,
      media: c['media'] == true,
      ignore: (c['ignore'] as String?) ?? '',
      id: id,
    );
  }

  /// Time zone and (if allowed) weather location come from the phone: nothing to type.
  static Future<void> autoConfigure(Api api) async {
    try {
      final sec = DateTime.now().timeZoneOffset.inSeconds;
      final st = await api.status();
      if (st['tz'] != sec) await api.cmd({'cmd': 'tz', 'sec': sec});
    } catch (_) {}
    await sendLocation(api);
  }

  static Future<bool> sendLocation(Api api) async {
    try {
      if (!await Permission.locationWhenInUse.isGranted) return false;
      final l = await PhoneBridge.location();
      if (l == null) return false;
      final r = await api.cmd({'cmd': 'loc', 'lat': l.lat, 'lon': l.lon});
      return r['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------------- permissions screen
/// One screen that explains each phone feature by showing what it looks like on the board, then asks for the permission.
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key, required this.api, this.firstRun = false});
  final Api api;
  final bool firstRun;
  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> with WidgetsBindingObserver {
  bool _notif = false, _loc = false, _mirror = false, _media = false, _locBusy = false;
  String? _locText;
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
    _ignore.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(); // back from Android settings
  }

  Future<void> _load() async {
    final g = await PhoneBridge.isGranted();
    final c = await PhoneBridge.getConfig();
    final l = await Permission.locationWhenInUse.isGranted;
    if (!mounted) return;
    setState(() {
      _notif = g;
      _loc = l;
      _mirror = c['mirror'] == true;
      _media = c['media'] == true;
      _ignore.text = (c['ignore'] as String?) ?? '';
    });
    // Right after the user grants access, switch both features on: that is what they came here for.
    final p = await SharedPreferences.getInstance();
    if (g && !(p.getBool('sync_defaults_done') ?? false)) {
      await p.setBool('sync_defaults_done', true);
      setState(() { _mirror = true; _media = true; });
      await _save();
    }
  }

  Future<void> _save() async {
    final a = widget.api;
    await PhoneBridge.setConfig(
      host: a is HttpApi ? a.host : '',
      token: a is HttpApi ? a.token : '',
      mirror: _mirror,
      media: _media,
      ignore: _ignore.text.trim(),
      id: (await SharedPreferences.getInstance()).getString('dev_id') ?? '',
    );
  }

  void _toast(String m) => ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _askLocation() async {
    setState(() => _locBusy = true);
    var st = await Permission.locationWhenInUse.request();
    if (st.isPermanentlyDenied) {
      _toast('Location is blocked. Allow it in the app settings.');
      await openAppSettings();
    }
    st = await Permission.locationWhenInUse.status;
    if (st.isGranted) {
      final ok = await PhoneSync.sendLocation(widget.api);
      final l = await PhoneBridge.location();
      if (mounted) setState(() => _locText = ok && l != null ? 'Weather set to ${l.lat.toStringAsFixed(2)}, ${l.lon.toStringAsFixed(2)}' : 'Turn on location in the phone quick settings, then try again.');
    }
    if (mounted) setState(() { _loc = st.isGranted; _locBusy = false; });
  }

  @override
  Widget build(BuildContext context) {
    final done = [_notif, _notif, _loc].where((x) => x).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phone magic'),
        actions: [if (widget.firstRun) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip'))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
        const Hint('Let your board know what is happening on your phone. Each one is optional.'),
        const SizedBox(height: 20),
        _Card(
          icon: Icons.notifications_none_rounded,
          title: 'Notifications',
          text: 'Messages, calls and app alerts pop up on the display, each in its own colour.',
          preview: const NotifScreen(),
          granted: _notif,
          action: _notif ? null : 'Allow notification access',
          onAction: PhoneBridge.openSettings,
          children: !_notif
              ? [
                  const _Hint('Android opens its list: turn on "ESP32 Hub", then come back here.'),
                  const _Restricted(),
                ]
              : [
                  _Toggle('Show notifications', _mirror, (v) { setState(() => _mirror = v); _save(); }),
                  TextField(
                    controller: _ignore,
                    decoration: const InputDecoration(labelText: 'Never show apps containing', hintText: 'bank, otp, messages'),
                    onSubmitted: (_) => _save(),
                    onEditingComplete: _save,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _save();
                      try {
                        await widget.api.cmd({'cmd': 'notify', 'app': 'WhatsApp', 'title': 'Test', 'text': 'This is how your notifications will look.', 'ttl': 6});
                      } catch (_) {
                        _toast('Board not reachable');
                      }
                    },
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Send a test notification'),
                  ),
                ],
        ),
        const SizedBox(height: 14),
        _Card(
          icon: Icons.music_note_outlined,
          title: 'Music',
          text: 'Play a song in any app and it appears on the display by itself, with art, progress and a live equaliser.',
          preview: const MusicScreen(),
          granted: _notif,
          action: _notif ? null : 'Allow notification access',
          onAction: PhoneBridge.openSettings,
          children: !_notif
              ? [const _Hint('Uses the same permission as notifications. Android only shows song details to apps with this access.'), const _Restricted()]
              : [_Toggle('Show the song that is playing', _media, (v) { setState(() => _media = v); _save(); })],
        ),
        const SizedBox(height: 14),
        _Card(
          icon: Icons.place_outlined,
          title: 'Weather where you are',
          text: 'The clock and weather use your location, so there is no city to pick. Only an approximate position is used and it is only sent to your board.',
          preview: const WeatherScreen(),
          granted: _loc,
          action: _loc ? null : (_locBusy ? 'Allowing…' : 'Allow location'),
          onAction: _locBusy ? null : _askLocation,
          children: [
            if (_loc) _Toggle('Update weather location', true, null),
            if (_locText != null) _Hint(_locText!),
            if (_loc)
              OutlinedButton.icon(onPressed: _locBusy ? null : _askLocation, icon: const Icon(Icons.my_location_rounded, size: 18), label: const Text('Use my location now')),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(done == 3 ? 'All set' : 'Done')),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.text, required this.preview, required this.granted, required this.action, required this.onAction, required this.children});
  final IconData icon;
  final String title, text;
  final Widget preview;
  final bool granted;
  final String? action;
  final VoidCallback? onAction;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DisplayFrame(child: preview),
          const SizedBox(height: 16),
          Row(children: [
            Icon(icon, color: granted ? HubColors.ok : HubColors.muted, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
            if (granted) const StatusPill(color: HubColors.ok, label: 'On'),
          ]),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: HubColors.muted, fontSize: 14, height: 1.45)),
          if (action != null) ...[
            const SizedBox(height: 14),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
          for (final w in children) ...[const SizedBox(height: 10), w],
        ]),
      );
}

/// Android 13+ blocks "notification access" for apps installed from a file until the user allows it in App info.
/// Without this hint the screen just says "App was denied access" and people get stuck.
class _Restricted extends StatelessWidget {
  const _Restricted();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: HubColors.surface2, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Android says "App was denied access"?', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 6),
          const Text('Apps installed from a file are blocked at first. Open App info, tap the ⋮ menu at the top right, choose "Allow restricted settings", then tap the button above again.',
              style: TextStyle(color: HubColors.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 4),
          TextButton(onPressed: openAppSettings, child: const Text('Open App info')),
        ]),
      );
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
        Switch(value: value, onChanged: onChanged),
      ]);
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(color: HubColors.muted, fontSize: 13.5, height: 1.4));
}
