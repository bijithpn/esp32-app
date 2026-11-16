import 'dart:math' as math;

import 'package:esp32_hub_app/core/catalog.dart';
import 'package:esp32_hub_app/features/ascii_animals.dart';
import 'package:esp32_hub_app/features/ascii_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

int _cells(AsciiWorld w) => w.flag.where((f) => f != 0).length;

void main() {
  test('there are seven animals, each with its own three knobs, and the scene is in the catalogue', () {
    expect(asciiAnimals.map((a) => a.id), ['butterflies', 'koi', 'jellyfish', 'dragonflies', 'frogs', 'cranes', 'crabs']);
    for (final a in asciiAnimals) {
      expect(a.knobs.length, 3, reason: a.id);
      final t = a.defaults();
      for (final k in [...asciiCommonKnobs, ...a.knobs]) {
        final v = t.get(k.key, a);
        expect(v >= k.min && v <= k.max, true, reason: '${a.id} default ${k.key}=$v outside ${k.min}..${k.max}');
      }
    }
    expect(sceneCatalog['ascii']?.hasPage, true);
  });

  test('every animal runs, draws cells, and stays on finite numbers at both ends of every knob', () {
    for (var i = 0; i < asciiAnimals.length; i++) {
      final a = asciiAnimals[i];
      final w = AsciiWorld(seed: 7)..setAnimal(i);
      var drawn = 0;
      for (var f = 0; f < 250; f++) {
        w.step(0.04);
        w.render(0.04);
        drawn += _cells(w);
      }
      expect(drawn / 250, greaterThan(8), reason: '${a.id} draws almost nothing');
      expect(w.count, w.targetCount);
      for (final extreme in [true, false]) {
        for (final k in [...asciiCommonKnobs, ...a.knobs]) {
          w.tune.set(k.key, extreme ? k.max : k.min, a);
        }
        w.tuneChanged();
        for (var f = 0; f < 200; f++) {
          if (f == 50) w.startle(30, 30);
          w.step(0.04);
          w.render(0.04);
        }
        for (var c = 0; c < asciiCells; c++) {
          expect(w.energy[c].isFinite, true, reason: '${a.id} energy');
        }
      }
    }
  });

  test('a tap feeds koi and startles the others', () {
    final koi = AsciiWorld(seed: 3)..setAnimal(1);
    for (var f = 0; f < 50; f++) { koi.step(0.04); }
    koi.render(0.04);
    final before = koi.flag.where((f) => f != 0).length;
    koi.startle(80, 64);
    koi.render(0.04);
    expect(koi.flag.where((f) => f != 0).length, greaterThan(before - 1)); // pellets appear as cells
    final frog = AsciiWorld(seed: 3)..setAnimal(4);
    frog.startle(80, 64);
    frog.render(0.04);
    expect(frog.energy.reduce(math.max), greaterThan(0.3)); // the ripple spreads
  });

  test('density sets how many are on screen, and the hue shifts the colours', () {
    final w = AsciiWorld(seed: 5);
    w.tune.density = 3;
    w.tuneChanged();
    expect(w.count, 12);
    w.tune.density = 0.1;
    w.tuneChanged();
    expect(w.count, 1);
    final plain = AsciiWorld(seed: 9)..setAnimal(3);
    final shifted = AsciiWorld(seed: 9)..setAnimal(3);
    shifted.tune.hue = 120;
    shifted.tuneChanged();
    for (final w in [plain, shifted]) {
      for (var f = 0; f < 100; f++) { w.step(0.04); }
      w.render(0.04);
    }
    var differ = 0;
    for (var i = 0; i < asciiCells; i++) {
      if (plain.flag[i] != 0 && plain.col[i] != shifted.col[i]) differ++;
    }
    expect(differ, greaterThan(3));
  });

  test('the Hub is told the animal and the whole tuning, and a tap as fractions of the screen', () {
    final a = asciiAnimals[1];
    final t = a.defaults()..hue = 40;
    final cmd = asciiShowCommand(a, t);
    expect(cmd['cmd'], 'ascii');
    expect(cmd['animal'], 'koi');
    expect(cmd['hue'], 40);
    expect(cmd.keys, containsAll(['density', 'speed', 'size', 'trail', 'trailFade', 'sparkle', 'fog', 'shimmer', 'direction', 'corner', 'meander', 'tailBeat', 'foodRange']));
    expect(asciiTapCommand(0.12345, 1), {'cmd': 'ascii', 'tap': [0.123, 1.0]});
  });

  test('saved choices survive, and damaged data falls back to the defaults', () {
    final s = AsciiSaved(animal: 'crabs');
    final a = asciiAnimalById('crabs')!;
    s.remember(a, a.defaults()..hue = -60..corner = false);
    final back = AsciiSaved.fromJson(s.toJson());
    expect(back.animal, 'crabs');
    expect(back.tuneFor(a).hue, -60);
    expect(back.tuneFor(a).corner, false);
    final bad = AsciiSaved.fromJson({'animal': 'dragon', 'tunes': {'koi': {'hue': 'x', 'density': 99999}}});
    expect(bad.animal, 'butterflies');
    expect(bad.tuneFor(asciiAnimalById('koi')!).density, 4); // clamped to the range
    expect(AsciiSaved.fromJson(null).animal, 'butterflies');
  });

  testWidgets('tapping the animals tells the Hub where, and the animals are drawn', (t) async {
    final sent = <List<double>>[];
    final c = AsciiController(seed: 11);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 320, height: 256, child: AsciiAnimalsView(controller: c, onTap: (x, y) => sent.add([x, y]))))),
    ));
    await t.pump(const Duration(milliseconds: 600));
    expect(_cells(c.world), greaterThan(0));
    final box = t.getRect(find.byKey(const ValueKey('ascii-touch')));
    await t.tapAt(box.topLeft + const Offset(160, 64));
    await t.pump(const Duration(milliseconds: 100));
    expect(sent.length, 1);
    expect(sent.first[0], closeTo(0.5, 0.01));
    expect(sent.first[1], closeTo(0.25, 0.01));
    await t.pumpWidget(const SizedBox());
  });
}
