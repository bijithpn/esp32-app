import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/diagnostics.dart';
import 'package:esp32_hub_app/core/discovery.dart';
import 'package:esp32_hub_app/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late FakeBridge b;
  late DiscoveryService d;
  setUp(() {
    b = FakeBridge();
    Bridge.current = b;
    d = DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero);
  });

  Future<List<FoundBoard>> run({String? wantId, List<KnownHint> hints = const [], bool sweep = true}) => d.scan(wantId: wantId, hints: hints, sweep: sweep, budget: const Duration(seconds: 3)).toList();

  test('the last known address answers first and is verified', () async {
    b.hellos['192.168.1.5'] = helloJson();
    final r = await run(hints: const [KnownHint('C224AC', '192.168.1.5', 'esp32-hub-c224ac.local')], wantId: 'C224AC');
    expect(r.single.source, 'known-ip');
    expect(r.single.id, 'C224AC');
  });

  test('UDP replies are only hints: the address is verified over HTTP', () async {
    b.udp = const [RawReply('192.168.1.7', '{"type":"esp32_hub","id":"AAAAAA","ip":"6.6.6.6"}')];
    b.hellos['192.168.1.7'] = helloJson(id: 'AAAAAA');
    final r = await run(sweep: false);
    expect(r.single.host, '192.168.1.7', reason: 'the advertised ip is not trusted');
  });

  test('another web server is never reported as a Hub', () async {
    b.udp = const [RawReply('192.168.1.20', '{}')];
    b.hellos['192.168.1.20'] = '<html>router admin</html>';
    expect(await run(sweep: false), isEmpty);
  });

  test('the same board from mDNS, UDP and the sweep is one result', () async {
    b.hellos['192.168.1.5'] = helloJson();
    b.mdnsHits = const [MdnsHit(host: '192.168.1.5')];
    b.udp = const [RawReply('192.168.1.5', '{}')];
    b.sweepHits = [RawReply('192.168.1.5', helloJson())];
    final r = await run();
    expect(r.length, lessThanOrEqualTo(3));
    expect(r.map((e) => e.id).toSet(), {'C224AC'});
    expect(r.map((e) => '${e.id}@${e.host}').toSet().length, r.length);
  });

  test('several boards are all found', () async {
    b.udp = const [RawReply('192.168.1.5', '{}'), RawReply('192.168.1.6', '{}')];
    b.hellos['192.168.1.5'] = helloJson(id: 'AAAAAA');
    b.hellos['192.168.1.6'] = helloJson(id: 'BBBBBB');
    final r = await run(sweep: false);
    expect(r.map((e) => e.id).toSet(), {'AAAAAA', 'BBBBBB'});
  });

  test('the sweep finds a board when everything else is silent', () async {
    b.sweepHits = [RawReply('192.168.1.77', helloJson())];
    final r = await run();
    expect(r.single.source, 'sweep');
    expect(b.sweeps, greaterThan(0));
  });

  test('the hotspot address is only probed when the phone is on that network', () async {
    b.hellos['192.168.4.1'] = helloJson(ap: true);
    expect(await run(sweep: false), isEmpty);
    b.net = const NetInfo(wifi: true, prefixes: ['192.168.4']);
    final r = await run(sweep: false);
    expect(r.single.ap, isTrue);
  });

  test('no network means no sweep', () async {
    b.net = const NetInfo();
    await run();
    expect(b.sweeps, 0);
    expect(d.lastPrefixes, isEmpty);
  });
}
