import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/catalog.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../theme.dart';

/// One mood as a small tile. The selected tile animates; the others hold a single frame.
class MoodTile extends StatelessWidget {
  const MoodTile({super.key, required this.mood, required this.selected, required this.onTap, this.compact = false});
  final String mood;
  final bool selected, compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = mood[0].toUpperCase() + mood.substring(1);
    final spec = moodSpecs[mood];
    return Semantics(
      button: true,
      selected: selected,
      label: '$name mood',
      child: Choice(
        selected: selected,
        onTap: onTap,
        padding: const EdgeInsets.all(6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 160 / 128,
              child: ExcludeSemantics(
                child: mood == 'auto'
                    ? Container(color: HubColors.screen, child: const Center(child: Icon(Icons.auto_awesome_rounded, color: HubColors.muted, size: 22)))
                    : selected
                        ? FaceScreen(mood: mood)
                        : CustomPaint(painter: _StillFace(mood)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (spec != null) Container(width: 7, height: 7, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: spec.color, shape: BoxShape.circle)),
            Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Ty.meta.copyWith(color: selected ? HubColors.text : HubColors.muted))),
          ]),
        ]),
      ),
    );
  }
}

class _StillFace extends CustomPainter {
  _StillFace(this.mood);
  final String mood;
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = HubColors.screen);
    final u = s.width / 160;
    paintFace(c, mood, s.width / 2, s.height / 2 - 8 * u, u, 1.3);
  }

  @override
  bool shouldRepaint(_StillFace old) => old.mood != mood;
}

/// Mood selector with the 13 moods of the Robot Eyes scene. The choice shows at once and is rolled back if the Hub refuses.
class RobotEyesScreen extends StatefulWidget {
  const RobotEyesScreen({super.key});
  @override
  State<RobotEyesScreen> createState() => _RobotEyesScreenState();
}

class _RobotEyesScreenState extends State<RobotEyesScreen> {
  String _mood = 'auto';

  Future<void> _set(String m) async {
    final hub = HubScope.read(context);
    final before = _mood;
    HapticFeedback.selectionClick();
    setState(() => _mood = m); // optimistic
    try {
      await hub.send({'cmd': 'mood', 'mood': m == 'auto' ? 'normal' : m}, dedupeKey: 'mood');
      hub.data['scene'] = 'eyes';
    } catch (e) {
      if (!mounted) return;
      setState(() => _mood = before); // rollback
      toast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Robot eyes')),
        body: ListView(padding: Sp.page, children: [
          DisplayFrame(child: AnimatedSwitcher(duration: motion(context, Motion.card), child: KeyedSubtree(key: ValueKey(_mood), child: FaceScreen(mood: _mood == 'auto' ? 'normal' : _mood)))),
          const SizedBox(height: 8),
          const Center(child: Text('Illustration of the display', style: Ty.meta)),
          const SectionTitle('Mood'),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.98,
            children: [for (final m in moodsAll) MoodTile(mood: m, selected: _mood == m, onTap: () => _set(m))],
          ),
          const SizedBox(height: 16),
          const Hint('Auto lets the Hub change its face by itself.'),
        ]),
      );
}
