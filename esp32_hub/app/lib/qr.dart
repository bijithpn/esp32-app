import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'theme.dart';

/// The Wi-Fi QR code shown on a board in setup mode: WIFI:T:WPA;S:ESP32-Hub;P:<8 characters>;;
class HubWifiQr {
  HubWifiQr(this.ssid, this.pass);
  final String ssid, pass;

  static HubWifiQr? parse(String text) {
    final t = text.trim();
    if (!t.toUpperCase().startsWith('WIFI:')) return null;
    String? field(String k) {
      final m = RegExp('(?:^|;)$k:((?:\\\\.|[^;\\\\])*)').firstMatch(t.substring(5));
      return m?.group(1)?.replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!);
    }

    final ssid = field('S');
    if (ssid == null || !ssid.startsWith('ESP32-Hub')) return null; // only the board's own hotspot
    return HubWifiQr(ssid, field('P') ?? '');
  }
}

/// What the board's "Pair (QR)" scene encodes: hub://pair?id=C224AC&t=TOKEN&ip=IP
/// The token is only shown on the board's own screen (physical access), never in a printed or shared code.
class PairInfo {
  PairInfo(this.id, this.token, this.ip);
  final String id, token, ip;

  static PairInfo? parse(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || u.scheme != 'hub') return null;
    final id = u.queryParameters['id'], t = u.queryParameters['t'], ip = u.queryParameters['ip'];
    if (id == null || t == null || ip == null) return null;
    return PairInfo(id.toUpperCase(), t, ip);
  }
}

/// Full-screen QR scanner with a viewfinder. Returns the scanned text (a Wi-Fi code or a pairing code from the board).
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key, this.hint = 'Scan the QR on a new Hub\'s setup screen, or its "Pair (QR)" scene. Hold the phone about 20 cm from the screen.'});
  final String hint;
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final MobileScannerController _ctl = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates, autoZoom: true); // autoZoom: the code on the board's small screen is tiny
  bool _done = false, _torch = false;
  bool? _camOk;
  String? _warn;

  @override
  void initState() {
    super.initState();
    _askCamera();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _askCamera() async {
    final st = await Permission.camera.request();
    if (mounted) setState(() => _camOk = st.isGranted);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v == null) continue;
      if (PairInfo.parse(v) != null || HubWifiQr.parse(v) != null) {
        _done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(v);
        return;
      }
      if (_warn == null) {
        setState(() => _warn = 'That QR code is not from an ESP32 Hub.');
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _warn = null);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false, // an open keyboard must never squash the camera view
      body: SafeArea(
        top: false,
        bottom: false,
        child: _camOk == null
            ? const Center(child: CircularProgressIndicator())
            : _camOk == false
                ? _noCamera()
                : LayoutBuilder(builder: (context, c) {
                    final box = (c.biggest.shortestSide * 0.68).clamp(200.0, 320.0);
                    return SizedBox(
                      width: c.maxWidth,
                      height: c.maxHeight,
                      child: Stack(fit: StackFit.expand, children: [
                        MobileScanner(controller: _ctl, onDetect: _onDetect, fit: BoxFit.cover, errorBuilder: (ctx, e) => _noCamera(error: true)),
                        CustomPaint(painter: _ViewfinderPainter(box)),
                        _ScanLine(box: box),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                              child: Row(children: [
                                IconButton(tooltip: 'Close', style: IconButton.styleFrom(backgroundColor: Colors.black54), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                                const Spacer(),
                                IconButton(
                                  tooltip: 'Torch',
                                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                  onPressed: () {
                                    _ctl.toggleTorch();
                                    setState(() => _torch = !_torch);
                                  },
                                  icon: Icon(_torch ? Icons.flash_on_rounded : Icons.flash_off_rounded),
                                ),
                              ]),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 0,
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 20),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                if (_warn != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: StatusPill(color: HubColors.warn, label: _warn!)),
                                Panel(
                                  color: const Color(0xE6101215),
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                    const Text('Scan the code on your Hub', style: Ty.title),
                                    const SizedBox(height: 6),
                                    Text(widget.hint, textAlign: TextAlign.center, style: Ty.secondary),
                                  ]),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ]),
                    );
                  }),
      ),
    );
  }

  Widget _noCamera({bool error = false}) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.no_photography_outlined, size: 48, color: HubColors.muted),
            const SizedBox(height: 18),
            Text(error ? 'The camera did not start' : 'Camera access is needed', textAlign: TextAlign.center, style: Ty.h2),
            const SizedBox(height: 8),
            const Hint('Only to read the QR code on your Hub. Nothing is recorded or sent anywhere. You can also type the code shown on the Hub\'s screen.'),
            const SizedBox(height: 24),
            FilledButton(onPressed: openAppSettings, child: const Text('Open settings')),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _askCamera, child: const Text('Try again')),
            const SizedBox(height: 6),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ]),
        ),
      );
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter(this.box);
  final double box;
  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: box, height: box), const Radius.circular(24));
    final dim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.62));
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 34.0;
    final b = r.outerRect;
    for (final c in [
      [b.topLeft, const Offset(l, 0), const Offset(0, l)],
      [b.topRight, const Offset(-l, 0), const Offset(0, l)],
      [b.bottomLeft, const Offset(l, 0), const Offset(0, -l)],
      [b.bottomRight, const Offset(-l, 0), const Offset(0, -l)],
    ]) {
      canvas.drawLine(c[0], c[0] + c[1], p);
      canvas.drawLine(c[0], c[0] + c[2], p);
    }
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => old.box != box;
}

/// A line that sweeps up and down inside the viewfinder.
class _ScanLine extends StatelessWidget {
  const _ScanLine({required this.box});
  final double box;
  @override
  Widget build(BuildContext context) => Live(paint: (c, size, t) {
        final top = size.height * 0.42 - box / 2 + 12, h = box - 24;
        final k = (math.sin(t * 2.2) + 1) / 2;
        final y = top + k * h;
        c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(size.width / 2 - box / 2 + 14, y - 1.5, box - 28, 3), const Radius.circular(2)),
          Paint()..color = Colors.white.withValues(alpha: 0.85),
        );
      });
}
