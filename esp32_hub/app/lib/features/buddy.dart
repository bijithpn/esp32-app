import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as web;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/bridge.dart';
import '../core/connection.dart';
import '../previews.dart';
import '../theme.dart';

class _Msg {
  _Msg(this.role, this.text, {this.error = false, this.tokens, this.retryOf});
  final String role; // user | assistant
  final String text;
  final bool error;
  final int? tokens;
  final String? retryOf;
}

/// Chat with a talking face. The Anthropic API key stays on the phone: it is stored with the Android Keystore, is sent only
/// to api.anthropic.com and is never given to the Hub, written to a log or shown in full on screen.
class BuddyScreen extends StatefulWidget {
  const BuddyScreen({super.key});
  @override
  State<BuddyScreen> createState() => _BuddyScreenState();
}

class _BuddyScreenState extends State<BuddyScreen> {
  static const _keyName = 'anthropic_key';
  final _in = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _chat = [];
  String _key = '';
  bool _busy = false, _loadedKey = false;
  int _tokensIn = 0, _tokensOut = 0;

  @override
  void initState() {
    super.initState();
    _loadKey();
    WidgetsBinding.instance.addPostFrameCallback((_) => HubScope.read(context).trySend({'cmd': 'say', 'text': 'Hi! I am Pixel. Ask me anything!', 'mood': 'excited'}));
  }

  @override
  void dispose() {
    _in.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    var k = await Bridge.current.secureGet(_keyName) ?? '';
    if (k.isEmpty) {
      // an older version kept the key in plain preferences: move it into the secure store and delete the plain copy
      final p = await SharedPreferences.getInstance();
      final old = p.getString(_keyName) ?? '';
      if (old.isNotEmpty) {
        await Bridge.current.secureSet(_keyName, old);
        await p.remove(_keyName);
        k = old;
      }
    }
    if (mounted) setState(() { _key = k; _loadedKey = true; });
  }

  String get _masked => _key.length < 8 ? '' : '${_key.substring(0, 7)}…${_key.substring(_key.length - 4)}';

  Future<void> _keySheet() async {
    final c = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Anthropic API key', style: Ty.h2),
          const SizedBox(height: 8),
          Hint(_key.isEmpty ? 'Paste your key to let Pixel answer.' : 'Saved: $_masked'),
          const SizedBox(height: 14),
          TextField(controller: c, obscureText: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'sk-ant-…')),
          const SizedBox(height: 8),
          const Hint('Stored in your phone\'s secure storage and sent only to api.anthropic.com. It is never sent to the Hub.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              final v = c.text.trim();
              if (v.isEmpty) return;
              await Bridge.current.secureSet(_keyName, v);
              if (mounted) setState(() => _key = v);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save key'),
          ),
          if (_key.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Bridge.current.secureSet(_keyName, null);
                if (mounted) setState(() => _key = '');
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Remove key', style: TextStyle(color: HubColors.danger)),
            ),
        ]),
      ),
    );
    c.dispose();
  }

  Future<void> _showOnHub(String text, [String? mood]) async {
    final ok = await HubScope.read(context).trySend({'cmd': 'say', 'text': text, 'mood': ?mood}, onError: (m) => toast(context, m));
    if (ok && mounted) toast(context, 'Showing on the Hub');
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent + 120, duration: motion(context, Motion.card), curve: Motion.curve);
      });

  Future<void> _ask([String? retry]) async {
    final q = retry ?? _in.text.trim();
    if (q.isEmpty || _busy) return;
    if (_key.isEmpty) {
      _keySheet();
      return;
    }
    setState(() {
      if (retry == null) _chat.add(_Msg('user', q));
      _chat.removeWhere((m) => m.error && m.retryOf == q);
      _busy = true;
    });
    _in.clear();
    _toBottom();
    try {
      final hist = [for (final m in _chat.where((m) => !m.error)) {'role': m.role, 'content': m.text}];
      final trimmed = hist.length > 8 ? hist.sublist(hist.length - 8) : hist;
      final r = await web
          .post(Uri.parse('https://api.anthropic.com/v1/messages'),
              headers: {'x-api-key': _key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json'},
              body: jsonEncode({
                'model': 'claude-haiku-5-5',
                'max_tokens': 200,
                'system': 'You are Pixel, a cute, warm, expressive little desk robot shown on a small 160x128 screen. '
                    'Start every reply with exactly one mood tag in square brackets, chosen from: [happy] [love] [excited] [surprised] [wink] [thinking] [sleepy] [sad] [angry] [normal]. '
                    'Pick the one that matches how you feel about what you say. Then reply in plain text, at most 140 characters, friendly and playful, no markdown, no emoji.',
                'messages': trimmed,
              }))
          .timeout(const Duration(seconds: 30));
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (r.statusCode == 401) throw const _KeyRejected();
      if (r.statusCode != 200) throw Exception(body['error']?['message'] ?? 'HTTP ${r.statusCode}');
      var text = (body['content'] as List).map((c) => c['text'] ?? '').join().trim();
      String? mood;
      final tag = RegExp(r'^\[(\w+)\]\s*').firstMatch(text);
      if (tag != null) {
        mood = tag.group(1)!.toLowerCase();
        text = text.substring(tag.end);
      }
      final u = body['usage'];
      final ti = (u is Map ? u['input_tokens'] as num? : null)?.toInt() ?? 0, to = (u is Map ? u['output_tokens'] as num? : null)?.toInt() ?? 0;
      if (!mounted) return;
      setState(() {
        _tokensIn += ti;
        _tokensOut += to;
        _chat.add(_Msg('assistant', text, tokens: ti + to > 0 ? ti + to : null));
      });
      await _showOnHub(text, mood);
    } on _KeyRejected {
      if (mounted) setState(() => _chat.add(_Msg('assistant', 'Anthropic didn\'t accept this API key. Check it in the key settings.', error: true, retryOf: q)));
    } catch (e) {
      final net = e is TimeoutException || e.toString().contains('SocketException') || e.toString().contains('ClientException');
      if (mounted) setState(() => _chat.add(_Msg('assistant', net ? 'Couldn\'t reach Anthropic. Check your internet connection and try again.' : 'Pixel couldn\'t answer just now. ${friendlyDetail(e)}', error: true, retryOf: q)));
    } finally {
      if (mounted) setState(() => _busy = false);
      _toBottom();
    }
  }

  String friendlyDetail(Object e) => e is Exception ? '$e'.replaceFirst('Exception: ', '') : 'Try again.';

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI buddy'),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 4), child: Center(child: hub.canSend ? const StatusPill(color: HubColors.ok, label: 'Hub') : const StatusPill(color: HubColors.warn, label: 'Hub offline'))),
          IconButton(tooltip: _key.isEmpty ? 'Add API key' : 'API key', icon: Icon(_key.isEmpty ? Icons.key_off_rounded : Icons.key_rounded), onPressed: _keySheet),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), children: [
            const Center(child: SizedBox(width: 150, child: DisplayFrame(child: ScenePreview(id: 'buddy')))),
            const SizedBox(height: 16),
            if (_chat.isEmpty)
              _loadedKey && _key.isEmpty
                  ? Panel(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Add your Anthropic API key', style: Ty.title),
                        const SizedBox(height: 6),
                        const Hint('Pixel needs a key to think. It stays on this phone. Without one you can still type something and have the Hub say it.'),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _keySheet, child: const Text('Add key')),
                      ]),
                    )
                  : const Hint('Ask a question. The answer appears on the Hub with a talking face.'),
            for (final m in _chat) _Bubble(m: m, onShow: m.role == 'assistant' && !m.error ? () => _showOnHub(m.text) : null, onRetry: m.error && m.retryOf != null ? () => _ask(m.retryOf) : null),
            if (_busy) const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.all(12), child: _Typing())),
            if (_tokensIn + _tokensOut > 0) Padding(padding: const EdgeInsets.only(top: 12), child: Center(child: Text('This chat: ${_tokensIn + _tokensOut} tokens ($_tokensIn in, $_tokensOut out)', style: Ty.meta))),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(children: [
              Expanded(child: TextField(controller: _in, minLines: 1, maxLines: 3, textInputAction: TextInputAction.send, decoration: const InputDecoration(hintText: 'Ask Pixel…'), onSubmitted: (_) => _ask())),
              const SizedBox(width: 8),
              IconButton.outlined(tooltip: 'Show this text on the Hub without asking AI', style: IconButton.styleFrom(minimumSize: const Size(52, 52), side: const BorderSide(color: HubColors.line)), onPressed: hub.canSend ? () { final t = _in.text.trim(); if (t.isNotEmpty) { _showOnHub(t); _in.clear(); } } : null, icon: const Icon(Icons.tv_rounded)),
              const SizedBox(width: 6),
              IconButton.filled(tooltip: 'Ask', style: IconButton.styleFrom(backgroundColor: HubColors.text, foregroundColor: HubColors.onPrimary, minimumSize: const Size(52, 52)), onPressed: _busy ? null : () => _ask(), icon: const Icon(Icons.arrow_upward_rounded)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _KeyRejected implements Exception {
  const _KeyRejected();
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m, this.onShow, this.onRetry});
  final _Msg m;
  final VoidCallback? onShow, onRetry;
  @override
  Widget build(BuildContext context) {
    final mine = m.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine ? HubColors.surface2 : HubColors.surface,
          borderRadius: BorderRadius.circular(Rad.card),
          border: Border.all(color: m.error ? HubColors.danger.withValues(alpha: 0.5) : HubColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.text, style: Ty.body.copyWith(color: m.error ? HubColors.danger : HubColors.text)),
          if (onShow != null || onRetry != null || m.tokens != null) ...[
            const SizedBox(height: 8),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (onShow != null) TextButton.icon(style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)), onPressed: onShow, icon: const Icon(Icons.tv_rounded, size: 16), label: const Text('Show on Hub')),
              if (onRetry != null) TextButton.icon(style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)), onPressed: onRetry, icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text('Try again')),
              if (m.tokens != null) Padding(padding: const EdgeInsets.only(left: 12), child: Text('${m.tokens} tokens', style: Ty.meta)),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();
  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reducedMotion(context)) {
      _c.value = 0.5;
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Pixel is thinking',
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(shape: BoxShape.circle, color: HubColors.muted.withValues(alpha: 0.3 + 0.7 * ((((_c.value * 3) - i) % 3) < 1 ? 1 - (((_c.value * 3) - i) % 3) : 0.0)))),
          ]),
        ),
      );
}
