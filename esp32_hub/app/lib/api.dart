import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'core/bridge.dart';
import 'core/errors.dart';
import 'core/models.dart';

export 'core/errors.dart' show HubException, HubError;

/// Thrown when the board is locked and the token is missing or wrong.
class LockedException extends HubException {
  LockedException() : super(HubError.auth, 'token required', 'auth_required');
  @override
  String toString() => 'Device is locked: token required';
}

final _rnd = math.Random.secure();

/// A short random id for one command. The board remembers it for two minutes, so a retry after a lost reply is not run twice.
String newRequestId() => List.generate(12, (_) => _rnd.nextInt(16).toRadixString(16)).join();

/// A connection to one ESP32 Hub. Screens use the [ConnectionManager]; this is the transport underneath.
abstract class Api {
  /// Short text for the UI (IP address, or "MQTT" followed by the device id).
  String get label;

  /// True when the board can be reached directly by HTTP (needed for phone sync in the background).
  bool get isLocal;

  Future<Map<String, dynamic>> list();
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body, {Duration? timeout});
  Future<void> close() async {}
}

/// What the connection manager needs from a local link (also implemented by fakes in tests).
abstract class HubLink extends Api {
  String get host;
  String get token;
  Future<FoundBoard?> hello({Duration timeout});
  Future<({Map<String, dynamic> data, int ms})> ping({Duration timeout});
  Future<bool> checkAuth();
}

/// The Wi-Fi setup calls a board answers while it is in pairing mode.
abstract class ProvisionLink extends HubLink {
  Future<Map<String, dynamic>> wifiSet(String ssid, String pass);
  Future<Map<String, dynamic>> wifiStatus();
  Future<List<WifiNetwork>> networks();
}

// ======================================================================= HTTP (local network)
class HttpApi extends ProvisionLink {
  HttpApi(String host, {this.token = '', this.expectId})
      : host = host.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
  @override
  final String host;
  @override
  final String token;

  /// When set, every reply is checked against this board id (commands never reach a different board).
  final String? expectId;

  static const _t = Duration(seconds: 4);

  @override
  String get label => host;
  @override
  bool get isLocal => true;

  String _u(String p) => 'http://$host$p';
  Map<String, String> get _headers => {'Content-Type': 'application/json', if (token.isNotEmpty) 'X-Hub-Token': token};

  Future<HttpResult> _get(String path, {Duration timeout = _t, bool auth = false}) =>
      Bridge.current.http('GET', _u(path), headers: auth ? _headers : const {}, timeout: timeout);

  Map<String, dynamic> _json(HttpResult r) {
    final m = r.json;
    if (m == null) throw HubException(HubError.badResponse, 'HTTP ${r.status}');
    return m;
  }

  void _checkStatus(HttpResult r) {
    if (r.status == 401) throw LockedException();
    if (r.status == 429) throw HubException(HubError.rateLimited, 'HTTP 429', 'rate_limited');
  }

  /// The board's identity answer (verified): null when something else answered.
  @override
  Future<FoundBoard?> hello({Duration timeout = const Duration(milliseconds: 1500)}) async {
    final r = await _get('/api/hello', timeout: timeout);
    if (r.status != 200) return null;
    return FoundBoard.parse(host, r.body, source: 'http', latencyMs: r.ms);
  }

  @override
  Future<Map<String, dynamic>> list() async {
    final r = await _get('/api/list', auth: true);
    _checkStatus(r);
    if (r.status != 200) throw HubException(HubError.badResponse, 'HTTP ${r.status}');
    final m = _json(r);
    _verify(m['id']);
    return m;
  }

  @override
  Future<Map<String, dynamic>> status() async {
    final r = await _get('/api/status', auth: true);
    _checkStatus(r);
    return _json(r);
  }

  /// Tiny health probe: identity, scene, a change counter, uptime, RSSI. Also carries the latency.
  @override
  Future<({Map<String, dynamic> data, int ms})> ping({Duration timeout = const Duration(milliseconds: 1800)}) async {
    final r = await _get('/api/ping', timeout: timeout, auth: true);
    _checkStatus(r);
    if (r.status == 404) {
      // firmware older than 0.6: fall back to the hello endpoint
      final h = await _get('/api/hello', timeout: timeout);
      return (data: _json(h), ms: h.ms);
    }
    final m = _json(r);
    _verify(m['id']);
    return (data: m, ms: r.ms);
  }

  void _verify(Object? id) {
    if (expectId != null && id != null && '$id'.toUpperCase() != expectId!.toUpperCase()) {
      throw HubException(HubError.wrongDevice, 'expected $expectId got $id');
    }
  }

  @override
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body, {Duration? timeout}) async {
    final b = {...body};
    b.putIfAbsent('rid', newRequestId);
    final r = await Bridge.current.http('POST', _u('/api/cmd'), headers: _headers, body: jsonEncode(b), timeout: timeout ?? const Duration(seconds: 10));
    _checkStatus(r);
    if (r.status == 413) throw HubException(HubError.deviceError, 'payload too large', 'payload_too_large');
    final m = _json(r);
    _verify(m['deviceId'] is String ? (m['deviceId'] as String).replaceFirst('hub-', '') : null);
    return m;
  }

  /// False when the token is wrong or missing on a locked board.
  @override
  Future<bool> checkAuth() async {
    final r = await Bridge.current.http('POST', _u('/api/cmd'), headers: _headers, body: jsonEncode({'cmd': 'noop'}), timeout: _t);
    return r.status != 401 && r.status != 429;
  }

  Future<Map<String, dynamic>> capabilities() async => _json(await _get('/api/capabilities', auth: true));
  Future<Map<String, dynamic>> diag() async {
    final r = await _get('/api/diag', auth: true, timeout: const Duration(seconds: 5));
    _checkStatus(r);
    return _json(r);
  }

  Future<Map<String, dynamic>> otaStatus() async => _json(await _get('/api/ota/status', auth: true));

  // ---------------------------------------------------------------- Wi-Fi setup
  /// Asks the board to join a network. Firmware 0.4.1+ answers {"state":"connecting"} and keeps its hotspot up, so
  /// [wifiStatus] can be polled. Older firmware replies with a web page and reboots at once ({"state":"legacy"}).
  @override
  Future<Map<String, dynamic>> wifiSet(String ssid, String pass) async {
    final r = await Bridge.current.http('POST', _u('/api/wifi'), headers: _headers, body: jsonEncode({'ssid': ssid, 'pass': pass}), timeout: _t);
    _checkStatus(r);
    return r.json ?? {'ok': true, 'state': 'legacy'};
  }

  /// {"state": idle | connecting | ok | fail, "phase", "ssid", "ip", "reason"}
  @override
  Future<Map<String, dynamic>> wifiStatus() async => _json(await _get('/api/wifi/status', timeout: const Duration(seconds: 3)));

  /// Networks the board sees, strongest first. Rich entries on firmware 0.6+ ({ssid, rssi, auth, secure, supported}),
  /// names only on older firmware. Empty while it is still scanning.
  @override
  Future<List<WifiNetwork>> networks() async {
    final r = await _get('/api/networks', timeout: const Duration(seconds: 5));
    List l;
    if (r.status == 404) {
      final old = await _get('/api/scan', timeout: const Duration(seconds: 5));
      l = jsonDecode(old.body) as List;
    } else {
      l = jsonDecode(r.body) as List;
    }
    final out = <WifiNetwork>[];
    for (final e in l) {
      final n = e is Map ? WifiNetwork.fromJson(e) : WifiNetwork(ssid: '$e');
      if (!n.ssid.startsWith('ESP32-Hub')) out.add(n); // never offer the board's own hotspot
    }
    return out;
  }

  // ---------------------------------------------------------------- OTA
  /// Uploads a firmware image. The board checks the header, the size, the model and the MD5 before it switches to it.
  /// Uses dart:io directly (a 1.5 MB body does not fit through the method channel), so it needs the board on the default network.
  Future<void> uploadFirmware(Uint8List bin, {String? md5, void Function(double)? onProgress, bool Function()? cancelled}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final boundary = '----hub${newRequestId()}';
      final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="update"; filename="firmware.bin"\r\nContent-Type: application/octet-stream\r\n\r\n');
      final tail = utf8.encode('\r\n--$boundary--\r\n');
      final req = await client.postUrl(Uri.parse(_u('/update')));
      req.headers
        ..set('Content-Type', 'multipart/form-data; boundary=$boundary')
        ..set('X-Hub-Model', 'esp32-hub')
        ..set('X-Hub-Size', '${bin.length}');
      if (token.isNotEmpty) req.headers.set('X-Hub-Token', token);
      if (md5 != null && md5.length == 32) req.headers.set('X-Hub-Md5', md5);
      req.contentLength = head.length + bin.length + tail.length;
      req.add(head);
      const chunk = 4096;
      for (var i = 0; i < bin.length; i += chunk) {
        if (cancelled?.call() == true) {
          req.abort(); // the board drops a half-written image and keeps running the current one
          throw HubException(HubError.cancelled);
        }
        req.add(Uint8List.sublistView(bin, i, math.min(i + chunk, bin.length)));
        if ((i ~/ chunk) % 16 == 0) await req.flush();
        onProgress?.call(math.min(i + chunk, bin.length) / bin.length);
      }
      req.add(tail);
      final res = await req.close().timeout(const Duration(seconds: 60));
      final body = await res.transform(utf8.decoder).join();
      Map<String, dynamic>? m;
      try {
        m = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {}
      if (res.statusCode == 401) throw LockedException();
      if (res.statusCode != 200) throw HubException(HubError.deviceError, 'update refused', '${m?['error'] ?? 'ota_failed'}');
    } on SocketException catch (e) {
      throw HubException(HubError.unreachable, e.message);
    } on TimeoutException {
      throw HubException(HubError.timeout, 'the board did not confirm the update');
    } finally {
      client.close(force: true);
    }
  }
}

/// A Wi-Fi network seen by the board.
class WifiNetwork {
  WifiNetwork({required this.ssid, this.rssi, this.auth = 'wpa2', this.secure = true, this.supported = true});
  final String ssid;
  final int? rssi;
  final String auth;
  final bool secure, supported;

  /// 0 (none) to 4 bars, same thresholds as the board's own screen.
  int get bars {
    final r = rssi;
    if (r == null) return 0;
    return r > -55 ? 4 : r > -65 ? 3 : r > -75 ? 2 : r > -90 ? 1 : 0;
  }

  static WifiNetwork fromJson(Map e) => WifiNetwork(
        ssid: '${e['ssid'] ?? ''}',
        rssi: e['rssi'] is num ? (e['rssi'] as num).toInt() : null,
        auth: '${e['auth'] ?? 'wpa2'}',
        secure: e['secure'] != false,
        supported: e['supported'] != false,
      );
}

// ======================================================================= MQTT (from anywhere)
class MqttConfig {
  MqttConfig({required this.host, this.port = 1883, this.user = '', this.pass = '', this.tls = false, required this.deviceId, required this.token});
  final String host, user, pass, deviceId, token;
  final int port;
  final bool tls;
}

/// Talks to the board through an MQTT broker. The board must have MQTT switched on (Settings > Integrations > MQTT)
/// with the same broker. Commands carry the device token. The broker password is kept in the secure store.
class MqttApi extends Api {
  MqttApi(this.cfg);
  final MqttConfig cfg;
  MqttServerClient? _c;
  Map<String, dynamic>? _list, _state;
  Completer<Map<String, dynamic>>? _waiting;
  Future<void> _queue = Future.value();

  @override
  String get label => 'MQTT ${cfg.deviceId}';
  @override
  bool get isLocal => false;

  String _topic(String leaf) => 'esp32hub/${cfg.deviceId}/$leaf';

  Future<void> connect() async {
    final id = 'app-${DateTime.now().millisecondsSinceEpoch}';
    final c = MqttServerClient.withPort(cfg.host, id, cfg.port);
    c.secure = cfg.tls;
    c.keepAlivePeriod = 30;
    c.logging(on: false);
    c.setProtocolV311();
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(id).startClean();
    try {
      await c.connect(cfg.user.isEmpty ? null : cfg.user, cfg.user.isEmpty ? null : cfg.pass);
    } catch (e) {
      c.disconnect();
      throw HubException(HubError.unreachable, 'Cannot reach the MQTT broker: $e');
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      c.disconnect();
      throw HubException(HubError.refused, 'MQTT broker refused the connection');
    }
    _c = c;
    c.updates!.listen((events) {
      for (final e in events) {
        final msg = e.payload as MqttPublishMessage;
        final text = MqttPublishPayload.bytesToStringAsString(msg.payload.message);
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (e.topic == _topic('list')) {
          _list = json;
        } else if (e.topic == _topic('state')) {
          _state = json;
        } else if (e.topic == _topic('res')) {
          if (_waiting != null && !_waiting!.isCompleted) _waiting!.complete(json);
        }
      }
    });
    c.subscribe(_topic('list'), MqttQos.atMostOnce);
    c.subscribe(_topic('state'), MqttQos.atMostOnce);
    c.subscribe(_topic('res'), MqttQos.atMostOnce);
  }

  @override
  Future<Map<String, dynamic>> list() async {
    for (var i = 0; i < 40 && _list == null; i++) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    final l = _list;
    if (l == null) throw HubException(HubError.timeout, 'No data from the device over MQTT');
    return {...l, if (_state?['scene'] != null) 'scene': _state!['scene']};
  }

  @override
  Future<Map<String, dynamic>> status() async => _state ?? <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body, {Duration? timeout}) {
    // one command at a time: replies on the "res" topic carry no id, so they are matched in order
    final run = _queue.then((_) async {
      final c = _c;
      if (c == null || c.connectionStatus?.state != MqttConnectionState.connected) {
        throw HubException(HubError.unreachable, 'Not connected to the broker');
      }
      _waiting = Completer<Map<String, dynamic>>();
      final b = MqttClientPayloadBuilder()..addString(jsonEncode({...body, 't': cfg.token}));
      c.publishMessage(_topic('cmd'), MqttQos.atMostOnce, b.payload!);
      try {
        return await _waiting!.future.timeout(timeout ?? const Duration(seconds: 8));
      } on TimeoutException {
        return <String, dynamic>{'ok': false, 'error': 'no reply (device offline or wrong token)'};
      }
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<void> close() async {
    _c?.disconnect();
    _c = null;
  }
}

/// An MQTT connection presented as a [HubLink], so the connection manager treats "from anywhere" like any other link.
/// The host is the literal "mqtt". Commands are published with the device token and answered on the board's "res" topic.
class RemoteLink extends HubLink {
  RemoteLink(this.mqtt, this.id);
  final MqttApi mqtt;
  final String id;
  @override
  String get host => 'mqtt';
  @override
  String get token => mqtt.cfg.token;
  @override
  String get label => mqtt.label;
  @override
  bool get isLocal => false;

  @override
  Future<FoundBoard?> hello({Duration timeout = const Duration(seconds: 6)}) async {
    final l = await mqtt.list().timeout(timeout);
    final lid = '${l['id'] ?? ''}'.toUpperCase();
    if (lid.isEmpty) return null;
    return FoundBoard(host: 'mqtt', id: lid, fw: '${l['fw'] ?? ''}', name: '${l['name'] ?? 'ESP32 Hub'}', apiVersion: (l['apiVersion'] as num?)?.toInt() ?? 0, lock: true, online: true, source: 'mqtt');
  }

  @override
  Future<({Map<String, dynamic> data, int ms})> ping({Duration timeout = const Duration(seconds: 4)}) async {
    final sw = Stopwatch()..start();
    final r = await mqtt.cmd({'cmd': 'noop'}, timeout: timeout);
    if (r['ok'] != true) throw HubException(HubError.timeout, 'no reply over MQTT');
    return (data: await mqtt.status(), ms: sw.elapsedMilliseconds);
  }

  @override
  Future<bool> checkAuth() async => (await mqtt.cmd({'cmd': 'noop'}))['ok'] == true;
  @override
  Future<Map<String, dynamic>> list() => mqtt.list();
  @override
  Future<Map<String, dynamic>> status() => mqtt.status();
  @override
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body, {Duration? timeout}) => mqtt.cmd(body, timeout: timeout);
  @override
  Future<void> close() => mqtt.close();
}

/// Sends a full 160x128 RGB565 (little-endian) frame to the Canvas scene, in 16-row strips.
Future<void> sendFrameVia(Future<Map<String, dynamic>> Function(Map<String, dynamic>) cmd, Uint8List rgb565, {void Function(double)? onProgress}) async {
  const w = 160, h = 128, rows = 16;
  for (var y = 0; y < h; y += rows) {
    final part = rgb565.sublist(y * w * 2, (y + rows) * w * 2);
    final r = await cmd({'cmd': 'pixels', 'x': 0, 'y': y, 'w': w, 'h': rows, 'data': base64Encode(part)});
    if (r['ok'] != true) throw HubException(HubError.deviceError, '${r['error'] ?? 'device error'}', '${r['errorCode'] ?? ''}');
    onProgress?.call((y + rows) / h);
  }
}

/// Sends up to 7 animation frames (80x64, RGB332 = 1 byte per pixel) and starts playing them.
Future<void> sendAnimationVia(Future<Map<String, dynamic>> Function(Map<String, dynamic>) cmd, List<Uint8List> frames, int delayMs, {void Function(double)? onProgress}) async {
  const w = 80, h = 64, rows = 32;
  var r = await cmd({'cmd': 'anim', 'action': 'clear'});
  if (r['ok'] != true) throw HubException(HubError.deviceError, '${r['error'] ?? 'device error'}');
  final total = frames.length * (h ~/ rows);
  var done = 0;
  for (var i = 0; i < frames.length; i++) {
    for (var y = 0; y < h; y += rows) {
      final part = frames[i].sublist(y * w, (y + rows) * w);
      r = await cmd({'cmd': 'anim', 'action': 'frame', 'i': i, 'y': y, 'h': rows, 'data': base64Encode(part)});
      if (r['ok'] != true) throw HubException(HubError.deviceError, '${r['error'] ?? 'device error'}');
      onProgress?.call(++done / total);
    }
  }
  r = await cmd({'cmd': 'anim', 'action': 'play', 'delay': delayMs});
  if (r['ok'] != true) throw HubException(HubError.deviceError, '${r['error'] ?? 'device error'}');
}
