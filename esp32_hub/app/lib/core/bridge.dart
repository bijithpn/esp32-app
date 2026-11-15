import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as web;

/// Result of one HTTP request to a board.
class HttpResult {
  const HttpResult(this.status, this.body, this.ms);
  final int status;
  final String body;
  final int ms;

  Map<String, dynamic>? get json {
    try {
      final m = jsonDecode(body);
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }
}

/// A network-level failure (nothing came back). [kind]: timeout | refused | unreachable | dns | io.
class HubNetError implements Exception {
  HubNetError(this.kind, [this.message = '']);
  final String kind;
  final String message;
  @override
  String toString() => 'HubNetError($kind${message.isEmpty ? '' : ': $message'})';
}

/// One reply to a UDP discovery request or a subnet sweep: who answered and what they said.
class RawReply {
  const RawReply(this.host, this.body);
  final String host, body;
}

/// A board announced through mDNS. Treated as a hint only: it is verified through the HTTP API afterwards.
class MdnsHit {
  const MdnsHit({required this.host, this.id = '', this.name = '', this.fw = ''});
  final String host, id, name, fw;
}

/// Snapshot / change of the phone's network.
class NetInfo {
  const NetInfo({this.wifi = false, this.cellular = false, this.validated = false, this.hotspot = false, this.prefixes = const []});
  final bool wifi, cellular, validated, hotspot;
  final List<String> prefixes;

  bool get hasLan => wifi || hotspot;

  static NetInfo fromMap(Map? m) {
    if (m == null) return const NetInfo();
    return NetInfo(
      wifi: m['wifi'] == true,
      cellular: m['cellular'] == true,
      validated: m['validated'] == true,
      hotspot: m['hotspot'] == true,
      prefixes: ((m['prefixes'] as List?) ?? const []).map((e) => '$e').toList(),
    );
  }
}

/// A change reported by the Android network monitor.
class NetEvent {
  const NetEvent(this.type, this.state, this.info);
  final String type; // snapshot | default | wifi | hotspot
  final String state; // available | changed | lost | ...
  final NetInfo info;
}

/// The song playing on the phone, as far as the music app exposes it. Any field can be empty: apps differ.
class NowPlaying {
  const NowPlaying({this.title = '', this.artist = '', this.app = '', this.playing = false, this.posSec = 0, this.durSec = 0, this.art});
  final String title, artist, app;
  final bool playing;
  final int posSec, durSec;
  final Uint8List? art;
}

enum JoinCode { ok, unsupported, unavailable, error }

/// All calls into the Android side. Every local-network call goes through the Wi-Fi network on the Kotlin side
/// (Network.openConnection / bindSocket); nothing here binds the whole app to a network.
/// Off Android (tests, desktop) the calls fall back to plain dart:io / in-memory so the logic stays testable.
class Bridge {
  Bridge();
  static final Bridge instance = Bridge();

  static const _ch = MethodChannel('esp32hub/bridge');
  static const _events = EventChannel('esp32hub/network');

  /// Replace in tests.
  static Bridge current = instance;

  final Map<String, String> _memSecure = {};

  Future<T?> _call<T>(String m, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  // ---------------------------------------------------------------- network
  Future<NetInfo> netSnapshot() async => NetInfo.fromMap(await _call<Map>('net.snapshot'));

  Stream<NetEvent> netEvents() {
    try {
      return _events.receiveBroadcastStream().map((e) {
        final m = (e as Map).cast<dynamic, dynamic>();
        return NetEvent('${m['t']}', '${m['state'] ?? ''}', NetInfo.fromMap(m));
      }).handleError((_) {});
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// One HTTP request to a board.
  Future<HttpResult> http(String method, String url, {Map<String, String> headers = const {}, String? body, Duration timeout = const Duration(seconds: 6)}) async {
    Map? r;
    try {
      r = await _ch.invokeMethod<Map>('net.http', {'method': method, 'url': url, 'headers': headers, 'body': body, 'timeoutMs': timeout.inMilliseconds});
    } on MissingPluginException {
      return _dartHttp(method, url, headers, body, timeout);
    } on PlatformException catch (e) {
      throw HubNetError('io', e.message ?? '');
    }
    if (r == null) throw HubNetError('io', 'no answer from the platform');
    if (r['error'] != null) throw HubNetError('${r['error']}', '${r['message'] ?? ''}');
    return HttpResult((r['status'] as num).toInt(), '${r['body'] ?? ''}', ((r['ms'] ?? 0) as num).toInt());
  }

  Future<HttpResult> _dartHttp(String method, String url, Map<String, String> headers, String? body, Duration timeout) async {
    final sw = Stopwatch()..start();
    try {
      final u = Uri.parse(url);
      final r = method == 'POST'
          ? await web.post(u, headers: headers, body: body).timeout(timeout)
          : await web.get(u, headers: headers).timeout(timeout);
      return HttpResult(r.statusCode, r.body, sw.elapsedMilliseconds);
    } on TimeoutException {
      throw HubNetError('timeout');
    } on SocketException catch (e) {
      throw HubNetError(e.osError?.errorCode == 111 ? 'refused' : 'unreachable', e.message);
    } catch (e) {
      throw HubNetError('io', '$e');
    }
  }

  /// Subnet sweep: asks each host for [path] and returns the ones that answered 200.
  Future<List<RawReply>> sweep(List<String> hosts, {String path = '/api/hello', int timeoutMs = 700}) async {
    final l = await _call<List>('net.sweep', {'hosts': hosts, 'path': path, 'timeoutMs': timeoutMs});
    return (l ?? const []).map((e) => RawReply('${(e as Map)['host']}', '${e['body']}')).toList();
  }

  /// UDP discovery broadcast. Replies are hints; verify them over HTTP.
  Future<List<RawReply>> udpDiscover({int timeoutMs = 1200}) async {
    final l = await _call<List>('net.udp', {'port': 41234, 'magic': 'ESP32_HUB_DISCOVER_V1', 'timeoutMs': timeoutMs});
    return (l ?? const []).map((e) => RawReply('${(e as Map)['host']}', '${e['body']}')).toList();
  }

  Future<List<MdnsHit>> mdns({int timeoutMs = 2500}) async {
    final l = await _call<List>('net.mdns', {'timeoutMs': timeoutMs});
    return (l ?? const []).map((e) {
      final m = e as Map;
      return MdnsHit(host: '${m['host']}', id: '${m['id'] ?? ''}', name: '${m['name'] ?? ''}', fw: '${m['fw'] ?? ''}');
    }).toList();
  }

  // ---------------------------------------------------------------- hotspot
  /// Joins the board's hotspot (Android 10+ asks the user once). The app is NOT pinned to it.
  Future<JoinCode> joinWifi(String ssid, String pass) async {
    final r = await _call<Map>('wifi.join', {'ssid': ssid, 'pass': pass});
    switch (r?['code']) {
      case 'ok':
        return JoinCode.ok;
      case 'unsupported':
        return JoinCode.unsupported;
      case 'unavailable':
        return JoinCode.unavailable;
      default:
        return JoinCode.error;
    }
  }

  Future<void> leaveHotspot() async => _call<void>('wifi.leave');

  // ---------------------------------------------------------------- secure storage
  Future<String?> secureGet(String name) async {
    try {
      final v = await _ch.invokeMethod<String>('secure.get', {'name': name});
      return v;
    } on MissingPluginException {
      return _memSecure[name];
    } on PlatformException {
      return null;
    }
  }

  Future<void> secureSet(String name, String? value) async {
    try {
      if (value == null) {
        await _ch.invokeMethod('secure.delete', {'name': name});
      } else {
        await _ch.invokeMethod('secure.set', {'name': name, 'value': value});
      }
    } on MissingPluginException {
      if (value == null) {
        _memSecure.remove(name);
      } else {
        _memSecure[name] = value;
      }
    } on PlatformException {
      // the Keystore refused: the caller sees the value missing next time
    }
  }

  // ---------------------------------------------------------------- phone features
  Future<bool> notificationAccess() async => (await _call<bool>('isGranted')) ?? false;
  Future<void> openNotificationSettings() => _call<void>('openSettings');
  Future<Map<String, dynamic>> getConfig() async => ((await _call<Map>('getConfig')) ?? const {}).cast<String, dynamic>();
  Future<void> setConfig(Map<String, dynamic> c) => _call<void>('setConfig', c);
  Future<({bool ignoring, int sdk})> battery() async {
    final m = await _call<Map>('batteryStatus');
    return (ignoring: m?['ignoringOptimizations'] == true, sdk: ((m?['sdk'] ?? 0) as num).toInt());
  }

  Future<void> openBatterySettings() => _call<void>('openBatterySettings');

  /// Needs notification access. Null when nothing is playing or the access is missing.
  Future<NowPlaying?> nowPlaying() async {
    final m = await _call<Map>('media.now');
    if (m == null) return null;
    return NowPlaying(
      title: '${m['title'] ?? ''}',
      artist: '${m['artist'] ?? ''}',
      app: '${m['app'] ?? ''}',
      playing: m['playing'] == true,
      posSec: ((m['pos'] ?? 0) as num).toInt(),
      durSec: ((m['dur'] ?? 0) as num).toInt(),
      art: m['art'] is Uint8List ? m['art'] as Uint8List : null,
    );
  }

  Future<({double lat, double lon})?> location() async {
    final m = await _call<Map>('getLocation');
    if (m == null || m['lat'] == null || m['lon'] == null) return null;
    return (lat: (m['lat'] as num).toDouble(), lon: (m['lon'] as num).toDouble());
  }
}
