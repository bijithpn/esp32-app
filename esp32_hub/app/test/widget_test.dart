import 'package:esp32_hub_app/core/app_prefs.dart';
import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/connection.dart';
import 'package:esp32_hub_app/core/diagnostics.dart';
import 'package:esp32_hub_app/core/discovery.dart';
import 'package:esp32_hub_app/core/models.dart';
import 'package:esp32_hub_app/core/registry.dart';
import 'package:esp32_hub_app/main.dart';
import 'package:esp32_hub_app/screens/manual.dart';
import 'package:esp32_hub_app/screens/pairing.dart';
import 'package:esp32_hub_app/screens/scene_ui.dart';
import 'package:esp32_hub_app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

Future<ConnectionManager> setup(WidgetTester t, {Widget Function()? home}) async {
  t.view.physicalSize = const Size(800, 3000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  SharedPreferences.setMockInitialValues({});
  final b = FakeBridge();
  Bridge.current = b;
  final hub = ConnectionManager(registry: DeviceRegistry(), bridge: b, log: DiagLog(), history: ConnHistory(), discovery: DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero));
  final prefs = AppPrefs();
  await t.runAsync(() async {
    await prefs.load();
    await hub.init();
  });
  await t.pumpWidget(MaterialApp(theme: buildHubTheme(), home: HubScope(manager: hub, child: PrefsScope(prefs: prefs, child: home == null ? const HomeGate() : home()))));
  return hub;
}

void main() {
  testWidgets('with no paired Hub the welcome screen offers the three routes', (t) async {
    final hub = await setup(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Add a new Hub'), findsOneWidget);
    expect(find.text('Scan the Hub\'s QR code'), findsOneWidget);
    expect(find.text('Enter address'), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('No Hub found'), findsOneWidget);
    expect(find.textContaining('Nothing answered'), findsOneWidget, reason: 'an actionable checklist, not a bare error');
    hub.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the pairing flow starts with clear instructions and a disabled connect button', (t) async {
    final hub = await setup(t, home: () => const PairingScreen());
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Hold the BOOT button for 2 seconds'), findsOneWidget);
    expect(find.textContaining('Step 1 of 6'), findsOneWidget);
    FilledButton btn() => t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect to Hub'));
    expect(btn().onPressed, isNull);
    await t.enterText(find.byType(TextField).first, 'abcd2345');
    await t.pump();
    expect(btn().onPressed, isNotNull);
    await t.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('StateView shows an error with a retry action', (t) async {
    var tapped = false;
    await t.pumpWidget(MaterialApp(theme: buildHubTheme(), home: Scaffold(body: StateView.error('Your Hub isn\'t responding.', onRetry: () => tapped = true))));
    await t.tap(find.text('Try again'));
    expect(tapped, isTrue);
  });

  testWidgets('a scene card shows name, category and the active marker', (t) async {
    await t.pumpWidget(MaterialApp(theme: buildHubTheme(), home: Scaffold(body: SizedBox(width: 180, height: 200, child: SceneCard(scene: const {'id': 'pomo', 'name': 'Pomodoro'}, active: true, favorite: false, onTap: () {})))));
    expect(find.text('Pomodoro'), findsOneWidget);
    expect(find.text('Productivity'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion is honoured', (t) async {
    late bool reduced;
    await t.pumpWidget(MediaQuery(data: const MediaQueryData(disableAnimations: true), child: Builder(builder: (c) {
      reduced = reducedMotion(c);
      return const SizedBox();
    })));
    expect(reduced, isTrue);
  });

  testWidgets('a paired Hub opens the dashboard with its name and a connection state', (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final b = FakeBridge();
    Bridge.current = b;
    final hub = ConnectionManager(registry: DeviceRegistry(), bridge: b, log: DiagLog(), history: ConnHistory(), discovery: DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero), linkFactory: (h, tk, id) => FakeLink(h, token: tk, id: id));
    final prefs = AppPrefs();
    await t.runAsync(() async {
      await prefs.load();
      await hub.registry.load();
      await hub.registry.upsert(HubDevice(id: 'C224AC', name: 'Desk Hub', host: '192.168.1.5'), select: true);
      await hub.init();
      await Future.delayed(const Duration(milliseconds: 100));
    });
    await t.pumpWidget(MaterialApp(theme: buildHubTheme(), home: HubScope(manager: hub, child: PrefsScope(prefs: prefs, child: const HomeGate()))));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Desk Hub'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('Quick actions'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('screens opened with Navigator.push can reach the shared state (no blank screen)', (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final b = FakeBridge();
    Bridge.current = b;
    final hub = ConnectionManager(registry: DeviceRegistry(), bridge: b, log: DiagLog(), history: ConnHistory(), discovery: DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero));
    await t.pumpWidget(HubApp(manager: hub, prefs: AppPrefs()));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.widgetWithText(FilledButton, 'Add a new Hub'), warnIfMissed: true);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Hold the BOOT button for 2 seconds'), findsOneWidget);
    await t.pageBack();
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    await t.tap(find.text('Enter address'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Connect manually'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('manual connect is prefilled with the saved address and token', (t) async {
    t.view.physicalSize = const Size(800, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final b = FakeBridge();
    Bridge.current = b;
    final hub = ConnectionManager(registry: DeviceRegistry(), bridge: b, log: DiagLog(), history: ConnHistory(), discovery: DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero));
    await t.runAsync(() async {
      await hub.registry.load();
      await hub.registry.upsert(HubDevice(id: 'C224AC', host: '192.168.1.12'), select: true);
      await hub.registry.setToken('C224AC', 'abc123token');
    });
    await t.pumpWidget(MaterialApp(theme: buildHubTheme(), builder: (c, w) => HubScope(manager: hub, child: w!), home: const ManualConnectScreen()));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 300));
    final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].controller!.text, '192.168.1.12');
    expect(fields[1].controller!.text, 'abc123token');
    await t.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
