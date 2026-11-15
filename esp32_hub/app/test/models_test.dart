import 'dart:convert';

import 'package:esp32_hub_app/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('connection state table', () {
    test('every state has a label, a meaning and valid targets', () {
      for (final s in ConnState.values) {
        final i = connStates[s];
        expect(i, isNotNull, reason: '$s');
        expect(i!.label, isNotEmpty);
        expect(i.meaning, isNotEmpty);
        expect(i.next, isNotEmpty, reason: '$s has no way out');
      }
    });

    test('connected can only be reached through authentication', () {
      for (final s in ConnState.values) {
        final reaches = connStates[s]!.next.contains(ConnState.connected);
        if (reaches) {
          expect([ConnState.authenticating, ConnState.reconnecting, ConnState.degraded, ConnState.provisioning, ConnState.networkSwitching, ConnState.firmwareUpdating, ConnState.error], contains(s), reason: '$s -> connected');
        }
      }
      expect(canTransition(ConnState.connecting, ConnState.connected), isFalse);
      expect(canTransition(ConnState.disconnected, ConnState.connected), isFalse);
      expect(canTransition(ConnState.authenticationRequired, ConnState.connected), isFalse);
      expect(canTransition(ConnState.discovering, ConnState.connected), isFalse);
    });

    test('contradictory moves are rejected, normal ones are not', () {
      expect(canTransition(ConnState.connected, ConnState.degraded), isTrue);
      expect(canTransition(ConnState.degraded, ConnState.reconnecting), isTrue);
      expect(canTransition(ConnState.reconnecting, ConnState.authenticating), isTrue);
      expect(canTransition(ConnState.connected, ConnState.deviceFound), isFalse);
      expect(canTransition(ConnState.connected, ConnState.connecting), isFalse);
    });

    test('timed states have a timeout, steady states do not', () {
      expect(connStates[ConnState.connecting]!.timeout, isNotNull);
      expect(connStates[ConnState.authenticating]!.timeout, isNotNull);
      expect(connStates[ConnState.degraded]!.timeout, isNotNull);
      expect(connStates[ConnState.connected]!.timeout, isNull);
    });
  });

  group('device identity', () {
    test('a valid hello is accepted with all identity fields', () {
      final f = FoundBoard.parse('192.168.1.5', helloJson())!;
      expect(f.id, 'C224AC');
      expect(f.fw, '0.6.0');
      expect(f.apiVersion, 1);
      expect(f.caps, contains('scenes'));
      expect(f.lock, isFalse);
      expect(f.legacy, isFalse);
    });

    test('other web servers and junk are not Hubs', () {
      expect(FoundBoard.parse('h', '<html>hello</html>'), isNull);
      expect(FoundBoard.parse('h', '{"device":"Printer","id":"X","fw":"1"}'), isNull);
      expect(FoundBoard.parse('h', '{"device":"ESP32-Hub","fw":"1"}'), isNull, reason: 'no id');
      expect(FoundBoard.parse('h', '{"device":"ESP32-Hub","id":"ABC"}'), isNull, reason: 'no firmware');
      expect(FoundBoard.parse('h', '[1,2]'), isNull);
    });

    test('firmware from before the API handshake is accepted as legacy', () {
      final f = FoundBoard.parse('h', '{"device":"ESP32-Hub","id":"abc123","fw":"0.5.1","ap":false,"online":true,"lock":true,"ip":"1.2.3.4"}')!;
      expect(f.legacy, isTrue);
      expect(f.id, 'ABC123');
      expect(f.lock, isTrue);
    });

    test('device JSON round-trips and never carries a token', () {
      final d = HubDevice(id: 'C224AC', name: 'Desk', host: '10.0.0.4', fw: '0.6.0', apiVersion: 1, caps: ['scenes'], lastConnected: DateTime(2026, 1, 2), favorites: ['eyes']);
      final j = jsonEncode(d.toJson());
      expect(j.toLowerCase(), isNot(contains('token')));
      final back = HubDevice.fromJson(jsonDecode(j))!;
      expect(back.id, d.id);
      expect(back.name, 'Desk');
      expect(back.favorites, ['eyes']);
      expect(back.lastConnected, DateTime(2026, 1, 2));
      expect(HubDevice.fromJson({'name': 'x'}), isNull);
      expect(HubDevice.fromJson('nope'), isNull);
    });

    test('hostname is unique per device', () {
      expect(HubDevice(id: 'C224AC').hostname, 'esp32-hub-c224ac.local');
    });
  });
}
