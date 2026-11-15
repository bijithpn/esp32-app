import 'package:flutter/material.dart';

import '../core/connection.dart';
import '../core/diagnostics.dart';
import '../theme.dart';

/// The last 100 connection events (kept on the phone, no secrets).
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  static IconData _icon(String k) => switch (k) {
        'connected' => Icons.link_rounded,
        'disconnected' => Icons.link_off_rounded,
        'wifi_changed' => Icons.wifi_rounded,
        'auth_failed' => Icons.lock_outline_rounded,
        'rebooted' => Icons.restart_alt_rounded,
        'firmware_updated' => Icons.system_update_alt_rounded,
        'ip_changed' => Icons.alt_route_rounded,
        'provisioned' => Icons.check_circle_outline_rounded,
        _ => Icons.circle_outlined,
      };

  static String _title(String k) => switch (k) {
        'connected' => 'Connected',
        'disconnected' => 'Connection lost',
        'wifi_changed' => 'Wi-Fi changed',
        'auth_failed' => 'Token refused',
        'rebooted' => 'Hub restarted',
        'firmware_updated' => 'Firmware updated',
        'ip_changed' => 'Address changed',
        'provisioned' => 'Wi-Fi set up',
        _ => k,
      };

  static Color _color(String k) => switch (k) {
        'connected' || 'provisioned' || 'firmware_updated' => HubColors.ok,
        'disconnected' || 'auth_failed' => HubColors.warn,
        _ => HubColors.muted,
      };

  String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    final hh = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (d.inHours < 24 && DateTime.now().day == t.day) return 'Today $hh';
    if (d.inHours < 48) return 'Yesterday $hh';
    return '${t.day}/${t.month} $hh';
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.read(context);
    return ListenableBuilder(
      listenable: hub.history,
      builder: (context, _) {
        final ev = hub.history.events;
        return Scaffold(
          appBar: AppBar(title: const Text('Connection history'), actions: [if (ev.isNotEmpty) TextButton(onPressed: hub.history.clear, child: const Text('Clear'))]),
          body: ev.isEmpty
              ? StateView.empty('Nothing yet', message: 'Connects, drops, network changes and updates show up here.', icon: Icons.history_rounded)
              : ListView.separated(
                  padding: Sp.page,
                  itemCount: ev.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (_, i) => _Row(e: ev[i], when: _when(ev[i].at)),
                ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.e, required this.when});
  final ConnEvent e;
  final String when;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(HistoryScreen._icon(e.kind), size: 20, color: HistoryScreen._color(e.kind)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(HistoryScreen._title(e.kind), style: Ty.bodyStrong), if (e.detail.isNotEmpty) Text(e.detail, style: Ty.secondary)])),
          Text(when, style: Ty.meta),
        ]),
      );
}
