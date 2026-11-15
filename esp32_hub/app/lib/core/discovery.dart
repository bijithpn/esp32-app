import 'dart:async';

import 'bridge.dart';
import 'diagnostics.dart';
import 'models.dart';

/// What the app already knows about a board, used to find it again fast.
class KnownHint {
  const KnownHint(this.id, this.host, this.hostname);
  final String id, host, hostname;
}

/// Timing of the last scan, for Diagnostics and for tuning.
class DiscoveryStats {
  int firstHitMs = -1;
  String firstSource = '';
  int boards = 0;
  int totalMs = 0;
  @override
  String toString() => 'first=${firstSource.isEmpty ? 'none' : '$firstSource@${firstHitMs}ms'} boards=$boards total=${totalMs}ms';
}

/// Finds ESP32 Hubs without anyone typing an address. Several strategies run at the same time and each verified board is
/// reported the moment it answers:
///  1. the last known address, and the board's own hostname (usually the answer, ~100 ms)
///  2. UDP discovery broadcast (one packet, every board in the LAN answers; ~300 ms)
///  3. mDNS "_esp32hub._tcp" through Android's resolver (1-3 s, can be blocked by multicast filtering)
///  4. the setup hotspot address 192.168.4.1 when the phone is on that network
///  5. a bounded sweep of the phone's /24 networks, started a moment later so the fast methods win
/// Every address from 2, 3 and 5 is only a hint: a board counts as found only after GET /api/hello returned a valid
/// identity (device marker, id, firmware). Any other web server on the LAN is ignored.
class DiscoveryService {
  DiscoveryService({Bridge? bridge, DiagLog? log, this.sweepDelay = const Duration(milliseconds: 900)})
      : _bridge = bridge ?? Bridge.current,
        _log = log ?? DiagLog.instance;

  final Bridge _bridge;
  final DiagLog _log;
  final Duration sweepDelay;
  DiscoveryStats lastStats = DiscoveryStats();

  /// The /24 networks the last scan looked at (e.g. ["192.168.1"]); empty means the phone has no LAN.
  List<String> lastPrefixes = [];

  Future<FoundBoard?> probe(String host, {Duration timeout = const Duration(milliseconds: 1200), String source = 'probe'}) async {
    try {
      final r = await _bridge.http('GET', 'http://$host/api/hello', timeout: timeout);
      if (r.status != 200) return null;
      return FoundBoard.parse(host, r.body, source: source, latencyMs: r.ms);
    } catch (_) {
      return null;
    }
  }

  /// Streams verified boards. [wantId] ends the scan at that board. [hints] are devices already paired.
  Stream<FoundBoard> scan({List<KnownHint> hints = const [], String? wantId, bool sweep = true, Duration budget = const Duration(seconds: 12)}) {
    final ctl = StreamController<FoundBoard>();
    var stop = false;
    ctl.onCancel = () => stop = true;
    final sw = Stopwatch()..start();
    final stats = DiscoveryStats();
    lastStats = stats;

    () async {
      try {
        final seen = <String>{};
        final emitted = <String>{};

        void emit(FoundBoard f) {
          if (stop) return;
          if (!emitted.add('${f.id}@${f.host}')) return; // the same board from two strategies is one result
          if (stats.firstHitMs < 0) {
            stats.firstHitMs = sw.elapsedMilliseconds;
            stats.firstSource = f.source;
          }
          stats.boards++;
          ctl.add(f);
          if (wantId == null || f.id == wantId.toUpperCase()) {
            if (wantId != null) stop = true;
          }
        }

        Future<void> check(String host, Duration t, String source) async {
          if (stop || !seen.add('$source|$host')) return;
          final f = await probe(host, timeout: t, source: source);
          if (f != null) emit(f);
        }

        final net = await _bridge.netSnapshot();
        lastPrefixes = net.prefixes;

        // 1. known addresses and hostnames
        final known = <Future<void>>[
          for (final h in hints) ...[
            if (h.host.isNotEmpty) check(h.host, const Duration(milliseconds: 1200), 'known-ip'),
            check(h.hostname, const Duration(milliseconds: 1500), 'hostname'),
          ],
        ];

        // 2. UDP
        Future<void> udp() async {
          for (final r in await _bridge.udpDiscover(timeoutMs: 1200)) {
            await check(r.host, const Duration(milliseconds: 1200), 'udp'); // the advertised ip is a hint: verify it
          }
        }

        // 3. mDNS
        Future<void> mdns() async {
          for (final m in await _bridge.mdns(timeoutMs: 2500)) {
            await check(m.host, const Duration(milliseconds: 1500), 'mdns');
          }
        }

        // 4. hotspot
        final onHotspotNet = net.hotspot || net.prefixes.contains('192.168.4');

        // 5. sweep, nearest to the last known address first
        Future<void> sweepAll() async {
          if (sweepDelay > Duration.zero) await Future.delayed(sweepDelay);
          if (stop) return;
          final lastHost = hints.map((h) => h.host).where((h) => h.contains('.')).firstOrNull;
          final lastOctet = int.tryParse((lastHost ?? '').split('.').last);
          final lastPre = lastHost == null ? null : (lastHost.split('.')..removeLast()).join('.');
          for (final pre in net.prefixes) {
            final order = [for (var i = 1; i < 255; i++) i];
            if (pre == lastPre && lastOctet != null) order.sort((a, b) => (a - lastOctet).abs().compareTo((b - lastOctet).abs()));
            for (var i = 0; i < order.length && !stop; i += 64) {
              final chunk = order.skip(i).take(64).map((o) => '$pre.$o').where((h) => !seen.contains('sweep|$h')).toList();
              for (final h in chunk) {
                seen.add('sweep|$h');
              }
              for (final r in await _bridge.sweep(chunk, timeoutMs: 700)) {
                if (stop) break;
                final f = FoundBoard.parse(r.host, r.body, source: 'sweep');
                if (f != null) emit(f);
              }
            }
          }
        }

        final work = <Future<void>>[
          ...known,
          udp(),
          mdns(),
          if (onHotspotNet) check('192.168.4.1', const Duration(milliseconds: 2000), 'hotspot'),
          if (sweep) sweepAll(),
        ];
        final budgetDone = Completer<void>();
        final budgetTimer = Timer(budget, () {
          if (!budgetDone.isCompleted) budgetDone.complete();
        });
        await Future.any([Future.wait(work).then<void>((_) {}), budgetDone.future]).catchError((_) {});
        budgetTimer.cancel();
        stats.totalMs = sw.elapsedMilliseconds;
        _log.i('discovery', stats.toString());
      } catch (e) {
        _log.w('discovery', 'scan stopped: $e'); // a failed lookup must never leave the UI waiting: the stream just ends
      } finally {
        stop = true;
        if (!ctl.isClosed) await ctl.close();
      }
    }();

    return ctl.stream;
  }

  /// Waits until a board with this id answers on the network (not as a hotspot), e.g. after Wi-Fi setup or a router restart.
  Future<FoundBoard?> waitFor(String id, {Duration limit = const Duration(seconds: 60), List<KnownHint> hints = const [], bool Function()? cancelled}) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      if (cancelled?.call() == true) return null;
      await for (final f in scan(hints: hints, wantId: id, budget: const Duration(seconds: 8))) {
        if (f.id == id.toUpperCase() && !f.ap) return f;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }
}
