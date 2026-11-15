import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'bridge.dart';
import 'models.dart';

/// Paired boards, stored on the phone. The list (names, last address, firmware) is ordinary preferences data;
/// every token and password is kept in the Keystore-backed [Bridge] secure store under a per-device key, so tokens
/// and commands can never be mixed up between boards.
class DeviceRegistry {
  static const _key = 'devices_v2';
  static const _sel = 'selected_device';

  final List<HubDevice> _devices = [];
  String? _selected;

  List<HubDevice> get devices => List.unmodifiable(_devices);
  String? get selectedId => _selected;
  HubDevice? get selected => byId(_selected);

  HubDevice? byId(String? id) {
    for (final d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _devices.clear();
    final raw = p.getString(_key);
    if (raw != null) {
      try {
        for (final j in jsonDecode(raw) as List) {
          final d = HubDevice.fromJson(j);
          if (d != null && byId(d.id) == null) _devices.add(d);
        }
      } catch (_) {
        // a corrupt list is rebuilt from the legacy keys below
      }
    }
    _selected = p.getString(_sel);
    if (_devices.isEmpty) await _migrateLegacy(p);
    if (_selected != null && byId(_selected) == null) _selected = _devices.isEmpty ? null : _devices.first.id;
  }

  /// Older app versions kept one board in 'host', 'token' and 'dev_id'. Move it over (tokens go to the secure store).
  Future<void> _migrateLegacy(SharedPreferences p) async {
    final id = p.getString('dev_id');
    if (id == null || id.isEmpty) return;
    final d = HubDevice(id: id.toUpperCase(), host: p.getString('host') ?? '');
    _devices.add(d);
    _selected = d.id;
    final t = p.getString('token') ?? '';
    if (t.isNotEmpty) await Bridge.current.secureSet(_tokenKey(d.id), t);
    final mp = p.getString('mq_pass') ?? '';
    if (mp.isNotEmpty) await Bridge.current.secureSet('mqtt_pass', mp);
    await p.remove('token'); // no tokens left in plain preferences
    await p.remove('mq_pass');
    await p.remove('mq_token');
    await _save(p);
  }

  static String _tokenKey(String id) => 'token:$id';

  Future<void> _save([SharedPreferences? sp]) async {
    final p = sp ?? await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(_devices.map((d) => d.toJson()).toList()));
    if (_selected == null) {
      await p.remove(_sel);
    } else {
      await p.setString(_sel, _selected!);
    }
  }

  Future<void> upsert(HubDevice d, {bool select = false}) async {
    final i = _devices.indexWhere((x) => x.id == d.id);
    if (i < 0) {
      _devices.add(d);
    } else {
      // keep what the user chose (name, favourites) unless the caller changed it on purpose
      _devices[i] = d;
    }
    if (select || _selected == null) _selected = d.id;
    await _save();
  }

  /// Merge fresh data from the board into the stored entry, keeping the user's own name and favourites.
  Future<HubDevice> refreshFrom(FoundBoard f) async {
    final old = byId(f.id);
    final merged = old == null
        ? f.toDevice()
        : old.copyWith(host: f.host, fw: f.fw, apiVersion: f.apiVersion, caps: f.caps, lastSeen: DateTime.now(), locked: f.lock);
    await upsert(merged);
    return merged;
  }

  Future<void> rename(String id, String name) async {
    final d = byId(id);
    if (d == null) return;
    await upsert(d.copyWith(name: name.trim().isEmpty ? d.name : name.trim()));
  }

  Future<void> markConnected(String id, {String? host}) async {
    final d = byId(id);
    if (d == null) return;
    await upsert(d.copyWith(lastConnected: DateTime.now(), lastSeen: DateTime.now(), host: host));
  }

  Future<void> select(String? id) async {
    _selected = id;
    await _save();
  }

  Future<void> remove(String id) async {
    _devices.removeWhere((d) => d.id == id);
    await Bridge.current.secureSet(_tokenKey(id), null);
    if (_selected == id) _selected = _devices.isEmpty ? null : _devices.first.id;
    await _save();
  }

  Future<String> token(String id) async => (await Bridge.current.secureGet(_tokenKey(id))) ?? '';

  Future<void> setToken(String id, String token) => Bridge.current.secureSet(_tokenKey(id), token.isEmpty ? null : token);

  // ---------------------------------------------------------------- remote (MQTT) access, per device
  /// Broker settings of one device. The broker password lives in the secure store; the rest is ordinary preferences.
  Future<MqttConfig?> mqttConfig(String id) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('mqtt_cfg:$id');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      final host = '${j['host'] ?? ''}';
      if (host.isEmpty) return null;
      return MqttConfig(
        host: host,
        port: (j['port'] as num?)?.toInt() ?? 1883,
        user: '${j['user'] ?? ''}',
        pass: (await Bridge.current.secureGet('mqtt_pass:$id')) ?? '',
        tls: j['tls'] == true,
        deviceId: id,
        token: await token(id),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMqtt(String id, {required String host, required int port, required String user, required String pass, required bool tls}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('mqtt_cfg:$id', jsonEncode({'host': host, 'port': port, 'user': user, 'tls': tls}));
    await Bridge.current.secureSet('mqtt_pass:$id', pass.isEmpty ? null : pass);
  }

  Future<void> clearMqtt(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.remove('mqtt_cfg:$id');
    await Bridge.current.secureSet('mqtt_pass:$id', null);
  }

  Future<void> toggleFavorite(String deviceId, String sceneId) async {
    final d = byId(deviceId);
    if (d == null) return;
    final f = [...d.favorites];
    f.contains(sceneId) ? f.remove(sceneId) : f.add(sceneId);
    await upsert(d.copyWith(favorites: f));
  }
}
