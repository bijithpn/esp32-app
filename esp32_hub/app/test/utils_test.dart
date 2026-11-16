import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:esp32_hub_app/core/app_prefs.dart';
import 'package:esp32_hub_app/core/backup.dart';
import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/catalog.dart';
import 'package:esp32_hub_app/core/diagnostics.dart';
import 'package:esp32_hub_app/core/errors.dart';
import 'package:esp32_hub_app/core/firmware.dart';
import 'package:esp32_hub_app/core/imaging.dart';
import 'package:esp32_hub_app/core/models.dart';
import 'package:esp32_hub_app/core/registry.dart';
import 'package:esp32_hub_app/version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Bridge.current = FakeBridge();
  });

  group('redaction', () {
    test('secrets are masked, ordinary words are not', () {
      expect(redact('{"token":"abc123","cmd":"x"}'), isNot(contains('abc123')));
      expect(redact('X-Hub-Token: deadbeef'), isNot(contains('deadbeef')));
      expect(redact('pass=hunter2&ssid=Home'), isNot(contains('hunter2')));
      expect(redact('x-api-key: sk-ant-api03-ABCDEF'), isNot(contains('ABCDEF')));
      expect(redact('WIFI:T:WPA;S:ESP32-Hub;P:abcd2345;;'), isNot(contains('abcd2345')));
      expect(redact('timeout: link down'), 'timeout: link down');
      expect(redact('attempt to 192.168.1.5 failed'), 'attempt to 192.168.1.5 failed');
    });
    test('the exported report contains no secret', () {
      final l = DiagLog(capacity: 3)..i('t', 'token=SECRET1')..i('t', 'a')..i('t', 'b')..i('t', 'c');
      final e = l.export(header: {'k': 'password: SECRET2'});
      expect(e, isNot(contains('SECRET')));
      expect(l.lines.length, 3, reason: 'bounded');
    });
    test('history is bounded and has no duplicates in a row', () async {
      final h = ConnHistory();
      for (var i = 0; i < 130; i++) {
        await h.add('connected', 'n$i');
      }
      await h.add('connected', 'n129');
      expect(h.events.length, 100);
    });
  });

  group('registry', () {
    test('legacy single-board settings are migrated and the token leaves plain storage', () async {
      SharedPreferences.setMockInitialValues({'host': '10.0.0.9', 'token': 'oldtok', 'dev_id': 'abc123'});
      final r = DeviceRegistry();
      await r.load();
      expect(r.selected?.id, 'ABC123');
      expect(r.selected?.host, '10.0.0.9');
      expect(await r.token('ABC123'), 'oldtok');
      expect((await SharedPreferences.getInstance()).getString('token'), isNull);
    });
    test('favourites and rename persist per device', () async {
      final r = DeviceRegistry();
      await r.load();
      await r.upsert(HubDevice(id: 'AAAAAA'), select: true);
      await r.upsert(HubDevice(id: 'BBBBBB'));
      await r.toggleFavorite('AAAAAA', 'eyes');
      await r.rename('BBBBBB', 'Kitchen');
      final r2 = DeviceRegistry();
      await r2.load();
      expect(r2.byId('AAAAAA')!.favorites, ['eyes']);
      expect(r2.byId('BBBBBB')!.favorites, isEmpty);
      expect(r2.byId('BBBBBB')!.name, 'Kitchen');
      expect(r2.selectedId, 'AAAAAA');
    });
    test('refreshing from the board keeps the name the user chose', () async {
      final r = DeviceRegistry();
      await r.load();
      await r.upsert(HubDevice(id: 'C224AC', name: 'Desk'), select: true);
      final f = FoundBoard.parse('10.0.0.2', helloJson(name: 'ESP32 Hub'))!;
      final d = await r.refreshFrom(f);
      expect(d.name, 'Desk');
      expect(d.host, '10.0.0.2');
    });
  });

  group('backup', () {
    test('export has no secrets and restore validates before changing anything', () async {
      final prefs = AppPrefs()..hideContent = true;
      final reg = DeviceRegistry();
      await reg.load();
      await reg.upsert(HubDevice(id: 'AAAAAA', name: 'Desk', host: '1.2.3.4'), select: true);
      await reg.setToken('AAAAAA', 'topsecret');
      final text = Backup.export(prefs, reg);
      expect(text, isNot(contains('topsecret')));
      expect(text, isNot(contains('1.2.3.4')));
      expect(() => Backup.restore('not json', prefs, reg), throwsFormatException);
      expect(() => Backup.restore('{"app":"other"}', prefs, reg), throwsFormatException);
      expect(() => Backup.restore('{"app":"esp32_hub","schema":99}', prefs, reg), throwsFormatException);
      expect(() => Backup.restore('{"app":"esp32_hub","schema":1,"presets":[{"bad":1}]}', prefs, reg), throwsFormatException);
      await prefs.savePreset(Preset(id: 'u1', name: 'Mine', icon: 'tune', commands: [{'cmd': 'auto', 'sec': 30}]));
      final again = Backup.export(prefs, reg);
      final fresh = AppPrefs();
      final msg = await Backup.restore(again, fresh, reg);
      expect(msg, contains('1 preset'));
      expect(fresh.custom.single.name, 'Mine');
    });
  });

  group('app prefs', () {
    test('built-in presets exist and Night dims in software', () {
      final p = AppPrefs();
      expect(p.presets.map((e) => e.id), containsAll(['work', 'relax', 'night']));
      final night = builtinPresets.firstWhere((e) => e.id == 'night');
      expect(night.commands.any((c) => c['cmd'] == 'dim' && (c['level'] as int) > 0), isTrue);
    });
    test('quick actions persist', () async {
      final p = AppPrefs();
      await p.setQuick(['ascii', 'next']);
      final q = AppPrefs();
      await q.load();
      expect(q.quickIds, ['ascii', 'next']);
    });
  });

  group('errors', () {
    test('the main UI never shows raw exception text', () {
      for (final e in [HubNetError('refused', 'SocketException: Connection refused'), HubNetError('timeout'), Exception('boom'), HubException(HubError.auth)]) {
        final t = friendlyError(e);
        expect(t, isNot(contains('Exception')));
        expect(t, isNot(contains('Socket')));
      }
      expect(friendlyError(HubNetError('refused')), contains('isn\'t responding'));
    });
  });

  group('firmware', () {
    test('versions compare numerically', () {
      expect(compareVersions('0.10.0', '0.9.2'), 1);
      expect(compareVersions('0.6.0', '0.6'), 0);
      expect(compareVersions('v1.0.0', '0.9.9'), 1);
      expect(compareVersions('0.5.1', '0.6.0'), -1);
    });
    test('a release needs a manifest and a compatible model', () {
      final rel = {'body': 'Notes', 'assets': [{'name': 'firmware.json', 'browser_download_url': 'u/m'}, {'name': 'fw.bin', 'browser_download_url': 'u/fw', 'size': 5}]};
      final p = FirmwareRelease.fromGithub(rel)!;
      final f = p.withManifest(jsonEncode({'version': '0.7.0', 'md5': 'a' * 32, 'size': 123, 'model': 'esp32-hub'}));
      expect(f.version, '0.7.0');
      expect(f.compatible, isTrue);
      expect(f.binUrl, 'u/fw');
      expect(f.notes, 'Notes');
      expect(() => p.withManifest('{"version":"1"}'), throwsFormatException);
      expect(() => p.withManifest('garbage'), throwsFormatException);
      expect(FirmwareRelease.fromGithub({'assets': []}), isNull, reason: 'an app-only release');
      expect(p.withManifest(jsonEncode({'version': '1', 'md5': 'b' * 32, 'model': 'other'})).compatible, isFalse);
    });
  });

  group('imaging', () {
    test('RGB565 and RGB332 pack as the board expects', () {
      expect(rgbaToRgb565(Uint8List.fromList([255, 0, 0, 255])), [0x00, 0xF8]);
      expect(rgbaToRgb565(Uint8List.fromList([0, 255, 0, 255])), [0xE0, 0x07]);
      expect(rgbaToRgb565(Uint8List.fromList([0, 0, 255, 255])), [0x1F, 0x00]);
      expect(rgbaToRgb332(Uint8List.fromList([255, 255, 255, 255])), [0xFF]);
      expect(rgbaToRgb332(Uint8List.fromList([255, 0, 0, 255])), [0xE0]);
      final back = rgb332ToRgba(Uint8List.fromList([0xFF, 0x00]));
      expect(back.sublist(0, 4), [255, 255, 255, 255]);
      expect(back.sublist(4, 8), [0, 0, 0, 255]);
    });
    test('animation limits: 7 frames, memory estimate, even thinning, ping-pong', () {
      expect(animMaxFrames, 7);
      expect(animMemory(7), 7 * 5120);
      expect(evenlySpaced(30, 7).length, 7);
      expect(evenlySpaced(30, 7).first, 0);
      expect(evenlySpaced(3, 7), [0, 1, 2]);
      expect(loopOrder(4, pingPong: false), [0, 1, 2, 3]);
      expect(loopOrder(4, pingPong: true), [0, 1, 2, 3, 2, 1]);
      expect(loopOrder(2, pingPong: true), [0, 1]);
      expect(loopOrder(4, pingPong: true).length, lessThanOrEqualTo(animMaxFrames));
    });
    test('cover rect keeps the target shape', () {
      final r = coverRect(400, 200, 160, 128);
      expect(r.width / r.height, closeTo(160 / 128, 0.01));
      expect(coverRect(400, 200, 160, 128, pan: 0).left, 0);
    });
  });

  group('project consistency', () {
    test('every scene the firmware has is in the app catalogue (nothing was dropped)', () {
      final src = File('../firmware/hub/scenes2.h').readAsStringSync();
      final ids = RegExp(r'\{"(\w+)",\s*"[^"]+",\s*\w+,\s*\w+,').allMatches(src).map((m) => m.group(1)!).toList();
      expect(ids.length, greaterThanOrEqualTo(14));
      for (final id in ids) {
        expect(sceneCatalog.containsKey(id), isTrue, reason: 'scene "$id" missing from the app');
      }
    });
    test('thirteen moods are offered', () => expect(moodsAll.length, 13));
    test('versions agree between app, pubspec and firmware', () {
      final pub = File('pubspec.yaml').readAsStringSync();
      expect(RegExp(r'^version: ([\d.]+)\+', multiLine: true).firstMatch(pub)!.group(1), appVersion);
      final ino = File('../firmware/hub/hub.ino').readAsStringSync();
      expect(RegExp(r'#define FW_VERSION "([\d.]+)"').firstMatch(ino)!.group(1), bundledFirmware);
    });
    test('the firmware API version matches what the app wants', () {
      final core = File('../firmware/hub/hubcore.h').readAsStringSync();
      expect(RegExp(r'#define API_VERSION (\d+)').firstMatch(core)!.group(1), '$apiVersionWanted');
    });
  });
}
