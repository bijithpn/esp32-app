import 'dart:async';

import 'package:esp32_hub_app/core/command_queue.dart';
import 'package:esp32_hub_app/core/errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs by priority, then in order', () async {
    final order = <String>[];
    final gate = Completer<void>();
    final q = CommandQueue((b, t) async {
      if (b['cmd'] == 'first') await gate.future;
      order.add('${b['cmd']}');
      return {'ok': true};
    });
    final a = q.submit({'cmd': 'first'});
    await Future.delayed(const Duration(milliseconds: 5));
    final low = q.submit({'cmd': 'low'}, priority: CmdPriority.low);
    final norm = q.submit({'cmd': 'norm'});
    final high = q.submit({'cmd': 'high'}, priority: CmdPriority.high);
    gate.complete();
    await Future.wait([a, low, norm, high]);
    expect(order, ['first', 'high', 'norm', 'low']);
  });

  test('a newer command with the same key replaces a waiting one', () async {
    final seen = <int>[];
    final gate = Completer<void>();
    final q = CommandQueue((b, t) async {
      if (b['n'] == 0) await gate.future;
      seen.add(b['n'] as int);
      return {'ok': true, 'n': b['n']};
    });
    final first = q.submit({'n': 0});
    await Future.delayed(const Duration(milliseconds: 5));
    final r1 = q.submit({'n': 1}, dedupeKey: 'slider');
    final r2 = q.submit({'n': 2}, dedupeKey: 'slider');
    gate.complete();
    await first;
    final a = await r1, b = await r2;
    expect(seen, [0, 2], reason: 'the replaced command never reached the board');
    expect(a['n'], 2, reason: 'the replaced caller gets the newer result');
    expect(b['n'], 2);
  });

  test('a lost reply is not retried for a non-idempotent command', () async {
    var calls = 0;
    final q = CommandQueue((b, t) async {
      calls++;
      throw HubException(HubError.timeout);
    });
    await expectLater(q.submit({'cmd': 'feed'}), throwsA(isA<HubException>()));
    expect(calls, 1, reason: 'feeding twice would be a different command');
  });

  test('a lost reply is retried for an idempotent command', () async {
    var calls = 0;
    final q = CommandQueue((b, t) async {
      calls++;
      if (calls == 1) throw HubException(HubError.timeout);
      return {'ok': true};
    });
    final r = await q.submit({'cmd': 'loc'}, idempotent: true);
    expect(r['ok'], true);
    expect(calls, 2);
  });

  test('a command that never reached the board is retried', () async {
    var calls = 0;
    final q = CommandQueue((b, t) async {
      calls++;
      if (calls == 1) throw HubException(HubError.refused);
      return {'ok': true};
    });
    await q.submit({'cmd': 'pomo'});
    expect(calls, 2);
  });

  test('boards that remember request ids make every retry safe', () async {
    var calls = 0;
    final q = CommandQueue((b, t) async {
      calls++;
      if (calls == 1) throw HubException(HubError.timeout);
      return {'ok': true};
    }, boardDedupes: () => true);
    await q.submit({'cmd': 'pet', 'action': 'feed'});
    expect(calls, 2);
  });

  test('auth errors are never retried', () async {
    var calls = 0;
    final q = CommandQueue((b, t) async {
      calls++;
      throw HubException(HubError.auth);
    });
    await expectLater(q.submit({'cmd': 'x'}, idempotent: true), throwsA(isA<HubException>().having((e) => e.kind, 'kind', HubError.auth)));
    expect(calls, 1);
  });

  test('the board refusing is reported as its own error, not as a lost link', () async {
    final results = <bool>[];
    final q = CommandQueue((b, t) async => {'ok': false, 'error': 'unknown scene', 'errorCode': 'unknown_scene'}, onResult: (ok, e) => results.add(ok));
    await expectLater(q.submit({'cmd': 'scene'}), throwsA(isA<HubException>().having((e) => e.code, 'code', 'unknown_scene')));
    expect(results, [true], reason: 'the board answered, so the link is healthy');
  });

  test('commands that waited too long are dropped as stale', () async {
    final gate = Completer<void>();
    final q = CommandQueue((b, t) async {
      if (b['n'] == 0) await gate.future;
      return {'ok': true};
    });
    final first = q.submit({'n': 0});
    await Future.delayed(const Duration(milliseconds: 5));
    final late = q.submit({'n': 1}, maxWaitOverride: const Duration(milliseconds: 20));
    final lateCheck = expectLater(late, throwsA(isA<HubException>().having((e) => e.kind, 'kind', HubError.stale)));
    await Future.delayed(const Duration(milliseconds: 60));
    gate.complete();
    await first;
    await lateCheck;
  });

  test('a new epoch discards everything that waited for the old connection', () async {
    final gate = Completer<void>();
    final q = CommandQueue((b, t) async {
      if (b['n'] == 0) await gate.future;
      return {'ok': true};
    });
    final first = q.submit({'n': 0});
    await Future.delayed(const Duration(milliseconds: 5));
    final waiting = q.submit({'n': 1});
    final check = expectLater(waiting, throwsA(isA<HubException>()));
    q.bumpEpoch();
    gate.complete();
    await first;
    await check;
    expect(q.length, 0);
  });
}
