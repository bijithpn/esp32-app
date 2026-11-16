// The Muse character and its customisation options, taken from the Muse gadget companion app (Apache-2.0).
// The sprites in assets/muse/look/ are 64 x 64 pixel-art layers: one body per character and coat
// (character_<character>_<coat>.png) and one optional outfit layer on top (outfit_<outfit>.png).

class MuseOption {
  const MuseOption(this.id, this.label);
  final String id, label;
}

const museCharacters = [
  MuseOption('muse', 'Muse'),
  MuseOption('kitty', 'Kitty'),
  MuseOption('bunny', 'Bunny'),
  MuseOption('bear', 'Bear'),
  MuseOption('panda', 'Panda'),
  MuseOption('robot', 'Robot'),
  MuseOption('chick', 'Chick'),
];

const museCoats = [
  MuseOption('cream', 'Cream'),
  MuseOption('rose', 'Rose'),
  MuseOption('mint', 'Mint'),
  MuseOption('night', 'Night'),
  MuseOption('sky', 'Sky'),
  MuseOption('sunset', 'Sunset'),
  MuseOption('lavender', 'Lavender'),
  MuseOption('gold', 'Gold'),
  MuseOption('snow', 'Snow'),
  MuseOption('ocean', 'Ocean'),
  MuseOption('cherry', 'Cherry'),
  MuseOption('forest', 'Forest'),
];

const museOutfits = [
  MuseOption('none', 'None'),
  MuseOption('bow', 'Bow'),
  MuseOption('scarf', 'Scarf'),
  MuseOption('crown', 'Crown'),
  MuseOption('glasses', 'Glasses'),
  MuseOption('hat', 'Hat'),
  MuseOption('star', 'Star'),
  MuseOption('flower', 'Flower'),
  MuseOption('headphones', 'Headphones'),
  MuseOption('bowtie', 'Bowtie'),
  MuseOption('shades', 'Shades'),
  MuseOption('party', 'Party hat'),
  MuseOption('sprout', 'Sprout'),
  MuseOption('halo', 'Halo'),
];

/// Coats shown by how light or warm they are, so people find "something warm" quickly.
const museCoatGroups = [
  ('Light', ['snow', 'cream']),
  ('Warm', ['gold', 'sunset', 'cherry', 'rose']),
  ('Cool', ['sky', 'ocean', 'lavender', 'night']),
  ('Green', ['mint', 'forest']),
];

/// Outfits shown by where they go.
const museOutfitGroups = [
  ('Head', ['crown', 'halo', 'hat', 'party', 'sprout', 'bow', 'flower', 'star']),
  ('Face', ['glasses', 'shades']),
  ('Neck and ears', ['scarf', 'bowtie', 'headphones']),
];

/// The middle shade of each coat, for the colour swatches.
const museCoatColors = {
  'cream': 0xffddc3a5,
  'rose': 0xffcf8ea6,
  'mint': 0xff8abdb0,
  'night': 0xff626484,
  'sky': 0xff8fb4d6,
  'sunset': 0xffe3a07a,
  'lavender': 0xffa996cc,
  'gold': 0xffdab45a,
  'snow': 0xffd2d6de,
  'ocean': 0xff55aebf,
  'cherry': 0xffd0626f,
  'forest': 0xff6aa86b,
};

MuseOption? museFind(List<MuseOption> options, String id) {
  for (final o in options) {
    if (o.id == id) return o;
  }
  return null;
}

/// The character the user picked: who, what colour, and what they wear.
class MuseLook {
  const MuseLook({this.character = 'muse', this.coat = 'cream', this.outfit = 'none'});
  final String character, coat, outfit;

  static bool _known(List<MuseOption> options, Object? id) => options.any((o) => o.id == id);

  /// Unknown or damaged values fall back to the default character, so old or hand-edited data never breaks the screen.
  factory MuseLook.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    const d = MuseLook();
    return MuseLook(
      character: _known(museCharacters, m['character']) ? m['character'] as String : d.character,
      coat: _known(museCoats, m['coat']) ? m['coat'] as String : d.coat,
      outfit: _known(museOutfits, m['outfit']) ? m['outfit'] as String : d.outfit,
    );
  }

  Map<String, dynamic> toJson() => {'character': character, 'coat': coat, 'outfit': outfit};

  MuseLook copy({String? character, String? coat, String? outfit}) =>
      MuseLook(character: character ?? this.character, coat: coat ?? this.coat, outfit: outfit ?? this.outfit);

  String get summary => [
        museFind(museCharacters, character)?.label,
        museFind(museCoats, coat)?.label,
        if (outfit != 'none') museFind(museOutfits, outfit)?.label,
      ].whereType<String>().join(' · ');

  @override
  bool operator ==(Object other) => other is MuseLook && other.character == character && other.coat == coat && other.outfit == outfit;
  @override
  int get hashCode => Object.hash(character, coat, outfit);
}
