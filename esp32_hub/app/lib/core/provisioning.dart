import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'bridge.dart';
import 'connection.dart';
import 'diagnostics.dart';
import 'discovery.dart';
import 'errors.dart';
import 'models.dart';

/// The six stages the user sees.
enum ProvStep { prepare, connectHub, selectWifi, joinNetwork, verify, finish }

/// What the join is doing right now. Mirrors the board's own phases (see /api/wifi/status "phase").
enum JoinPhase {
  idle,
  validatingCredentials,
  stoppingScan,
  preparingInterface,
  connecting,
  waitingForAssociation,
  waitingForDhcp,
  verifyingConnection,
  verifyingApplicationReachability,
  savingCredentials,
  completed,
  failed,
}

String joinPhaseText(JoinPhase p) {
  switch (p) {
    case JoinPhase.idle:
      return '';
    case JoinPhase.validatingCredentials:
      return 'Checking the details';
    case JoinPhase.stoppingScan:
    case JoinPhase.preparingInterface:
      return 'Getting the Hub ready';
    case JoinPhase.connecting:
      return 'Sending the network to the Hub';
    case JoinPhase.waitingForAssociation:
      return 'The Hub is joining the network';
    case JoinPhase.waitingForDhcp:
      return 'Waiting for the router to give the Hub an address';
    case JoinPhase.verifyingConnection:
      return 'The Hub is online';
    case JoinPhase.verifyingApplicationReachability:
      return 'Finding the Hub on your Wi-Fi';
    case JoinPhase.savingCredentials:
      return 'Saving';
    case JoinPhase.completed:
      return 'Done';
    case JoinPhase.failed:
      return 'Failed';
  }
}

/// Non-sensitive progress that survives the app being closed mid-setup. It never contains the Wi-Fi password.
class ProvProgress {
  ProvProgress({required this.deviceId, required this.ssid, required this.step, required this.at});
  final String deviceId, ssid, step;
  final DateTime at;
  Map<String, dynamic> toJson() => {'id': deviceId, 'ssid': ssid, 'step': step, 't': at.millisecondsSinceEpoch};
  static ProvProgress? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['t'] is! int) return null;
    return ProvProgress(deviceId: j['id'] as String, ssid: '${j['ssid'] ?? ''}', step: '${j['step'] ?? ''}', at: DateTime.fromMillisecondsSinceEpoch(j['t'] as int));
  }

  bool get fresh => DateTime.now().difference(at) < const Duration(minutes: 30);
}

typedef ProvLinkFactory = ProvisionLink Function(String host, String expectId, String token);

/// Guided Wi-Fi setup: join the Hub's setup hotspot, pick the home network, hand it over, and find the Hub again on the
/// home network by its identity. Deterministic phases, a failure reason for every way it can fail, no password in any
/// log or in the saved progress, and a way back in if the app is closed or the phone switches networks halfway.
class ProvisioningController extends ChangeNotifier {
  ProvisioningController({
    required this.hub,
    Bridge? bridge,
    DiscoveryService? discovery,
    ProvLinkFactory? linkFactory,
    this.hotspotSsid = 'ESP32-Hub',
    this.joinTimeout = const Duration(seconds: 70),
    this.pollEvery = const Duration(milliseconds: 1200),
  })  : _bridge = bridge ?? Bridge.current,
        _discovery = discovery ?? hub.discovery,
        _linkFactory = linkFactory ?? ((h, id, t) => HttpApi(h, token: t, expectId: id)),
        _log = hub.log;

  final ConnectionManager hub;
  final Bridge _bridge;
  final DiscoveryService _discovery;
  final ProvLinkFactory _linkFactory;
  final DiagLog _log;
  final String hotspotSsid;
  final Duration joinTimeout, pollEvery;

  static const _progressKey = 'prov_progress_v1';
  static const hotspotHost = '192.168.4.1';

  ProvStep step = ProvStep.prepare;
  JoinPhase phase = JoinPhase.idle;
  JoinFailure? failure;
  String? message; // an instruction or a problem, in plain language
  List<WifiNetwork> networks = [];
  bool scanning = false;
  bool protect = true; // lock the Hub with a token as part of pairing
  FoundBoard? board; // the Hub, as seen on its hotspot
  HubDevice? paired;
  bool _cancelled = false;
  int _scanRun = 0;
  ProvisionLink? _link;

  bool get busy => phase != JoinPhase.idle && phase != JoinPhase.failed && phase != JoinPhase.completed;

  void _go(ProvStep s) {
    step = s;
    notifyListeners();
  }

  void _setPhase(JoinPhase p, {JoinFailure? fail, String? msg}) {
    phase = p;
    failure = fail;
    if (msg != null || p == JoinPhase.failed) message = msg ?? (fail == null ? null : joinFailureText(fail));
    _log.i('prov', 'phase ${p.name}${fail == null ? '' : ' failure=${fail.name}'}');
    notifyListeners();
  }

  // ------------------------------------------------------------------ progress persistence
  Future<void> _saveProgress(String id, String ssid, String stepName) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_progressKey, jsonEncode(ProvProgress(deviceId: id, ssid: ssid, step: stepName, at: DateTime.now()).toJson()));
  }

  static Future<ProvProgress?> loadProgress() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_progressKey);
    if (raw == null) return null;
    try {
      final pr = ProvProgress.fromJson(jsonDecode(raw));
      return pr != null && pr.fresh ? pr : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearProgress() async => (await SharedPreferences.getInstance()).remove(_progressKey);

  // ------------------------------------------------------------------ step 1-2: reach the Hub
  /// Joins the Hub's hotspot with Android's own approval dialog and finds the Hub on it. [password] is the 8-character code
  /// shown on the Hub's screen (it is different for every Hub).
  Future<bool> connectToHub(String password) async {
    _cancelled = false;
    failure = null;
    message = null;
    hub.beginProvisioning();
    _go(ProvStep.connectHub);
    _setPhase(JoinPhase.connecting, msg: 'Android will ask you to allow the connection. Tap Connect.');
    final code = await _bridge.joinWifi(hotspotSsid, password);
    if (_cancelled) return false;
    switch (code) {
      case JoinCode.ok:
        break;
      case JoinCode.unsupported:
        // Android 9 and older: there is no approval API. Ask the user to join the Wi-Fi in settings; we keep probing below.
        message = 'Join the Wi-Fi "$hotspotSsid" in your phone\'s settings (password: the 8 characters on the Hub\'s screen), then come back.';
        notifyListeners();
      case JoinCode.unavailable:
        _setPhase(JoinPhase.failed, msg: 'Android didn\'t connect to "$hotspotSsid". If you tapped Cancel, try again. Otherwise check that the Hub is showing its setup screen (hold BOOT for 2 seconds) and that the code is right.');
        return false;
      case JoinCode.error:
        _setPhase(JoinPhase.failed, msg: 'Couldn\'t start the connection to the Hub. Check the code on the Hub\'s screen and try again.');
        return false;
    }
    // the phone needs a moment to get an address (DHCP): keep asking instead of failing on the first try
    FoundBoard? f;
    for (var i = 0; i < 25 && !_cancelled; i++) {
      f = await _discovery.probe(hotspotHost, timeout: const Duration(milliseconds: 1500), source: 'hotspot');
      if (f != null) break;
      await Future.delayed(const Duration(seconds: 1));
    }
    if (_cancelled) return false;
    if (f == null) {
      _setPhase(JoinPhase.failed, msg: 'Joined the Hub\'s Wi-Fi, but the Hub didn\'t answer. Wait a few seconds and try again.');
      return false;
    }
    board = f;
    _link = _linkFactory(hotspotHost, f.id, '');
    _setPhase(JoinPhase.idle);
    _go(ProvStep.selectWifi);
    await _saveProgress(f.id, '', 'selectWifi');
    unawaited(loadNetworks());
    return true;
  }

  /// A Hub that is already reachable on its hotspot (the phone joined it from the Wi-Fi settings, or the user came back).
  Future<bool> attachHotspotBoard(FoundBoard f) async {
    hub.beginProvisioning();
    board = f;
    _link = _linkFactory(f.host, f.id, '');
    _setPhase(JoinPhase.idle);
    _go(ProvStep.selectWifi);
    unawaited(loadNetworks());
    return true;
  }

  /// Changing the Wi-Fi of a Hub that is already online (no hotspot): the Hub tries the new network first and falls back to the
  /// old one if that fails, so a typo can never strand it. The connection manager keeps its normal state meanwhile.
  Future<void> attachOnlineBoard(FoundBoard f, String token) async {
    board = f;
    protect = false;
    _link = _linkFactory(f.host, f.id, token);
    _setPhase(JoinPhase.idle);
    _go(ProvStep.selectWifi);
    unawaited(loadNetworks());
  }

  // ------------------------------------------------------------------ step 3: choose the network
  /// Asks the board for the networks it sees; a scan takes a few seconds, so ask again until something comes back.
  /// Never runs while a join is in progress (a scan makes the join fail).
  Future<void> loadNetworks() async {
    final l = _link;
    if (l == null) return;
    final run = ++_scanRun;
    scanning = true;
    notifyListeners();
    for (var i = 0; i < 12 && run == _scanRun && !busy && !_cancelled; i++) {
      try {
        final n = await l.networks();
        if (run != _scanRun) return;
        if (n.isNotEmpty) {
          networks = _tidy(n);
          notifyListeners();
          break;
        }
      } catch (_) {
        // the board is busy scanning: ask again
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    if (run == _scanRun) {
      scanning = false;
      notifyListeners();
    }
  }

  /// Strongest first, one entry per name (the board already de-duplicates; this protects against older firmware).
  static List<WifiNetwork> _tidy(List<WifiNetwork> n) {
    final best = <String, WifiNetwork>{};
    for (final w in n) {
      final o = best[w.ssid];
      if (o == null || (w.rssi ?? -200) > (o.rssi ?? -200)) best[w.ssid] = w;
    }
    final l = best.values.toList()..sort((a, b) => (b.rssi ?? -200).compareTo(a.rssi ?? -200));
    return l;
  }

  // ------------------------------------------------------------------ step 4-6: join, verify, save
  /// Validates the details locally before anything is sent. Returns the failure, or null when fine.
  static JoinFailure? validate(String ssid, String pass, {bool secure = true, String hotspot = 'ESP32-Hub'}) {
    if (ssid.isEmpty || utf8.encode(ssid).length > 32) return JoinFailure.invalidCredentials;
    if (ssid.startsWith(hotspot)) return JoinFailure.ownHotspot;
    final pl = utf8.encode(pass).length;
    if (secure && (pl < 8 || pl > 63)) return JoinFailure.invalidCredentials;
    if (!secure && pass.isNotEmpty) return JoinFailure.invalidCredentials;
    return null;
  }

  /// Hands the network to the Hub and follows the attempt to the end. Returns the paired device, or null (see [failure]).
  Future<HubDevice?> submit(String ssid, String pass, {bool secure = true}) async {
    final l = _link, b = board;
    if (l == null || b == null) return null;
    _cancelled = false;
    _scanRun++; // stop scanning while the board is busy joining
    scanning = false;
    _go(ProvStep.joinNetwork);
    _setPhase(JoinPhase.validatingCredentials);
    final bad = validate(ssid, pass, secure: secure, hotspot: hotspotSsid);
    if (bad != null) {
      _setPhase(JoinPhase.failed, fail: bad);
      return null;
    }
    _setPhase(JoinPhase.stoppingScan);
    _setPhase(JoinPhase.preparingInterface);
    // Pairing lock: while the phone is physically on the Hub's own hotspot (which needs the code from its screen) the Hub
    // can be protected with a fresh token. The token goes straight into the Keystore-backed store.
    String token = '';
    if (protect) {
      try {
        final r = await l.cmd({'cmd': 'lock', 'on': true});
        if (r['token'] is String) {
          token = r['token'] as String;
          await hub.registry.setToken(b.id, token);
        }
      } catch (e) {
        _log.w('prov', 'could not lock the Hub during pairing: ${toHubException(e)}'); // continue unprotected; Settings > Security can lock it later
      }
    }
    _setPhase(JoinPhase.connecting);
    await _saveProgress(b.id, ssid, 'joinNetwork');
    Map<String, dynamic> r;
    try {
      r = await l.wifiSet(ssid, pass);
    } catch (_) {
      r = {'state': 'legacy'}; // an old board restarts before it answers: that is fine, look for it below
    }
    if (_cancelled) return null;
    if (r['state'] == 'fail') {
      _setPhase(JoinPhase.failed, fail: joinFailureFrom('${r['reason']}'));
      _go(ProvStep.selectWifi);
      unawaited(loadNetworks());
      return null;
    }
    String? newIp;
    FoundBoard? onLan;
    if (r['state'] == 'connecting') {
      final res = await _pollJoin(l, b.id);
      if (_cancelled) return null;
      if (res.failure != null) {
        _setPhase(JoinPhase.failed, fail: res.failure);
        _go(ProvStep.selectWifi);
        unawaited(loadNetworks());
        return null;
      }
      newIp = res.ip;
      onLan = res.found;
    } else {
      _setPhase(JoinPhase.waitingForAssociation, msg: 'The Hub is restarting and joining "$ssid". This takes about 20 seconds.');
    }

    // The Hub leaves its hotspot now. Let go of it so the phone is back on the home Wi-Fi, then find the Hub by identity.
    _go(ProvStep.verify);
    _setPhase(JoinPhase.verifyingApplicationReachability);
    if (onLan == null) {
      await _bridge.leaveHotspot();
      await Future.delayed(const Duration(seconds: 2));
      onLan = await _discovery.waitFor(b.id, limit: const Duration(seconds: 70), hints: [KnownHint(b.id, newIp ?? '', 'esp32-hub-${b.id.toLowerCase()}.local')], cancelled: () => _cancelled);
    } else {
      await _bridge.leaveHotspot();
    }
    if (_cancelled) return null;
    if (onLan == null) {
      _setPhase(JoinPhase.failed, fail: JoinFailure.networkDisconnected,
          msg: 'The Hub joined "$ssid", but your phone can\'t see it yet. Make sure the phone is back on the same Wi-Fi, then tap Find my Hub.');
      return null;
    }
    return _finish(onLan);
  }

  Future<HubDevice> _finish(FoundBoard f) async {
    _setPhase(JoinPhase.savingCredentials);
    final dev = f.toDevice(base: hub.registry.byId(f.id));
    await hub.registry.upsert(dev, select: true);
    await ProvisioningController.clearProgress();
    paired = dev;
    _setPhase(JoinPhase.completed);
    _go(ProvStep.finish);
    return dev;
  }

  /// Polls the board until it says whether the join worked. If the hotspot disappears first (the board already restarted and
  /// the phone moved to the home Wi-Fi) it looks for the board on the network instead.
  Future<({JoinFailure? failure, String? ip, FoundBoard? found})> _pollJoin(ProvisionLink l, String id) async {
    final end = DateTime.now().add(joinTimeout);
    var errors = 0;
    while (DateTime.now().isBefore(end) && !_cancelled) {
      try {
        final s = await l.wifiStatus();
        errors = 0;
        switch ('${s['state']}') {
          case 'ok':
            _setPhase(JoinPhase.verifyingConnection);
            return (failure: null, ip: '${s['ip']}', found: null);
          case 'fail':
            return (failure: joinFailureFrom('${s['reason']}'), ip: null, found: null);
          default:
            _setPhase('${s['phase']}' == 'waiting_dhcp' ? JoinPhase.waitingForDhcp : JoinPhase.waitingForAssociation);
        }
      } catch (_) {
        errors++;
        if (errors >= 3) {
          // The hotspot is gone: either the join worked and the Hub restarted, or the phone lost the Wi-Fi. Look on the LAN.
          _setPhase(JoinPhase.verifyingApplicationReachability, msg: 'Looking for the Hub on your Wi-Fi');
          await _bridge.leaveHotspot();
          await Future.delayed(const Duration(seconds: 2));
          await for (final f in _discovery.scan(wantId: id, budget: const Duration(seconds: 8))) {
            if (f.ap || f.id != id) continue;
            // reachable again: after a failed try an online board goes back to its old network, after a successful one it restarted
            try {
              final s = await _linkFactory(f.host, id, '').wifiStatus();
              if ('${s['state']}' == 'fail') return (failure: joinFailureFrom('${s['reason']}'), ip: null, found: null);
              if ('${s['state']}' == 'connecting') break;
            } catch (_) {
              continue;
            }
            return (failure: null, ip: f.host, found: f);
          }
          errors = 0;
        }
      }
      await Future.delayed(pollEvery);
    }
    return (failure: _cancelled ? null : JoinFailure.timeout, ip: null, found: null);
  }

  // ------------------------------------------------------------------ recovery
  /// Called when the setup screen opens: if an earlier setup was interrupted (app closed, phone switched networks) look for
  /// that Hub on the network by identity and finish pairing it without starting over.
  Future<HubDevice?> resume() async {
    final p = await loadProgress();
    if (p == null) return null;
    _log.i('prov', 'resuming setup of ${p.deviceId}');
    final f = await _discovery.waitFor(p.deviceId, limit: const Duration(seconds: 10), cancelled: () => _cancelled);
    if (f == null) return null;
    return _finish(f);
  }

  Future<void> cancel() async {
    _cancelled = true;
    _scanRun++;
    await _bridge.leaveHotspot();
    if (phase != JoinPhase.completed) {
      await hub.endProvisioning(null);
    }
  }

  /// Back from the finish screen into the normal app.
  Future<void> complete() async {
    final d = paired;
    await hub.endProvisioning(d);
  }

  /// Back to the first step after a failed hotspot connection.
  void backToPrepare() {
    failure = null;
    message = null;
    phase = JoinPhase.idle;
    _go(ProvStep.prepare);
  }

  void backToNetworks() {
    failure = null;
    message = null;
    phase = JoinPhase.idle;
    _go(ProvStep.selectWifi);
    unawaited(loadNetworks());
  }
}
