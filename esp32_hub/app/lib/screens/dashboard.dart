import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_prefs.dart';
import '../core/bridge.dart';
import '../core/catalog.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../features/character.dart';
import '../features/music.dart';
import '../features/weather.dart';
import '../phone.dart';
import '../previews.dart';
import '../theme.dart';
import 'devices.dart';
import 'notifications.dart';
import 'presets.dart';
import 'scene_library.dart';
import 'scene_ui.dart';
import 'settings_screen.dart';

/// Colour, label and animation of the connection indicator for each state.
({Color color, String label, bool pulse}) connLook(ConnState s) {
  switch (s) {
    case ConnState.connected:
      return (color: HubColors.ok, label: 'Connected', pulse: false);
    case ConnState.degraded:
      return (color: HubColors.warn, label: 'Weak connection', pulse: true);
    case ConnState.reconnecting:
      return (color: HubColors.warn, label: 'Reconnecting', pulse: true);
    case ConnState.connecting:
    case ConnState.authenticating:
    case ConnState.discovering:
    case ConnState.deviceFound:
      return (color: HubColors.accent, label: 'Connecting', pulse: true);
    case ConnState.networkSwitching:
      return (color: HubColors.warn, label: 'Network changed', pulse: true);
    case ConnState.authenticationRequired:
      return (color: HubColors.warn, label: 'Token needed', pulse: false);
    case ConnState.firmwareUpdating:
      return (color: HubColors.accent, label: 'Updating', pulse: true);
    case ConnState.provisioning:
      return (color: HubColors.accent, label: 'Setting up', pulse: true);
    case ConnState.unavailable:
      return (color: HubColors.warn, label: 'Not reachable', pulse: false);
    case ConnState.error:
      return (color: HubColors.danger, label: 'Problem', pulse: false);
    case ConnState.disconnected:
      return (color: HubColors.muted, label: 'Not connected', pulse: false);
  }
}

/// The dashboard: which Hub, whether it is connected, what is on its display, and the few things you do most.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  final _msg = TextEditingController();
  String? _optimistic; // the scene the user just picked, until the Hub confirms it
  bool _notif = false, _music = false, _loc = false;
  Map<String, dynamic> _status = {};
  Timer? _statusTimer;
  late final ConnectionManager _hub;

  @override
  void initState() {
    super.initState();
    _hub = HubScope.read(context);
    WidgetsBinding.instance.addObserver(this);
    _hub.setDashboardActive(true);
    _hub.addListener(_onHub);
    _statusTimer = Timer.periodic(const Duration(seconds: 20), (_) => _loadStatus());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadStatus();
      _checkPerms();
      if (_hub.canSend) {
        PhoneSync.pushConfig(_hub);
        PhoneSync.autoConfigure(_hub);
      }
    });
  }

  ConnState _last = ConnState.disconnected;
  void _onHub() {
    if (_hub.state == ConnState.connected && _last != ConnState.connected) {
      _loadStatus();
      PhoneSync.pushConfig(_hub);
      PhoneSync.autoConfigure(_hub);
    }
    if (_optimistic != null && '${_hub.data['scene']}' == _optimistic) _optimistic = null;
    _last = _hub.state;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hub.removeListener(_onHub);
    _hub.setDashboardActive(false);
    _statusTimer?.cancel();
    _msg.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPerms();
  }

  Future<void> _loadStatus() async {
    if (!_hub.canSend) return;
    try {
      final s = await _hub.api!.status();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // the connection monitor reports problems; this only fills in the Wi-Fi name
    }
  }

  Future<void> _checkPerms() async {
    final b = Bridge.current;
    final n = await b.notificationAccess();
    final c = await b.getConfig();
    final l = await Permission.locationWhenInUse.isGranted;
    if (mounted) setState(() { _notif = n && c['mirror'] == true; _music = n && c['media'] == true; _loc = l; });
  }

  Future<void> _sendMsg() async {
    final t = _msg.text.trim();
    if (t.isEmpty) return;
    if (await _hub.trySend({'cmd': 'msg', 'text': t, 'ttl': 10}, onError: (m) => toast(context, m))) {
      if (!mounted) return;
      _msg.clear();
      FocusScope.of(context).unfocus();
      toast(context, 'Sent to the display');
    }
  }

  Future<void> _runQuick(QuickAction q) async {
    for (final c in q.commands) {
      if (!await _hub.trySend(c, onError: (m) => toast(context, m))) return;
    }
    if (q.commands.first['cmd'] == 'scene') _hub.data['scene'] = q.commands.first['id'];
    if (mounted) setState(() {});
  }

  Future<void> _autoRotate() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(20), child: Align(alignment: Alignment.centerLeft, child: Text('Auto-rotate scenes', style: Ty.h2))),
          for (final e in {'Off': 0, 'Every 10 seconds': 10, 'Every 30 seconds': 30, 'Every minute': 60}.entries) ListTile(title: Text(e.key), onTap: () => Navigator.pop(ctx, e.value)),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (v != null && mounted) {
      if (await _hub.trySend({'cmd': 'auto', 'sec': v}, idempotent: true, onError: (m) => toast(context, m)) && mounted) toast(context, v == 0 ? 'Auto-rotate off' : 'Rotating every $v s');
    }
  }

  String _sceneName(String id) {
    for (final s in (_hub.data['scenes'] as List? ?? const [])) {
      if (s['id'] == id) return '${s['name']}';
    }
    return id.isEmpty ? '—' : id;
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final d = hub.device;
    final current = _optimistic ?? '${hub.data['scene'] ?? ''}';
    final scenes = ((hub.data['scenes'] as List?) ?? const []).where((s) => !systemScenes.contains(s['id'])).toList();
    final favs = d?.favorites ?? const <String>[];
    final shown = [
      ...scenes.where((s) => favs.contains(s['id'])),
      ...scenes.where((s) => !favs.contains(s['id'])).take(math(favs.length)),
    ];
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await hub.refreshData();
            await _loadStatus();
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
            _Header(onDevices: () => Navigator.of(context).push(hubRoute(const DevicesScreen())), onSettings: () => Navigator.of(context).push(hubRoute(const SettingsScreen()))),
            const SizedBox(height: 12),
            _ConnBanner(hub: hub),
            _Preview(hub: hub, current: current, mood: 'normal', name: _sceneName(current), onNext: () async {
              if (await hub.trySend({'cmd': 'next'}, dedupeKey: 'next', onError: (m) => toast(context, m))) {
                await Future.delayed(const Duration(milliseconds: 350));
                await hub.refreshData();
              }
            }, onAuto: _autoRotate),
            // ---- quick actions
            const SectionTitle('Quick actions'),
            ListenableBuilder(
              listenable: PrefsScope.of(context),
              builder: (_, __) => SizedBox(
                height: 48,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final q in PrefsScope.of(context).quick) _QuickChip(q: q, enabled: hub.canSend, onTap: () => _runQuick(q)),
                  _QuickChip(q: const QuickAction('presets', 'Presets', 'tune', []), enabled: true, onTap: () => Navigator.of(context).push(hubRoute(const PresetsScreen()))),
                ]),
              ),
            ),
            // ---- message
            const SectionTitle('Send a message'),
            Row(children: [
              Expanded(child: TextField(controller: _msg, maxLength: 60, textInputAction: TextInputAction.send, decoration: const InputDecoration(hintText: 'Good morning!', counterText: ''), onSubmitted: (_) => _sendMsg())),
              const SizedBox(width: 10),
              IconButton.filled(
                tooltip: 'Send',
                onPressed: hub.canSend ? _sendMsg : null,
                style: IconButton.styleFrom(backgroundColor: HubColors.text, foregroundColor: HubColors.onPrimary, minimumSize: const Size(54, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control))),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ]),
            // ---- character
            const SectionTitle('Character'),
            CharacterCard(onOpen: () => Navigator.of(context).push(hubRoute(const CharacterScreen()))),
            // ---- scenes
            SectionTitle('Scenes', trailing: TextButton(onPressed: () => Navigator.of(context).push(hubRoute(SceneLibraryScreen(mood: 'normal'))), child: const Text('See all'))),
            if (scenes.isEmpty)
              const Panel(child: Text('Scenes appear when the Hub is connected.', style: Ty.secondary))
            else
              SizedBox(
                height: 192,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final s in shown.take(8))
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 150,
                        child: SceneCard(
                          scene: s as Map,
                          active: current == s['id'],
                          favorite: favs.contains(s['id']),
                          mood: 'normal',
                          onTap: () => startScene(context, hub, s, mood: 'normal', optimistic: (id) => setState(() => _optimistic = id)),
                        ),
                      ),
                    ),
                ]),
              ),
            // ---- phone integrations
            const SectionTitle('From your phone'),
            Group(children: [
              _Integration(icon: Icons.notifications_none_rounded, title: 'Notifications', sub: 'Pop up on the display', on: _notif, onTap: () => Navigator.of(context).push(hubRoute(const NotificationsScreen())).then((_) => _checkPerms())),
              _Integration(icon: Icons.music_note_outlined, title: 'Music', sub: 'Shows the song that is playing', on: _music, onTap: () => Navigator.of(context).push(hubRoute(const MusicPage())).then((_) => _checkPerms())),
              _Integration(icon: Icons.place_outlined, title: 'Weather', sub: 'Uses a location you choose', on: _loc, onTap: () => Navigator.of(context).push(hubRoute(const WeatherPage())).then((_) => _checkPerms())),
            ]),
            // ---- device information
            const SectionTitle('Hub'),
            _InfoCard(hub: hub, status: _status),
          ]),
        ),
      ),
    );
  }

  int math(int favCount) => favCount >= 6 ? 0 : 6 - favCount;
}

class _Header extends StatelessWidget {
  const _Header({required this.onDevices, required this.onSettings});
  final VoidCallback onDevices, onSettings;
  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final look = connLook(hub.state);
    return Row(children: [
      Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.control),
          onTap: onDevices,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(hub.device?.name ?? 'ESP32 Hub', maxLines: 1, overflow: TextOverflow.ellipsis, style: Ty.h1.copyWith(fontSize: 28))),
                const Icon(Icons.expand_more_rounded, color: HubColors.muted),
              ]),
              const SizedBox(height: 6),
              Semantics(label: 'Connection: ${look.label}', child: StatusPill(color: look.color, label: look.label, pulse: look.pulse)),
            ]),
          ),
        ),
      ),
      IconButton(tooltip: 'Settings', onPressed: onSettings, icon: const Icon(Icons.settings_outlined)),
    ]);
  }
}

class _ConnBanner extends StatelessWidget {
  const _ConnBanner({required this.hub});
  final ConnectionManager hub;
  @override
  Widget build(BuildContext context) {
    final s = hub.state;
    String? title, text, action;
    VoidCallback? onAction;
    switch (s) {
      case ConnState.reconnecting:
      case ConnState.networkSwitching:
        title = s == ConnState.networkSwitching ? 'Your phone changed networks' : 'Looking for your Hub';
        text = hub.reason.isEmpty ? 'This usually takes a few seconds.' : hub.reason;
      case ConnState.unavailable:
        title = 'Can\'t reach your Hub';
        text = hub.reason.isEmpty ? 'Check that it is powered on and connected to Wi-Fi.' : hub.reason;
        action = 'Try again';
        onAction = hub.retryNow;
      case ConnState.authenticationRequired:
        title = 'This Hub is locked';
        text = 'Enter its token to control it.';
        action = 'Enter token';
        onAction = () => _askToken(context, hub);
      case ConnState.error:
        title = 'Something went wrong';
        text = friendlyError(hub.reason);
        action = 'Try again';
        onAction = hub.retryNow;
      case ConnState.degraded:
        title = 'Weak connection';
        text = 'Commands may be slow. The app keeps checking.';
      default:
        break;
    }
    return AnimatedSize(
      duration: motion(context, Motion.card),
      curve: Motion.curve,
      alignment: Alignment.topCenter,
      child: title == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                color: HubColors.warn.withValues(alpha: 0.07),
                borderColor: HubColors.warn.withValues(alpha: 0.3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Ty.title), const SizedBox(height: 4), Text(text ?? '', style: Ty.secondary.copyWith(fontSize: 14))])),
                  if (action != null) TextButton(onPressed: onAction, child: Text(action)),
                ]),
              ),
            ),
    );
  }
}

Future<void> _askToken(BuildContext context, ConnectionManager hub) async {
  final c = TextEditingController();
  final t = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('This Hub is locked'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Hint('Enter its token. It is in Settings on the phone that locked it, or scan the QR from the Hub\'s "Pair (QR)" scene.'),
        const SizedBox(height: 14),
        TextField(controller: c, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'Token')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Unlock'))],
    ),
  );
  c.dispose();
  if (t != null && t.isNotEmpty) await hub.submitToken(t);
}

class _Preview extends StatelessWidget {
  const _Preview({required this.hub, required this.current, required this.mood, required this.name, required this.onNext, required this.onAuto});
  final ConnectionManager hub;
  final String current, mood, name;
  final VoidCallback onNext, onAuto;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Opacity(
          opacity: hub.canSend ? 1 : 0.55,
          child: DisplayFrame(child: AnimatedSwitcher(duration: motion(context, Motion.card), child: KeyedSubtree(key: ValueKey('$current$mood'), child: ScenePreview(id: current, mood: mood == 'auto' ? 'normal' : mood)))),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('On the display', style: Ty.meta), const SizedBox(height: 2), Text(name, style: Ty.title)])),
          IconButton.outlined(tooltip: 'Auto-rotate', onPressed: hub.canSend ? onAuto : null, icon: const Icon(Icons.autorenew_rounded), style: IconButton.styleFrom(side: const BorderSide(color: HubColors.line), minimumSize: const Size(48, 48))),
          const SizedBox(width: 8),
          IconButton.outlined(tooltip: 'Next scene', onPressed: hub.canSend ? onNext : null, icon: const Icon(Icons.skip_next_rounded), style: IconButton.styleFrom(side: const BorderSide(color: HubColors.line), minimumSize: const Size(48, 48))),
        ]),
        const SizedBox(height: 2),
        const Text('Illustration of the scene, not a live picture of the screen.', style: Ty.meta),
      ]);
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.q, required this.enabled, required this.onTap});
  final QuickAction q;
  final bool enabled;
  final VoidCallback onTap;
  static const _icons = <String, IconData>{
    'schedule': Icons.schedule_rounded, 'timer': Icons.timer_rounded, 'cloud': Icons.wb_cloudy_rounded, 'mood': Icons.sentiment_satisfied_alt_rounded,
    'bedtime': Icons.bedtime_rounded, 'skip': Icons.skip_next_rounded, 'wifi': Icons.wifi_tethering_rounded, 'tune': Icons.tune_rounded,
  };
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Pressable(
            onTap: enabled ? onTap : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: HubColors.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: HubColors.line)),
              child: Row(children: [Icon(_icons[q.icon] ?? Icons.bolt_rounded, size: 18, color: HubColors.muted), const SizedBox(width: 8), Text(q.label, style: Ty.bodyStrong.copyWith(fontSize: 14))]),
            ),
          ),
        ),
      );
}

class _Integration extends StatelessWidget {
  const _Integration({required this.icon, required this.title, required this.sub, required this.on, required this.onTap});
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
        trailing: on ? const StatusPill(color: HubColors.ok, label: 'On') : const Text('Set up', style: TextStyle(color: HubColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
      );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.hub, required this.status});
  final ConnectionManager hub;
  final Map<String, dynamic> status;
  @override
  Widget build(BuildContext context) {
    final d = hub.device;
    final rssi = (hub.pingData['rssi'] ?? status['rssi']) as num?;
    final ssid = '${status['ssid'] ?? ''}';
    final bars = rssi == null || rssi == 0 ? 0 : rssi > -55 ? 4 : rssi > -65 ? 3 : rssi > -75 ? 2 : rssi > -90 ? 1 : 0;
    final up = (hub.pingData['uptime'] ?? status['uptime']) as num?;
    String uptime() {
      if (up == null) return '—';
      final s = up.toInt();
      return s >= 86400 ? '${s ~/ 86400} d ${(s % 86400) ~/ 3600} h' : s >= 3600 ? '${s ~/ 3600} h ${(s % 3600) ~/ 60} min' : '${s ~/ 60} min';
    }

    return Group(children: [
      Row2(icon: Icons.wifi_rounded, title: ssid.isEmpty ? 'Wi-Fi' : ssid, sub: hub.viaRemote ? 'Through the internet (MQTT)' : (hub.net.hasLan ? 'Local network' : 'No local network'), trailing: SignalBars(bars: bars)),
      Row2(icon: Icons.memory_rounded, title: 'Firmware ${d?.fw.isEmpty ?? true ? '—' : d!.fw}', sub: 'Hub ${d?.id ?? '—'} · up $uptime'),
      Row2(icon: Icons.speed_rounded, title: hub.latencyMs >= 0 ? '${hub.latencyMs} ms response' : 'Response time', sub: hub.lastOkAt == null ? 'Not measured yet' : 'Last checked ${_ago(hub.lastOkAt!)}'),
    ]);
  }

  String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    return s < 5 ? 'just now' : s < 60 ? '$s s ago' : '${s ~/ 60} min ago';
  }
}
