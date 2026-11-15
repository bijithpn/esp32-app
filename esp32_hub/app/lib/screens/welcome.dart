import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/connection.dart';
import '../core/models.dart';
import '../qr.dart';
import '../theme.dart';
import 'manual.dart';
import 'pairing.dart';

/// First screen for a new user, and the "add a Hub" screen later. Shows what is nearby, with the QR and manual routes
/// as secondary options. Searching never blocks the screen.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, this.addMode = false});
  final bool addMode;
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _searchedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  Future<void> _search() async {
    final hub = HubScope.read(context);
    hub.clearNearby();
    await hub.startDiscovery();
    if (mounted) setState(() => _searchedOnce = true);
  }

  Future<void> _open(FoundBoard f) async {
    final hub = HubScope.read(context);
    if (f.ap) {
      // The phone is on the Hub's setup hotspot: it still needs Wi-Fi.
      final c = await Navigator.of(context).push<bool>(hubRoute(PairingScreen(hotspotBoard: f)));
      if (c == true && mounted && widget.addMode) Navigator.of(context).pop();
      return;
    }
    final existing = hub.registry.byId(f.id);
    final d = f.toDevice(base: existing);
    await hub.registry.upsert(d, select: true);
    await hub.connectDevice(d);
    if (mounted && widget.addMode) Navigator.of(context).pop();
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context).push<String>(hubRoute(const QrScanPage()));
    if (v == null || !mounted) return;
    final wifi = HubWifiQr.parse(v);
    if (wifi != null) {
      await Navigator.of(context).push(hubRoute(PairingScreen(wifiQr: wifi)));
      return;
    }
    final info = PairInfo.parse(v);
    if (info == null) return;
    // A pairing code from the Hub's own screen: it carries the token, so it is shown only to someone standing at the Hub.
    final hub = HubScope.read(context);
    final d = (hub.registry.byId(info.id) ?? HubDevice(id: info.id)).copyWith(host: info.ip, locked: true);
    await hub.registry.upsert(d, select: true);
    await hub.registry.setToken(info.id, info.token);
    await hub.connectDevice(d);
    if (mounted && widget.addMode) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final found = hub.nearby;
    final searching = hub.searching;
    final mood = searching && found.isEmpty ? 'thinking' : found.isNotEmpty ? 'happy' : 'sleepy';
    return Scaffold(
      appBar: widget.addMode ? AppBar(title: const Text('Add a Hub')) : null,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
              if (!widget.addMode) ...[
                const SizedBox(height: 8),
                Text('ESP32 Hub', style: Ty.meta.copyWith(letterSpacing: 1.6, fontWeight: FontWeight.w700)),
                const SizedBox(height: 20),
              ],
              Center(child: SizedBox(width: 208, child: DisplayFrame(child: AnimatedSwitcher(duration: motion(context, Motion.card), child: KeyedSubtree(key: ValueKey(mood), child: FaceScreen(mood: mood)))))),
              const SizedBox(height: 28),
              AnimatedSwitcher(
                duration: motion(context, Motion.small),
                child: Text(
                  searching && found.isEmpty ? 'Looking for your Hub' : found.isEmpty ? (_searchedOnce ? 'No Hub found' : 'Looking for your Hub') : found.length == 1 ? 'Found your Hub' : 'Found ${found.length} Hubs',
                  key: ValueKey('$searching${found.length}'),
                  textAlign: TextAlign.center,
                  style: Ty.h2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                found.isNotEmpty ? 'Choose one to open it.' : searching ? 'Keep it powered on and your phone on the same Wi-Fi.' : 'Check the checklist below, then search again.',
                textAlign: TextAlign.center,
                style: Ty.secondary.copyWith(fontSize: 14),
              ),
              const SizedBox(height: 16),
              SizedBox(height: 2, child: searching ? ClipRRect(borderRadius: BorderRadius.circular(2), child: const LinearProgressIndicator(minHeight: 2)) : null),
              const SizedBox(height: 16),
              if (found.isNotEmpty) ...[
                const SectionTitle('Nearby', top: 8),
                Group(children: [for (final f in found) _BoardRow(board: f, paired: hub.registry.byId(f.id) != null, onTap: () => _open(f))]),
              ] else if (!searching && _searchedOnce)
                const _Checklist(),
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: () => Navigator.of(context).push(hubRoute(const PairingScreen())), icon: const Icon(Icons.add_rounded), label: const Text('Add a new Hub')),
              const SizedBox(height: 10),
              OutlinedButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner_rounded), label: const Text('Scan the Hub\'s QR code')),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                TextButton(onPressed: searching ? null : _search, child: const Text('Search again')),
                TextButton(onPressed: () => Navigator.of(context).push(hubRoute(const ManualConnectScreen())), child: const Text('Enter address')),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.board, required this.paired, required this.onTap});
  final FoundBoard board;
  final bool paired;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Row2(
        icon: board.ap ? Icons.wifi_tethering_rounded : Icons.developer_board_rounded,
        iconColor: board.ap ? HubColors.warn : HubColors.text,
        title: board.name,
        sub: board.ap ? 'Setup mode · needs Wi-Fi' : '${board.id} · firmware ${board.fw}${board.lock ? ' · locked' : ''}${board.latencyMs > 0 ? ' · ${board.latencyMs} ms' : ''}',
        trailing: board.ap
            ? const Text('Set up', style: TextStyle(color: HubColors.accent, fontWeight: FontWeight.w600, fontSize: 13))
            : paired
                ? const StatusPill(color: HubColors.ok, label: 'Paired')
                : chevron,
        onTap: onTap,
      );
}

class _Checklist extends StatelessWidget {
  const _Checklist();
  @override
  Widget build(BuildContext context) => const Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Nothing answered', style: Ty.title),
          SizedBox(height: 10),
          _Tip(Icons.power_rounded, 'Is it powered?', 'You should see a face, or a SETUP screen on a new Hub.'),
          _Tip(Icons.wifi_rounded, 'Same Wi-Fi?', 'Your phone must be on the network the Hub joined (2.4 GHz). Some routers isolate Wi-Fi devices from each other.'),
          _Tip(Icons.add_circle_outline_rounded, 'Brand-new Hub?', 'Tap "Add a new Hub": the app walks you through it. Hold BOOT for 2 seconds to start pairing.'),
        ]),
      );
}

class _Tip extends StatelessWidget {
  const _Tip(this.icon, this.title, this.text);
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: HubColors.muted),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Ty.bodyStrong), const SizedBox(height: 2), Text(text, style: Ty.secondary)])),
        ]),
      );
}

/// Used when no network scan is possible at all.
String netProblem(NetInfo n) => n.hasLan ? '' : 'Your phone isn\'t on a Wi-Fi network. Turn Wi-Fi on and join the same network as the Hub.';
