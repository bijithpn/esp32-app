import 'package:flutter/material.dart';

import '../core/connection.dart';
import '../core/models.dart';
import '../theme.dart';
import 'dashboard.dart' show connLook;
import 'welcome.dart';

/// Every Hub paired with this phone. Switch, rename, remove, add. Each Hub keeps its own token: nothing is shared between them.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  String _seen(HubDevice d) {
    final t = d.lastConnected;
    if (t == null) return 'Never connected';
    final s = DateTime.now().difference(t);
    if (s.inMinutes < 2) return 'Connected just now';
    if (s.inHours < 1) return 'Last connected ${s.inMinutes} min ago';
    if (s.inDays < 1) return 'Last connected ${s.inHours} h ago';
    return 'Last connected ${s.inDays} d ago';
  }

  static Future<void> rename(BuildContext context, ConnectionManager hub, HubDevice d) async {
    final c = TextEditingController(text: d.name);
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: c, maxLength: 24, autofocus: true, decoration: const InputDecoration(labelText: 'Name', counterText: '')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save'))],
      ),
    );
    c.dispose();
    if (n == null || n.isEmpty) return;
    await hub.registry.rename(d.id, n);
    if (hub.device?.id == d.id && hub.canSend) await hub.trySend({'cmd': 'name', 'name': n}, idempotent: true); // the Hub shows this name to other phones too
    hub.deviceChanged();
  }

  Future<void> _remove(BuildContext context, ConnectionManager hub, HubDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text('The Hub stays set up and keeps its Wi-Fi. This phone forgets it and its token, so you will need to pair it again to control it.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove', style: TextStyle(color: HubColors.danger)))],
      ),
    );
    if (ok == true) {
      final wasCurrent = hub.device?.id == d.id;
      if (wasCurrent) {
        await hub.disconnect(forget: true);
      } else {
        await hub.registry.remove(d.id);
      }
      hub.deviceChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final devices = hub.registry.devices;
    return Scaffold(
      appBar: AppBar(title: const Text('Your Hubs')),
      body: ListView(padding: Sp.page, children: [
        if (devices.isEmpty)
          StateView.empty('No Hubs yet', message: 'Add your first Hub to get started.', icon: Icons.developer_board_rounded)
        else
          for (final d in devices)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Builder(builder: (context) {
                final current = hub.device?.id == d.id;
                final look = current ? connLook(hub.state) : null;
                return Panel(
                  onTap: current
                      ? () => Navigator.of(context).pop()
                      : () async {
                          Navigator.of(context).pop();
                          await hub.connectDevice(d);
                        },
                  child: Row(children: [
                    Icon(Icons.developer_board_rounded, color: current ? HubColors.text : HubColors.muted),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(d.name, style: Ty.title),
                        const SizedBox(height: 2),
                        Text('${d.id} · ${d.host.isEmpty ? 'no address yet' : d.host}${d.fw.isEmpty ? '' : ' · fw ${d.fw}'}', style: Ty.secondary),
                        const SizedBox(height: 2),
                        Text(_seen(d), style: Ty.meta),
                        if (look != null) ...[const SizedBox(height: 8), StatusPill(color: look.color, label: look.label, pulse: look.pulse)],
                      ]),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      onSelected: (v) => v == 'rename' ? rename(context, hub, d) : _remove(context, hub, d),
                      itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'remove', child: Text('Remove'))],
                    ),
                  ]),
                );
              }),
            ),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: () => Navigator.of(context).push(hubRoute(const WelcomeScreen(addMode: true))), icon: const Icon(Icons.add_rounded), label: const Text('Add a Hub')),
      ]),
    );
  }
}
