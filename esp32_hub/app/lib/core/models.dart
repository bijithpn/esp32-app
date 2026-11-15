import 'dart:convert';

/// The explicit connection states. Every state has one meaning, a set of valid next states, a timeout and a UI face
/// (see [ConnStateInfo]). The [ConnectionManager] is the only writer.
enum ConnState {
  /// No device selected, or the user disconnected. Nothing is running.
  disconnected,

  /// Looking for boards on the network (no device is verified yet).
  discovering,

  /// A board answered discovery and its identity checked out. Waiting for the user (or auto-connect) to open it.
  deviceFound,

  /// Opening the HTTP link to a chosen board.
  connecting,

  /// Link is up; checking the token / lock state.
  authenticating,

  /// Identity and authentication verified and commands are succeeding.
  connected,

  /// Was connected, but pings or commands are failing or slow. Retrying quickly before declaring the link lost.
  degraded,

  /// The link is lost. Retrying with exponential back-off.
  reconnecting,

  /// The Wi-Fi setup flow owns the connection (hotspot / joining a network).
  provisioning,

  /// The phone changed networks (Wi-Fi lost or switched). Waiting for a usable network, then rediscovering.
  networkSwitching,

  /// The board is locked and this phone has no valid token.
  authenticationRequired,

  /// An over-the-air update is running; the board will restart.
  firmwareUpdating,

  /// Gave up for now: board not found after the retry budget, or the phone has no network.
  unavailable,

  /// Unexpected failure that needs the user (details in diagnostics).
  error,
}

class ConnStateInfo {
  const ConnStateInfo(this.label, this.meaning, this.timeout, this.next);

  /// Short text for the UI.
  final String label;
  final String meaning;

  /// How long the state may last before the manager moves on (null = no limit).
  final Duration? timeout;

  /// Valid transitions out of this state.
  final Set<ConnState> next;
}

const _all = ConnState.values;

/// The transition table. A move that is not listed here is rejected and logged, so the UI can never show a
/// contradictory state (for example "connected" straight after "authenticationRequired" without authenticating).
final Map<ConnState, ConnStateInfo> connStates = {
  ConnState.disconnected: ConnStateInfo('Not connected', 'Nothing selected', null,
      {ConnState.discovering, ConnState.connecting, ConnState.reconnecting, ConnState.provisioning, ConnState.unavailable}),
  ConnState.discovering: ConnStateInfo('Searching', 'Looking for boards', const Duration(seconds: 12),
      {ConnState.deviceFound, ConnState.connecting, ConnState.unavailable, ConnState.disconnected, ConnState.reconnecting, ConnState.provisioning, ConnState.networkSwitching, ConnState.error}),
  ConnState.deviceFound: ConnStateInfo('Hub found', 'A verified board is waiting', null,
      {ConnState.connecting, ConnState.discovering, ConnState.disconnected, ConnState.provisioning, ConnState.unavailable}),
  ConnState.connecting: ConnStateInfo('Connecting', 'Opening the link', const Duration(seconds: 8),
      {ConnState.authenticating, ConnState.reconnecting, ConnState.unavailable, ConnState.disconnected, ConnState.error, ConnState.authenticationRequired, ConnState.networkSwitching, ConnState.provisioning}),
  ConnState.authenticating: ConnStateInfo('Verifying', 'Checking identity and token', const Duration(seconds: 6),
      {ConnState.connected, ConnState.authenticationRequired, ConnState.reconnecting, ConnState.unavailable, ConnState.disconnected, ConnState.error, ConnState.networkSwitching, ConnState.provisioning}),
  ConnState.connected: ConnStateInfo('Connected', 'Verified and responding', null,
      {ConnState.degraded, ConnState.reconnecting, ConnState.disconnected, ConnState.networkSwitching, ConnState.firmwareUpdating, ConnState.provisioning, ConnState.authenticationRequired, ConnState.discovering}),
  ConnState.degraded: ConnStateInfo('Weak link', 'Requests are failing or slow', const Duration(seconds: 6),
      {ConnState.connected, ConnState.reconnecting, ConnState.disconnected, ConnState.networkSwitching, ConnState.firmwareUpdating, ConnState.authenticationRequired, ConnState.provisioning}),
  ConnState.reconnecting: ConnStateInfo('Reconnecting', 'Link lost, retrying', null,
      {ConnState.connecting, ConnState.authenticating, ConnState.connected, ConnState.unavailable, ConnState.networkSwitching, ConnState.disconnected, ConnState.authenticationRequired, ConnState.discovering, ConnState.error, ConnState.firmwareUpdating, ConnState.provisioning}),
  ConnState.provisioning: ConnStateInfo('Setting up', 'Wi-Fi setup in progress', const Duration(minutes: 5),
      {ConnState.connecting, ConnState.connected, ConnState.disconnected, ConnState.discovering, ConnState.unavailable, ConnState.error, ConnState.networkSwitching}),
  ConnState.networkSwitching: ConnStateInfo('Network changed', 'Waiting for a usable network', const Duration(seconds: 20),
      {ConnState.reconnecting, ConnState.discovering, ConnState.connecting, ConnState.unavailable, ConnState.disconnected, ConnState.connected, ConnState.provisioning}),
  ConnState.authenticationRequired: ConnStateInfo('Token needed', 'The board is locked', null,
      {ConnState.authenticating, ConnState.connecting, ConnState.disconnected, ConnState.discovering, ConnState.provisioning}),
  ConnState.firmwareUpdating: ConnStateInfo('Updating', 'Firmware update running', const Duration(minutes: 4),
      {ConnState.reconnecting, ConnState.connected, ConnState.error, ConnState.disconnected, ConnState.unavailable}),
  ConnState.unavailable: ConnStateInfo('Unavailable', 'Not reachable right now', null,
      {ConnState.discovering, ConnState.reconnecting, ConnState.connecting, ConnState.disconnected, ConnState.networkSwitching, ConnState.provisioning}),
  ConnState.error: ConnStateInfo('Problem', 'Needs attention', null, {..._all}),
};

bool canTransition(ConnState from, ConnState to) => from == to || (connStates[from]?.next.contains(to) ?? false);

/// A board the user has paired. Secrets (token, MQTT password) are NOT part of this object: they live in the
/// Android Keystore-backed store, keyed by [id].
class HubDevice {
  HubDevice({
    required this.id,
    this.name = 'ESP32 Hub',
    this.host = '',
    this.fw = '',
    this.apiVersion = 0,
    this.caps = const [],
    this.lastSeen,
    this.lastConnected,
    this.locked = false,
    this.favorites = const [],
  });

  /// The board's 6-character id (from its MAC). The identity everything is verified against.
  final String id;
  final String name, host, fw;
  final int apiVersion;
  final List<String> caps;
  final DateTime? lastSeen, lastConnected;
  final bool locked;
  final List<String> favorites;

  String get hostname => 'esp32-hub-${id.toLowerCase()}.local';

  HubDevice copyWith({String? name, String? host, String? fw, int? apiVersion, List<String>? caps, DateTime? lastSeen, DateTime? lastConnected, bool? locked, List<String>? favorites}) => HubDevice(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        fw: fw ?? this.fw,
        apiVersion: apiVersion ?? this.apiVersion,
        caps: caps ?? this.caps,
        lastSeen: lastSeen ?? this.lastSeen,
        lastConnected: lastConnected ?? this.lastConnected,
        locked: locked ?? this.locked,
        favorites: favorites ?? this.favorites,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'fw': fw,
        'api': apiVersion,
        'caps': caps,
        'seen': lastSeen?.millisecondsSinceEpoch,
        'conn': lastConnected?.millisecondsSinceEpoch,
        'locked': locked,
        'fav': favorites,
      };

  static HubDevice? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    DateTime? ts(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    return HubDevice(
      id: id,
      name: j['name'] is String ? j['name'] as String : 'ESP32 Hub',
      host: j['host'] is String ? j['host'] as String : '',
      fw: j['fw'] is String ? j['fw'] as String : '',
      apiVersion: j['api'] is int ? j['api'] as int : 0,
      caps: j['caps'] is List ? (j['caps'] as List).map((e) => '$e').toList() : const [],
      lastSeen: ts(j['seen']),
      lastConnected: ts(j['conn']),
      locked: j['locked'] == true,
      favorites: j['fav'] is List ? (j['fav'] as List).map((e) => '$e').toList() : const [],
    );
  }

  @override
  String toString() => jsonEncode(toJson());
}

/// A verified answer to GET /api/hello (or a UDP discovery reply).
class FoundBoard {
  FoundBoard({
    required this.host,
    required this.id,
    required this.fw,
    this.name = 'ESP32 Hub',
    this.apiVersion = 0,
    this.ap = false,
    this.lock = false,
    this.online = false,
    this.pairing = false,
    this.caps = const [],
    this.source = '',
    this.latencyMs = 0,
    this.safeMode = false,
  });
  final String host, id, fw, name, source;
  final int apiVersion, latencyMs;
  final bool ap, lock, online, pairing, safeMode;
  final List<String> caps;

  /// A board that is running firmware older than the API v1 handshake (no apiVersion in /api/hello).
  bool get legacy => apiVersion == 0;

  HubDevice toDevice({HubDevice? base}) => (base ?? HubDevice(id: id)).copyWith(name: name, host: host, fw: fw, apiVersion: apiVersion, caps: caps, lastSeen: DateTime.now(), locked: lock);

  /// Identity check: only an ESP32 Hub answers like this. A plain HTTP 200 is not enough: it needs the device marker,
  /// a board id and a firmware version. Returns null for anything else.
  static FoundBoard? parse(String host, String body, {String source = '', int latencyMs = 0}) {
    Object? m;
    try {
      m = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (m is! Map) return null;
    final isHub = m['device'] == 'ESP32-Hub' || m['type'] == 'esp32_hub';
    final id = m['id'];
    final fw = m['fw'] ?? m['firmware'];
    if (!isHub || id is! String || id.isEmpty || fw is! String) return null;
    return FoundBoard(
      host: host,
      id: id.toUpperCase(),
      fw: fw,
      name: m['name'] is String && (m['name'] as String).isNotEmpty ? m['name'] as String : 'ESP32 Hub',
      apiVersion: m['apiVersion'] is int ? m['apiVersion'] as int : 0,
      ap: m['ap'] == true,
      lock: m['lock'] == true,
      online: m['online'] == true,
      pairing: m['pairing'] == true,
      safeMode: m['safeMode'] == true,
      caps: m['caps'] is List ? (m['caps'] as List).map((e) => '$e').toList() : const [],
      source: source,
      latencyMs: latencyMs,
    );
  }
}
