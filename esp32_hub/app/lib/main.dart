import 'package:flutter/material.dart';

import 'core/app_prefs.dart';
import 'core/connection.dart';
import 'core/diagnostics.dart';
import 'screens/dashboard.dart';
import 'screens/welcome.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A screen that fails to build shows a readable message (and is logged) instead of a blank page.
  ErrorWidget.builder = (details) {
    DiagLog.instance.e('ui', 'build error: ${details.exceptionAsString()}');
    return Material(
      color: HubColors.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, color: HubColors.danger, size: 36),
            const SizedBox(height: 12),
            const Text('This screen couldn\'t open', style: Ty.title),
            const SizedBox(height: 6),
            Text('Go back and try again. Details are in Settings > Diagnostics.', textAlign: TextAlign.center, style: Ty.secondary.copyWith(fontSize: 14)),
          ]),
        ),
      ),
    );
  };
  FlutterError.onError = (d) {
    DiagLog.instance.e('ui', 'flutter error: ${d.exceptionAsString()}');
    FlutterError.presentError(d);
  };
  runApp(const HubApp());
}

/// Root: one [ConnectionManager] (the single owner of every connection) and one [AppPrefs], shared with all screens.
class HubApp extends StatefulWidget {
  const HubApp({super.key, this.manager, this.prefs});

  /// Tests pass their own; the app creates them.
  final ConnectionManager? manager;
  final AppPrefs? prefs;
  @override
  State<HubApp> createState() => _HubAppState();
}

class _HubAppState extends State<HubApp> {
  late final ConnectionManager _hub = widget.manager ?? ConnectionManager();
  late final AppPrefs _prefs = widget.prefs ?? AppPrefs();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _prefs.load();
      await _hub.init(); // restores paired Hubs from the phone at once, then verifies the selected one in the background
    } catch (e) {
      DiagLog.instance.e('app', 'start-up failed: $e'); // the app still opens, on the welcome screen
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    if (widget.manager == null) _hub.dispose(); // only what this widget created
    if (widget.prefs == null) _prefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ESP32 Hub',
        debugShowCheckedModeBanner: false,
        theme: buildHubTheme(),
        // The shared state must sit ABOVE the Navigator: every screen opened with Navigator.push is a sibling of the home
        // screen, not a child, so it could not find the manager if it were provided inside `home`.
        builder: (context, child) => HubScope(manager: _hub, child: PrefsScope(prefs: _prefs, child: child ?? const SizedBox())),
        home: _ready ? const HomeGate() : const Scaffold(body: SizedBox.expand()), // a blank dark frame for the few milliseconds the saved Hubs take to load
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
