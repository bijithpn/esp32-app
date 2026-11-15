import 'package:flutter/material.dart';

import 'core/app_prefs.dart';
import 'core/connection.dart';
import 'screens/dashboard.dart';
import 'screens/welcome.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HubApp());
}

/// Root: one [ConnectionManager] (the single owner of every connection) and one [AppPrefs], shared with all screens.
class HubApp extends StatefulWidget {
  const HubApp({super.key});
  @override
  State<HubApp> createState() => _HubAppState();
}

class _HubAppState extends State<HubApp> {
  final _hub = ConnectionManager();
  final _prefs = AppPrefs();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _prefs.load();
    await _hub.init(); // restores paired Hubs from the phone at once, then verifies the selected one in the background
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _hub.dispose();
    _prefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ESP32 Hub',
        debugShowCheckedModeBanner: false,
        theme: buildHubTheme(),
        home: _ready
            ? HubScope(manager: _hub, child: PrefsScope(prefs: _prefs, child: const HomeGate()))
            : const Scaffold(body: SizedBox.expand()), // a blank dark frame for the few milliseconds the saved Hubs take to load
      );
}

/// Shows the welcome screen until a Hub is paired, then the dashboard.
class HomeGate extends StatelessWidget {
  const HomeGate({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = HubScope.of(context);
    return AnimatedSwitcher(
      duration: motion(context, Motion.screen),
      child: hub.device == null ? const WelcomeScreen(key: ValueKey('welcome')) : const DashboardScreen(key: ValueKey('dashboard')),
    );
  }
}
