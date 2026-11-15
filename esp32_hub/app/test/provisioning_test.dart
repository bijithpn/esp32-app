import 'dart:convert';

import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/connection.dart';
import 'package:esp32_hub_app/core/diagnostics.dart';
import 'package:esp32_hub_app/core/errors.dart';
import 'package:esp32_hub_app/core/discovery.dart';
import 'package:esp32_hub_app/core/models.dart';
import 'package:esp32_hub_app/core/provisioning.dart';
import 'package:esp32_hub_app/core/registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge b;
  late ConnectionManager hub;
  late FakeLink hotspot;
  late ProvisioningController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    b = FakeBridge();
    Bridge.current = b;
    b.hellos['192.168.4.1'] = helloJson(ap: true);
    hotspot = FakeLink('192.168.4.1')..ap = true;
    hub = ConnectionManager(registry: DeviceRegistry(), bridge: b, log: DiagLog(), history: ConnHistory(), discovery: DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero));
    c = ProvisioningController(hub: hub, bridge: b, linkFactory: (h, id, t) => hotspot, pollEvery: const Duration(milliseconds: 5), joinTimeout: const Duration(seconds: 2));
  });
  tearDown(() {
    c.dispose();
    hub.dispose();
  });

  group('credential validation', () {
    test('accepts normal networks and open networks', () {
      expect(ProvisioningController.validate('Home', 'password1'), isNull);
      expect(ProvisioningController.validate('Cafe', '', secure: false), isNull);
    });
    test('rejects bad details before anything is sent', () {
      expect(ProvisioningController.validate('', 'password1'), JoinFailure.invalidCredentials);
      expect(ProvisioningController.validate('x' * 33, 'password1'), JoinFailure.invalidCredentials);
      expect(ProvisioningController.validate('Home', 'short'), JoinFailure.invalidCredentials);
      expect(ProvisioningController.validate('Home', 'p' * 64), JoinFailure.invalidCredentials);
      expect(ProvisioningController.validate('Cafe', 'oops', secure: false), JoinFailure.invalidCredentials);
      expect(ProvisioningController.validate('ESP32-Hub', 'password1'), JoinFailure.ownHotspot);
    });
  });

  test('every failure reason has its own plain message, not a generic timeout', () {
    final texts = <String>{};
    for (final r in ['bad_password', 'not_found', 'unsupported_security', 'assoc_failed', 'weak_signal', 'dhcp_timeout', 'router_unavailable', 'invalid_credentials', 'own_hotspot']) {
      final f = joinFailureFrom(r);
      expect(f, isNot(JoinFailure.unknown), reason: r);
      texts.add(joinFailureText(f));
    }
    expect(texts.length, 9);
    expect(joinFailureFrom('whatever'), JoinFailure.unknown);
    for (final t in texts) {
      expect(t, isNot(contains('WiFi.begin')));
    }
  });

  test('hotspot: user rejects the Android dialog -> recoverable failure', () async {
    b.joinResult = JoinCode.unavailable;
    expect(await c.connectToHub('abcd2345'), isFalse);
    expect(c.phase, JoinPhase.failed);
    expect(c.message, contains('Cancel'));
    c.backToPrepare();
    expect(c.step, ProvStep.prepare);
  });

  test('full happy path: hotspot -> networks -> join -> found on the LAN -> saved and selected', () async {
    expect(await c.connectToHub('abcd2345'), isTrue);
    expect(c.step, ProvStep.selectWifi);
    await Future.delayed(const Duration(milliseconds: 30));
    expect(c.networks.single.ssid, 'Home');
    hotspot.wifiStatuses.addAll([
      {'state': 'connecting', 'phase': 'associating'},
      {'state': 'connecting', 'phase': 'waiting_dhcp'},
      {'state': 'ok', 'phase': 'completed', 'ip': '192.168.1.42'},
    ]);
    b.hellos['192.168.1.42'] = helloJson();
    b.udp = const [RawReply('192.168.1.42', '{}')];
    final seen = <JoinPhase>[];
    c.addListener(() {
      if (seen.isEmpty || seen.last != c.phase) seen.add(c.phase);
    });
    final dev = await c.submit('Home', 'password1');
    expect(dev, isNotNull);
    expect(dev!.id, 'C224AC');
    expect(c.step, ProvStep.finish);
    expect(seen, containsAllInOrder([JoinPhase.validatingCredentials, JoinPhase.connecting, JoinPhase.waitingForAssociation, JoinPhase.waitingForDhcp, JoinPhase.verifyingApplicationReachability, JoinPhase.savingCredentials, JoinPhase.completed]));
    expect(hub.registry.selected?.id, 'C224AC');
    expect(await hub.registry.token('C224AC'), 'abcdef0123456789', reason: 'the pairing lock token is stored securely');
    expect(b.left, isTrue, reason: 'the hotspot is released afterwards');
    final p = await SharedPreferences.getInstance();
    expect(p.getString('prov_progress_v1'), isNull, reason: 'progress is cleared when done');
  });

  test('wrong password is reported as such and the user returns to the network list', () async {
    await c.connectToHub('abcd2345');
    hotspot.wifiStatuses.add({'state': 'fail', 'reason': 'bad_password'});
    expect(await c.submit('Home', 'wrongpass1'), isNull);
    expect(c.failure, JoinFailure.badPassword);
    expect(c.step, ProvStep.selectWifi);
  });

  test('the password is never written to saved progress or logs', () async {
    await c.connectToHub('abcd2345');
    hotspot.wifiStatuses.add({'state': 'fail', 'reason': 'not_found'});
    await c.submit('Home', 'SuperSecret99');
    final p = await SharedPreferences.getInstance();
    expect(jsonEncode(p.getKeys().map((k) => '${p.get(k)}').toList()), isNot(contains('SuperSecret99')));
    expect(hub.log.lines.map((l) => l.text).join('\n'), isNot(contains('SuperSecret99')));
    expect(hub.log.lines.map((l) => l.text).join('\n'), isNot(contains('abcd2345')));
  });

  test('an interrupted setup is recovered by identity, without starting over', () async {
    final p = await SharedPreferences.getInstance();
    await p.setString('prov_progress_v1', jsonEncode(ProvProgress(deviceId: 'C224AC', ssid: 'Home', step: 'joinNetwork', at: DateTime.now()).toJson()));
    b.hellos['192.168.1.42'] = helloJson();
    b.udp = const [RawReply('192.168.1.42', '{}')];
    final d = await c.resume();
    expect(d?.id, 'C224AC');
    expect(hub.registry.byId('C224AC')?.host, '192.168.1.42');
  });

  test('stale progress is ignored', () async {
    final p = await SharedPreferences.getInstance();
    await p.setString('prov_progress_v1', jsonEncode(ProvProgress(deviceId: 'C224AC', ssid: 'Home', step: 'x', at: DateTime.now().subtract(const Duration(hours: 2))).toJson()));
    expect(await ProvisioningController.loadProgress(), isNull);
  });
}
