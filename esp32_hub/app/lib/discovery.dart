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

  /// Quick checks first (last known address, mDNS name, the board's own hotspot), then every address on the local
  /// network, 40 at a time. Reports each board as soon as it is found. `wantId` makes it stop at that board.
  static Stream<FoundBoard> scan({String? lastHost, String? wantId}) async* {
    await PhoneBridge.bindWifi();   // a Wi-Fi without internet (the board's hotspot) must not lose to mobile data
    final seen = <String>{};
    Future<FoundBoard?> one(String h) async {
      if (!seen.add(h)) return null;
      return probe(h);
    }

    final quick = [if (lastHost != null && lastHost.isNotEmpty) lastHost, 'esp32-hub.local', '192.168.4.1'];
    for (final f in await Future.wait(quick.map(one))) {
      if (f != null) {
        yield f;
        if (wantId == null || f.id == wantId) return;
      }
    }
    lastPrefixes = await _prefixes();
    for (final pre in lastPrefixes) {
      final hosts = [for (var i = 1; i < 255; i++) '$pre.$i'];
      for (var i = 0; i < hosts.length; i += 40) {
        final chunk = hosts.sublist(i, i + 40 > hosts.length ? hosts.length : i + 40);
        for (final f in await Future.wait(chunk.map((h) async {
          if (!seen.add(h)) return null;
          return probe(h, timeout: const Duration(milliseconds: 900));
        }))) {
          if (f != null) {
            yield f;
            if (wantId == null || f.id == wantId) return;
          }
        }
      }
    }
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
