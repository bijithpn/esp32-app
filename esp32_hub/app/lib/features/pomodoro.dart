import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/connection.dart';
import '../core/errors.dart';
import '../theme.dart';

/// Focus timer. The Hub is the authority: the screen mirrors the Hub's own timer (asked every 3 s and whenever the app comes
/// back), and counts down locally in between. So the time stays correct after the app was closed, the phone went offline or
/// the Hub reconnected: the next answer from the Hub simply replaces what is shown.
class PomodoroScreen extends StatefulWidget {
  const PomodoroScreen({super.key});
  @override
  State<PomodoroScreen> createState() => _PomodoroScreenState();
}

class _PomodoroScreenState extends State<PomodoroScreen> with WidgetsBindingObserver {
  Timer? _poll, _tick;
  bool _running = false, _synced = false, _legacy = false;
  String _mode = 'focus';
  int _remainMs = 25 * 60000, _totalMs = 25 * 60000, _done = 0;
  double _work = 25, _brk = 5;
  DateTime _fetchedAt = DateTime.now();
  int _lastDone = -1;
  String _lastMode = 'focus';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _act('show', quiet: true);
      await _fetch();
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _fetch());
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && _running) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _fetch();
  }

  int get _shownRemain => _running ? math.max(0, _remainMs - DateTime.now().difference(_fetchedAt).inMilliseconds) : _remainMs;

  Future<void> _fetch() async {
    final hub = HubScope.read(context);
    if (!hub.canSend) {
      if (mounted) setState(() => _synced = false);
      return;
    }
    try {
      final r = await hub.send({'cmd': 'state'}, idempotent: true, dedupeKey: 'state', retries: 0, timeout: const Duration(seconds: 3));
      final p = r['pomo'];
      if (p is! Map || !mounted) {
        if (mounted) setState(() => _legacy = true);
        return;
      }
      final done = (p['done'] as num).toInt();
      final mode = '${p['mode']}';
      setState(() {
        _legacy = false;
        _synced = true;
        _running = p['running'] == true;
        _mode = mode;
        _remainMs = (p['remainMs'] as num).toInt();
        _totalMs = math.max(1, (p['totalMs'] as num).toInt());
        _done = done;
        _fetchedAt = DateTime.now();
        if (!_running) {
          _work = (p['workMin'] as num).toDouble().clamp(5, 60);
          _brk = (p['brkMin'] as num).toDouble().clamp(1, 30);
        }
      });
      // session feedback: a focus block finished (the Hub moved on to the break) while this screen was open
      if (_lastDone >= 0 && done > _lastDone) {
        HapticFeedback.heavyImpact();
        if (mounted) toast(context, 'Focus session complete. Time for a break.');
      } else if (_lastMode == 'break' && mode == 'focus' && _lastDone >= 0 && _running) {
        HapticFeedback.mediumImpact();
        if (mounted) toast(context, 'Break over. Ready to focus?');
      }
      _lastDone = done;
      _lastMode = mode;
    } catch (e) {
      final h = toHubException(e);
      if (h.kind == HubError.deviceError) {
        if (mounted) setState(() => _legacy = true); // an older firmware without the "state" command
      } else if (mounted) {
        setState(() => _synced = false);
      }
    }
  }

  Future<void> _act(String a, {bool quiet = false}) async {
    final hub = HubScope.read(context);
    if (_busy) return;
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    final ok = await hub.trySend({'cmd': 'pomo', 'action': a, 'work': _work.round(), 'brk': _brk.round()}, onError: quiet ? null : (m) => toast(context, m));
    if (mounted) setState(() => _busy = false);
    if (ok) await _fetch();
  }

  String _fmt(int ms) {
    final s = (ms / 1000).ceil();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final remain = _shownRemain;
    final progress = 1 - remain / _totalMs;
    final focus = _mode == 'focus';
    final col = focus ? const Color(0xFFFF8A78) : HubColors.ok;
    final started = _running || remain < _totalMs;
    return Scaffold(
      appBar: AppBar(title: const Text('Focus timer'), actions: [if (!_synced && !_legacy) const Padding(padding: EdgeInsets.only(right: 16), child: StatusPill(color: HubColors.warn, label: 'Offline'))]),
      body: ListView(padding: Sp.page, children: [
        const SizedBox(height: 8),
        Center(
          child: Semantics(
            label: '${focus ? 'Focus' : 'Break'}, ${_fmt(remain)} left, ${_running ? 'running' : 'paused'}',
            child: SizedBox(
              width: 280,
              height: 280,
              child: Stack(alignment: Alignment.center, children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: progress.clamp(0.0, 1.0)),
                  duration: motion(context, const Duration(milliseconds: 700)),
                  curve: Motion.curve,
                  builder: (_, v, __) => CustomPaint(size: const Size(280, 280), painter: _Ring(v, col)),
                ),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(focus ? 'FOCUS' : 'BREAK', style: Ty.meta.copyWith(letterSpacing: 2, color: col, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(_fmt(remain), style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w300, letterSpacing: -2, fontFeatures: [FontFeature.tabularFigures()])),
                  const SizedBox(height: 4),
                  Text(_running ? 'Running' : started ? 'Paused' : 'Ready', style: Ty.secondary),
                ]),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: hub.canSend && !_busy ? () => _act(_running ? 'pause' : 'start') : null,
              icon: Icon(_running ? Icons.pause_rounded : Icons.play_arrow_rounded),
              label: Text(_running ? 'Pause' : started ? 'Resume' : 'Start'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(onPressed: hub.canSend && !_busy ? () => _act('skip') : null, icon: const Icon(Icons.skip_next_rounded), label: const Text('Skip'))),
          const SizedBox(width: 10),
          IconButton.outlined(tooltip: 'Reset', style: IconButton.styleFrom(minimumSize: const Size(52, 52), side: const BorderSide(color: HubColors.line)), onPressed: hub.canSend && !_busy ? () => _act('reset') : null, icon: const Icon(Icons.restart_alt_rounded)),
        ]),
        const SizedBox(height: 8),
        Center(child: Text('$_done session${_done == 1 ? '' : 's'} completed today', style: Ty.meta)),
        const SectionTitle('Lengths'),
        Panel(
          child: Column(children: [
            _Len(label: 'Focus', value: _work, min: 5, max: 60, div: 11, enabled: !_running, onChanged: (v) => setState(() => _work = v), onEnd: (_) => _act('show', quiet: true)),
            const Divider(height: 24),
            _Len(label: 'Break', value: _brk, min: 1, max: 30, div: 29, enabled: !_running, onChanged: (v) => setState(() => _brk = v), onEnd: (_) => _act('show', quiet: true)),
          ]),
        ),
        const SizedBox(height: 12),
        if (_legacy)
          const Hint('This Hub\'s firmware is older than 0.6, so the timer on screen can\'t follow the Hub. Update the firmware from Settings > Device for a synced timer.', color: HubColors.warn)
        else
          const Hint('The Hub keeps the time. Lengths can be changed while the timer is not running.'),
      ]),
    );
  }
}

class _Len extends StatelessWidget {
  const _Len({required this.label, required this.value, required this.min, required this.max, required this.div, required this.enabled, required this.onChanged, required this.onEnd});
  final String label;
  final double value, min, max;
  final int div;
  final bool enabled;
  final ValueChanged<double> onChanged, onEnd;
  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [Expanded(child: Text(label, style: Ty.bodyStrong)), Text('${value.round()} min', style: Ty.body.copyWith(color: HubColors.muted))]),
        Slider(value: value.clamp(min, max), min: min, max: max, divisions: div, onChanged: enabled ? onChanged : null, onChangeEnd: enabled ? onEnd : null),
      ]);
}

class _Ring extends CustomPainter {
  _Ring(this.progress, this.color);
  final double progress;
  final Color color;
  @override
  void paint(Canvas c, Size s) {
    final r = s.width / 2 - 10;
    final o = s.center(Offset.zero);
    c.drawCircle(o, r, Paint()..color = HubColors.surface2..style = PaintingStyle.stroke..strokeWidth = 10);
    c.drawArc(Rect.fromCircle(center: o, radius: r), -math.pi / 2, 2 * math.pi * progress, false, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_Ring old) => old.progress != progress || old.color != color;
}
