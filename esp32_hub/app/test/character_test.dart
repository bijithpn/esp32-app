import 'package:esp32_hub_app/core/bridge.dart';
import 'package:esp32_hub_app/core/connection.dart';
import 'package:esp32_hub_app/core/diagnostics.dart';
import 'package:esp32_hub_app/core/discovery.dart';
import 'package:esp32_hub_app/core/registry.dart';
import 'package:esp32_hub_app/core/errors.dart';
import 'package:esp32_hub_app/core/muse_look.dart';
import 'package:esp32_hub_app/features/character.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  test('damaged saved data falls back to the default character', () {
    expect(MuseLook.fromJson(null), const MuseLook());
    expect(MuseLook.fromJson({'character': 'dragon', 'coat': 'rose', 'outfit': 5}), const MuseLook(coat: 'rose'));
    final look = const MuseLook(character: 'panda', coat: 'ocean', outfit: 'crown');
    expect(MuseLook.fromJson(look.toJson()), look);
  });

  test('every character, coat and outfit has its sprite in the app', () async {
    for (final c in museCharacters) {
      for (final k in museCoats) {
        await rootBundle.load('assets/muse/look/character_${c.id}_${k.id}.png');
      }
    }
    for (final o in museOutfits.where((o) => o.id != 'none')) {
      await rootBundle.load('assets/muse/look/outfit_${o.id}.png');
    }
  });

  test('the Hub is sent the names of the character, coat and outfit, and nothing else', () async {
    final sent = <Map<String, dynamic>>[];
    await sendMuseToHub((b) async { sent.add(b); return {'ok': true}; }, const MuseLook(character: 'kitty', coat: 'rose', outfit: 'crown'));
    expect(sent, [{'cmd': 'char', 'character': 'kitty', 'coat': 'rose', 'outfit': 'crown'}]);
  });

  test('a Hub with older firmware is told apart from other errors', () async {
    expect(sendMuseToHub((b) async => {'ok': false, 'error': 'unknown cmd'}, const MuseLook()), throwsA(isA<CharacterNeedsUpdate>()));
    expect(sendMuseToHub((b) async => {'ok': false, 'error': 'unknown outfit'}, const MuseLook()), throwsA(isA<HubException>()));
  });

  test('touches land on the same parts as on the real Muse', () {
    expect(museTouchZone(const Offset(0.5, 0.15)), 'head');
    expect(museTouchZone(const Offset(0.5, 0.45)), 'cheek');
    expect(museTouchZone(const Offset(0.5, 0.8)), 'belly');
    expect(museTouchZone(const Offset(0.1, 0.55)), 'hand');
    expect(museTouchZone(const Offset(0.9, 0.55)), 'hand');
    expect(museTouchCommand('belly'), {'cmd': 'char', 'touch': 'belly'});
    expect(museTouchCommand('head', petting: true), {'cmd': 'char', 'touch': 'head', 'petting': true});
  });

  testWidgets('tapping and stroking the character tells the Hub which part was touched', (t) async {
    final sent = <List<Object>>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 200, height: 200, child: TouchableMuse(look: const MuseLook(), onTouch: (z, p) => sent.add([z, p]))),
        ),
      ),
    ));
    final box = t.getRect(find.byKey(const ValueKey('touch-muse')));
    await t.tapAt(box.topLeft + const Offset(100, 20)); // top: head
    await t.pump(const Duration(milliseconds: 500));
    await t.tapAt(box.topLeft + const Offset(100, 170)); // bottom: belly
    await t.pump(const Duration(milliseconds: 500));
    await t.tapAt(box.topLeft + const Offset(15, 110)); // side: hand
    await t.pump(const Duration(milliseconds: 500));
    expect(sent, [['head', false], ['belly', false], ['hand', false]]);
    // a stroke across the head is petting
    final g = await t.startGesture(box.topLeft + const Offset(60, 30));
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(40, 0));
    await g.up();
    await t.pump(const Duration(milliseconds: 500));
    expect(sent.last, ['head', true]);
  });

  testWidgets('choosing a character, colour and outfit updates the summary', (t) async {
    t.view.physicalSize = const Size(800, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final b = FakeBridge();
    Bridge.current = b;
    final hub = ConnectionManager(registry: DeviceRegistry(), bridge: b, log: DiagLog(), history: ConnHistory(), discovery: DiscoveryService(bridge: b, log: DiagLog(), sweepDelay: Duration.zero));
    await t.pumpWidget(MaterialApp(home: HubScope(manager: hub, child: const CharacterScreen())));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await t.pump();
    expect(find.text('Muse · Cream'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('character-bunny')));
    await t.pump();
    await t.tap(find.text('Colour'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('coat-mint')));
    await t.pump();
    await t.tap(find.text('Outfit'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('outfit-halo')));
    await t.pump();
    expect(find.text('Bunny · Mint · Halo'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('reset-look')));
    await t.pump();
    expect(find.text('Muse · Cream'), findsOneWidget);
  });
}
