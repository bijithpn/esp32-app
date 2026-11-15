import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'phone.dart';

/// A board found on the network.
class FoundBoard {
  FoundBoard({required this.host, required this.id, required this.fw, required this.ap, required this.lock});
  final String host, id, fw;
  final bool ap, lock;
}

/// Finds ESP32 Hubs without anyone typing an IP address.
/// The board answers GET /api/hello (tiny, always open, never reveals the token).
class Discovery {
  /// Networks the last scan looked at (e.g. ["192.168.1"]), so the app can say what it searched. Empty = phone has no Wi-Fi/IP.
  static List<String> lastPrefixes = [];

  /// Asks one address whether it is a hub. Returns null if not (or no answer in time).
  static Future<FoundBoard?> probe(String host, {Duration timeout = const Duration(milliseconds: 1200)}) async {
    try {
      final r = await http.get(Uri.parse('http://$host/api/hello')).timeout(timeout);
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map || m['device'] != 'ESP32-Hub') return null;
      return FoundBoard(host: host, id: '${m['id'] ?? ''}', fw: '${m['fw'] ?? ''}', ap: m['ap'] == true, lock: m['lock'] == true);
    } catch (_) {
      return null;
    }
  }

  /// The first three numbers of every IPv4 network this phone is on (e.g. "192.168.1").
  static Future<List<String>> _prefixes() async {
    final out = <String>[];
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          final p = a.address.split('.');
          if (p.length == 4 && !a.isLoopback && !a.address.startsWith('169.254')) out.add('${p[0]}.${p[1]}.${p[2]}');
        }
      }
    } catch (_) {}
    return out.toSet().toList();
  }

  /// Finds boards fast by trying every method at the same time and reporting each board the moment it answers:
  ///  1. the last known address (usually the answer: the router gives the board the same IP every time)
  ///  2. Android's own mDNS lookup of the board's "_esp32hub._tcp" service (a couple of seconds, no scanning)
  ///  3. the board's hotspot address 192.168.4.1
  ///  4. every address of the phone's network, 48 at a time, nearest to the last known address first
  /// `wantId` makes it stop at that board.
  static Stream<FoundBoard> scan({String? lastHost, String? wantId}) {
    final ctl = StreamController<FoundBoard>();
    var stop = false;
    ctl.onCancel = () => stop = true;

    () async {
      try {
        await PhoneBridge.bindWifi(force: true); // a Wi-Fi without internet (the board's hotspot) must not lose to mobile data
        final seen = <String>{};

        Future<void> check(String h, Duration t) async {
          if (stop || !seen.add(h)) return;
          final f = await probe(h, timeout: t);
          if (f == null || stop) return;
          ctl.add(f);
          if (wantId == null || f.id == wantId) stop = true;
        }

        final prefixes = await _prefixes();
        lastPrefixes = prefixes;

        // 4. sweep the local network(s); the likeliest addresses first
        final hosts = <String>[];
        final lastOctet = int.tryParse((lastHost ?? '').split('.').last);
        final lastPre = (lastHost ?? '').contains('.') ? (lastHost!.split('.')..removeLast()).join('.') : null;
        for (final pre in prefixes) {
          final order = [for (var i = 1; i < 255; i++) i];
          if (pre == lastPre && lastOctet != null) order.sort((a, b) => (a - lastOctet).abs().compareTo((b - lastOctet).abs()));
          hosts.addAll(order.map((i) => '$pre.$i'));
        }
        Future<void> sweep() async {
          var next = 0;
          Future<void> worker() async {
            while (!stop) {
              final k = next++;
              if (k >= hosts.length) return;
              await check(hosts[k], const Duration(milliseconds: 700));
            }
          }
          await Future.wait(List.generate(48, (_) => worker()));
        }

        Future<void> mdns() async {
          for (final ip in await PhoneBridge.mdnsFind()) {
            await check(ip, const Duration(milliseconds: 1500));
          }
        }

        await Future.wait([
          if (lastHost != null && lastHost.isNotEmpty) check(lastHost, const Duration(milliseconds: 1500)),
          check('192.168.4.1', const Duration(milliseconds: 2000)),
          check('esp32-hub.local', const Duration(milliseconds: 1500)),
          mdns(),
          sweep(),
        ]);
      } catch (_) {
        // a failed lookup must never leave the app waiting: the stream just ends
      } finally {
        if (!ctl.isClosed) await ctl.close();
      }
    }();

    return ctl.stream;
  }

  /// Waits for a board with this id to (re)appear, e.g. after Wi-Fi setup or a router restart.
  static Future<FoundBoard?> waitFor(String id, {Duration limit = const Duration(seconds: 60), String? lastHost}) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      await for (final f in scan(lastHost: lastHost, wantId: id)) {
        if (f.id == id && !f.ap) return f;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }
}
