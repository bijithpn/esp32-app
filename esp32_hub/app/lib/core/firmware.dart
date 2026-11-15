import 'dart:convert';

/// Compares dotted versions numerically ("0.10.0" > "0.9.2"). Anything that is not a number counts as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[.\-+]')).map((e) => int.tryParse(e) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p < q ? -1 : 1;
  }
  return 0;
}

/// A firmware image published with a release: the .bin, and a small manifest next to it.
class FirmwareRelease {
  FirmwareRelease({required this.version, required this.binUrl, required this.md5, required this.size, required this.notes, required this.model, this.minApi = 0});
  final String version, binUrl, md5, notes, model;
  final int size, minApi;

  /// Whether this image is meant for this kind of board ("esp32-hub": ESP32 + ST7735S 160 x 128).
  bool get compatible => model == 'esp32-hub';

  /// Reads a GitHub "release" object. Needs an asset "firmware.json" ({version, md5, size, model, minApi}) and the .bin it names.
  /// Returns null for releases that carry no firmware (the app releases).
  static FirmwareRelease? fromGithub(Map<String, dynamic> rel) {
    final assets = (rel['assets'] as List?)?.whereType<Map>().toList() ?? const [];
    final manifest = assets.where((a) => '${a['name']}' == 'firmware.json').firstOrNull;
    if (manifest == null) return null;
    return FirmwareRelease._pending(rel, assets, '${manifest['browser_download_url']}');
  }

  /// Fills the rest from the manifest text. Throws [FormatException] for a damaged manifest.
  FirmwareRelease withManifest(String text) {
    Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const FormatException('The firmware manifest is not valid.');
    }
    if (j is! Map || j['version'] is! String || j['md5'] is! String || (j['md5'] as String).length != 32) throw const FormatException('The firmware manifest is incomplete.');
    final file = '${j['file'] ?? 'firmware.bin'}';
    final bin = _assets.where((a) => '${a['name']}' == file || '${a['name']}'.endsWith('.bin')).firstOrNull;
    if (bin == null) throw const FormatException('The release has no firmware file.');
    return FirmwareRelease(
      version: j['version'] as String,
      binUrl: '${bin['browser_download_url']}',
      md5: (j['md5'] as String).toLowerCase(),
      size: (j['size'] as num?)?.toInt() ?? (bin['size'] as num?)?.toInt() ?? 0,
      notes: _notes,
      model: '${j['model'] ?? ''}',
      minApi: (j['minApi'] as num?)?.toInt() ?? 0,
    );
  }

  FirmwareRelease._pending(Map<String, dynamic> rel, this._assets, this.manifestUrl)
      : version = '',
        binUrl = '',
        md5 = '',
        size = 0,
        notes = '',
        model = '',
        minApi = 0,
        _notes = '${rel['body'] ?? ''}';

  List<Map> _assets = const [];
  String _notes = '';
  String manifestUrl = '';
}
