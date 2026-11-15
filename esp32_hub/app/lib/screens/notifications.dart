import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_prefs.dart';
import '../core/bridge.dart';
import '../core/connection.dart';
import '../theme.dart';

/// Notification mirroring: permission, what is shared, which apps are excluded, a test, and whether delivery worked.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> with WidgetsBindingObserver {
  bool _access = false, _mirror = false, _loaded = false;
  Map<String, String> _seen = {};
  String _lastDelivery = '';
  final _words = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _words.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(); // back from Android settings
  }

  Future<void> _load() async {
    final b = Bridge.current;
    final g = await b.notificationAccess();
    final c = await b.getConfig();
    var seen = <String, String>{};
    try {
      seen = (jsonDecode('${c['seen'] ?? '{}'}') as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      // an unreadable list just starts empty
    }
    if (!mounted) return;
    final p = PrefsScope.read(context);
    setState(() {
      _access = g;
      _mirror = c['mirror'] == true;
      _seen = seen;
      _lastDelivery = '${c['lastDelivery'] ?? ''}';
      _words.text = '${c['ignore'] ?? ''}';
      _loaded = true;
    });
    // the native side needs these; keep them in step with the app's settings
    await b.setConfig({'hideContent': p.hideContent, 'blocked': p.blocked.join(',')});
    if (g && !(c['mirror'] == true) && !(c['media'] == true)) {
      // right after the user grants access, switch both on: that is what they came here for
    }
  }

  Future<void> _setMirror(bool v) async {
    setState(() => _mirror = v);
    await Bridge.current.setConfig({'mirror': v});
  }

  Future<void> _saveWords() => Bridge.current.setConfig({'ignore': _words.text.trim()});

  Future<void> _toggleApp(String pkg, bool blocked) async {
    final p = PrefsScope.read(context);
    final next = {...p.blocked};
    blocked ? next.add(pkg) : next.remove(pkg);
    await p.setBlocked(next);
    await Bridge.current.setConfig({'blocked': next.join(',')});
  }

  String get _deliveryText {
    final p = _lastDelivery.split('|');
    if (p.length < 3) return 'Nothing sent yet';
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(int.tryParse(p[0]) ?? 0));
    final when = ago.inSeconds < 60 ? 'just now' : ago.inMinutes < 60 ? '${ago.inMinutes} min ago' : '${ago.inHours} h ago';
    if (p[1] == '1') return 'Delivered to the Hub · $when';
    final why = switch (p[2]) {
      'stale' => 'it was too old to be useful, so it was dropped',
      'offline' => 'the Hub was offline',
      'token' => 'the Hub refused the token',
      'rate' => 'the Hub asked to slow down',
      _ => 'the Hub didn\'t answer',
    };
    return 'Last one not delivered ($when): $why';
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final prefs = PrefsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: !_loaded
          ? StateView.loading('Checking permission')
          : ListView(padding: Sp.page, children: [
              const DisplayFrame(child: _NotifPreview()),
              const SizedBox(height: 8),
              const Center(child: Text('How a notification looks on the display', style: Ty.meta)),
              const SectionTitle('Permission'),
              Panel(
                child: Row(children: [
                  Icon(_access ? Icons.check_circle_outline_rounded : Icons.lock_outline_rounded, color: _access ? HubColors.ok : HubColors.muted),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_access ? 'Notification access allowed' : 'Notification access needed', style: Ty.bodyStrong), Text(_access ? 'You can turn it off in Android settings.' : 'Android asks you to switch on "ESP32 Hub".', style: Ty.secondary)])),
                  if (!_access) FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 40)), onPressed: Bridge.current.openNotificationSettings, child: const Text('Allow')),
                ]),
              ),
              if (!_access) ...[
                const SizedBox(height: 12),
                Panel(
                  color: HubColors.surface2,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Android says "App was denied access"?', style: Ty.bodyStrong),
                    const SizedBox(height: 6),
                    const Hint('Apps installed from a file are blocked at first. Open App info, tap the ⋮ menu at the top right, choose "Allow restricted settings", then tap Allow again.'),
                  ]),
                ),
              ],
              if (_access) ...[
                const SectionTitle('Show on the Hub'),
                Group(children: [
                  _Switch(title: 'Mirror notifications', sub: 'New notifications pop up on the display', value: _mirror, onChanged: _setMirror),
                  _Switch(title: 'Hide the message text', sub: 'Show only which app it came from', value: prefs.hideContent, onChanged: (v) async { await prefs.setHideContent(v); await Bridge.current.setConfig({'hideContent': v}); }),
                ]),
                const SectionTitle('Privacy'),
                const Hint('Only the app name, a title (40 characters) and a short text (120 characters) are sent, and only to your Hub on your own network. Nothing goes through any server. Ongoing and silent notifications are never sent.'),
                const SizedBox(height: 12),
                TextField(controller: _words, decoration: const InputDecoration(labelText: 'Never show apps containing', hintText: 'bank, otp, authenticator'), onSubmitted: (_) => _saveWords(), onEditingComplete: _saveWords),
                const SectionTitle('Apps'),
                if (_seen.isEmpty)
                  const Panel(child: Text('Apps appear here after they send a notification. Switch one off to exclude it.', style: Ty.secondary))
                else
                  Group(children: [
                    for (final e in (_seen.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()))))
                      _Switch(title: e.value, sub: e.key, value: !prefs.blocked.contains(e.key), onChanged: (v) => _toggleApp(e.key, !v)),
                  ]),
                const SectionTitle('Delivery'),
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [const Icon(Icons.send_rounded, size: 18, color: HubColors.muted), const SizedBox(width: 10), Expanded(child: Text(_deliveryText, style: Ty.body))]),
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.link_rounded, size: 18, color: HubColors.muted),
                      const SizedBox(width: 10),
                      Expanded(child: Text(hub.canSend ? 'Hub connected (${hub.device?.host ?? ''})' : 'Hub not connected: notifications wait up to 20 seconds, then are dropped', style: Ty.body)),
                    ]),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: hub.canSend ? () => hub.trySend({'cmd': 'notify', 'app': 'WhatsApp', 'title': 'Test', 'text': 'This is how your notifications will look.', 'ttl': 6}, onError: (m) => toast(context, m)) : null,
                      icon: const Icon(Icons.notifications_active_outlined, size: 20),
                      label: const Text('Send a test notification'),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                const _BatteryNote(),
              ],
            ]),
    );
  }
}

class _NotifPreview extends StatelessWidget {
  const _NotifPreview();
  @override
  Widget build(BuildContext context) => const NotifScreen();
}

class _Switch extends StatelessWidget {
  const _Switch({required this.title, required this.sub, required this.value, required this.onChanged});
  final String title, sub;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Ty.bodyStrong), const SizedBox(height: 2), Text(sub, style: Ty.secondary, maxLines: 1, overflow: TextOverflow.ellipsis)])),
          Switch(value: value, onChanged: onChanged),
        ]),
      );
}

/// Honest note about Android power management.
class _BatteryNote extends StatefulWidget {
  const _BatteryNote();
  @override
  State<_BatteryNote> createState() => _BatteryNoteState();
}

class _BatteryNoteState extends State<_BatteryNote> {
  bool? _ignoring;
  @override
  void initState() {
    super.initState();
    Bridge.current.battery().then((b) => mounted ? setState(() => _ignoring = b.ignoring) : null);
  }

  @override
  Widget build(BuildContext context) => Panel(
        color: HubColors.surface2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Background delivery', style: Ty.bodyStrong),
          const SizedBox(height: 6),
          Hint(_ignoring == true
              ? 'Battery optimisation is off for this app, so Android is less likely to stop it. Some phone makers still limit background apps; nothing can guarantee delivery in every power mode.'
              : 'Android may pause apps in the background to save battery (Doze), which can delay notifications. You can exempt this app, but some phone makers still limit background apps.'),
          if (_ignoring == false) TextButton(onPressed: Bridge.current.openBatterySettings, child: const Text('Battery settings')),
        ]),
      );
}
