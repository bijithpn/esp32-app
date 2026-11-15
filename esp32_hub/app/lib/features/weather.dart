import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as web;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/bridge.dart';
import '../core/connection.dart';
import '../phone.dart';
import '../theme.dart';

String weatherLabel(int code) {
  if (code == 0) return 'Clear';
  if (code <= 2) return 'Partly cloudy';
  if (code == 3) return 'Overcast';
  if (code <= 48) return 'Fog';
  if (code <= 57) return 'Drizzle';
  if (code <= 67 || (code >= 80 && code <= 82)) return code >= 80 ? 'Showers' : 'Rain';
  if (code <= 77) return 'Snow';
  if (code >= 95) return 'Thunderstorm';
  return 'Weather';
}

class _Place {
  _Place(this.name, this.lat, this.lon);
  final String name;
  final double lat, lon;
}

/// Weather settings: where the Hub gets its weather, a preview with the Hub's real numbers, and when it last updated.
/// The Hub fetches the weather itself (Open-Meteo, no key). The last numbers are kept on the phone so something sensible
/// shows when the Hub is offline.
class WeatherPage extends StatefulWidget {
  const WeatherPage({super.key});
  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> with WidgetsBindingObserver {
  static const _cacheKey = 'weather_cache_v1';
  final _search = TextEditingController(), _lat = TextEditingController(), _lon = TextEditingController();
  Timer? _debounce, _poll;
  Map<String, dynamic>? _w; // temp, humidity, wind, code, ageSec
  bool _cached = false, _refreshing = false, _searching = false;
  double? _curLat, _curLon;
  String _place = '';
  List<_Place> _results = [];
  String? _searchError;
  PermissionStatus _perm = PermissionStatus.denied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadCache();
      if (!mounted) return;
      await HubScope.read(context).trySend({'cmd': 'scene', 'id': 'weather'});
      await _fetch();
    });
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
    _checkPerm();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _poll?.cancel();
    _search.dispose();
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPerm(); // back from the system settings
  }

  Future<void> _checkPerm() async {
    final s = await Permission.locationWhenInUse.status;
    if (mounted) setState(() => _perm = s);
  }

  Future<void> _loadCache() async {
    final p = await SharedPreferences.getInstance();
    _place = p.getString('weather_place') ?? '';
    final raw = p.getString(_cacheKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        if (mounted) setState(() { _w = j; _cached = true; });
      } catch (_) {
        // an unreadable cache is ignored
      }
    }
  }

  Future<void> _fetch() async {
    final hub = HubScope.read(context);
    if (!hub.canSend) return;
    try {
      final r = await hub.send({'cmd': 'state'}, idempotent: true, dedupeKey: 'state', retries: 0, timeout: const Duration(seconds: 3));
      final w = r['weather'];
      if (w is Map && mounted) {
        final m = w.cast<String, dynamic>();
        setState(() {
          _curLat = (m['lat'] as num?)?.toDouble();
          _curLon = (m['lon'] as num?)?.toDouble();
          if (m['temp'] != null) {
            _w = {...m, 'at': DateTime.now().millisecondsSinceEpoch};
            _cached = false;
          }
        });
        if (m['temp'] != null) (await SharedPreferences.getInstance()).setString(_cacheKey, jsonEncode(_w));
      }
    } catch (_) {
      // offline: the cached numbers stay on screen
    }
  }

  Future<void> _setLocation(double lat, double lon, String name) async {
    final hub = HubScope.read(context);
    final ok = await hub.trySend({'cmd': 'loc', 'lat': lat, 'lon': lon}, idempotent: true, onError: (m) => toast(context, m));
    if (!ok || !mounted) return;
    (await SharedPreferences.getInstance()).setString('weather_place', name);
    setState(() { _place = name; _curLat = lat; _curLon = lon; _results = []; _search.clear(); _refreshing = true; });
    for (var i = 0; i < 4; i++) {
      await Future.delayed(const Duration(seconds: 3)); // the Hub fetches within a few seconds
      await _fetch();
    }
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _useMine() async {
    var st = await Permission.locationWhenInUse.request();
    if (!mounted) return;
    setState(() => _perm = st);
    if (!st.isGranted) return;
    final l = await Bridge.current.location();
    if (!mounted) return;
    if (l == null) {
      toast(context, 'Turn on location in the quick settings, then try again.');
      return;
    }
    await PhoneSync.sendLocation(HubScope.read(context));
    await _setLocation(l.lat, l.lon, 'Your location');
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() { _results = []; _searchError = null; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _runSearch(q.trim()));
  }

  Future<void> _runSearch(String q) async {
    setState(() { _searching = true; _searchError = null; });
    try {
      // The city text goes to Open-Meteo's geocoding service (the same free service the Hub uses for the forecast). Nothing else is sent.
      final r = await web.get(Uri.https('geocoding-api.open-meteo.com', '/v1/search', {'name': q, 'count': '6', 'language': 'en', 'format': 'json'})).timeout(const Duration(seconds: 6));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final list = (j['results'] as List?) ?? const [];
      if (!mounted) return;
      setState(() => _results = [
            for (final e in list) _Place('${e['name']}${e['admin1'] != null ? ', ${e['admin1']}' : ''}${e['country'] != null ? ' · ${e['country']}' : ''}', (e['latitude'] as num).toDouble(), (e['longitude'] as num).toDouble()),
          ]);
      if (_results.isEmpty) setState(() => _searchError = 'No place called "$q". Check the spelling.');
    } catch (_) {
      if (mounted) setState(() => _searchError = 'Couldn\'t reach the city search. Check your internet connection, or use coordinates below.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  String _ago(Map<String, dynamic> w) {
    final age = (w['ageSec'] as num?)?.toInt();
    int? secs;
    if (_cached && w['at'] is int) secs = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(w['at'] as int)).inSeconds;
    secs ??= (age != null && age >= 0) ? age : null;
    if (secs == null) return '—';
    if (secs < 60) return 'just now';
    if (secs < 3600) return '${secs ~/ 60} min ago';
    return '${secs ~/ 3600} h ago';
  }

  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    final w = _w;
    final temp = w?['temp'] is num ? (w!['temp'] as num).round().toString() : '--';
    final code = (w?['code'] as num?)?.toInt() ?? -1;
    return Scaffold(
      appBar: AppBar(title: const Text('Weather')),
      body: ListView(padding: Sp.page, children: [
        DisplayFrame(child: WeatherScreen(temp: temp, place: _place.isEmpty ? 'Set a location' : _place, label: code < 0 ? '…' : weatherLabel(code))),
        const SizedBox(height: 16),
        if (w == null)
          const Panel(child: Row(children: [Icon(Icons.cloud_off_rounded, color: HubColors.muted), SizedBox(width: 12), Expanded(child: Text('No weather yet. Choose a location below and the Hub fetches it within a few seconds.', style: Ty.secondary))]))
        else
          Row(children: [
            _Stat(icon: Icons.thermostat_rounded, label: 'Temperature', value: '$temp°C'),
            const SizedBox(width: 10),
            _Stat(icon: Icons.water_drop_outlined, label: 'Humidity', value: '${(w['humidity'] as num?)?.round() ?? '—'}%'),
            const SizedBox(width: 10),
            _Stat(icon: Icons.air_rounded, label: 'Wind', value: '${(w['wind'] as num?)?.round() ?? '—'} km/h'),
          ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text(w == null ? '' : (_cached ? 'Last known · ${_ago(w)}${hub.canSend ? '' : ' · Hub offline'}' : 'Updated ${_ago(w)}'), style: Ty.meta)),
          if (_refreshing) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) else TextButton(onPressed: hub.canSend && _curLat != null ? () => _setLocation(_curLat!, _curLon!, _place) : null, child: const Text('Refresh')),
        ]),
        const SectionTitle('Location', top: 12),
        if (_perm.isPermanentlyDenied)
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Location is blocked for this app', style: Ty.title),
              const SizedBox(height: 6),
              const Hint('That\'s fine: search for a city below instead. Or allow it in the app settings to use where you are.'),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: openAppSettings, child: const Text('Open app settings')),
            ]),
          )
        else
          OutlinedButton.icon(onPressed: hub.canSend ? _useMine : null, icon: const Icon(Icons.my_location_rounded), label: Text(_perm.isGranted ? 'Use my location now' : 'Allow and use my location')),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          onChanged: _onSearch,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(labelText: 'Search a city', prefixIcon: const Icon(Icons.search_rounded, color: HubColors.muted), suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null),
        ),
        if (_searchError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Hint(_searchError!, color: HubColors.warn)),
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 10),
          Group(children: [for (final p in _results) Row2(icon: Icons.place_outlined, title: p.name, sub: '${p.lat.toStringAsFixed(2)}, ${p.lon.toStringAsFixed(2)}', onTap: hub.canSend ? () => _setLocation(p.lat, p.lon, p.name.split(',').first.split(' · ').first) : null)]),
        ],
        const SizedBox(height: 8),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Enter coordinates', style: Ty.bodyStrong),
            children: [
              Row(children: [
                Expanded(child: TextField(controller: _lat, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitude'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: _lon, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitude'))),
              ]),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: hub.canSend
                    ? () {
                        final la = double.tryParse(_lat.text), lo = double.tryParse(_lon.text);
                        if (la == null || lo == null || la.abs() > 90 || lo.abs() > 180) {
                          toast(context, 'Latitude is -90 to 90 and longitude -180 to 180.');
                          return;
                        }
                        _setLocation(la, lo, '${la.toStringAsFixed(2)}, ${lo.toStringAsFixed(2)}');
                      }
                    : null,
                child: const Text('Use these coordinates'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Hint('Only an approximate position is used, and it is only sent to your Hub.'),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Panel(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: HubColors.muted),
            const SizedBox(height: 8),
            Text(value, style: Ty.title),
            Text(label, style: Ty.meta),
          ]),
        ),
      );
}
