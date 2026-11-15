import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Masks anything that looks like a secret. Used for every line that is stored or exported.
String redact(String s) {
  var out = s;
  // "token":"abc", "pass": "abc", "api_key":"abc", x-api-key: abc, t=abc, ssid passwords in WIFI: strings
  out = out.replaceAllMapped(
    RegExp(r'''(?<![A-Za-z0-9_])("?(?:token|pass|password|passwd|pwd|key|api[_-]?key|secret|authorization|x-hub-token|x-api-key|t)"?\s*[:=]\s*"?)([^",}&\s;]+)''', caseSensitive: false),
    (m) => '${m.group(1)}***',
  );
  out = out.replaceAllMapped(RegExp(r'sk-ant-[A-Za-z0-9_\-]+'), (_) => 'sk-ant-***');
  out = out.replaceAllMapped(RegExp(r'(P:)([^;]+)(;)'), (m) => '${m.group(1)}***${m.group(3)}');
  return out;
}

enum LogLevel { debug, info, warn, error }

class LogLine {
  LogLine(this.at, this.level, this.tag, this.text);
  final DateTime at;
  final LogLevel level;
  final String tag, text;
  @override
  String toString() => '${at.toIso8601String()} ${level.name.toUpperCase().padRight(5)} [$tag] $text';
}

/// Bounded in-memory log. Nothing sensitive can enter it because [add] redacts first.
class DiagLog {
  DiagLog({this.capacity = 400});
  final int capacity;
  final List<LogLine> _lines = [];

  static final DiagLog instance = DiagLog();

  List<LogLine> get lines => List.unmodifiable(_lines);

  void add(LogLevel level, String tag, String text) {
    _lines.add(LogLine(DateTime.now(), level, tag, redact(text)));
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
    if (kDebugMode) debugPrint('[$tag] ${redact(text)}');
  }

  void d(String tag, String text) => add(LogLevel.debug, tag, text);
  void i(String tag, String text) => add(LogLevel.info, tag, text);
  void w(String tag, String text) => add(LogLevel.warn, tag, text);
  void e(String tag, String text) => add(LogLevel.error, tag, text);

  void clear() => _lines.clear();

  /// Text for sharing. Header lines carry no identifiers beyond what the user already sees in the app.
  String export({Map<String, String> header = const {}}) {
    final b = StringBuffer('ESP32 Hub app diagnostics (secrets removed)\n');
    header.forEach((k, v) => b.writeln('$k: ${redact(v)}'));
    b.writeln();
    for (final l in _lines) {
      b.writeln(l);
    }
    return b.toString();
  }
}

/// A notable connection event for the History screen.
class ConnEvent {
  ConnEvent(this.at, this.kind, this.detail, {this.deviceId = ''});
  final DateTime at;
  final String kind; // connected | disconnected | wifi_changed | auth_failed | rebooted | firmware_updated | ip_changed | provisioned
  final String detail;
  final String deviceId;

  Map<String, dynamic> toJson() => {'t': at.millisecondsSinceEpoch, 'k': kind, 'd': detail, 'id': deviceId};
  static ConnEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['t'];
    if (t is! int) return null;
    return ConnEvent(DateTime.fromMillisecondsSinceEpoch(t), '${j['k']}', '${j['d'] ?? ''}', deviceId: '${j['id'] ?? ''}');
  }
}

/// Last 100 connection events, kept on the phone (no secrets, no passwords).
class ConnHistory extends ChangeNotifier {
  static const _key = 'conn_history_v1';
  static const max = 100;
  final List<ConnEvent> _events = [];
  List<ConnEvent> get events => List.unmodifiable(_events.reversed);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    _events.clear();
    if (raw == null) return;
    try {
      for (final j in jsonDecode(raw) as List) {
        final e = ConnEvent.fromJson(j);
        if (e != null) _events.add(e);
      }
    } catch (_) {
      // a corrupt history is just dropped
    }
    notifyListeners();
  }

  Future<void> add(String kind, String detail, {String deviceId = ''}) async {
    // the same event twice in a row (flapping) is one line
    if (_events.isNotEmpty && _events.last.kind == kind && _events.last.detail == detail && DateTime.now().difference(_events.last.at) < const Duration(minutes: 1)) return;
    _events.add(ConnEvent(DateTime.now(), kind, redact(detail), deviceId: deviceId));
    if (_events.length > max) _events.removeRange(0, _events.length - max);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(_events.map((e) => e.toJson()).toList()));
  }

  Future<void> clear() async {
    _events.clear();
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }
}
