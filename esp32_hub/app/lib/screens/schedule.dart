import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../theme.dart';

class _Item {
  _Item({required this.h, required this.m, required this.days, required this.scene, this.mood = ''});
  int h, m, days; // days: bit 0 = Sunday ... bit 6 = Saturday (the board's tm_wday)
  String scene, mood;
  Map<String, dynamic> toJson() => {'h': h, 'm': m, 'd': days, 's': scene, if (mood.isNotEmpty) 'mood': mood};
  static _Item from(Map j) => _Item(h: (j['h'] as num).toInt(), m: (j['m'] as num).toInt(), days: (j['d'] as num?)?.toInt() ?? 127, scene: '${j['s']}', mood: '${j['mood'] ?? ''}');
}

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

String daysText(int d) {
  if (d == 127) return 'Every day';
  if (d == 62) return 'Weekdays';
  if (d == 65) return 'Weekends';
  return [for (var i = 0; i < 7; i++) if (d & (1 << i) != 0) _dayNames[i]].join(' ');
}

/// Scene schedule, stored and run by the Hub itself (so it works with the phone off). It needs the Hub to know the time:
/// the Hub gets it from the internet after every restart, so a schedule waits until then. Up to 8 entries.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});
  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  List<_Item> _items = [];
  bool _loading = true, _timeSynced = true, _legacy = false, _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final hub = HubScope.read(context);
    setState(() { _loading = true; _error = null; });
    try {
      final r = await hub.send({'cmd': 'sched', 'action': 'get'}, idempotent: true);
      if (!mounted) return;
      setState(() {
        _items = [for (final e in (r['items'] as List? ?? const [])) _Item.from(e as Map)];
        _timeSynced = r['timeSynced'] != false;
        _legacy = false;
      });
    } catch (e) {
      if (!mounted) return;
      final h = toHubException(e);
      setState(() {
        _legacy = h.kind == HubError.deviceError;
        _error = _legacy ? null : friendlyError(e);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _save(List<_Item> next) async {
    final hub = HubScope.read(context);
    setState(() => _saving = true);
    try {
      final r = await hub.send({'cmd': 'sched', 'action': 'set', 'items': next.map((e) => e.toJson()).toList()}, idempotent: true);
      if (!mounted) return false;
      setState(() { _items = [for (final e in (r['items'] as List? ?? const [])) _Item.from(e as Map)]; _timeSynced = r['timeSynced'] != false; });
      return true;
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([_Item? it, int? index]) async {
    final hub = HubScope.read(context);
    final scenes = ((hub.data['scenes'] as List?) ?? const []).where((s) => !systemScenes.contains(s['id'])).toList();
    var item = it == null ? _Item(h: 7, m: 30, days: 127, scene: scenes.isEmpty ? 'clock' : '${scenes.first['id']}') : _Item(h: it.h, m: it.m, days: it.days, scene: it.scene, mood: it.mood);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(it == null ? 'New schedule' : 'Edit schedule', style: Ty.h2),
              const SizedBox(height: 16),
              Panel(
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: TimeOfDay(hour: item.h, minute: item.m));
                  if (t != null) set(() { item.h = t.hour; item.m = t.minute; });
                },
                child: Row(children: [const Icon(Icons.schedule_rounded, color: HubColors.muted), const SizedBox(width: 14), const Expanded(child: Text('Time', style: Ty.bodyStrong)), Text('${item.h.toString().padLeft(2, '0')}:${item.m.toString().padLeft(2, '0')}', style: Ty.title)]),
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var i = 0; i < 7; i++) FilterChip(label: Text(_dayNames[i]), selected: item.days & (1 << i) != 0, onSelected: (v) => set(() => item.days = v ? item.days | (1 << i) : item.days & ~(1 << i))),
              ]),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: scenes.any((s) => s['id'] == item.scene) ? item.scene : null,
                decoration: const InputDecoration(labelText: 'Show'),
                items: [for (final s in scenes) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}'))],
                onChanged: (v) => set(() { item.scene = v ?? item.scene; if (item.scene != 'eyes') item.mood = ''; }),
              ),
              if (item.scene == 'eyes') ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: item.mood.isEmpty ? 'auto' : item.mood,
                  decoration: const InputDecoration(labelText: 'Mood'),
                  items: [for (final m in moodsAll) DropdownMenuItem(value: m, child: Text(m[0].toUpperCase() + m.substring(1)))],
                  onChanged: (v) => set(() => item.mood = v == 'auto' ? '' : (v ?? '')),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton(onPressed: item.days == 0 ? null : () => Navigator.pop(ctx, true), child: const Text('Save')),
              if (it != null) TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Delete', style: TextStyle(color: HubColors.danger))),
            ]),
          ),
        ),
      ),
    );
    if (ok == null) return;
    final next = [..._items];
    if (ok) {
      index == null ? next.add(item) : next[index] = item;
    } else if (index != null) {
      next.removeAt(index);
    }
    await _save(next);
  }

  Future<void> _template(_Item t) async {
    if (_items.length >= 8) {
      toast(context, 'The Hub holds up to 8 schedules.');
      return;
    }
    await _save([..._items, t]);
  }

  String _sceneName(String id) {
    final hub = HubScope.read(context);
    for (final s in (hub.data['scenes'] as List? ?? const [])) {
      if (s['id'] == id) return '${s['name']}';
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule'), actions: [IconButton(tooltip: 'Add', onPressed: hub.canSend && !_saving && _items.length < 8 && !_legacy ? () => _edit() : null, icon: const Icon(Icons.add_rounded))]),
      body: _loading
          ? StateView.loading('Reading the schedule')
          : _legacy
              ? StateView.empty('Needs newer firmware', message: 'Scheduling is stored on the Hub. Update its firmware to 0.6 or newer from Settings > Device > Firmware.', icon: Icons.system_update_alt_rounded)
              : _error != null
                  ? StateView.error(_error!, onRetry: _load)
                  : ListView(padding: Sp.page, children: [
                      if (!_timeSynced) ...[
                        Panel(color: HubColors.warn.withValues(alpha: 0.07), borderColor: HubColors.warn.withValues(alpha: 0.3), child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.schedule_send_outlined, color: HubColors.warn), SizedBox(width: 12), Expanded(child: Text('The Hub doesn\'t know the time yet. It gets it from the internet a few seconds after it joins Wi-Fi. Schedules start working once it does.', style: Ty.secondary))])),
                        const SizedBox(height: 16),
                      ],
                      if (_items.isEmpty) ...[
                        const Text('Nothing scheduled', style: Ty.title),
                        const SizedBox(height: 6),
                        const Hint('Pick a scene for a time of day. The Hub runs it by itself, even when your phone is away.'),
                        const SectionTitle('Ideas'),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          _Idea('Clock in the morning', () => _template(_Item(h: 7, m: 0, days: 62, scene: 'clock'))),
                          _Idea('Weather before work', () => _template(_Item(h: 8, m: 0, days: 62, scene: 'weather'))),
                          _Idea('Focus timer at 9', () => _template(_Item(h: 9, m: 0, days: 62, scene: 'pomo'))),
                          _Idea('Ambient in the evening', () => _template(_Item(h: 19, m: 0, days: 127, scene: 'plasma'))),
                          _Idea('Sleepy eyes at night', () => _template(_Item(h: 22, m: 30, days: 127, scene: 'eyes', mood: 'sleepy'))),
                        ]),
                      ] else
                        Group(children: [
                          for (var i = 0; i < _items.length; i++)
                            Row2(
                              icon: Icons.alarm_rounded,
                              title: '${_items[i].h.toString().padLeft(2, '0')}:${_items[i].m.toString().padLeft(2, '0')} · ${_sceneName(_items[i].scene)}${_items[i].mood.isEmpty ? '' : ' (${_items[i].mood})'}',
                              sub: daysText(_items[i].days),
                              trailing: chevron,
                              onTap: () => _edit(_items[i], i),
                            ),
                        ]),
                      const SizedBox(height: 16),
                      const Hint('Times follow the time zone your phone sent to the Hub. After a power cut the Hub needs a moment to learn the time again; schedules are kept.'),
                    ]),
    );
  }
}

class _Idea extends StatelessWidget {
  const _Idea(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ActionChip(label: Text(label), onPressed: onTap);
}
