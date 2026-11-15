import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../core/provisioning.dart';
import '../qr.dart';
import '../theme.dart';

const _stepTitles = ['Prepare', 'Connect', 'Wi-Fi', 'Join', 'Verify', 'Done'];

/// Guided setup: prepare the Hub, connect to it, pick the Wi-Fi, join, verify, finish.
/// Also used (with [onlineBoard]) to change the Wi-Fi of a Hub that is already online: the Hub tries the new network first
/// and keeps the old one if that fails.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, this.hotspotBoard, this.wifiQr, this.onlineBoard, this.token = ''});
  final FoundBoard? hotspotBoard, onlineBoard;
  final HubWifiQr? wifiQr;
  final String token;
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  late final ProvisioningController c;
  final _code = TextEditingController(), _ssid = TextEditingController(), _pass = TextEditingController();
  final _ssidFocus = FocusNode();
  bool _showPass = false, _manual = false, _closed = false;
  WifiNetwork? _picked;
  ProvProgress? _resume;

  bool get _changing => widget.onlineBoard != null;

  @override
  void initState() {
    super.initState();
    final hub = HubScope.read(context);
    c = ProvisioningController(hub: hub);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.onlineBoard != null) {
        await c.attachOnlineBoard(widget.onlineBoard!, widget.token);
      } else if (widget.hotspotBoard != null) {
        await c.attachHotspotBoard(widget.hotspotBoard!);
      } else if (widget.wifiQr != null) {
        _code.text = widget.wifiQr!.pass;
        await c.connectToHub(widget.wifiQr!.pass);
      } else {
        final p = await ProvisioningController.loadProgress();
        if (mounted) setState(() => _resume = p);
      }
    });
  }

  @override
  void dispose() {
    _closed = true;
    if (c.phase != JoinPhase.completed && !_changing) {
      c.cancel(); // let go of the hotspot and hand the connection back
    }
    c.dispose();
    _code.dispose();
    _ssid.dispose();
    _pass.dispose();
    _ssidFocus.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context).push<String>(hubRoute(const QrScanPage(hint: 'Scan the QR on the Hub\'s setup screen. It contains the Wi-Fi code.')));
    final w = v == null ? null : HubWifiQr.parse(v);
    if (w != null && mounted) {
      setState(() => _code.text = w.pass);
      await c.connectToHub(w.pass);
    }
  }

  Future<void> _tryResume() async {
    final d = await c.resume();
    if (!mounted) return;
    if (d == null) {
      setState(() => _resume = null);
      toast(context, 'That Hub isn\'t on the network yet. Continue with the steps below.');
    } else {
      await _done();
    }
  }

  Future<void> _done() async {
    await c.complete();
    if (mounted && !_closed) Navigator.of(context).pop(true);
  }

  Future<void> _submit() async {
    final ssid = _manual ? _ssid.text.trim() : (_picked?.ssid ?? '');
    final secure = _manual ? _pass.text.isNotEmpty : (_picked?.secure ?? true);
    FocusScope.of(context).unfocus();
    final d = await c.submit(ssid, _pass.text, secure: secure);
    if (d != null && mounted) {
      _pass.clear(); // nothing keeps the password once it has been handed over
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final idx = c.step.index;
          return Scaffold(
            appBar: AppBar(title: Text(_changing ? 'Change Wi-Fi' : 'Set up your Hub'), actions: [
              if (c.step == ProvStep.joinNetwork || c.step == ProvStep.verify) TextButton(
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    await c.cancel();
                    if (mounted) nav.pop();
                  },
                  child: const Text('Cancel')),
            ]),
            body: SafeArea(
              child: ListView(padding: Sp.page, children: [
                if (!_changing) _Progress(index: idx),
                const SizedBox(height: 20),
                AnimatedSwitcher(
                  duration: motion(context, Motion.card),
                  switchInCurve: Motion.curve,
                  child: KeyedSubtree(key: ValueKey(c.step), child: _body()),
                ),
              ]),
            ),
          );
        },
      );

  Widget _body() {
    switch (c.step) {
      case ProvStep.prepare:
        return _prepare();
      case ProvStep.connectHub:
        return _working('Connecting to your Hub', c.message ?? 'One moment…', failed: c.phase == JoinPhase.failed, retry: () => c.backToPrepare());
      case ProvStep.selectWifi:
        return _wifi();
      case ProvStep.joinNetwork:
      case ProvStep.verify:
        return _working(joinPhaseText(c.phase).isEmpty ? 'Working' : joinPhaseText(c.phase), c.message ?? 'This usually takes under 30 seconds. Keep the Hub powered.', failed: c.phase == JoinPhase.failed, retry: c.backToNetworks);
      case ProvStep.finish:
        return _finish();
    }
  }

  // ---------------------------------------------------------------- 1 prepare
  Widget _prepare() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Get your Hub ready', style: Ty.h2),
        const SizedBox(height: 6),
        const Hint('Two quick things on the Hub, then the app does the rest.'),
        if (_resume != null) ...[
          const SizedBox(height: 16),
          Panel(
            color: HubColors.accent.withValues(alpha: 0.08),
            borderColor: HubColors.accent.withValues(alpha: 0.35),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Setup of Hub ${_resume!.deviceId} was interrupted', style: Ty.title),
              const SizedBox(height: 6),
              const Hint('If it already joined your Wi-Fi, the app can finish pairing without starting over.'),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: FilledButton(onPressed: _tryResume, child: const Text('Find my Hub'))),
                const SizedBox(width: 10),
                OutlinedButton(
                    onPressed: () async {
                      await ProvisioningController.clearProgress();
                      if (mounted) setState(() => _resume = null);
                    },
                    child: const Text('Start over')),
              ]),
            ]),
          ),
        ],
        const SizedBox(height: 20),
        const _Do(n: 1, who: 'On the Hub', title: 'Hold the BOOT button for 2 seconds', text: 'Release when the screen shows a QR code and a short password. This starts pairing mode for 10 minutes.'),
        const _Do(n: 2, who: 'On your phone', title: 'Enter the code from the Hub\'s screen', text: 'Every Hub has its own 8-character code, so nobody else can join its setup network.'),
        const SizedBox(height: 4),
        TextField(
          controller: _code,
          maxLength: 8,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Code on the Hub',
            counterText: '',
            suffixIcon: IconButton(tooltip: 'Scan the QR instead', icon: const Icon(Icons.qr_code_scanner_rounded, color: HubColors.muted), onPressed: _scan),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _code.text.trim().length == 8 ? () => c.connectToHub(_code.text.trim()) : null, child: const Text('Connect to Hub')),
        const SizedBox(height: 6),
        const Hint('Android shows a one-time "Connect" dialog. The Hub has no internet, so Android may warn about that: that is expected.'),
      ]);

  // ---------------------------------------------------------------- 3 wifi
  Widget _wifi() {
    final failed = c.failure != null;
    final nets = c.networks;
    final canSend = !c.busy && ((_manual && _ssid.text.trim().isNotEmpty) || (!_manual && _picked != null && _picked!.supported));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_changing ? 'Choose a new network' : 'Choose your Wi-Fi', style: Ty.h2),
      const SizedBox(height: 6),
      const Hint('The Hub only works on 2.4 GHz networks (WPA2 or open). It remembers the network and reconnects by itself.'),
      if (failed || c.message != null && c.phase == JoinPhase.failed) ...[
        const SizedBox(height: 16),
        _Problem(c.message ?? joinFailureText(c.failure!)),
      ],
      const SizedBox(height: 16),
      Row(children: [
        const Expanded(child: Text('Nearby networks', style: Ty.bodyStrong)),
        if (c.scanning)
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        else
          TextButton(onPressed: c.loadNetworks, child: const Text('Scan again')),
      ]),
      const SizedBox(height: 8),
      if (nets.isEmpty)
        Panel(child: Text(c.scanning ? 'Looking for networks…' : 'No networks found. You can type the name below.', style: Ty.secondary.copyWith(fontSize: 14)))
      else
        Group(children: [
          for (final n in nets.take(8))
            Row2(
              title: n.ssid,
              sub: !n.supported ? 'Not supported (${n.auth.toUpperCase()})' : (n.secure ? 'Secured · ${n.auth.toUpperCase()}' : 'Open network'),
              iconColor: HubColors.muted,
              icon: n.secure ? Icons.lock_outline_rounded : Icons.lock_open_rounded,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_picked?.ssid == n.ssid && !_manual) const Padding(padding: EdgeInsets.only(right: 10), child: Icon(Icons.check_rounded, color: HubColors.ok)),
                SignalBars(bars: n.bars, color: n.supported ? HubColors.text : HubColors.muted),
              ]),
              titleColor: n.supported ? null : HubColors.muted,
              onTap: c.busy || !n.supported ? null : () => setState(() { _picked = n; _manual = false; _ssid.text = n.ssid; }),
            ),
        ]),
      const SizedBox(height: 8),
      Group(children: [
        Row2(
          icon: Icons.edit_outlined,
          title: 'Other or hidden network',
          sub: 'Type its name and password',
          trailing: _manual ? const Icon(Icons.check_rounded, color: HubColors.ok) : null,
          onTap: () {
            setState(() { _manual = true; _picked = null; _ssid.clear(); });
            _ssidFocus.requestFocus();
          },
        ),
      ]),
      const SizedBox(height: 16),
      if (_manual) ...[
        TextField(controller: _ssid, focusNode: _ssidFocus, autocorrect: false, enableSuggestions: false, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Network name')),
        const SizedBox(height: 12),
      ],
      if (_manual || (_picked?.secure ?? false))
        TextField(
          controller: _pass,
          obscureText: !_showPass,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(tooltip: _showPass ? 'Hide password' : 'Show password', icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: HubColors.muted), onPressed: () => setState(() => _showPass = !_showPass)),
          ),
        ),
      if (!_changing) ...[
        const SizedBox(height: 8),
        Row(children: [
          const Expanded(child: Text('Protect this Hub with a token', style: Ty.body)),
          Switch(value: c.protect, onChanged: (v) => setState(() => c.protect = v)),
        ]),
        const Hint('Recommended. Only phones you pair can control the Hub or update its firmware. The token is stored in your phone\'s secure storage.'),
      ],
      const SizedBox(height: 20),
      FilledButton(onPressed: canSend ? _submit : null, child: Text(_changing ? 'Switch network' : 'Connect Hub')),
    ]);
  }

  // ---------------------------------------------------------------- 2 / 4 / 5 working
  Widget _working(String title, String text, {required bool failed, required VoidCallback retry}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: SizedBox(width: 176, child: DisplayFrame(child: FaceScreen(mood: failed ? 'sad' : 'thinking')))),
        const SizedBox(height: 24),
        Text(failed ? 'That didn\'t work' : title, textAlign: TextAlign.center, style: Ty.h2),
        const SizedBox(height: 8),
        Text(text, textAlign: TextAlign.center, style: Ty.secondary.copyWith(fontSize: 14)),
        const SizedBox(height: 20),
        if (!failed) ClipRRect(borderRadius: BorderRadius.circular(3), child: const LinearProgressIndicator(minHeight: 3)) else FilledButton(onPressed: retry, child: const Text('Try again')),
        if (c.phase == JoinPhase.failed && c.failure == JoinFailure.networkDisconnected) ...[
          const SizedBox(height: 10),
          OutlinedButton(
              onPressed: () async {
                final d = await c.resume();
                if (d != null && mounted) await _done();
              },
              child: const Text('Find my Hub')),
        ],
      ]);

  // ---------------------------------------------------------------- 6 finish
  Widget _finish() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: SizedBox(width: 176, child: DisplayFrame(child: FaceScreen(mood: 'excited')))),
        const SizedBox(height: 24),
        const Text('Your Hub is online', textAlign: TextAlign.center, style: Ty.h2),
        const SizedBox(height: 8),
        Text('${c.paired?.name ?? 'The Hub'} is paired and verified on your Wi-Fi.', textAlign: TextAlign.center, style: Ty.secondary.copyWith(fontSize: 14)),
        const SizedBox(height: 24),
        FilledButton(onPressed: _done, child: const Text('Open dashboard')),
      ]);
}

class _Progress extends StatelessWidget {
  const _Progress({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          for (var i = 0; i < _stepTitles.length; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: motion(context, Motion.small),
                height: 3,
                decoration: BoxDecoration(color: i <= index ? HubColors.text : HubColors.line, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            if (i < _stepTitles.length - 1) const SizedBox(width: 4),
          ],
        ]),
        const SizedBox(height: 8),
        Text('Step ${index + 1} of ${_stepTitles.length} · ${_stepTitles[index]}', style: Ty.meta),
      ]);
}

class _Do extends StatelessWidget {
  const _Do({required this.n, required this.who, required this.title, required this.text});
  final int n;
  final String who, title, text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: HubColors.line)),
            child: Text('$n', style: Ty.meta.copyWith(color: HubColors.text)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(who.toUpperCase(), style: Ty.meta.copyWith(letterSpacing: 1.0, fontSize: 11)),
            const SizedBox(height: 2),
            Text(title, style: Ty.bodyStrong),
            const SizedBox(height: 2),
            Text(text, style: Ty.secondary),
          ])),
        ]),
      );
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Panel(
        color: HubColors.danger.withValues(alpha: 0.08),
        borderColor: HubColors.danger.withValues(alpha: 0.4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline_rounded, size: 20, color: HubColors.danger),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: Ty.body.copyWith(fontSize: 14))),
        ]),
      );
}
