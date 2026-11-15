import 'package:permission_handler/permission_handler.dart';

import 'core/bridge.dart';
import 'core/connection.dart';
import 'core/errors.dart';

/// Keeps the phone-side helpers pointed at the board, and configures the board from the phone.
class PhoneSync {
  /// Tells the background service where the board is (it keeps working while this app is closed).
  /// The token goes to the native side encrypted (Android Keystore), never into plain preferences.
  static Future<void> pushConfig(ConnectionManager hub) async {
    final d = hub.device;
    if (d == null) return;
    await Bridge.current.setConfig({'host': d.host, 'id': d.id, 'token': await hub.registry.token(d.id)});
  }

  /// Time zone and (if allowed) weather location come from the phone: nothing to type.
  static Future<void> autoConfigure(ConnectionManager hub) async {
    try {
      final sec = DateTime.now().timeZoneOffset.inSeconds;
      final st = await hub.api?.status();
      if (st != null && st['tz'] != sec) await hub.send({'cmd': 'tz', 'sec': sec}, idempotent: true);
    } catch (_) {
      // not fatal: the board keeps its previous time zone
    }
    await sendLocation(hub);
  }

  /// Sends the phone's approximate location to the board for the weather. Returns false when not allowed or not available.
  static Future<bool> sendLocation(ConnectionManager hub) async {
    try {
      if (!await Permission.locationWhenInUse.isGranted) return false;
      final l = await Bridge.current.location();
      if (l == null) return false;
      await hub.send({'cmd': 'loc', 'lat': l.lat, 'lon': l.lon}, idempotent: true);
      return true;
    } catch (e) {
      hub.log.w('phone', 'location send failed: ${toHubException(e)}');
      return false;
    }
  }
}
