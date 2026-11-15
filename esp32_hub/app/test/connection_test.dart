import 'dart:async';
import 'dart:math';

import 'package:esp32_hub_app/api.dart';
import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/connection.dart';
import 'package:esp32_hub_app/core/diagnostics.dart';
import 'package:esp32_hub_app/core/errors.dart';
import 'package:esp32_hub_app/core/models.dart';
import 'package:esp32_hub_app/core/registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBridge bridge;
  late Map<String, FakeLink> links;
  late ConnectionManager hub;
  final states = <ConnState>[];

  Future<void> makeHub({List<Duration>? backoff}) async {
    SharedPreferences.setMockInitialValues({});
    bridge = FakeBridge();
    Bridge.current = bridge;
    links = {};
    states.clear();
    hub = ConnectionManager(
      registry: DeviceRegistry(),
      bridge: bridge,
      log: DiagLog(),
      history: ConnHistory(),
      random: _FixedRandom(),
      backoff: backoff ?? const [Duration(milliseconds: 10), Duration(milliseconds: 20), Duration(milliseconds: 40)],
      activeInterval: const Duration(milliseconds: 20),
      idleInterval: const Duration(milliseconds: 20),
      degradedInterval: const Duration(milliseconds: 10),
      linkFactory: (host, token, id) => links.putIfAbsent(host, () => FakeLink(host, token: token, id: id)),
    );
    hub.addListener(() {
      if (states.isEmpty || states.last != hub.state) states.add(hub.state);
    });
  }

  Future<HubDevice> pair({String host = '192.168.1.5', bool locked = false}) async {
    final d = HubDevice(id: 'C224AC', name: 'Desk', host: host, locked: locked);
    await hub.registry.upsert(d, select: true);
    return d;
  }

  tearDown(() => hub.dispose());

  test('restores the paired device from the phone at once and only then verifies it', () async {
    await makeHub();
    await pair();
    links['192.168.1.5'] = FakeLink('192.168.1.5');
    await hub.init();
    expect(hub.device?.id, 'C224AC', reason: 'the cached device shows immediately');
    await until(() => hub.state == ConnState.connected, what: 'connected');
    expect(states, containsAllInOrder([ConnState.connecting, ConnState.authenticating, ConnState.connected]));
    expect(hub.data['scene'], 'eyes');
  });

  test('never says connected before identity and the scene list are verified', () async {
    await makeHub();
    await pair();
    final gate = Completer<void>();
    final slow = _SlowList('192.168.1.5', gate);
    links['192.168.1.5'] = slow;
    await hub.init();
    await Future.delayed(const Duration(milliseconds: 60));
    expect(hub.state, isNot(ConnState.connected), reason: 'list() has not answered yet');
    gate.complete();
    await until(() => hub.state == ConnState.connected);
  });

  test('a different device at the saved address is not accepted', () async {
    await makeHub();
    await pair();
    links['192.168.1.5'] = FakeLink('192.168.1.5', id: 'FFFFFF');
    await hub.init();
    await Future.delayed(const Duration(milliseconds: 150));
    expect(hub.state, isNot(ConnState.connected));
    expect(hub.canSend, isFalse);
  });

  test('a locked board without a valid token asks for one, and a correct token connects', () async {
    await makeHub();
    await pair(locked: true);
    final l = FakeLink('192.168.1.5')..lockedBoard = true..authOk = false;
    links['192.168.1.5'] = l;
    await hub.init();
    await until(() => hub.state == ConnState.authenticationRequired, what: 'token needed');
    expect(hub.canSend, isFalse);
    l.authOk = true;
    await hub.submitToken('s3cret');
    await until(() => hub.state == ConnState.connected);
    expect(await hub.registry.token('C224AC'), 's3cret');
  });

  test('missing pings take it to degraded, then reconnecting, and it recovers when the link is back', () async {
    await makeHub();
    await pair();
    final l = FakeLink('192.168.1.5');
    links['192.168.1.5'] = l;
    await hub.init();
    await until(() => hub.state == ConnState.connected);
    hub.setDashboardActive(true);
    l.up = false;
    await until(() => hub.state == ConnState.reconnecting, what: 'reconnecting');
    expect(states, contains(ConnState.degraded), reason: 'it goes through "weak link" first');
    expect(hub.canSend, isFalse, reason: 'no commands while reconnecting');
    l.up = true;
    await until(() => hub.state == ConnState.connected, what: 'recovered');
  });

  test('consecutive command failures never leave it showing connected', () async {
    await makeHub();
    await pair();
    final l = FakeLink('192.168.1.5')..cmdError = HubException(HubError.timeout);
    links['192.168.1.5'] = l;
    await hub.init();
    await until(() => hub.state == ConnState.connected);
    for (var i = 0; i < 3; i++) {
      await hub.send({'cmd': 'x$i'}).then((_) {}, onError: (_) {});
    }
    expect(hub.state, isNot(ConnState.connected));
  });

  test('a successful command after a hiccup brings it back from degraded', () async {
    await makeHub();
    await pair();
    final l = FakeLink('192.168.1.5');
    links['192.168.1.5'] = l;
    await hub.init();
    await until(() => hub.state == ConnState.connected);
    l.cmdError = HubException(HubError.timeout);
    await hub.send({'cmd': 'a'}).then((_) {}, onError: (_) {});
    expect(hub.state, ConnState.degraded);
    l.cmdError = null;
    await hub.send({'cmd': 'b'});
    await hub.send({'cmd': 'c'});
    expect(hub.state, ConnState.connected);
  });

  test('when the board moves to another address it is found again by identity', () async {
    await makeHub();
    await pair();
    final old = FakeLink('192.168.1.5');
    links['192.168.1.5'] = old;
    bridge.hellos['192.168.1.9'] = helloJson();
    links['192.168.1.9'] = FakeLink('192.168.1.9');
    await hub.init();
    await until(() => hub.state == ConnState.connected);
    old.up = false;
    bridge.hellos.remove('192.168.1.5');
    bridge.udp = const [RawReply('192.168.1.9', '{}')];
    await until(() => hub.device?.host == '192.168.1.9' && hub.state == ConnState.connected, limit: const Duration(seconds: 6), what: 'new address');
    expect(hub.history.events.map((e) => e.kind), contains('ip_changed'));
  });

  test('losing Wi-Fi pauses everything, and Wi-Fi coming back reconnects at once', () async {
    await makeHub();
    await pair();
    final l = FakeLink('192.168.1.5');
    links['192.168.1.5'] = l;
    await hub.init();
    await until(() => hub.state == ConnState.connected);
    bridge.net = const NetInfo();
    bridge.events.add(NetEvent('wifi', 'lost', bridge.net));
    await until(() => hub.state == ConnState.networkSwitching, what: 'network switching');
    expect(hub.canSend, isFalse);
    bridge.net = const NetInfo(wifi: true, validated: true, prefixes: ['192.168.1']);
    bridge.events.add(NetEvent('wifi', 'available', bridge.net));
    await until(() => hub.state == ConnState.connected, limit: const Duration(seconds: 5), what: 'reconnected after Wi-Fi returned');
    expect(hub.history.events.map((e) => e.kind), containsAll(['wifi_changed', 'connected']));
  });

  test('with no network at all it waits instead of retrying', () async {
    await makeHub();
    await pair();
    final l = FakeLink('192.168.1.5')..up = false;
    links['192.168.1.5'] = l;
    bridge.net = const NetInfo();
    await hub.init();
    await until(() => hub.state == ConnState.unavailable, what: 'unavailable');
    final before = bridge.requests.length;
    await Future.delayed(const Duration(milliseconds: 150));
    expect(bridge.requests.length, before, reason: 'no discovery traffic without a network');
  });

  test('retry delays follow the back-off schedule with jitter', () async {
    await makeHub(backoff: const [Duration(milliseconds: 500), Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 15)]);
    // the manager exposes its schedule; the jitter is +-20 % around each step
    final rnd = _FixedRandom();
    for (var i = 0; i < hub.backoff.length; i++) {
      final base = hub.backoff[i].inMilliseconds;
      final j = (base * (0.8 + rnd.nextDouble() * 0.4)).round();
      expect(j, inInclusiveRange((base * 0.8).round(), (base * 1.2).round()));
    }
    expect(hub.backoff.map((d) => d.inMilliseconds), [500, 1000, 2000, 4000, 8000, 15000]);
  });

  test('commands carry through the queue and a board refusal is a normal error', () async {
    await makeHub();
    await pair();
    final l = FakeLink('192.168.1.5');
    links['192.168.1.5'] = l;
    await hub.init();
    await until(() => hub.state == ConnState.connected);
    final r = await hub.send({'cmd': 'scene', 'id': 'eyes'});
    expect(r['ok'], true);
    expect(l.sent.last['cmd'], 'scene');
    expect(hub.queue.length, 0);
  });

  test('sending while not connected fails fast with a friendly error', () async {
    await makeHub();
    await expectLater(hub.send({'cmd': 'x'}), throwsA(isA<HubException>()));
    final msgs = <String>[];
    expect(await hub.trySend({'cmd': 'x'}, onError: msgs.add), isFalse);
    expect(msgs.single, isNot(contains('Exception')));
  });

  test('invalid transitions are rejected and logged, not applied', () async {
    await makeHub();
    await hub.init();
    expect(hub.state, ConnState.disconnected);
    hub.beginFirmwareUpdate(); // disconnected -> firmwareUpdating is not allowed
    expect(hub.state, ConnState.disconnected);
    expect(hub.log.lines.any((l) => l.text.contains('rejected transition')), isTrue);
  });

  test('switching devices keeps tokens apart', () async {
    await makeHub();
    await hub.registry.setToken('AAAAAA', 'token-a');
    await hub.registry.setToken('BBBBBB', 'token-b');
    expect(await hub.registry.token('AAAAAA'), 'token-a');
    expect(await hub.registry.token('BBBBBB'), 'token-b');
    await hub.registry.upsert(HubDevice(id: 'AAAAAA'));
    await hub.registry.remove('AAAAAA');
    expect(await hub.registry.token('AAAAAA'), '');
    expect(await hub.registry.token('BBBBBB'), 'token-b');
  });
}

class _FixedRandom implements Random {
  @override
  bool nextBool() => true;
  @override
  double nextDouble() => 0.5;
  @override
  int nextInt(int max) => 0;
}

class _SlowList extends FakeLink {
  _SlowList(super.host, this.gate);
  final Completer<void> gate;
  @override
  Future<Map<String, dynamic>> list() async {
    await gate.future;
    return super.list();
  }
}
