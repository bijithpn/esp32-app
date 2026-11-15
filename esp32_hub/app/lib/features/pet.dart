import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/connection.dart';
import '../previews.dart';
import '../theme.dart';

/// The pixel cat. Hunger and sleep come from the Hub (it is the authority); the buttons send one action each.
class PetScreen extends StatefulWidget {
  const PetScreen({super.key});
  @override
  State<PetScreen> createState() => _PetScreenState();
}

class _PetScreenState extends State<PetScreen> {
  int _hunger = 20;
  bool _asleep = false, _known = false;
  String? _reaction;
  Timer? _poll, _reactionTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await HubScope.read(context).trySend({'cmd': 'pet', 'action': 'show'});
      await _fetch();
    });
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _fetch());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _reactionTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final hub = HubScope.read(context);
    if (!hub.canSend) return;
    try {
      final r = await hub.send({'cmd': 'state'}, idempotent: true, dedupeKey: 'state', retries: 0, timeout: const Duration(seconds: 3));
      final p = r['pet'];
      if (p is Map && mounted) setState(() { _hunger = (p['hunger'] as num).toInt(); _asleep = p['asleep'] == true; _known = true; });
    } catch (_) {
      // an older firmware has no "state": the buttons still work
    }
  }

  Future<void> _act(String a, String reaction) async {
    HapticFeedback.lightImpact();
    final ok = await HubScope.read(context).trySend({'cmd': 'pet', 'action': a}, onError: (m) => toast(context, m));
    if (!ok || !mounted) return;
    setState(() => _reaction = reaction);
    _reactionTimer?.cancel();
    _reactionTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _reaction = null);
    });
    unawaited(_fetch());
  }

  String get _mood => _asleep ? 'Sleeping' : _hunger > 70 ? 'Hungry' : _hunger > 40 ? 'Peckish' : 'Content';

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final can = hub.canSend;
    final fed = (100 - _hunger).clamp(0, 100) / 100;
    final hungry = _hunger > 70;
    return Scaffold(
      appBar: AppBar(title: const Text('Pixel pet')),
      body: ListView(padding: Sp.page, children: [
        Stack(alignment: Alignment.center, children: [
          const DisplayFrame(child: ScenePreview(id: 'pet')),
          Positioned(
            top: 14,
            child: AnimatedSwitcher(
              duration: motion(context, Motion.small),
              child: _reaction == null ? const SizedBox.shrink() : Container(key: ValueKey(_reaction), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)), child: Text(_reaction!, style: Ty.meta.copyWith(color: Colors.white))),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        const Center(child: Text('Illustration of the display', style: Ty.meta)),
        const SizedBox(height: 20),
        Panel(
          child: Column(children: [
            Row(children: [
              const Expanded(child: Text('Fullness', style: Ty.bodyStrong)),
              Text(_known ? _mood : '—', style: Ty.body.copyWith(color: hungry ? HubColors.warn : HubColors.muted)),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _known ? fed : 0),
                duration: motion(context, Motion.card),
                curve: Motion.curve,
                builder: (_, v, __) => LinearProgressIndicator(value: v, minHeight: 8, color: hungry ? HubColors.warn : HubColors.ok, backgroundColor: HubColors.surface2),
              ),
            ),
            const SizedBox(height: 10),
            const Align(alignment: Alignment.centerLeft, child: Text('Gets hungrier by about 1% a minute. Feeding makes it happy.', style: Ty.meta)),
          ]),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _Act(icon: Icons.set_meal_rounded, label: 'Feed', on: can ? () => _act('feed', 'Yum!') : null),
          _Act(icon: Icons.sports_esports_rounded, label: 'Play', on: can ? () => _act('play', 'Wheee!') : null),
          _Act(icon: Icons.favorite_rounded, label: 'Pat', on: can ? () => _act('pat', 'Purr…') : null),
          _Act(icon: Icons.bedtime_rounded, label: 'Sleep', on: can && !_asleep ? () => _act('sleep', 'Zzz') : null),
          _Act(icon: Icons.wb_sunny_rounded, label: 'Wake', on: can && _asleep ? () => _act('wake', 'Good morning') : null),
        ]),
      ]),
    );
  }
}

class _Act extends StatelessWidget {
  const _Act({required this.icon, required this.label, required this.on});
  final IconData icon;
  final String label;
  final VoidCallback? on;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: (MediaQuery.of(context).size.width - 32 - 20) / 3,
        child: OutlinedButton(
          onPressed: on,
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 64), padding: const EdgeInsets.symmetric(vertical: 10)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 22), const SizedBox(height: 4), Text(label, style: const TextStyle(fontSize: 13))]),
        ),
      );
}
