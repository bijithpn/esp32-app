import 'dart:convert';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/connection.dart';
import '../core/errors.dart';
import '../core/muse_look.dart';
import '../theme.dart';

const _prefKey = 'muse_look';
const _folder = 'assets/muse/look';

/// The saved look, or the default Muse. Damaged data never throws.
Future<MuseLook> loadMuseLook() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
    if (raw != null) return MuseLook.fromJson(jsonDecode(raw));
  } catch (_) {}
  return const MuseLook();
}

Future<void> saveMuseLook(MuseLook look) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_prefKey, jsonEncode(look.toJson()));
  } catch (_) {}
}

/// The sprite layers for a look, bottom first. The body always exists; the outfit only when one is chosen.
List<String> museLayers(MuseLook look) => [
      '$_folder/character_${look.character}_${look.coat}.png',
      if (look.outfit != 'none') '$_folder/outfit_${look.outfit}.png',
    ];

/// What the Hub is told: which character, coat and outfit. The Hub draws and animates the character itself, so nothing
/// else is sent. (Names match the Hub's own tables, see CH_CHARS / CH_COATS / CH_OUTFITS in firmware/hub/character.h.)
Map<String, dynamic> museCommand(MuseLook look) => {'cmd': 'char', 'character': look.character, 'coat': look.coat, 'outfit': look.outfit};

/// Sends the look to the Hub. A Hub with older firmware answers "unknown cmd": that is reported as [CharacterNeedsUpdate].
Future<void> sendMuseToHub(Future<Map<String, dynamic>> Function(Map<String, dynamic>) cmd, MuseLook look) async {
  final r = await cmd(museCommand(look));
  if (r['ok'] == true) return;
  final msg = '${r['error'] ?? ''}';
  if (msg.contains('unknown cmd')) throw const CharacterNeedsUpdate();
  throw HubException(HubError.deviceError, msg.isEmpty ? 'device error' : msg, '${r['errorCode'] ?? ''}');
}

class CharacterNeedsUpdate implements Exception {
  const CharacterNeedsUpdate();
  @override
  String toString() => 'Update the Hub firmware to show your character';
}

/// Which part of the character a touch lands on. [p] is the touch position inside the character's square, 0..1 each way.
/// Mirrors the real Muse: head (top and ears), cheek (the face), hand (the sides) and belly (below the face).
String museTouchZone(Offset p) {
  if ((p.dx < 0.28 || p.dx > 0.72) && p.dy > 0.3) return 'hand';
  if (p.dy < 0.36) return 'head';
  if (p.dy < 0.6) return 'cheek';
  return 'belly';
}

/// What the Hub is sent for a touch. The Hub answers with the character's own reaction (see firmware/hub/character.h).
Map<String, dynamic> museTouchCommand(String zone, {bool petting = false}) => {'cmd': 'char', 'touch': zone, if (petting) 'petting': true};

/// The character as a touch target: tap or poke it, stroke the head or cheek to pet it, and it reacts on the phone at once
/// (a bounce and a heart) while [onTouch] tells the Hub, which plays the character's real reaction on the display.
class TouchableMuse extends StatefulWidget {
  const TouchableMuse({super.key, required this.look, required this.onTouch});
  final MuseLook look;
  final void Function(String zone, bool petting) onTouch;
  @override
  State<TouchableMuse> createState() => _TouchableMuseState();
}

class _TouchableMuseState extends State<TouchableMuse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Offset _at = const Offset(0.5, 0.4);
  bool _heart = false;
  DateTime _lastPet = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _touch(Offset local, Size size, {required bool stroke}) {
    final p = Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
    final zone = museTouchZone(p);
    final petting = stroke && (zone == 'head' || zone == 'cheek');
    if (stroke) {
      if (!petting || DateTime.now().difference(_lastPet) < const Duration(milliseconds: 700)) return; // strokes are throttled
      _lastPet = DateTime.now();
    }
    HapticFeedback.selectionClick();
    widget.onTouch(zone, petting);
    if (!mounted || reducedMotion(context)) return;
    setState(() { _at = p; _heart = petting || zone == 'head'; });
    _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          return Semantics(
            button: true,
            label: 'Your character. Double tap to poke it.',
            onTap: () => widget.onTouch('head', false),
            child: GestureDetector(
              key: const ValueKey('touch-muse'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _touch(d.localPosition, size, stroke: false),
              onLongPressStart: (d) => _touch(d.localPosition, size, stroke: true),
              onPanUpdate: (d) => _touch(d.localPosition, size, stroke: true),
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, child) {
                  final v = _c.value, k = math.sin(v * math.pi);
                  return Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(
                      child: Transform(
                        alignment: Alignment.bottomCenter,
                        transform: Matrix4.diagonal3Values(1 + 0.05 * k, 1 - 0.07 * k, 1),
                        child: child,
                      ),
                    ),
                    if (_heart && v > 0 && v < 1)
                      Positioned(
                        left: _at.dx * size.width - 10,
                        top: _at.dy * size.height - 10 - 28 * v,
                        child: Opacity(opacity: 1 - v, child: const Icon(Icons.favorite_rounded, size: 20, color: HubColors.pink)),
                      ),
                  ]);
                },
                child: MuseSprite(key: const ValueKey('preview'), look: widget.look, size: size.shortestSide),
              ),
            ),
          );
        },
      );
}

class CharacterPreview extends StatefulWidget {
  const CharacterPreview({super.key});
  @override
  State<CharacterPreview> createState() => _CharacterPreviewState();
}

class _CharacterPreviewState extends State<CharacterPreview> {
  MuseLook? _look;
  @override
  void initState() {
    super.initState();
    loadMuseLook().then((l) {
      if (mounted) setState(() => _look = l);
    });
  }

  @override
  Widget build(BuildContext context) => ColoredBox(color: const Color(0xFF0A0C1A), child: Center(child: _look == null ? null : MuseSprite(look: _look!, size: 100)));
}

/// The character as it appears in the app: crisp pixels, body plus outfit.
class MuseSprite extends StatelessWidget {
  const MuseSprite({super.key, required this.look, this.size = 96, this.outfit = true});
  final MuseLook look;
  final double size;
  final bool outfit;

  @override
  Widget build(BuildContext context) {
    Widget layer(String path) => Image.asset(path, filterQuality: FilterQuality.none, gaplessPlayback: true, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink());
    final layers = museLayers(look);
    return SizedBox(
      width: size,
      height: size,
      child: ExcludeSemantics(child: Stack(fit: StackFit.expand, children: [layer(layers.first), if (outfit && layers.length > 1) layer(layers.last)])),
    );
  }
}

enum _Tab { character, colour, outfit }

/// Customise the character that lives on the Hub: pick who it is, its colour and what it wears, then show it on the display.
class CharacterScreen extends StatefulWidget {
  const CharacterScreen({super.key});
  @override
  State<CharacterScreen> createState() => _CharacterScreenState();
}

class _CharacterScreenState extends State<CharacterScreen> {
  MuseLook _look = const MuseLook();
  _Tab _tab = _Tab.character;
  bool _sending = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    loadMuseLook().then((l) {
      if (mounted) setState(() { _look = l; _loaded = true; });
    });
  }

  void _change(MuseLook look) {
    if (look == _look) return;
    HapticFeedback.selectionClick();
    setState(() => _look = look);
    saveMuseLook(look);
  }

  /// A touch on the character: the Hub plays the reaction. Quiet when no Hub is connected (the phone still reacts) or if one command is dropped.
  void _touchHub(String zone, bool petting) {
    final hub = HubScope.read(context);
    if (!hub.canSend) return;
    hub.trySend(museTouchCommand(zone, petting: petting), dedupeKey: 'touch');
  }

  Future<void> _show() async {
    final hub = HubScope.read(context);
    final look = _look;
    setState(() => _sending = true);
    try {
      await sendMuseToHub((b) => hub.send(b, idempotent: true, timeout: const Duration(seconds: 6)), look);
      if (mounted) toast(context, '${look.summary} is alive on the Hub');
    } on CharacterNeedsUpdate {
      if (mounted) toast(context, 'Update the Hub firmware to show your character');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send: ${friendlyError(e)}');
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final sending = _sending;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your character'),
        actions: [
          TextButton(key: const ValueKey('reset-look'), onPressed: _look == const MuseLook() ? null : () => _change(const MuseLook()), child: const Text('Reset')),
        ],
      ),
      body: !_loaded
          ? StateView.loading('Loading your character')
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(children: [
                  DisplayFrame(child: ColoredBox(color: Colors.black, child: Center(child: FractionallySizedBox(heightFactor: 1, child: AspectRatio(aspectRatio: 1, child: TouchableMuse(look: _look, onTouch: _touchHub)))))),
                  const SizedBox(height: 8),
                  Text(_look.summary, key: const ValueKey('summary'), style: Ty.title, textAlign: TextAlign.center),
                  const SizedBox(height: 2),
                  const Hint('Tap it, poke it, or stroke its head. It reacts on the Hub too.'),
                ]),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<_Tab>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(backgroundColor: HubColors.surface, selectedBackgroundColor: HubColors.surface2, selectedForegroundColor: HubColors.text, foregroundColor: HubColors.muted, side: const BorderSide(color: HubColors.line), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control))),
                  segments: const [
                    ButtonSegment(value: _Tab.character, label: Text('Character')),
                    ButtonSegment(value: _Tab.colour, label: Text('Colour')),
                    ButtonSegment(value: _Tab.outfit, label: Text('Outfit')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (v) => setState(() => _tab = v.first),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: ValueKey('section-${_tab.name}'),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: switch (_tab) {
                    _Tab.character => _characters(),
                    _Tab.colour => _colours(),
                    _Tab.outfit => _outfits(),
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('show-on-hub'),
                        onPressed: sending || !hub.canSend ? null : _show,
                        icon: const Icon(Icons.send_rounded, size: 20),
                        label: Text(hub.canSend ? 'Show on the Hub' : 'Connect a Hub to show it'),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }

  Widget _tile({required Key key, required String label, required bool selected, required VoidCallback onTap, required Widget child, double size = 88}) => SizedBox(
        width: size,
        child: Semantics(
          label: label,
          child: Choice(
            key: key,
            selected: selected,
            onTap: onTap,
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            radius: Rad.control,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: size - 16, height: size - 16, child: child),
              const SizedBox(height: 2),
              FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, style: Ty.meta.copyWith(color: selected ? HubColors.text : HubColors.muted))),
            ]),
          ),
        ),
      );

  Widget _characters() => Wrap(spacing: 10, runSpacing: 10, children: [
        for (final o in museCharacters)
          _tile(key: ValueKey('character-${o.id}'), label: o.label, selected: _look.character == o.id, onTap: () => _change(_look.copy(character: o.id)), child: MuseSprite(look: _look.copy(character: o.id), outfit: false, size: 72)),
      ]);

  Widget _colours() {
    final order = [for (final g in museCoatGroups) ...g.$2];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / 4;
        return Wrap(runSpacing: 14, children: [
          for (final id in order)
            SizedBox(
              width: w,
              child: Semantics(
                button: true,
                selected: _look.coat == id,
                label: '${museFind(museCoats, id)!.label} coat',
                child: InkResponse(
                  key: ValueKey('coat-$id'),
                  onTap: () => _change(_look.copy(coat: id)),
                  radius: 36,
                  child: Column(children: [
                    AnimatedContainer(
                      duration: motion(context, Motion.fast),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: Color(museCoatColors[id]!), shape: BoxShape.circle, border: Border.all(color: _look.coat == id ? HubColors.text : HubColors.line, width: _look.coat == id ? 3 : 1)),
                      child: _look.coat == id ? Icon(Icons.check, size: 22, color: ThemeData.estimateBrightnessForColor(Color(museCoatColors[id]!)) == Brightness.dark ? Colors.white : Colors.black) : null,
                    ),
                    const SizedBox(height: 4),
                    Text(museFind(museCoats, id)!.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Ty.meta.copyWith(color: _look.coat == id ? HubColors.text : HubColors.muted)),
                  ]),
                ),
              ),
            ),
        ]);
      }),
    ]);
  }

  Widget _outfits() {
    final order = ['none', for (final g in museOutfitGroups) ...g.$2];
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final id in order)
        _tile(
          key: ValueKey('outfit-$id'),
          size: 72,
          label: museFind(museOutfits, id)!.label,
          selected: _look.outfit == id,
          onTap: () => _change(_look.copy(outfit: id)),
          child: id == 'none' ? const Center(child: Icon(Icons.block, size: 24, color: HubColors.muted)) : MuseSprite(look: _look.copy(outfit: id), size: 56),
        ),
    ]);
  }
}

/// Dashboard card: the current character with a way to change it.
class CharacterCard extends StatefulWidget {
  const CharacterCard({super.key, required this.onOpen});
  final VoidCallback onOpen;
  @override
  State<CharacterCard> createState() => _CharacterCardState();
}

class _CharacterCardState extends State<CharacterCard> {
  MuseLook _look = const MuseLook();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final l = await loadMuseLook();
    if (mounted) setState(() => _look = l);
  }

  @override
  Widget build(BuildContext context) => Panel(
        onTap: () {
          widget.onOpen();
          // the screen saves on every change; pick it up when the user comes back
          Future.delayed(const Duration(milliseconds: 400), _reload);
        },
        child: Row(children: [
          Container(
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(Rad.control), border: Border.all(color: HubColors.line)),
            child: MuseSprite(look: _look, size: 72),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_look.summary, style: Ty.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              const Hint('Change the character, colour and outfit'),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: HubColors.muted),
        ]),
      );
}
