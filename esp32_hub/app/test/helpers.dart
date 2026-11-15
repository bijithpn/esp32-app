import 'dart:async';
import 'dart:convert';

import 'package:esp32_hub_app/api.dart';
import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/errors.dart';
import 'package:esp32_hub_app/core/models.dart';

String helloJson({String id = 'C224AC', String fw = '0.6.0', bool ap = false, bool lock = false, int api = 1, String name = 'Desk Hub', bool pairing = false}) => jsonEncode({
      'type': 'esp32_hub', 'device': 'ESP32-Hub', 'id': id, 'deviceId': 'hub-$id', 'name': name, 'fw': fw, 'apiVersion': api, 'ap': ap, 'online': !ap, 'lock': lock, 'pairing': pairing, 'caps': ['scenes', 'weather'],
    });

typedef HttpHandler = Future<HttpResult> Function(String method, Uri url, String? body);

/// A Bridge with no Android behind it: everything the tests need is scripted.
class FakeBridge extends Bridge {
  NetInfo net = const NetInfo(wifi: true, validated: true, prefixes: ['192.168.1']);
  final events = StreamController<NetEvent>.broadcast();
  final Map<String, String> hellos = {}; // host -> /api/hello body
  List<RawReply> udp = [];
  List<MdnsHit> mdnsHits = [];
  List<RawReply> sweepHits = [];
  JoinCode joinResult = JoinCode.ok;
  HttpHandler? handler;
  final List<String> requests = [];
  final List<Map<String, dynamic>> configs = [];
  int sweeps = 0;
  bool left = false;

  @override
  Future<NetInfo> netSnapshot() async => net;
  @override
  Stream<NetEvent> netEvents() => events.stream;
  @override
  Future<List<RawReply>> udpDiscover({int timeoutMs = 1200}) async => udp;
  @override
  Future<List<MdnsHit>> mdns({int timeoutMs = 2500}) async => mdnsHits;
  @override
  Future<List<RawReply>> sweep(List<String> hosts, {String path = '/api/hello', int timeoutMs = 700}) async {
    sweeps++;
    return sweepHits.where((r) => hosts.contains(r.host)).toList();
  }

  @override
  Future<JoinCode> joinWifi(String ssid, String pass) async => joinResult;
  @override
  Future<void> leaveHotspot() async => left = true;
  @override
  Future<void> setConfig(Map<String, dynamic> c) async => configs.add(c);

  @override
  Future<HttpResult> http(String method, String url, {Map<String, String> headers = const {}, String? body, Duration timeout = const Duration(seconds: 6)}) async {
    final u = Uri.parse(url);
    requests.add('$method ${u.host}${u.path}');
    if (handler != null) return handler!(method, u, body);
    if (u.path == '/api/hello' && hellos.containsKey(u.host)) return HttpResult(200, hellos[u.host]!, 12);
    throw HubNetError('unreachable', 'no route to ${u.host}');
  }
}

/// A scripted local link for the connection manager.
class FakeLink extends ProvisionLink {
  FakeLink(this.host, {this.token = '', this.id = 'C224AC'});
  @override
  final String host;
  @override
  final String token;
  final String id;
  bool up = true, authOk = true, lockedBoard = false, ap = false;
  String fw = '0.6.0';
  int apiVersion = 1;
  int pingMs = 20, rev = 1;
  Object? cmdError;
  final List<Map<String, dynamic>> sent = [];
  Map<String, dynamic> listData = {
    'id': 'C224AC', 'fw': '0.6.0', 'scene': 'eyes', 'lock': false, 'scenes': [{'id': 'eyes', 'name': 'Robot Eyes', 'args': []}],
  };
  List<WifiNetwork> nets = [WifiNetwork(ssid: 'Home', rssi: -50)];
  Map<String, dynamic> wifiSetResult = {'ok': true, 'state': 'connecting'};
  final List<Map<String, dynamic>> wifiStatuses = [];
  bool closed = false;

  @override
  String get label => host;
  @override
  bool get isLocal => true;

  void _need() {
    if (!up) throw HubException(HubError.timeout, 'link down');
  }

  @override
  Future<FoundBoard?> hello({Duration timeout = const Duration(seconds: 1)}) async {
    _need();
    return FoundBoard.parse(host, helloJson(id: id, fw: fw, ap: ap, lock: lockedBoard, api: apiVersion), source: 'test', latencyMs: pingMs);
  }

  @override
  Future<({Map<String, dynamic> data, int ms})> ping({Duration timeout = const Duration(seconds: 1)}) async {
    _need();
    return (data: {'id': id, 'rev': rev, 'rssi': -55, 'uptime': 100}, ms: pingMs);
  }

  @override
  Future<bool> checkAuth() async {
    _need();
    return authOk;
  }

  @override
  Future<Map<String, dynamic>> list() async {
    _need();
    return {...listData, 'rev': rev};
  }

  @override
  Future<Map<String, dynamic>> status() async {
    _need();
    return {'ssid': 'Home', 'rssi': -55};
  }

  @override
  Future<Map<String, dynamic>> cmd(Map<String, dynamic> body, {Duration? timeout}) async {
    _need();
    sent.add(body);
    if (cmdError != null) throw cmdError!;
    if (body['cmd'] == 'lock') return {'ok': true, 'token': 'abcdef0123456789'};
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> wifiSet(String ssid, String pass) async {
    sent.add({'wifi': ssid});
    return wifiSetResult;
  }

  @override
  Future<Map<String, dynamic>> wifiStatus() async => wifiStatuses.isEmpty ? {'state': 'connecting', 'phase': 'associating'} : wifiStatuses.removeAt(0);

  @override
  Future<List<WifiNetwork>> networks() async => nets;

  @override
  Future<void> close() async => closed = true;
}

/// Polls until [cond] holds (the real timers in the manager need a moment).
Future<void> until(bool Function() cond, {Duration limit = const Duration(seconds: 3), String what = 'condition'}) async {
  final end = DateTime.now().add(limit);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for $what');
    await Future.delayed(const Duration(milliseconds: 5));
  }
}
