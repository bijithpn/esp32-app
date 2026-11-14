import 'dart:math' as math;
import 'dart:typed_data';

/// Turns 512 audio samples into 16 spectrum-band levels (0..255) for the display's "Music Bars" scene.
class Spectrum {
  Spectrum({this.n = 512, this.sampleRate = 22050, this.bands = 16}) {
    for (var i = 0; i < n; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    }
    // band edges: log spaced from 60 Hz to 9 kHz
    for (var k = 0; k <= bands; k++) {
      _edges.add(60 * math.pow(9000 / 60, k / bands).toDouble());
    }
  }

  final int n, sampleRate, bands;
  late final Float64List _re = Float64List(n), _im = Float64List(n), _window = Float64List(n);
  final List<double> _edges = [];

  /// [samples] must hold at least [n] values in the 16-bit range (-32768..32767); the last [n] are used.
  List<int> process(List<double> samples) {
    final off = samples.length - n;
    for (var i = 0; i < n; i++) {
      _re[i] = samples[off + i] * _window[i];
      _im[i] = 0;
    }
    _fft();
    final out = List<int>.filled(bands, 0);
    for (var k = 0; k < bands; k++) {
      var lo = (_edges[k] * n / sampleRate).floor();
      var hi = (_edges[k + 1] * n / sampleRate).ceil();
      if (lo < 1) lo = 1;
      if (hi <= lo) hi = lo + 1;
      if (hi > n ~/ 2) hi = n ~/ 2;
      var peak = 0.0;
      for (var b = lo; b < hi; b++) {
        final m = math.sqrt(_re[b] * _re[b] + _im[b] * _im[b]) / (n / 4) / 32768.0;
        if (m > peak) peak = m;
      }
      final db = 20 * math.log(peak + 1e-9) / math.ln10;       // about -90 (silence) .. 0 (full scale)
      out[k] = ((db + 62) / 52 * 255).clamp(0, 255).round();    // -62 dB -> 0, -10 dB -> 255
    }
    return out;
  }

  // in-place iterative radix-2 FFT over _re/_im
  void _fft() {
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = _re[i]; _re[i] = _re[j]; _re[j] = tr;
        final ti = _im[i]; _im[i] = _im[j]; _im[j] = ti;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = -2 * math.pi / len;
      final wr = math.cos(ang), wi = math.sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        for (var k = 0; k < len ~/ 2; k++) {
          final ur = _re[i + k], ui = _im[i + k];
          final vr = _re[i + k + len ~/ 2] * cr - _im[i + k + len ~/ 2] * ci;
          final vi = _re[i + k + len ~/ 2] * ci + _im[i + k + len ~/ 2] * cr;
          _re[i + k] = ur + vr; _im[i + k] = ui + vi;
          _re[i + k + len ~/ 2] = ur - vr; _im[i + k + len ~/ 2] = ui - vi;
          final nr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = nr;
        }
      }
    }
  }
}
