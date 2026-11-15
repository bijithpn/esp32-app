import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../api.dart';
import 'bridge.dart';
import 'command_queue.dart';
import 'diagnostics.dart';
import 'discovery.dart';
import 'errors.dart';
import 'models.dart';
import 'registry.dart';

typedef LinkFactory = HubLink Function(String host, String token, String expectId);

/// The single source of truth for device connectivity.
///
/// It owns: the paired-device registry, discovery, authentication, the health monitor, the reconnect loop with
/// back-off, network-change recovery, the command queue and the diagnostics. Screens read [state] and call [send];
/// nothing else in the app opens a connection to a board.
///
/// Rules it enforces:
///  - "connected" is only ever set after the board answered /api/hello with the expected identity, authentication passed
///    and /api/list returned (see [_openLink]).
///  - consecutive command or ping failures take it to "degraded" and then "reconnecting": it can never stay "connected"
///    while commands keep failing.
///  - transitions follow [connStates]; anything else is rejected and logged.
///  - nothing runs while the app is in the background (no battery drain from retry loops).
class ConnectionManager extends ChangeNotifier with WidgetsBindingObserver {
  ConnectionManager({
    DeviceRegistry? registry,
    DiscoveryService? discovery,
    Bridge? bridge,
    DiagLog? log,
    ConnHistory? history,
    LinkFactory? linkFactory,
    math.Random? random,
    this.backoff = const [Duration(milliseconds: 500), Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 15)],
    this.activeInterval = const Duration(seconds: 5),
    this.idleInterval = const Duration(seconds: 20),
    this.degradedInterval = const Duration(milliseconds: 1500),
    this.maxAttempts = 40,
  })  : registry = registry ?? DeviceRegistry(),
        _bridge = bridge ?? Bridge.current,
        log = log ?? DiagLog.instance,
        history = history ?? ConnHistory(),
        _rnd = random ?? math.Random(),
        discovery = discovery ?? DiscoveryService(bridge: bridge ?? Bridge.current, log: log ?? DiagLog.instance),
        _linkFactory = linkFactory ?? ((h, t, id) => HttpApi(h, token: t, expectId: id)) {
    queue = CommandQueue(_execute, onResult: _onCommandResult, boardDedupes: () => (device?.apiVersion ?? 0) >= 1);
  }

  final DeviceRegistry registry;
  final DiscoveryService discovery;
  final DiagLog log;
  final ConnHistory history;
  final Bridge _bridge;
  final LinkFactory _linkFactory;
  final math.Random _rnd;
  late final CommandQueue queue;

  final List<Duration> backoff;
  final Duration activeInterval, idleInterval, degradedInterval;
  final int maxAttempts;

  // ---------------------------------------------------------------- observable state
  ConnState _state = ConnState.disconnected;
  ConnState get state => _state;
  String _reason = '';

  /// Why the state is what it is (for the UI's second line). Plain language.
  String get reason => _reason;

  HubDevice? get device => _device;
  HubDevice? _device;

  Api? get api => _link;
  HubLink? _link;

  /// The board's /api/list: scenes, current scene, firmware, lock.
  Map<String, dynamic> data = {};

  /// Last /api/ping: uptime, rssi, heap.
  Map<String, dynamic> pingData = {};
  int latencyMs = -1;
  DateTime? lastOkAt;
  DateTime? stateSince = DateTime.now();
  int reconnectAttempt = 0;
  DateTime? nextRetryAt;
  NetInfo net = const NetInfo();
  List<FoundBoard> nearby = [];
  bool searching = false;
  bool get connected => _state == ConnState.connected;

  /// True when the link goes through the MQTT broker instead of the local network.
  bool get viaRemote => _link is RemoteLink;

  /// Commands may be sent in these states (degraded still tries: the link may recover on the next request).
  bool get canSend => _state == ConnState.connected || _state == ConnState.degraded;

  bool _foreground = true;
  bool _dashboardActive = false;
  int _loopId = 0; // bumped to cancel the running reconnect loop / connect attempt
  int _consecutiveFails = 0, _slowCount = 0, _okStreak = 0;
  int _rev = -1;
  Timer? _healthTimer, _stableTimer, _stateTimeout;
  Completer<void>? _wake;
  bool _pinging = false;
  StreamSubscription<NetEvent>? _netSub;
  final _netEvents = StreamController<NetEvent>.broadcast();
  Stream<NetEvent> get netEvents => _netEvents.stream;

  // ---------------------------------------------------------------- lifecycle
  /// Restores paired devices at once (no network needed), then verifies the selected one in the background.
  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    await Future.wait([registry.load(), history.load()]);
    net = await _bridge.netSnapshot();
    _netSub = _bridge.netEvents().listen(_onNet);
    _device = registry.selected;
    if (_device != null) {
      log.i('conn', 'restored ${_device!.name} (${_device!.id}) from the registry');
      unawaited(_openAndVerify(reason: 'App started'));
    }
    notifyListeners();
  }

  bool _disposed = false;

  void _wakeUp() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// A loop that was in flight when the manager was disposed must not touch it any more.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loopId++;
    _wakeUp();
    WidgetsBinding.instance.removeObserver(this);
    _netSub?.cancel();
    _healthTimer?.cancel();
    _stableTimer?.cancel();
    _stateTimeout?.cancel();
    _netEvents.close();
    _link?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (!fg) {
      _healthTimer?.cancel();
      _loopId++; // pauses any retry loop: no background battery drain
      _wakeUp();
      log.d('conn', 'app in background: monitor paused');
    } else {
      log.d('conn', 'app in foreground: resuming');
      _resume();
    }
  }

  void setDashboardActive(bool v) {
    if (_dashboardActive == v) return;
    _dashboardActive = v;
    _scheduleHealth();
  }

  // ---------------------------------------------------------------- state machine
  bool _set(ConnState next, [String why = '']) {
    if (!canTransition(_state, next)) {
      log.w('conn', 'rejected transition ${_state.name} -> ${next.name} ($why)');
      return false;
    }
    if (_state != next) {
      log.i('conn', '${_state.name} -> ${next.name}${why.isEmpty ? '' : ' ($why)'}');
      _state = next;
      stateSince = DateTime.now();
      _stateTimeout?.cancel();
      final t = connStates[next]?.timeout;
      if (t != null) _stateTimeout = Timer(t, () => _onStateTimeout(next));
    }
    _reason = why;
    notifyListeners();
    return true;
  }

  /// A state that lasts longer than its limit moves on, so nothing sits in "connecting" forever.
  void _onStateTimeout(ConnState s) {
    if (_state != s) return;
    switch (s) {
      case ConnState.connecting:
      case ConnState.authenticating:
        log.w('conn', '${s.name} timed out');
        _loopId++;
        _startReconnect('The Hub did not answer in time');
      case ConnState.degraded:
        _lost('The connection stayed weak');
      case ConnState.networkSwitching:
        _startReconnect('Network settled');
      case ConnState.discovering:
        searching = false;
        if (_device == null) {
          _set(nearby.isEmpty ? ConnState.unavailable : ConnState.deviceFound, nearby.isEmpty ? 'No Hub found' : '');
        }
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- connecting
  /// Connects to a board the user picked (from discovery or the device list).
  Future<void> connectDevice(HubDevice d) async {
    _loopId++;
    queue.bumpEpoch();
    _device = d;
    await registry.select(d.id);
    await _openAndVerify(reason: 'Opening ${d.name}');
  }

  /// Opens the saved device now (the "retry" button).
  Future<void> retryNow() async {
    if (_device == null) return;
    reconnectAttempt = 0;
    _wakeUp();
    if (_state == ConnState.unavailable || _state == ConnState.error || _state == ConnState.authenticationRequired || _state == ConnState.disconnected) {
      await _openAndVerify(reason: 'Retry');
    }
  }

  /// Verified open: hello (identity) -> authenticate -> list. Only then "connected".
  Future<void> _openAndVerify({required String reason}) async {
    final d = _device;
    if (d == null) return;
    final id = ++_loopId;
    if (_state != ConnState.reconnecting && _state != ConnState.networkSwitching) {
      _set(ConnState.connecting, reason);
    }
    final sw = Stopwatch()..start();
    final result = await _tryHost(d, d.host, id);
    if (id != _loopId) return;
    if (result == _Open.ok) {
      log.i('conn', 'verified ${d.id} in ${sw.elapsedMilliseconds} ms');
      return;
    }
    if (result == _Open.auth || result == _Open.cancelled) return;
    // cached address did not work: search by identity
    _startReconnect(result == _Open.wrongDevice ? 'Another device answered at the saved address' : 'Looking for your Hub');
  }

  /// One verified connection attempt to [host]. Returns what happened.
  Future<_Open> _tryHost(HubDevice d, String host, int attempt) async {
    if (host.isEmpty) return _Open.unreachable;
    final token = await registry.token(d.id);
    if (attempt != _loopId) return _Open.cancelled;
    HubLink link;
    if (host == 'mqtt') {
      // from anywhere: through the user's MQTT broker (the Hub connects out to it, so no port forwarding)
      final cfg = await registry.mqttConfig(d.id);
      if (cfg == null) return _Open.unreachable;
      final m = MqttApi(cfg);
      try {
        await m.connect();
      } catch (e) {
        log.w('conn', 'MQTT broker unreachable: ${toHubException(e)}');
        return _Open.unreachable;
      }
      link = RemoteLink(m, d.id);
    } else {
      link = _linkFactory(host, token, d.id);
    }
    try {
      final f = await link.hello(timeout: const Duration(milliseconds: 1800));
      if (attempt != _loopId) return _Open.cancelled;
      if (f == null || f.id != d.id) {
        log.w('conn', 'identity check failed at $host (${f?.id ?? 'not a Hub'})');
        return f == null ? _Open.unreachable : _Open.wrongDevice;
      }
      if (f.ap) {
        // the board is in setup mode: it has no home Wi-Fi. That is a provisioning job, not a connection problem.
        _link = link;
        _set(ConnState.unavailable, 'The Hub is in setup mode and needs Wi-Fi');
        return _Open.cancelled;
      }
      _set(ConnState.authenticating, 'Verifying');
      if (f.lock || d.locked) {
        final ok = await link.checkAuth();
        if (attempt != _loopId) return _Open.cancelled;
        if (!ok) {
          _link = link;
          _device = await registry.refreshFrom(f);
          _set(ConnState.authenticationRequired, 'This Hub is locked');
          history.add('auth_failed', 'Token rejected by ${d.name}', deviceId: d.id);
          return _Open.auth;
        }
      }
      final list = await link.list();
      if (attempt != _loopId) return _Open.cancelled;
      final prevFw = d.fw;
      final prevHost = d.host;
      _device = host == 'mqtt' ? d : await registry.refreshFrom(f);
      await registry.markConnected(d.id, host: host == 'mqtt' ? null : host);
      _device = registry.byId(d.id);
      _link?.close();
      _link = link;
      data = list;
      latencyMs = f.latencyMs;
      lastOkAt = DateTime.now();
      _rev = (list['rev'] as num?)?.toInt() ?? -1;
      _consecutiveFails = 0;
      _slowCount = 0;
      _okStreak = 0;
      _set(ConnState.connected, '');
      history.add('connected', '${_device!.name} at $host', deviceId: d.id);
      if (prevHost.isNotEmpty && host != 'mqtt' && prevHost != host) history.add('ip_changed', '$prevHost -> $host', deviceId: d.id);
      if (prevFw.isNotEmpty && f.fw != prevFw) history.add('firmware_updated', '$prevFw -> ${f.fw}', deviceId: d.id);
      _afterConnected();
      return _Open.ok;
    } catch (e) {
      final h = toHubException(e);
      log.w('conn', 'attempt to $host failed: $h');
      if (h.kind == HubError.auth) {
        _link = link;
        _set(ConnState.authenticationRequired, 'This Hub is locked');
        return _Open.auth;
      }
      if (h.kind == HubError.wrongDevice) return _Open.wrongDevice;
      if (_state == ConnState.authenticating) _set(ConnState.reconnecting, 'Lost the Hub while verifying');
      return _Open.unreachable;
    }
  }

  void _afterConnected() {
    nextRetryAt = null;
    final d = _device!;
    registry.token(d.id).then((t) => _bridge.setConfig({'host': d.host, 'id': d.id, 'token': t}));
    // the back-off only resets after the link stayed up for 20 s, so a flapping link keeps slowing its retries down
    _stableTimer?.cancel();
    _stableTimer = Timer(const Duration(seconds: 20), () {
      if (_state == ConnState.connected) reconnectAttempt = 0;
    });
    _scheduleHealth();
    notifyListeners();
  }

  // ---------------------------------------------------------------- health monitor
  void _scheduleHealth() {
    _healthTimer?.cancel();
    if (!_foreground || _link == null) return;
    if (_state != ConnState.connected && _state != ConnState.degraded) return;
    final every = _state == ConnState.degraded ? degradedInterval : (_dashboardActive ? activeInterval : idleInterval);
    _healthTimer = Timer(every, _healthTick);
  }

  Future<void> _healthTick() async {
    final link = _link;
    if (link == null || _pinging || !_foreground) return;
    if (_state != ConnState.connected && _state != ConnState.degraded) return;
    _pinging = true;
    try {
      final r = await link.ping();
      if (link != _link) return;
      pingData = r.data;
      latencyMs = r.ms;
      lastOkAt = DateTime.now();
      _consecutiveFails = 0;
      _okStreak++;
      _slowCount = r.ms > 1500 ? _slowCount + 1 : 0;
      final rev = (r.data['rev'] as num?)?.toInt();
      if (rev != null && rev != _rev) {
        _rev = rev;
        unawaited(refreshData());
      }
      if (_state == ConnState.degraded && _okStreak >= 2 && _slowCount == 0) {
        _set(ConnState.connected, 'Link recovered');
      } else if (_state == ConnState.connected && _slowCount >= 3) {
        _set(ConnState.degraded, 'The Hub is responding slowly');
      }
      notifyListeners();
    } catch (e) {
      if (link != _link) return;
      final h = toHubException(e);
      if (h.kind == HubError.auth) {
        _set(ConnState.authenticationRequired, 'The token no longer works');
        history.add('auth_failed', 'Token rejected', deviceId: _device?.id ?? '');
        return;
      }
      _noteFailure('ping: $h');
    } finally {
      _pinging = false;
      _scheduleHealth();
    }
  }

  void _noteFailure(String what) {
    _okStreak = 0;
    _consecutiveFails++;
    log.w('conn', 'failure $_consecutiveFails: $what');
    if (_consecutiveFails >= 3) {
      _lost('The Hub stopped responding');
    } else if (_state == ConnState.connected) {
      _set(ConnState.degraded, 'The Hub is slow to answer');
    }
    _scheduleHealth();
  }

  void _onCommandResult(bool ok, Object? err) {
    if (ok) {
      if (_consecutiveFails > 0) _consecutiveFails = 0;
      lastOkAt = DateTime.now();
      if (_state == ConnState.degraded) {
        _okStreak++;
        if (_okStreak >= 2) _set(ConnState.connected, 'Link recovered');
      }
    } else if (canSend) {
      _noteFailure('command: $err');
    }
  }

  /// Re-reads scenes and the current scene (after the board reported a change).
  Future<void> refreshData() async {
    final l = _link;
    if (l == null || !canSend) return;
    try {
      data = await l.list();
      notifyListeners();
    } catch (e) {
      log.d('conn', 'refresh failed: $e');
    }
  }

  // ---------------------------------------------------------------- losing and regaining the link
  void _lost(String why) {
    if (_state == ConnState.reconnecting || _state == ConnState.unavailable) return;
    history.add('disconnected', why, deviceId: _device?.id ?? '');
    queue.bumpEpoch(HubError.unreachable);
    _startReconnect(why);
  }

  void _startReconnect(String why) {
    final d = _device;
    if (d == null) return;
    _healthTimer?.cancel();
    final id = ++_loopId;
    if (_state != ConnState.reconnecting) {
      if (!_set(ConnState.reconnecting, why)) return;
    } else {
      _reason = why;
      notifyListeners();
    }
    unawaited(_reconnectLoop(id));
  }

  Duration _delay(int attempt) {
    final base = backoff[math.min(attempt, backoff.length - 1)];
    final jitter = 0.8 + _rnd.nextDouble() * 0.4; // +-20 %: many phones must not retry in lockstep
    return Duration(milliseconds: (base.inMilliseconds * jitter).round());
  }

  Future<void> _reconnectLoop(int id) async {
    while (id == _loopId && _foreground && _state == ConnState.reconnecting) {
      final d = _device;
      if (d == null) return;
      // no usable network: wait for the network monitor instead of burning battery
      if (!net.hasLan) {
        _set(ConnState.unavailable, 'Your phone isn\'t on a Wi-Fi network');
        return;
      }
      if (reconnectAttempt >= maxAttempts) {
        _set(ConnState.unavailable, 'Your Hub isn\'t responding');
        return;
      }
      final wait = _delay(reconnectAttempt);
      nextRetryAt = DateTime.now().add(wait);
      notifyListeners();
      _wake = Completer<void>();
      await Future.any([Future.delayed(wait), _wake!.future]);
      if (id != _loopId || !_foreground) return;
      reconnectAttempt++;
      // 1. the saved address (cheap)
      var r = await _tryHost(d, _device?.host ?? '', id);
      if (id != _loopId) return;
      if (r == _Open.ok || r == _Open.auth) return;
      // away from home: after a few misses try the MQTT broker, when this Hub has one set up
      if (reconnectAttempt >= 4 && (_device?.host ?? '') != 'mqtt' && await registry.mqttConfig(d.id) != null) {
        r = await _tryHost(d, 'mqtt', id);
        if (id != _loopId) return;
        if (r == _Open.ok || r == _Open.auth) return;
      }
      // 2. find it by identity: it may have a new address
      FoundBoard? found;
      await for (final f in discovery.scan(hints: [KnownHint(d.id, d.host, d.hostname)], wantId: d.id, budget: const Duration(seconds: 4))) {
        if (f.id == d.id && !f.ap) {
          found = f;
          break;
        }
      }
      if (id != _loopId) return;
      if (found != null) {
        r = await _tryHost(d, found.host, id);
        if (id != _loopId) return;
        if (r == _Open.ok || r == _Open.auth) return;
      }
    }
  }

  void _resume() {
    final d = _device;
    if (d == null) return;
    switch (_state) {
      case ConnState.connected:
      case ConnState.degraded:
        unawaited(_healthTick());
        _scheduleHealth();
      case ConnState.reconnecting:
      case ConnState.unavailable:
      case ConnState.networkSwitching:
      case ConnState.connecting:
      case ConnState.authenticating:
        reconnectAttempt = 0;
        _startReconnectFromAnyState('Back in the app');
      default:
        break;
    }
  }

  void _startReconnectFromAnyState(String why) {
    if (_state == ConnState.reconnecting) {
      _startReconnect(why);
    } else if (_state == ConnState.unavailable || _state == ConnState.networkSwitching || _state == ConnState.connecting || _state == ConnState.authenticating) {
      if (_set(ConnState.reconnecting, why)) {
        final id = ++_loopId;
        unawaited(_reconnectLoop(id));
      }
    }
  }

  // ---------------------------------------------------------------- phone network changes
  void _onNet(NetEvent e) {
    _netEvents.add(e);
    final was = net;
    net = e.info;
    log.d('net', '${e.type}/${e.state} wifi=${net.wifi} cell=${net.cellular} validated=${net.validated} nets=${net.prefixes}');
    if (e.type == 'wifi' && e.state == 'lost') {
      history.add('wifi_changed', 'Phone left Wi-Fi', deviceId: _device?.id ?? '');
      if (_device != null && (canSend || _state == ConnState.reconnecting || _state == ConnState.connecting)) {
        _loopId++;
        _healthTimer?.cancel();
        queue.bumpEpoch(HubError.noNetwork);
        _set(ConnState.networkSwitching, 'Your phone left the Wi-Fi network');
      }
    } else if (e.type == 'wifi' && (e.state == 'available' || e.state == 'changed')) {
      final changed = was.prefixes.join() != net.prefixes.join();
      if (changed) history.add('wifi_changed', 'Phone joined ${net.prefixes.join(', ')}.x', deviceId: _device?.id ?? '');
      if (_device != null && _foreground && _state != ConnState.provisioning && _state != ConnState.firmwareUpdating) {
        // a new network or a new phone address: the saved board address may be wrong now, search straight away
        reconnectAttempt = 0;
        if (_state == ConnState.connected || _state == ConnState.degraded) {
          if (changed) {
            _healthTimer?.cancel();
            _startReconnect('Your phone changed networks');
          }
        } else {
          _startReconnectFromAnyState('Network is back');
          _wakeUp();
        }
      }
    }
  }

  // ---------------------------------------------------------------- commands
  /// Sends one command through the queue (request id, retry policy, timeout, priority).
  Future<Map<String, dynamic>> send(
    Map<String, dynamic> body, {
    CmdPriority priority = CmdPriority.normal,
    bool idempotent = false,
    String? dedupeKey,
    Duration timeout = const Duration(seconds: 8),
    int retries = 1,
  }) {
    if (!canSend) {
      return Future.error(HubException(net.hasLan ? HubError.unreachable : HubError.noNetwork, 'state ${_state.name}'));
    }
    return queue.submit(body, priority: priority, idempotent: idempotent, dedupeKey: dedupeKey, timeout: timeout, retries: retries);
  }

  /// Convenience for screens: true when the board accepted it. Failures are logged and the friendly text is returned via [onError].
  Future<bool> trySend(Map<String, dynamic> body, {void Function(String message)? onError, bool idempotent = false, String? dedupeKey, CmdPriority priority = CmdPriority.normal}) async {
    try {
      await send(body, idempotent: idempotent, dedupeKey: dedupeKey, priority: priority);
      return true;
    } catch (e) {
      log.w('cmd', '${body['cmd']} failed: ${toHubException(e)}');
      onError?.call(friendlyError(e));
      return false;
    }
  }

  Future<Map<String, dynamic>> _execute(Map<String, dynamic> body, Duration timeout) {
    final l = _link;
    if (l == null) return Future.error(HubException(HubError.unreachable, 'no link'));
    return l.cmd(body, timeout: timeout);
  }

  // ---------------------------------------------------------------- discovery for the welcome screen
  Future<void> startDiscovery({bool sweep = true}) async {
    if (searching) return;
    searching = true;
    if (_state == ConnState.disconnected || _state == ConnState.unavailable || _state == ConnState.deviceFound) _set(ConnState.discovering, 'Searching nearby');
    notifyListeners();
    final hints = registry.devices.map((d) => KnownHint(d.id, d.host, d.hostname)).toList();
    try {
      await for (final f in discovery.scan(hints: hints, sweep: sweep)) {
        final i = nearby.indexWhere((x) => x.id == f.id);
        if (i >= 0) {
          nearby[i] = f;
        } else {
          nearby = [...nearby, f];
        }
        if (_state == ConnState.discovering && !f.ap) _set(ConnState.deviceFound, 'Found ${f.name}');
        notifyListeners();
      }
    } finally {
      searching = false;
      if (_state == ConnState.discovering) _set(nearby.isEmpty ? ConnState.unavailable : ConnState.deviceFound, nearby.isEmpty ? 'No Hub found' : '');
      notifyListeners();
    }
  }

  /// Called after the registry changed (favourites, name) so the screens rebuild.
  void deviceChanged() {
    _device = registry.byId(_device?.id) ?? _device;
    notifyListeners();
  }

  void clearNearby() {
    nearby = [];
    notifyListeners();
  }

  // ---------------------------------------------------------------- authentication
  /// Stores a token the user typed or scanned, then re-verifies.
  Future<void> submitToken(String token) async {
    final d = _device;
    if (d == null) return;
    await registry.setToken(d.id, token.trim());
    _loopId++;
    if (_state == ConnState.authenticationRequired) _set(ConnState.authenticating, 'Checking the token');
    final id = _loopId;
    final r = await _tryHost(d, d.host, id);
    if (r == _Open.unreachable) _startReconnect('The Hub did not answer');
  }

  /// A token changed on the board (lock / rotate): keep talking with the new one.
  Future<void> adoptToken(String token) async {
    final d = _device;
    if (d == null) return;
    await registry.setToken(d.id, token);
    final h = _link?.host;
    if (h != null) {
      _link?.close();
      _link = _linkFactory(h, token, d.id);
    }
    _bridge.setConfig({'token': token});
    notifyListeners();
  }

  // ---------------------------------------------------------------- provisioning / firmware hooks
  /// Wi-Fi setup takes over: the monitor and retries stop until [endProvisioning].
  void beginProvisioning() {
    _loopId++;
    _healthTimer?.cancel();
    queue.bumpEpoch();
    if (_state != ConnState.provisioning) _set(_canGo(ConnState.provisioning) ? ConnState.provisioning : _state, 'Setting up Wi-Fi');
  }

  bool _canGo(ConnState s) => canTransition(_state, s);

  /// Setup finished. If a board was paired, connect to it; otherwise go back to idle.
  Future<void> endProvisioning(HubDevice? paired) async {
    if (paired != null) {
      history.add('provisioned', '${paired.name} joined Wi-Fi', deviceId: paired.id);
      if (_state == ConnState.provisioning) _set(ConnState.connecting, 'Opening the new Hub');
      await connectDevice(paired);
    } else if (_state == ConnState.provisioning) {
      _device == null ? _set(ConnState.disconnected) : _set(ConnState.connecting, 'Resuming');
      if (_device != null) await _openAndVerify(reason: 'Resuming');
    }
  }

  /// An OTA upload is about to start: stop probing so the board is not disturbed.
  void beginFirmwareUpdate() {
    _healthTimer?.cancel();
    _loopId++;
    queue.bumpEpoch();
    _set(ConnState.firmwareUpdating, 'Installing firmware');
  }

  /// After the upload the board restarts: reconnect and check which firmware is running.
  Future<String?> finishFirmwareUpdate() async {
    final d = _device;
    if (d == null) return null;
    history.add('rebooted', 'Restarting after the update', deviceId: d.id);
    if (_set(ConnState.reconnecting, 'The Hub is restarting')) {
      reconnectAttempt = 0;
      final id = ++_loopId;
      unawaited(_reconnectLoop(id));
    }
    for (var i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 750));
      if (_state == ConnState.connected) return _device?.fw;
    }
    return null;
  }

  /// The user picked "disconnect" / "switch Hub".
  Future<void> disconnect({bool forget = false}) async {
    _loopId++;
    _healthTimer?.cancel();
    queue.bumpEpoch();
    final d = _device;
    _link?.close();
    _link = null;
    if (forget && d != null) await registry.remove(d.id);
    _device = forget ? registry.selected : null;
    if (!forget) await registry.select(null);
    data = {};
    _set(ConnState.disconnected, '');
  }

  // ---------------------------------------------------------------- report
  String diagnosticsReport() {
    final d = _device;
    return log.export(header: {
      'App state': _state.name,
      'Reason': _reason,
      'Device id': d?.id ?? '-',
      'Firmware': d?.fw ?? '-',
      'API version': '${d?.apiVersion ?? '-'}',
      'Latency ms': '$latencyMs',
      'Last OK': lastOkAt?.toIso8601String() ?? '-',
      'Phone networks': net.prefixes.join(', '),
      'Discovery': discovery.lastStats.toString(),
    });
  }
}

enum _Open { ok, unreachable, wrongDevice, auth, cancelled }

/// Gives every screen access to the one [ConnectionManager].
class HubScope extends InheritedNotifier<ConnectionManager> {
  const HubScope({super.key, required ConnectionManager manager, required super.child}) : super(notifier: manager);

  static ConnectionManager of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HubScope>()!.notifier!;

  /// Read without rebuilding when it changes.
  static ConnectionManager read(BuildContext context) => (context.getInheritedWidgetOfExactType<HubScope>()!).notifier!;
}
