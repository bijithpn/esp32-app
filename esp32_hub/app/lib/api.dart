import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// Thrown when the board is locked and the token is missing or wrong.
class LockedException implements Exception {
  @override
  String toString() => 'Device is locked: token required';
}

/// A connection to one ESP32 Hub. Screens only use this class, so they work the same
/// over the local network (HttpApi) and over the internet (MqttApi).
abstract class Api {
  /// Short text for the UI (IP address, or "MQTT" followed by the device id).
  String get label;

  /// True when the board can be reached directly by HTTP (needed for phone sync in the background).
  bool get isLocal;

  Future<Map<String, dynamic>> list();
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body);
  Future<void> wifi(String ssid, String pass);
  Future<void> close() async {}

  /// Send a full 160x128 RGB565 (little-endian) frame to the Canvas scene, in 16-row strips.
  Future<void> sendFrame(Uint8List rgb565, {void Function(double)? onProgress}) async {
    const w = 160, h = 128, rows = 16;
    for (var y = 0; y < h; y += rows) {
      final part = rgb565.sublist(y * w * 2, (y + rows) * w * 2);
      final r = await cmd({'cmd': 'pixels', 'x': 0, 'y': y, 'w': w, 'h': rows, 'data': base64Encode(part)});
      if (r['ok'] != true) throw Exception(r['error'] ?? 'device error');
      onProgress?.call((y + rows) / h);
    }
  }

  /// Send up to 7 animation frames (80x64, RGB332 = 1 byte per pixel) and start playing them.
  Future<void> sendAnimation(List<Uint8List> frames, int delayMs, {void Function(double)? onProgress}) async {
    const w = 80, h = 64, rows = 32;
    var r = await cmd({'cmd': 'anim', 'action': 'clear'});
    if (r['ok'] != true) throw Exception(r['error'] ?? 'device error');
    final total = frames.length * (h ~/ rows);
    var done = 0;
    for (var i = 0; i < frames.length; i++) {
      for (var y = 0; y < h; y += rows) {
        final part = frames[i].sublist(y * w, (y + rows) * w);
        r = await cmd({'cmd': 'anim', 'action': 'frame', 'i': i, 'y': y, 'h': rows, 'data': base64Encode(part)});
        if (r['ok'] != true) throw Exception(r['error'] ?? 'device error');
        onProgress?.call(++done / total);
      }
    }
    r = await cmd({'cmd': 'anim', 'action': 'play', 'delay': delayMs});
    if (r['ok'] != true) throw Exception(r['error'] ?? 'device error');
  }
}

// ======================================================================= HTTP (local network)
class HttpApi extends Api {
  HttpApi(String host, {this.token = ''})
      : host = host.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
  final String host;
  final String token;
  static const _t = Duration(seconds: 6);

  @override
  String get label => host;
  @override
  bool get isLocal => true;

  Uri _u(String p) => Uri.parse('http://$host$p');
  Map<String, String> get _headers =>
      {'Content-Type': 'application/json', if (token.isNotEmpty) 'X-Hub-Token': token};

  @override
  Future<Map<String, dynamic>> list() async {
    final r = await http.get(_u('/api/list')).timeout(_t);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> status() async {
    final r = await http.get(_u('/api/status')).timeout(_t);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body) async {
    final r = await http.post(_u('/api/cmd'), headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 15));
    if (r.statusCode == 401) throw LockedException();
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// False when the token is wrong or missing on a locked board.
  Future<bool> checkAuth() async {
    final r = await http.post(_u('/api/cmd'), headers: _headers, body: jsonEncode({'cmd': 'noop'})).timeout(_t);
    return r.statusCode != 401;
  }

  @override
  Future<void> wifi(String ssid, String pass) async {
    final r = await http.post(_u('/api/wifi'), headers: _headers, body: jsonEncode({'ssid': ssid, 'pass': pass})).timeout(_t);
    if (r.statusCode == 401) throw LockedException();
  }
}

// ======================================================================= MQTT (from anywhere)
class MqttConfig {
  MqttConfig({required this.host, this.port = 1883, this.user = '', this.pass = '', this.tls = false, required this.deviceId, required this.token});
  final String host, user, pass, deviceId, token;
  final int port;
  final bool tls;
}

/// Talks to the board through an MQTT broker. The board must have MQTT switched on
/// (Settings > Remote access) with the same broker. Commands carry the device token.
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
      throw Exception('Cannot reach the MQTT broker: $e');
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      c.disconnect();
      throw Exception('MQTT broker refused the connection');
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
    if (l == null) throw Exception('No data from the device. Is MQTT enabled on it, with the same broker and device id?');
    return {...l, if (_state?['scene'] != null) 'scene': _state!['scene']};
  }

  @override
  Future<Map<String, dynamic>> status() async => _state ?? <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body) {
    // one command at a time: replies on the "res" topic carry no id, so they are matched in order
    final run = _queue.then((_) async {
      final c = _c;
      if (c == null || c.connectionStatus?.state != MqttConnectionState.connected) {
        throw Exception('Not connected to the broker');
      }
      _waiting = Completer<Map<String, dynamic>>();
      final b = MqttClientPayloadBuilder()..addString(jsonEncode({...body, 't': cfg.token}));
      c.publishMessage(_topic('cmd'), MqttQos.atMostOnce, b.payload!);
      try {
        return await _waiting!.future.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        return <String, dynamic>{'ok': false, 'error': 'no reply (device offline or wrong token)'};
      }
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<void> wifi(String ssid, String pass) async => throw UnsupportedError('Wi-Fi setup needs a direct connection or Bluetooth');

  @override
  Future<void> close() async {
    _c?.disconnect();
    _c = null;
  }
}
