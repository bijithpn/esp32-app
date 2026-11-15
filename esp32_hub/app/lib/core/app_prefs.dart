import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A one-tap action for the dashboard: a few commands sent in order.
class QuickAction {
  const QuickAction(this.id, this.label, this.icon, this.commands);
  final String id, label, icon;
  final List<Map<String, dynamic>> commands;
}

const quickActionLibrary = <QuickAction>[
  QuickAction('clock', 'Show clock', 'schedule', [{'cmd': 'scene', 'id': 'clock'}]),
  QuickAction('pomo', 'Start focus', 'timer', [{'cmd': 'pomo', 'action': 'start'}]),
  QuickAction('weather', 'Show weather', 'cloud', [{'cmd': 'scene', 'id': 'weather'}]),
  QuickAction('happy', 'Happy eyes', 'mood', [{'cmd': 'mood', 'mood': 'happy'}]),
  QuickAction('sleepy', 'Sleepy eyes', 'bedtime', [{'cmd': 'mood', 'mood': 'sleepy'}]),
  QuickAction('next', 'Next scene', 'skip', [{'cmd': 'next'}]),
  QuickAction('pairing', 'Pairing mode', 'wifi', [{'cmd': 'pairing'}]),
];

/// A saved set of settings: which scene, auto-rotate, software dimming.
class Preset {
  Preset({required this.id, required this.name, required this.icon, required this.commands, this.builtin = false, this.note = ''});
  final String id, name, icon, note;
  final List<Map<String, dynamic>> commands;
  final bool builtin;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'icon': icon, 'cmds': commands, 'note': note};
  static Preset? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String || j['cmds'] is! List) return null;
    final cmds = <Map<String, dynamic>>[];
    for (final c in j['cmds'] as List) {
      if (c is Map && c['cmd'] is String) cmds.add(c.cast<String, dynamic>());
    }
    return Preset(id: j['id'] as String, name: j['name'] as String, icon: '${j['icon'] ?? 'tune'}', commands: cmds, note: '${j['note'] ?? ''}');
  }
}

/// Presets that ship with the app. "Night" dims the picture in software: the Hub's backlight is wired to 3V3, so there
/// is no hardware brightness control.
final builtinPresets = <Preset>[
  Preset(id: 'work', name: 'Work', icon: 'work', builtin: true, note: 'Pomodoro timer, no auto-rotate, full colour', commands: [
    {'cmd': 'dim', 'level': 0},
    {'cmd': 'auto', 'sec': 0},
    {'cmd': 'pomo', 'action': 'show'},
  ]),
  Preset(id: 'relax', name: 'Relax', icon: 'spa', builtin: true, note: 'Ambient scenes, slow rotation', commands: [
    {'cmd': 'dim', 'level': 0},
    {'cmd': 'scene', 'id': 'plasma'},
    {'cmd': 'auto', 'sec': 60},
  ]),
  Preset(id: 'night', name: 'Night', icon: 'night', builtin: true, note: 'Clock, dimmed in software, no motion', commands: [
    {'cmd': 'dim', 'level': 2},
    {'cmd': 'auto', 'sec': 0},
    {'cmd': 'scene', 'id': 'clock'},
  ]),
];

/// App-side preferences that are not tied to one board: dashboard shortcuts, saved presets, notification privacy.
class AppPrefs extends ChangeNotifier {
  static const _kQuick = 'quick_actions_v1', _kPresets = 'presets_v1', _kHide = 'notif_hide_content', _kBlocked = 'notif_blocked';

  List<String> quickIds = ['clock', 'pomo', 'weather', 'happy'];
  List<Preset> custom = [];
  bool hideContent = false;
  Set<String> blocked = {};

  List<QuickAction> get quick => [for (final id in quickIds) ...quickActionLibrary.where((q) => q.id == id)];
  List<Preset> get presets => [...builtinPresets, ...custom];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final q = p.getStringList(_kQuick);
    if (q != null) quickIds = q.where((id) => quickActionLibrary.any((a) => a.id == id)).toList();
    custom = [];
    final raw = p.getString(_kPresets);
    if (raw != null) {
      try {
        for (final j in jsonDecode(raw) as List) {
          final pr = Preset.fromJson(j);
          if (pr != null) custom.add(pr);
        }
      } catch (_) {
        // a corrupt list is dropped; built-in presets are not stored
      }
    }
    hideContent = p.getBool(_kHide) ?? false;
    blocked = (p.getStringList(_kBlocked) ?? const []).toSet();
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kQuick, quickIds);
    await p.setString(_kPresets, jsonEncode(custom.map((e) => e.toJson()).toList()));
    await p.setBool(_kHide, hideContent);
    await p.setStringList(_kBlocked, blocked.toList());
  }

  Future<void> setQuick(List<String> ids) async {
    quickIds = ids.take(6).toList();
    notifyListeners();
    await _save();
  }

  Future<void> savePreset(Preset p) async {
    custom = [...custom.where((x) => x.id != p.id), p];
    notifyListeners();
    await _save();
  }

  Future<void> deletePreset(String id) async {
    custom = custom.where((x) => x.id != id).toList();
    notifyListeners();
    await _save();
  }

  Future<void> setHideContent(bool v) async {
    hideContent = v;
    notifyListeners();
    await _save();
  }

  Future<void> setBlocked(Set<String> v) async {
    blocked = v;
    notifyListeners();
    await _save();
  }
}

/// Gives screens access to the one [AppPrefs] (dashboard shortcuts, presets, notification privacy).
class PrefsScope extends InheritedNotifier<AppPrefs> {
  const PrefsScope({super.key, required AppPrefs prefs, required super.child}) : super(notifier: prefs);
  static AppPrefs of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PrefsScope>()!.notifier!;
  static AppPrefs read(BuildContext context) => context.getInheritedWidgetOfExactType<PrefsScope>()!.notifier!;
}
