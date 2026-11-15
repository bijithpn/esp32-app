import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../features/features.dart';
import '../previews.dart';
import '../theme.dart';

/// Starts a scene on the Hub. Scenes with their own screen open it; scenes with options ask first. Optimistic: the
/// dashboard shows the new scene at once and rolls back with a message if the Hub refuses.
Future<bool> startScene(BuildContext context, ConnectionManager hub, Map scene, {String mood = 'normal', void Function(String? id)? optimistic}) async {
  final id = '${scene['id']}';
  final page = specialPage(id);
  if (page != null) {
    await Navigator.of(context).push(hubRoute(page));
    hub.refreshData();
    return true;
  }
  final args = (scene['args'] as List?) ?? const [];
  Map<String, dynamic>? values;
  if (args.isNotEmpty && id != 'eyes') {
    values = await showModalBottomSheet<Map<String, dynamic>>(context: context, isScrollControlled: true, builder: (ctx) => _ArgsSheet(scene: scene, args: args));
    if (values == null) return false;
  }
  final prev = '${hub.data['scene']}';
  optimistic?.call(id);
  try {
    await hub.send({'cmd': 'scene', 'id': id, if (id == 'eyes' && mood != 'normal') 'args': {'mood': mood}, 'args': ?values}, dedupeKey: 'scene');
    hub.data['scene'] = id;
    return true;
  } catch (e) {
    optimistic?.call(prev); // roll back the optimistic change
    if (context.mounted) toast(context, friendlyError(e));
    return false;
  }
}

class _ArgsSheet extends StatefulWidget {
  const _ArgsSheet({required this.scene, required this.args});
  final Map scene;
  final List args;
  @override
  State<_ArgsSheet> createState() => _ArgsSheetState();
}

class _ArgsSheetState extends State<_ArgsSheet> {
  final values = <String, dynamic>{};
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${widget.scene['name']}', style: Ty.h2),
          const SizedBox(height: 16),
          for (final a in widget.args) ...[
            if (a['type'] == 'choice')
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final o in a['options'])
                  ChoiceChip(label: Text(o.toString()), selected: values[a['key']] == o, onSelected: (_) => setState(() => values[a['key']] = o)),
              ])
            else
              TextField(maxLength: a['max'] ?? 16, decoration: InputDecoration(labelText: '${a['key']}'.replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase())), onChanged: (v) => values[a['key']] = v),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          FilledButton(onPressed: () => Navigator.pop(context, values), child: const Text('Start')),
        ]),
      );
}

/// A scene as a card: live illustration, name, category, active dot, favourite star.
class SceneCard extends StatelessWidget {
  const SceneCard({super.key, required this.scene, required this.active, required this.favorite, required this.onTap, this.onFavorite, this.enabled = true, this.mood = 'normal'});
  final Map scene;
  final bool active, favorite, enabled;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final String mood;

  @override
  Widget build(BuildContext context) {
    final id = '${scene['id']}';
    final info = sceneInfo(id);
    return Semantics(
      button: true,
      selected: active,
      label: '${scene['name']}, ${info.category.label}${active ? ', showing now' : ''}',
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Choice(
          selected: active,
          onTap: enabled ? onTap : null,
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Stack(children: [
              ClipRRect(borderRadius: BorderRadius.circular(10), child: AspectRatio(aspectRatio: 160 / 128, child: ExcludeSemantics(child: _Still(id: id, active: active, mood: mood)))),
              if (onFavorite != null)
                Positioned(
                  right: 2,
                  top: 2,
                  child: IconButton(
                    tooltip: favorite ? 'Remove from favourites' : 'Add to favourites',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    style: IconButton.styleFrom(backgroundColor: Colors.black45, minimumSize: const Size(32, 32)),
                    icon: Icon(favorite ? Icons.star_rounded : Icons.star_border_rounded, color: favorite ? HubColors.warn : Colors.white70),
                    onPressed: onFavorite,
                  ),
                ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text('${scene['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Ty.bodyStrong)),
              if (active) const Icon(Icons.circle, size: 8, color: HubColors.ok),
            ]),
            const SizedBox(height: 2),
            Text(enabled ? info.category.label : 'Needs newer firmware', maxLines: 1, overflow: TextOverflow.ellipsis, style: Ty.meta),
          ]),
        ),
      ),
    );
  }
}

/// Only the active card animates: a grid of 20 live painters would waste battery for nothing.
class _Still extends StatelessWidget {
  const _Still({required this.id, required this.active, required this.mood});
  final String id, mood;
  final bool active;
  @override
  Widget build(BuildContext context) => active ? ScenePreview(id: id, mood: mood) : _Frozen(id: id);
}

/// A single calm frame of a scene (the painters stop when the platform asks for reduced motion, which gives one frame).
class _Frozen extends StatelessWidget {
  const _Frozen({required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: ScenePreview(id: id),
      );
}
