import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/imaging.dart';
import '../theme.dart';

const _gw = 40, _gh = 32;
const _black = 0xFF000000;

enum _Tool { pencil, eraser, fill, picker }

/// Pixel-art editor (40 x 32, each pixel is 4 x 4 on the display) plus photo sending.
class CanvasEditorScreen extends StatefulWidget {
  const CanvasEditorScreen({super.key});
  @override
  State<CanvasEditorScreen> createState() => _CanvasEditorScreenState();
}

class _CanvasEditorScreenState extends State<CanvasEditorScreen> {
  bool _photo = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Canvas')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(backgroundColor: HubColors.surface, selectedBackgroundColor: HubColors.surface2, selectedForegroundColor: HubColors.text, foregroundColor: HubColors.muted, side: const BorderSide(color: HubColors.line), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control))),
              segments: const [ButtonSegment(value: false, label: Text('Pixel art'), icon: Icon(Icons.grid_on_rounded)), ButtonSegment(value: true, label: Text('Photo'), icon: Icon(Icons.photo_outlined))],
              selected: {_photo},
              onSelectionChanged: (v) => setState(() => _photo = v.first),
            ),
          ),
          Expanded(child: _photo ? const _PhotoSender() : const _PixelEditor()),
        ]),
      );
}

// ======================================================================= pixel editor
class _PixelEditor extends StatefulWidget {
  const _PixelEditor();
  @override
  State<_PixelEditor> createState() => _PixelEditorState();
}

class _PixelEditorState extends State<_PixelEditor> {
  static const palette = <int>[
    0xFF000000, 0xFFFFFFFF, 0xFFE53935, 0xFFFB8C00, 0xFFFDD835, 0xFF43A047, 0xFF00ACC1, 0xFF1E88E5, 0xFF8E24AA, 0xFFEC407A, 0xFF8B5A2B, 0xFF9E9E9E,
  ];
  Uint32List _cells = Uint32List(_gw * _gh)..fillRange(0, _gw * _gh, _black);
  final _undo = <Uint32List>[], _redo = <Uint32List>[];
  final _rev = ValueNotifier<int>(0);
  _Tool _tool = _Tool.pencil;
  int _color = 0xFFE53935;
  final _recent = <int>[];
  bool _grid = true;
  double _scale = 1, _baseScale = 1;
  Offset _offset = Offset.zero;
  Size _box = Size.zero;
  int? _lastX, _lastY;
  bool _stroking = false;
  DateTime _strokeAt = DateTime.now();
  double? _progress;
  bool _cancel = false;

  @override
  void dispose() {
    _rev.dispose();
    super.dispose();
  }

  void _snapshot() {
    _undo.add(Uint32List.fromList(_cells));
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
  }

  void _doUndo() {
    if (_undo.isEmpty) return;
    _redo.add(Uint32List.fromList(_cells));
    _cells = _undo.removeLast();
    _rev.value++;
    setState(() {});
  }

  void _doRedo() {
    if (_redo.isEmpty) return;
    _undo.add(Uint32List.fromList(_cells));
    _cells = _redo.removeLast();
    _rev.value++;
    setState(() {});
  }

  /// Screen position -> grid cell (accounts for zoom and pan).
  (int, int)? _cell(Offset p) {
    final cs = _box.width / _gw * _scale;
    final x = ((p.dx - _offset.dx) / cs).floor(), y = ((p.dy - _offset.dy) / cs).floor();
    if (x < 0 || y < 0 || x >= _gw || y >= _gh) return null;
    return (x, y);
  }

  void _clampOffset() {
    final w = _box.width * _scale, h = _box.height * _scale;
    _offset = Offset(_offset.dx.clamp(math.min(0.0, _box.width - w), 0.0), _offset.dy.clamp(math.min(0.0, _box.height - h), 0.0));
  }

  void _plot(int x, int y, int color) {
    _cells[y * _gw + x] = color;
  }

  void _line(int x0, int y0, int x1, int y1, int color) {
    // Bresenham: a fast drag leaves no gaps
    var dx = (x1 - x0).abs(), dy = -(y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    var err = dx + dy, x = x0, y = y0;
    while (true) {
      _plot(x, y, color);
      if (x == x1 && y == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) { err += dy; x += sx; }
      if (e2 <= dx) { err += dx; y += sy; }
    }
  }

  void _flood(int x, int y, int to) {
    final from = _cells[y * _gw + x];
    if (from == to) return;
    final stack = <int>[y * _gw + x];
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      if (_cells[i] != from) continue;
      _cells[i] = to;
      final cx = i % _gw, cy = i ~/ _gw;
      if (cx > 0) stack.add(i - 1);
      if (cx < _gw - 1) stack.add(i + 1);
      if (cy > 0) stack.add(i - _gw);
      if (cy < _gh - 1) stack.add(i + _gw);
    }
  }

  void _useColor(int c) {
    setState(() {
      _color = c;
      if (!palette.contains(c)) {
        _recent.remove(c);
        _recent.insert(0, c);
        if (_recent.length > 6) _recent.removeLast();
      }
    });
  }

  void _start(ScaleStartDetails d) {
    _baseScale = _scale;
    if (d.pointerCount != 1) return;
    final c = _cell(d.localFocalPoint);
    if (c == null) return;
    _strokeAt = DateTime.now();
    switch (_tool) {
      case _Tool.picker:
        _useColor(_cells[c.$2 * _gw + c.$1]);
        setState(() => _tool = _Tool.pencil);
        return;
      case _Tool.fill:
        _snapshot();
        _flood(c.$1, c.$2, _color);
        _stroking = true;
      case _Tool.pencil:
      case _Tool.eraser:
        _snapshot();
        _plot(c.$1, c.$2, _tool == _Tool.eraser ? _black : _color);
        _stroking = true;
    }
    _lastX = c.$1;
    _lastY = c.$2;
    _rev.value++;
  }

  void _update(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      // a second finger: this is zoom / pan. If a stroke had only just begun it was an accident, so take it back.
      if (_stroking && DateTime.now().difference(_strokeAt).inMilliseconds < 180 && _undo.isNotEmpty) {
        _cells = _undo.removeLast();
        _rev.value++;
      }
      _stroking = false;
      final ns = (_baseScale * d.scale).clamp(1.0, 6.0);
      final focal = d.localFocalPoint;
      final k = ns / _scale;
      setState(() {
        _offset = focal - (focal - _offset) * k + d.focalPointDelta;
        _scale = ns;
        _clampOffset();
      });
      return;
    }
    if (!_stroking || (_tool != _Tool.pencil && _tool != _Tool.eraser)) return;
    final c = _cell(d.localFocalPoint);
    if (c == null) return;
    if (_lastX != null && (c.$1 != _lastX || c.$2 != _lastY)) {
      _line(_lastX!, _lastY!, c.$1, c.$2, _tool == _Tool.eraser ? _black : _color);
      _lastX = c.$1;
      _lastY = c.$2;
      _rev.value++;
    }
  }

  void _end(ScaleEndDetails d) {
    if (_stroking) setState(() {}); // refresh undo / redo buttons
    _stroking = false;
    _lastX = _lastY = null;
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(title: const Text('Clear the canvas?'), content: const Text('You can undo this.'), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
      ]),
    );
    if (ok != true) return;
    _snapshot();
    _cells.fillRange(0, _cells.length, _black);
    _rev.value++;
    setState(() {});
  }

  Future<void> _import() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes(), targetWidth: 400);
      final img = (await codec.getNextFrame()).image;
      if (!mounted) return;
      final picked = await showModalBottomSheet<Uint32List>(context: context, isScrollControlled: true, builder: (_) => _ImportSheet(img: img));
      img.dispose();
      if (picked != null) {
        _snapshot();
        _cells = picked;
        _rev.value++;
        setState(() {});
      }
    } catch (e) {
      if (mounted) toast(context, 'That picture couldn\'t be opened.');
    }
  }

  Uint8List _rgba160() {
    final rgba = Uint8List(160 * 128 * 4);
    for (var y = 0; y < 128; y++) {
      for (var x = 0; x < 160; x++) {
        final c = _cells[(y ~/ 4) * _gw + (x ~/ 4)];
        final i = (y * 160 + x) * 4;
        rgba[i] = (c >> 16) & 0xFF;
        rgba[i + 1] = (c >> 8) & 0xFF;
        rgba[i + 2] = c & 0xFF;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  Future<void> _send() async {
    final hub = HubScope.read(context);
    setState(() { _progress = 0; _cancel = false; });
    try {
      await sendFrameVia(
        (b) {
          if (_cancel) throw HubException(HubError.cancelled);
          return hub.send(b, idempotent: true, timeout: const Duration(seconds: 10));
        },
        rgbaToRgb565(_rgba160()),
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      );
      if (mounted) toast(context, 'Sent to the Hub');
    } catch (e) {
      if (mounted && toHubException(e).kind != HubError.cancelled) toast(context, 'Couldn\'t send: ${friendlyError(e)}');
    }
    if (mounted) setState(() => _progress = null);
  }

  void _preview() => showModalBottomSheet<void>(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Preview on the Hub', style: Ty.h2),
            const SizedBox(height: 12),
            DisplayFrame(child: CustomPaint(painter: _CellsPainter(_cells, _rev, grid: false, scale: 1, offset: Offset.zero))),
            const SizedBox(height: 6),
            const Hint('Each pixel becomes a 4 x 4 block on the 160 x 128 display.'),
          ]),
        ),
      );

  Future<void> _customColor() async {
    final c = await showModalBottomSheet<int>(context: context, isScrollControlled: true, builder: (_) => _ColorSheet(initial: Color(_color)));
    if (c != null) _useColor(c);
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      Row(children: [
        for (final t in _Tool.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              button: true,
              selected: _tool == t,
              label: t.name,
              child: Choice(
                selected: _tool == t,
                onTap: () => setState(() => _tool = t),
                padding: const EdgeInsets.all(10),
                radius: Rad.control,
                child: Icon(switch (t) { _Tool.pencil => Icons.edit_rounded, _Tool.eraser => Icons.auto_fix_normal_rounded, _Tool.fill => Icons.format_color_fill_rounded, _Tool.picker => Icons.colorize_rounded }, size: 22),
              ),
            ),
          ),
        const Spacer(),
        IconButton(tooltip: 'Undo', onPressed: _undo.isEmpty ? null : _doUndo, icon: const Icon(Icons.undo_rounded)),
        IconButton(tooltip: 'Redo', onPressed: _redo.isEmpty ? null : _doRedo, icon: const Icon(Icons.redo_rounded)),
      ]),
      const SizedBox(height: 8),
      AspectRatio(
        aspectRatio: _gw / _gh,
        child: LayoutBuilder(builder: (ctx, c) {
          _box = Size(c.maxWidth, c.maxHeight);
          return ClipRRect(
            borderRadius: BorderRadius.circular(Rad.control),
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: HubColors.line), borderRadius: BorderRadius.circular(Rad.control)),
              child: GestureDetector(
                onScaleStart: _start,
                onScaleUpdate: _update,
                onScaleEnd: _end,
                child: RepaintBoundary(child: CustomPaint(size: _box, painter: _CellsPainter(_cells, _rev, grid: _grid, scale: _scale, offset: _offset))),
              ),
            ),
          );
        }),
      ),
      const SizedBox(height: 6),
      Row(children: [
        const Expanded(child: Text('Draw with one finger. Pinch to zoom, two fingers to move.', style: Ty.meta)),
        if (_scale > 1) TextButton(onPressed: () => setState(() { _scale = 1; _offset = Offset.zero; }), child: const Text('Reset zoom')),
        IconButton(tooltip: _grid ? 'Hide grid' : 'Show grid', onPressed: () => setState(() => _grid = !_grid), icon: Icon(_grid ? Icons.grid_on_rounded : Icons.grid_off_rounded, size: 20)),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final c in [...palette, ..._recent]) _Swatch(color: c, selected: _color == c, onTap: () => _useColor(c)),
          Semantics(button: true, label: 'Custom colour', child: Pressable(onTap: _customColor, child: Container(width: 40, height: 40, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: HubColors.line)), child: const Icon(Icons.add_rounded, size: 20, color: HubColors.muted)))),
        ]),
      ),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.image_outlined, size: 20), label: const Text('Import image')),
        OutlinedButton.icon(onPressed: _preview, icon: const Icon(Icons.visibility_outlined, size: 20), label: const Text('Preview')),
        OutlinedButton.icon(onPressed: _clear, icon: const Icon(Icons.delete_outline_rounded, size: 20), label: const Text('Clear')),
      ]),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: _progress == null && hub.canSend ? _send : null, icon: const Icon(Icons.send_rounded, size: 20), label: const Text('Send to the Hub')),
      if (_progress != null) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(value: _progress),
        Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _cancel = true, child: const Text('Cancel'))),
      ],
    ]);
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});
  final int color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: 'Colour #${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        child: Pressable(
          onTap: onTap,
          child: AnimatedContainer(
            duration: motion(context, Motion.fast),
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(color: Color(color), shape: BoxShape.circle, border: Border.all(color: selected ? HubColors.accent : HubColors.line, width: selected ? 3 : 1)),
          ),
        ),
      );
}

class _CellsPainter extends CustomPainter {
  _CellsPainter(this.cells, Listenable repaint, {required this.grid, required this.scale, required this.offset}) : super(repaint: repaint);
  final Uint32List cells;
  final bool grid;
  final double scale;
  final Offset offset;
  @override
  void paint(Canvas canvas, Size size) {
    final cs = size.width / _gw * scale;
    final p = Paint();
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var y = 0; y < _gh; y++) {
      for (var x = 0; x < _gw; x++) {
        final r = Rect.fromLTWH(offset.dx + x * cs, offset.dy + y * cs, cs + 0.6, cs + 0.6);
        if (r.right < 0 || r.bottom < 0 || r.left > size.width || r.top > size.height) continue;
        p.color = Color(cells[y * _gw + x]);
        canvas.drawRect(r, p);
      }
    }
    if (grid && cs >= 6) {
      final g = Paint()..color = const Color(0x22FFFFFF)..strokeWidth = 0.5;
      for (var x = 0; x <= _gw; x++) {
        canvas.drawLine(Offset(offset.dx + x * cs, offset.dy), Offset(offset.dx + x * cs, offset.dy + _gh * cs), g);
      }
      for (var y = 0; y <= _gh; y++) {
        canvas.drawLine(Offset(offset.dx, offset.dy + y * cs), Offset(offset.dx + _gw * cs, offset.dy + y * cs), g);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CellsPainter old) => old.grid != grid || old.scale != scale || old.offset != offset || old.cells != cells;
}

// ---------------------------------------------------------------- import (crop) sheet
class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.img});
  final ui.Image img;
  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  bool _fit = false;
  double _pan = 0.5;
  Uint32List? _cells;
  Uint8List? _png;

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    final r = await renderImage(widget.img, _gw, _gh, fit: _fit, pan: _pan);
    final out = Uint32List(_gw * _gh);
    for (var i = 0; i < out.length; i++) {
      out[i] = 0xFF000000 | (r.rgba[i * 4] << 16) | (r.rgba[i * 4 + 1] << 8) | r.rgba[i * 4 + 2];
    }
    if (mounted) setState(() { _cells = out; _png = r.png; });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Import image', style: Ty.h2),
          const SizedBox(height: 12),
          if (_png != null) AspectRatio(aspectRatio: _gw / _gh, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(_png!, fit: BoxFit.fill, filterQuality: FilterQuality.none, gaplessPlayback: true))),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('Fill (crop)')), ButtonSegment(value: true, label: Text('Fit (whole picture)'))],
            selected: {_fit},
            onSelectionChanged: (v) { _fit = v.first; _render(); },
          ),
          if (!_fit) ...[
            const SizedBox(height: 8),
            Row(children: [const Text('Crop position', style: Ty.secondary), Expanded(child: Slider(value: _pan, onChanged: (v) { setState(() => _pan = v); }, onChangeEnd: (_) => _render()))]),
          ],
          const SizedBox(height: 8),
          FilledButton(onPressed: _cells == null ? null : () => Navigator.pop(context, _cells), child: const Text('Use this')),
        ]),
      );
}

class _ColorSheet extends StatefulWidget {
  const _ColorSheet({required this.initial});
  final Color initial;
  @override
  State<_ColorSheet> createState() => _ColorSheetState();
}

class _ColorSheetState extends State<_ColorSheet> {
  late HSVColor _c = HSVColor.fromColor(widget.initial);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Custom colour', style: Ty.h2),
          const SizedBox(height: 16),
          Container(height: 56, decoration: BoxDecoration(color: _c.toColor(), borderRadius: BorderRadius.circular(Rad.control), border: Border.all(color: HubColors.line))),
          Slider(value: _c.hue, max: 360, onChanged: (v) => setState(() => _c = _c.withHue(v))),
          Slider(value: _c.saturation, onChanged: (v) => setState(() => _c = _c.withSaturation(v))),
          Slider(value: _c.value, onChanged: (v) => setState(() => _c = _c.withValue(v))),
          const SizedBox(height: 8),
          FilledButton(onPressed: () => Navigator.pop(context, _c.toColor().toARGB32()), child: const Text('Use colour')),
        ]),
      );
}

// ======================================================================= photo
class _PhotoSender extends StatefulWidget {
  const _PhotoSender();
  @override
  State<_PhotoSender> createState() => _PhotoSenderState();
}

class _PhotoSenderState extends State<_PhotoSender> {
  ui.Image? _img;
  Uint8List? _rgba, _png;
  bool _fit = false;
  double _pan = 0.5;
  double? _progress;
  String? _error;

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes(), targetWidth: 640);
      final img = (await codec.getNextFrame()).image;
      _img?.dispose();
      _img = img;
      await _render();
    } catch (e) {
      if (mounted) setState(() => _error = 'That picture couldn\'t be opened.');
    }
  }

  Future<void> _render() async {
    final img = _img;
    if (img == null) return;
    final r = await renderImage(img, 160, 128, fit: _fit, pan: _pan);
    if (mounted) setState(() { _rgba = r.rgba; _png = r.png; _error = null; });
  }

  Future<void> _send() async {
    final hub = HubScope.read(context);
    setState(() { _progress = 0; _error = null; });
    try {
      await sendFrameVia((b) => hub.send(b, idempotent: true, timeout: const Duration(seconds: 10)), rgbaToRgb565(_rgba!), onProgress: (p) => mounted ? setState(() => _progress = p) : null);
      if (mounted) toast(context, 'Sent to the Hub');
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t send: ${friendlyError(e)}');
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      const Hint('Pick a photo. It is fitted to the display shape (160 x 128) and sent in a few strips.'),
      const SizedBox(height: 12),
      if (_png != null) DisplayFrame(child: Image.memory(_png!, fit: BoxFit.fill, filterQuality: FilterQuality.none, gaplessPlayback: true)) else StateView.empty('No photo yet', icon: Icons.photo_outlined, message: 'Choose one from your gallery.'),
      if (_png != null) ...[
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: false, label: Text('Fill (crop)')), ButtonSegment(value: true, label: Text('Fit'))],
          selected: {_fit},
          onSelectionChanged: (v) { _fit = v.first; _render(); },
        ),
        if (!_fit) Row(children: [const Text('Crop position', style: Ty.secondary), Expanded(child: Slider(value: _pan, onChanged: (v) => setState(() => _pan = v), onChangeEnd: (_) => _render()))]),
      ],
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.photo_library_outlined), label: const Text('Choose photo')),
        const SizedBox(width: 10),
        Expanded(child: FilledButton.icon(onPressed: _rgba == null || _progress != null || !hub.canSend ? null : _send, icon: const Icon(Icons.send_rounded), label: const Text('Send'))),
      ]),
      if (_progress != null) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(value: _progress)),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Hint(_error!, color: HubColors.danger)),
    ]);
  }
}

/// Used by tests and other screens that need the same conversion the editor uses.
Uint8List cellsToRgba160(Uint32List cells) {
  final rgba = Uint8List(160 * 128 * 4);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 160; x++) {
      final c = cells[(y ~/ 4) * _gw + (x ~/ 4)];
      final i = (y * 160 + x) * 4;
      rgba[i] = (c >> 16) & 0xFF;
      rgba[i + 1] = (c >> 8) & 0xFF;
      rgba[i + 2] = c & 0xFF;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}
