import 'dart:convert';

import 'app_prefs.dart';
import 'registry.dart';

/// Export / restore of the user's non-secret settings: dashboard shortcuts, saved presets, notification privacy,
/// device names and favourite scenes. Tokens, passwords, API keys and Wi-Fi details are never included.
class Backup {
  static const schema = 1;

  static String export(AppPrefs prefs, DeviceRegistry registry) => const JsonEncoder.withIndent('  ').convert({
        'schema': schema,
        'app': 'esp32_hub',
        'quick': prefs.quickIds,
        'presets': prefs.custom.map((e) => e.toJson()).toList(),
        'notifications': {'hideContent': prefs.hideContent, 'blocked': prefs.blocked.toList()},
        'devices': [
          for (final d in registry.devices) {'id': d.id, 'name': d.name, 'favorites': d.favorites},
        ],
      });

  /// Validates [text] completely before changing anything. Throws [FormatException] with a readable message.
  static Future<String> restore(String text, AppPrefs prefs, DeviceRegistry registry) async {
    Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const FormatException('This is not a backup file.');
    }
    if (j is! Map || j['app'] != 'esp32_hub') throw const FormatException('This backup is not from ESP32 Hub.');
    final v = j['schema'];
    if (v is! int || v > schema) throw const FormatException('This backup was made by a newer version of the app.');
    final quick = j['quick'] is List ? (j['quick'] as List).map((e) => '$e').where((id) => quickActionLibrary.any((a) => a.id == id)).toList() : null;
    final presets = <Preset>[];
    if (j['presets'] is List) {
      for (final e in j['presets'] as List) {
        final p = Preset.fromJson(e);
        if (p == null) throw const FormatException('A saved preset in the file is damaged.');
        presets.add(p);
      }
    }
    final n = j['notifications'];
    var restoredDevices = 0;
    if (quick != null) await prefs.setQuick(quick);
    for (final p in presets) {
      await prefs.savePreset(p);
    }
    if (n is Map) {
      await prefs.setHideContent(n['hideContent'] == true);
      if (n['blocked'] is List) await prefs.setBlocked((n['blocked'] as List).map((e) => '$e').toSet());
    }
    if (j['devices'] is List) {
      for (final e in j['devices'] as List) {
        if (e is! Map) continue;
        final d = registry.byId('${e['id']}');
        if (d == null) continue; // only boards that are paired on this phone: a backup cannot pair a board
        await registry.upsert(d.copyWith(name: '${e['name'] ?? d.name}', favorites: e['favorites'] is List ? (e['favorites'] as List).map((x) => '$x').toList() : d.favorites));
        restoredDevices++;
      }
    }
    return 'Restored ${presets.length} preset(s), ${quick?.length ?? 0} shortcut(s) and settings for $restoredDevices Hub(s).';
  }
}
