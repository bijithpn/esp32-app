import 'package:flutter/material.dart';

import '../core/app_prefs.dart';
import '../core/catalog.dart';
import '../core/connection.dart';
import '../theme.dart';

IconData presetIcon(String name) => switch (name) {
      'work' => Icons.work_outline_rounded,
      'spa' => Icons.spa_outlined,
      'night' => Icons.nightlight_outlined,
      _ => Icons.tune_rounded,
    };

/// Saved sets of settings. Work, Relax and Night come with the app; your own can be added.
/// Night dims the picture in software (the Hub's backlight is wired straight to 3V3, so there is no hardware brightness).
class PresetsScreen extends StatefulWidget {
  const PresetsScreen({super.key});
  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  String? _running;

  Future<void> _apply(Preset p) async {
    final hub = HubScope.read(context);
    setState(() => _running = p.id);
    var ok = true;
    for (final c in p.commands) {
      ok = await hub.trySend(c, onError: (m) => toast(context, m));
      if (!ok) break;
    }
    if (mounted) {
      setState(() => _running = null);
      if (ok) toast(context, '${p.name} is on');
      hub.refreshData();
    }
  }

  Future<void> _edit() async {
    final hub = HubScope.read(context);
    final scenes = ((hub.data['scenes'] as List?) ?? const []).where((s) => !systemScenes.contains(s['id'])).toList();
    final name = TextEditingController();
    String? scene;
    var auto = 0, dim = 0;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('New preset', style: Ty.h2),
              const SizedBox(height: 14),
              TextField(controller: name, maxLength: 20, decoration: const InputDecoration(labelText: 'Name', counterText: '')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: scene,
                decoration: const InputDecoration(labelText: 'Scene'),
                items: [for (final s in scenes) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}'))],
                onChanged: (v) => set(() => scene = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: auto,
                decoration: const InputDecoration(labelText: 'Auto-rotate'),
                items: const [DropdownMenuItem(value: 0, child: Text('Off')), DropdownMenuItem(value: 10, child: Text('Every 10 seconds')), DropdownMenuItem(value: 30, child: Text('Every 30 seconds')), DropdownMenuItem(value: 60, child: Text('Every minute'))],
                onChanged: (v) => set(() => auto = v ?? 0),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: dim,
                decoration: const InputDecoration(labelText: 'Dim the picture (software)'),
                items: const [DropdownMenuItem(value: 0, child: Text('Off')), DropdownMenuItem(value: 1, child: Text('A little')), DropdownMenuItem(value: 2, child: Text('Half')), DropdownMenuItem(value: 3, child: Text('Very dim'))],
                onChanged: (v) => set(() => dim = v ?? 0),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  if (name.text.trim().isEmpty) {
                    toast(ctx, 'Give the preset a name.');
                  } else {
                    Navigator.pop(ctx, true);
                  }
                },
                child: const Text('Save preset'),
              ),
            ]),
          ),
        ),
      ),
    );
    final n = name.text.trim();
    name.dispose();
    if (saved == true && n.isNotEmpty && mounted) {
      await PrefsScope.read(context).savePreset(Preset(id: 'u${DateTime.now().millisecondsSinceEpoch}', name: n, icon: 'tune', note: [if (scene != null) sceneInfo(scene!).blurb, if (dim > 0) 'dimmed'].where((e) => e.isNotEmpty).join(' · '), commands: [
        {'cmd': 'dim', 'level': dim},
        {'cmd': 'auto', 'sec': auto},
        if (scene != null) {'cmd': 'scene', 'id': scene},
      ]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final prefs = PrefsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Presets'), actions: [IconButton(tooltip: 'New preset', onPressed: _edit, icon: const Icon(Icons.add_rounded))]),
      body: ListView(padding: Sp.page, children: [
        const Hint('A preset changes several things at once. Tap one to apply it to your Hub.'),
        const SizedBox(height: 16),
        for (final p in prefs.presets)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Panel(
              onTap: hub.canSend && _running == null ? () => _apply(p) : null,
              child: Row(children: [
                Icon(presetIcon(p.icon), color: HubColors.text),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(p.name, style: Ty.title), if (p.note.isNotEmpty) Text(p.note, style: Ty.secondary)])),
                if (_running == p.id) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) else if (!p.builtin) IconButton(tooltip: 'Delete ${p.name}', icon: const Icon(Icons.delete_outline_rounded, color: HubColors.muted), onPressed: () => prefs.deletePreset(p.id)) else chevron,
              ]),
            ),
          ),
        const SizedBox(height: 8),
        const Hint('"Night" darkens the picture in software. The Hub\'s backlight is wired straight to the power rail, so its true brightness can\'t be changed.'),
      ]),
    );
  }
}
