import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as web;

import '../api.dart';
import '../core/connection.dart';
import '../core/errors.dart';
import '../core/firmware.dart';
import '../theme.dart';
import '../version.dart';

enum _Stage { checking, ready, downloading, uploading, restarting, done, failed }

/// Firmware update centre: what is installed, what is available, release notes, compatibility, then a guarded install.
/// Nothing installs without the user pressing Install and confirming.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key});
  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen> {
  _Stage _stage = _Stage.checking;
  FirmwareRelease? _rel;
  String? _error, _result;
  double _progress = 0;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() { _stage = _Stage.checking; _error = null; _rel = null; });
    try {
      // The project's own releases on GitHub. The request carries nothing about you or your Hub.
      final r = await web.get(Uri.parse('$releasesUrl?per_page=15'), headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'esp32-hub-app'}).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
      FirmwareRelease? best;
      for (final e in jsonDecode(r.body) as List) {
        final p = FirmwareRelease.fromGithub((e as Map).cast<String, dynamic>());
        if (p == null) continue;
        final m = await web.get(Uri.parse(p.manifestUrl)).timeout(const Duration(seconds: 10));
        final full = p.withManifest(m.body);
        if (!full.compatible) continue;
        if (best == null || compareVersions(full.version, best.version) > 0) best = full;
      }
      if (!mounted) return;
      setState(() { _rel = best; _stage = _Stage.ready; });
    } catch (e) {
      if (mounted) setState(() { _stage = _Stage.failed; _error = e is FormatException ? 'A release has a damaged firmware description: ${e.message}' : 'Couldn\'t check for updates. Check your internet connection and try again.'; });
    }
  }

  Future<void> _install() async {
    final hub = HubScope.read(context);
    final rel = _rel;
    final api = hub.api;
    if (rel == null || api is! HttpApi) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Install ${rel.version}?'),
        content: const Text('The Hub restarts when the update finishes. Keep it powered and stay on the same Wi-Fi.\n\nThis Hub has no automatic rollback: if an update were interrupted or faulty, you would have to reflash it with a USB cable.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Install'))],
      ),
    );
    if (ok != true || !mounted) return;
    _cancel = false;
    setState(() { _stage = _Stage.downloading; _progress = 0; _error = null; });
    Uint8List bin;
    try {
      bin = await _download(rel);
    } catch (e) {
      if (mounted) setState(() { _stage = _Stage.failed; _error = _cancel ? 'Cancelled. Nothing was changed.' : 'The download failed. Nothing was changed on the Hub.'; });
      return;
    }
    if (_cancel || !mounted) {
      if (mounted) setState(() { _stage = _Stage.ready; });
      return;
    }
    // sanity checks before the Hub is touched: an ESP32 app image starts with 0xE9 and must fit the 1.9 MB slot
    if (bin.length < 100000 || bin.length > 1966080 || bin[0] != 0xE9 || (rel.size > 0 && bin.length != rel.size)) {
      setState(() { _stage = _Stage.failed; _error = 'The downloaded file is not a valid firmware image. Nothing was changed on the Hub.'; });
      return;
    }
    hub.beginFirmwareUpdate();
    setState(() { _stage = _Stage.uploading; _progress = 0; });
    try {
      await api.uploadFirmware(bin, md5: rel.md5, cancelled: () => _cancel, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
    } catch (e) {
      final h = toHubException(e);
      await hub.finishFirmwareUpdate(); // the Hub keeps running the old image: reconnect to it
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = h.kind == HubError.cancelled ? 'Cancelled. The Hub is still running its previous firmware.' : _otaMessage(h);
        });
      }
      return;
    }
    if (mounted) setState(() => _stage = _Stage.restarting);
    final fw = await hub.finishFirmwareUpdate();
    if (!mounted) return;
    final good = fw != null && compareVersions(fw, rel.version) == 0;
    setState(() {
      _stage = good ? _Stage.done : _Stage.failed;
      _result = good ? 'Your Hub is running ${rel.version}.' : null;
      _error = good ? null : (fw == null ? 'The Hub didn\'t come back within a minute. Check that it is powered; it may still be restarting.' : 'The Hub restarted with firmware $fw instead of ${rel.version}.');
    });
  }

  String _otaMessage(HubException h) {
    switch (h.code) {
      case 'ota_wrong_model':
        return 'The Hub says this firmware is for a different board. Nothing was changed.';
      case 'ota_too_large':
        return 'The firmware doesn\'t fit this Hub\'s update slot. Nothing was changed.';
      case 'ota_not_esp32_image':
        return 'The Hub rejected the file: it isn\'t a valid ESP32 firmware image. Nothing was changed.';
      case 'ota_stalled':
      case 'ota_aborted':
        return 'The upload stopped halfway. The Hub kept its previous firmware.';
      default:
        if (h.kind == HubError.auth) return 'The Hub didn\'t accept this phone\'s token, so the update was refused.';
        if (h.detail.contains('MD5') || h.code.contains('MD5')) return 'The Hub checked the file and it didn\'t match what was published. Nothing was changed.';
        return 'The update failed and the Hub kept its previous firmware. Try again.';
    }
  }

  Future<Uint8List> _download(FirmwareRelease rel) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(rel.binUrl));
      req.headers.set('User-Agent', 'esp32-hub-app');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength > 0 ? res.contentLength : rel.size;
      final out = BytesBuilder(copy: false);
      await for (final chunk in res) {
        if (_cancel) throw const HttpException('cancelled');
        out.add(chunk);
        if (total > 0 && mounted) setState(() => _progress = out.length / total);
      }
      return out.takeBytes();
    } finally {
      c.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final d = hub.device;
    final installed = d?.fw ?? '';
    final rel = _rel;
    final newer = rel != null && installed.isNotEmpty && compareVersions(rel.version, installed) > 0;
    final busy = _stage == _Stage.downloading || _stage == _Stage.uploading || _stage == _Stage.restarting;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Firmware'), automaticallyImplyLeading: !busy),
        body: ListView(padding: Sp.page, children: [
          Group(children: [
            Row2(icon: Icons.memory_rounded, title: 'Installed', sub: d?.name ?? '', trailing: Text(installed.isEmpty ? '—' : installed, style: Ty.title)),
            Row2(icon: Icons.cloud_download_outlined, title: 'Available', trailing: _stage == _Stage.checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(rel?.version ?? 'none found', style: Ty.title)),
            Row2(icon: Icons.verified_outlined, title: 'Compatibility', sub: 'ESP32 · ST7735S 160 × 128 · API ${d?.apiVersion ?? 0} (app expects $apiVersionWanted)', trailing: StatusPill(color: (d?.apiVersion ?? 0) >= apiVersionWanted ? HubColors.ok : HubColors.warn, label: (d?.apiVersion ?? 0) >= apiVersionWanted ? 'Current' : 'Legacy')),
          ]),
          const SizedBox(height: 16),
          if (_stage == _Stage.checking) StateView.loading('Checking for updates'),
          if (_stage == _Stage.failed && _error != null) ...[
            Panel(color: HubColors.danger.withValues(alpha: 0.08), borderColor: HubColors.danger.withValues(alpha: 0.4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.error_outline_rounded, color: HubColors.danger), const SizedBox(width: 12), Expanded(child: Text(_error!, style: Ty.body.copyWith(fontSize: 14)))])),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _check, child: const Text('Check again')),
          ],
          if (_stage == _Stage.done) Panel(color: HubColors.ok.withValues(alpha: 0.08), borderColor: HubColors.ok.withValues(alpha: 0.4), child: Row(children: [const Icon(Icons.check_circle_outline_rounded, color: HubColors.ok), const SizedBox(width: 12), Expanded(child: Text(_result ?? 'Updated.', style: Ty.bodyStrong))])),
          if (_stage == _Stage.ready) ...[
            if (rel == null)
              Panel(child: Text('No firmware releases were found. This app was built with firmware $bundledFirmware.', style: Ty.secondary.copyWith(fontSize: 14)))
            else if (!newer)
              Panel(child: Row(children: [const Icon(Icons.check_circle_outline_rounded, color: HubColors.ok), const SizedBox(width: 12), Expanded(child: Text('Your Hub is up to date.', style: Ty.bodyStrong))]))
            else ...[
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Version ${rel.version} is available', style: Ty.title),
                  const SizedBox(height: 8),
                  Text(rel.notes.trim().isEmpty ? 'No release notes.' : rel.notes.trim(), maxLines: 12, overflow: TextOverflow.ellipsis, style: Ty.secondary.copyWith(fontSize: 14)),
                  const SizedBox(height: 8),
                  Text('${(rel.size / 1024).round()} KB · MD5 ${rel.md5.substring(0, 8)}…', style: Ty.meta),
                ]),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: hub.canSend && hub.api is HttpApi ? _install : null, icon: const Icon(Icons.system_update_alt_rounded), label: const Text('Install update')),
              if (hub.api is! HttpApi) const Padding(padding: EdgeInsets.only(top: 8), child: Hint('Updating needs a direct Wi-Fi connection to the Hub.')),
            ],
          ],
          if (busy) ...[
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(switch (_stage) { _Stage.downloading => 'Downloading the update', _Stage.uploading => 'Sending it to the Hub', _ => 'The Hub is restarting' }, style: Ty.title),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: _stage == _Stage.restarting ? null : _progress, minHeight: 6),
                const SizedBox(height: 8),
                Text(_stage == _Stage.restarting ? 'Checking the new version once it is back.' : '${(_progress * 100).round()} %. Do not unplug the Hub.', style: Ty.secondary),
                if (_stage != _Stage.restarting) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('Cancel'))),
              ]),
            ),
          ],
          const SectionTitle('How updates stay safe'),
          const Hint('The app asks the Hub to accept the file only with your token, and the Hub checks the image header, its size, the board model and an MD5 of what it received before it switches to it. It does not check a digital signature, and it cannot roll back by itself if a new version misbehaves, so only install releases from this project.'),
        ]),
      ),
    );
  }
}
