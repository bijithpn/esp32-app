import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/connection.dart';
import '../theme.dart';
import 'scene_ui.dart';

/// Every scene on the Hub, by category, with favourites on top.
class SceneLibraryScreen extends StatefulWidget {
  const SceneLibraryScreen({super.key, this.mood = 'normal'});
  final String mood;
  @override
  State<SceneLibraryScreen> createState() => _SceneLibraryScreenState();
}

class _SceneLibraryScreenState extends State<SceneLibraryScreen> {
  SceneCategory? _cat;

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final scenes = ((hub.data['scenes'] as List?) ?? const []).where((s) => !systemScenes.contains(s['id'])).toList();
    final current = '${hub.data['scene']}';
    final favs = hub.device?.favorites ?? const <String>[];
    final caps = hub.device?.caps ?? const <String>[];
    bool supported(String id) {
      final need = sceneInfo(id).needs;
      if (need == null || caps.isEmpty) return true; // older firmware reports no capabilities: assume it works
      return caps.contains(need) || caps.contains(need == 'animations' ? 'anim' : need);
    }

    final shown = scenes.where((s) => _cat == null || sceneInfo('${s['id']}').category == _cat).toList();
    final favScenes = scenes.where((s) => favs.contains(s['id'])).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Scenes')),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            _Chip(label: 'All', selected: _cat == null, onTap: () => setState(() => _cat = null)),
            for (final c in SceneCategory.values) _Chip(label: c.label, selected: _cat == c, onTap: () => setState(() => _cat = c)),
          ]),
        ),
        Expanded(
          child: scenes.isEmpty
              ? StateView.empty('No scenes yet', message: 'Connect to a Hub to see its scenes.', icon: Icons.grid_view_rounded)
              : ListView(padding: Sp.page, children: [
                  if (_cat == null && favScenes.isNotEmpty) ...[
                    const SectionTitle('Favourites', top: 8),
                    _Grid(scenes: favScenes, current: current, favs: favs, supported: supported, mood: widget.mood),
                    const SectionTitle('All scenes'),
                  ],
                  _Grid(scenes: shown, current: current, favs: favs, supported: supported, mood: widget.mood),
                ]),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
        child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap(), side: BorderSide(color: selected ? HubColors.text : HubColors.line)),
      );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.scenes, required this.current, required this.favs, required this.supported, required this.mood});
  final List scenes;
  final String current, mood;
  final List<String> favs;
  final bool Function(String) supported;
  @override
  Widget build(BuildContext context) {
    final hub = HubScope.read(context);
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.93,
      children: [
        for (final s in scenes)
          SceneCard(
            scene: s as Map,
            active: current == s['id'],
            favorite: favs.contains(s['id']),
            enabled: supported('${s['id']}'),
            mood: mood,
            onFavorite: hub.device == null ? null : () => hub.registry.toggleFavorite(hub.device!.id, '${s['id']}').then((_) => hub.deviceChanged()),
            onTap: () => startScene(context, hub, s, mood: mood),
          ),
      ],
    );
  }
}
