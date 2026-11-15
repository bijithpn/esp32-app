import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../theme.dart';

/// Readable diagnostics for the connected Hub, a connection test with real timings, and sanitised logs for sharing.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _Step {
  _Step(this.name);
  final String name;
  bool? ok;
  String detail = '';
  bool get running => ok == null;
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Map<String, dynamic>? _diag;
  String? _diagError;
  bool _loading = true, _testing = false;
  List<_Step> _steps = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final hub = HubScope.read(context);
    setState(() { _loading = true; _diagError = null; });
    final a = hub.api;
    try {
      if (a is HttpApi) {
        final d = await a.diag();
        if (mounted) setState(() => _diag = d);
      } else {
        setState(() => _diagError = 'Detailed diagnostics need a direct Wi-Fi connection to the Hub.');
      }
    } catch (e) {
      final h = toHubException(e);
      if (mounted) setState(() => _diagError = h.kind == HubError.badResponse ? 'This Hub\'s firmware is older than 0.6 and has no detailed diagnostics. You can still run the connection test.' : friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runTest() async {
    final hub = HubScope.read(context);
    final a = hub.api;
    setState(() { _testing = true; _steps = []; });
    Future<void> step(String name, Future<String> Function() body) async {
      final s = _Step(name);
      setState(() => _steps = [..._steps, s]);
      try {
        s.detail = await body();
        s.ok = true;
      } catch (e) {
        s.ok = false;
        s.detail = friendlyError(e);
        hub.log.w('test', '$name failed: ${toHubException(e)}');
      }
      if (mounted) setState(() {});
    }

    if (a is HubLink) {
      await step('Reach the Hub and verify its identity', () async {
        final f = await a.hello(timeout: const Duration(seconds: 3));
        if (f == null) throw HubException(HubError.wrongDevice);
        if (hub.device != null && f.id != hub.device!.id) throw HubException(HubError.wrongDevice);
        return '${f.name} · ${f.id} · firmware ${f.fw} · API ${f.apiVersion}';
      });
      await step('Authentication', () async => await a.checkAuth() ? 'Accepted' : throw HubException(HubError.auth));
      await step('Response time (7 requests)', () async {
        final t = <int>[];
        for (var i = 0; i < 7; i++) {
          t.add((await a.ping(timeout: const Duration(seconds: 3))).ms);
        }
        t.sort();
        return 'median ${t[3]} ms · slowest ${t.last} ms · fastest ${t.first} ms';
      });
      await step('Command round trip', () async {
        final sw = Stopwatch()..start();
        await hub.send({'cmd': 'noop'}, idempotent: true, retries: 0, timeout: const Duration(seconds: 4));
        return '${sw.elapsedMilliseconds} ms';
      });
    } else {
      setState(() => _steps = [_Step('Connect to a Hub first')..ok = false]);
    }
    if (mounted) setState(() => _testing = false);
    _load();
  }

  Widget _kv(String k, Object? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 132, child: Text(k, style: Ty.secondary)), Expanded(child: Text('${v ?? '—'}', style: Ty.body.copyWith(fontSize: 14)))]),
      );

  String _uptime(num? s) {
    if (s == null) return '—';
    final v = s.toInt();
    return v >= 86400 ? '${v ~/ 86400} d ${(v % 86400) ~/ 3600} h' : v >= 3600 ? '${v ~/ 3600} h ${(v % 3600) ~/ 60} min' : '${v ~/ 60} min ${v % 60} s';
  }

  String _kb(Object? b) => b is num ? '${(b / 1024).toStringAsFixed(1)} KB' : '—';

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final d = hub.device;
    final dg = _diag;
    final heap = dg?['heap'] as Map?;
    final wifi = dg?['wifi'] as Map?;
    final render = dg?['render'] as Map?;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics'), actions: [IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded))]),
      body: ListView(padding: Sp.page, children: [
        FilledButton.icon(onPressed: _testing || !hub.canSend ? null : _runTest, icon: _testing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.network_check_rounded), label: Text(_testing ? 'Testing…' : 'Run connection test')),
        if (_steps.isNotEmpty) ...[
          const SizedBox(height: 14),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final s in _steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 22, child: s.running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(s.ok! ? Icons.check_circle_rounded : Icons.error_rounded, size: 20, color: s.ok! ? HubColors.ok : HubColors.danger)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(s.name, style: Ty.bodyStrong), if (s.detail.isNotEmpty) Text(s.detail, style: Ty.secondary)])),
                  ]),
                ),
            ]),
          ),
        ],
        const SectionTitle('Connection'),
        Panel(child: Column(children: [
          _kv('State', '${connStates[hub.state]?.label ?? ''}${hub.reason.isEmpty ? '' : ' · ${hub.reason}'}'),
          _kv('Via', hub.viaRemote ? 'Internet (MQTT)' : 'Local network'),
          _kv('Address', d?.host),
          _kv('Latency', hub.latencyMs >= 0 ? '${hub.latencyMs} ms' : '—'),
          _kv('Last success', hub.lastOkAt?.toLocal().toIso8601String().substring(11, 19)),
          _kv('Phone network', hub.net.prefixes.isEmpty ? 'none' : hub.net.prefixes.map((p) => '$p.x').join(', ')),
          _kv('Discovery', hub.discovery.lastStats.toString()),
        ])),
        const SectionTitle('Hub'),
        if (_loading)
          StateView.loading('Reading diagnostics')
        else if (_diagError != null)
          Panel(child: Text(_diagError!, style: Ty.secondary.copyWith(fontSize: 14)))
        else if (dg != null) ...[
          Panel(child: Column(children: [
            _kv('Device ID', dg['id']),
            _kv('Firmware', dg['fw']),
            _kv('API version', dg['apiVersion']),
            _kv('Uptime', _uptime(dg['uptime'] as num?)),
            _kv('Last reset', '${dg['resetReason']}'.replaceAll('_', ' ')),
            _kv('Crashes', '${dg['crashes']} in a row · ${dg['crashesTotal']} total'),
            _kv('Safe mode', dg['safeMode'] == true ? 'ON (skipped saved scene and MQTT)' : 'off'),
            _kv('Time known', dg['timeSynced'] == true ? 'yes' : 'not yet'),
          ])),
          const SectionTitle('Memory'),
          Panel(child: Column(children: [
            _kv('Free now', _kb(heap?['free'])),
            _kv('Lowest ever', _kb(heap?['min'])),
            _kv('Largest block', _kb(heap?['maxBlock'])),
            _kv('Fragmentation', heap == null ? '—' : '${heap['fragPct']} %'),
            _kv('Loop stack free', _kb(dg['loopStackFree'])),
          ])),
          const SectionTitle('Wi-Fi and display'),
          Panel(child: Column(children: [
            _kv('Network', wifi?['ssid']),
            _kv('Signal', wifi == null ? null : '${wifi['rssi']} dBm · channel ${wifi['channel']}'),
            _kv('Address', wifi?['ip']),
            _kv('Last drop reason', wifi == null ? null : 'code ${wifi['lastDiscReason']} (${wifi['discCount']} drops since the last join)'),
            _kv('Frame time', render == null ? null : '${((render['frameUs'] as num) / 1000).toStringAsFixed(1)} ms (budget ${render['frameMs']} ms)'),
            _kv('Longest loop gap', render == null ? null : '${render['loopGapMaxMs']} ms'),
          ])),
        ],
        const SectionTitle('Logs'),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Passwords, tokens and API keys are removed before anything is shown or copied.', style: Ty.secondary),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: hub.diagnosticsReport()));
                    if (context.mounted) toast(context, 'Report copied');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  label: const Text('Copy report'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: () { hub.log.clear(); setState(() {}); }, child: const Text('Clear')),
            ]),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: HubColors.bg, borderRadius: BorderRadius.circular(10)),
              child: SingleChildScrollView(reverse: true, child: SelectableText(hub.log.lines.reversed.take(80).toList().reversed.map((l) => l.toString().substring(11)).join('\n'), style: Ty.mono.copyWith(fontSize: 11, color: HubColors.muted))),
            ),
          ]),
        ),
      ]),
    );
  }
}
