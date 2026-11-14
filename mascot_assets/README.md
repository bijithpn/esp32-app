# Mascot / Companion Face Assets (ESP32 display)

Downloaded from itch.io, except folder 01, which is from OpenGameArt. Each folder's `_preview.png` is a contact sheet of the pack.

| Folder | Contents | Source | License |
|---|---|---|---|
| `01_robot_emoji_littlelostrobots/` | 15 robot emoji (your favourite) | https://opengameart.org/content/little-lost-robots-expressions | CC-BY 4.0, so credit the author |
| `02_kawaii_eyes_faces/` | 9 kawaii faces with blush: angry, squint, joy, laugh, shock, smug and more. Eyes plus mouth only | https://todemann.itch.io/cute-faces-sprite | See page |
| `03_scifi_robot_alien_emojis/` | 13 sets of 4-7 expressions each: robots, cyborgs and aliens | https://matseb2611.itch.io/sci-fi-emojis | See page |
| `04_cute_cats/` | Kawaii cat emojis (128px) and stickers (320px), plus 4 grumpy and chill cats | https://amorlea.itch.io/pink-red-adorable-cat-stickers-emojis-1 and https://digitalartph24.itch.io/free-cute-cat-stickers-pack | See pages |
| `05_expressive_emoji_rpg/` | 50 emoji with many emotions: cry, love, angry, sleepy, sick, dizzy and more | https://free-game-assets.itch.io/free-emoji-icons-for-rpg-games | Craftpix license: https://craftpix.net/file-licenses/ |

The itch.io pages did not state licenses on the page text I checked. Open each source page before publishing or selling anything.

## ESP32 tips
- Resize to your screen size (for example 128x128 or 240x240), then convert to RGB565 with LVGL's image converter.
- The cat stickers are about 1 MB each, so downscale them a lot.
- The 128px cat emojis are the lightest cat option.

## Animated pets and animals (added later)
These are animated sprite sheets, with one PNG per animation in most packs.

| Folder | Contents | Source | License |
|---|---|---|---|
| `06_animated_cats/pet_cats_pack_CC0/` | 6 pixel cats. Each has idle, sit, lie, sleep, lick, itch, stretch, meow, walk and run, plus a meow VFX | https://luizmelo.itch.io/pet-cat-pack | CC0 |
| `06_animated_cats/pixel_cats_64x64/`, `pixel_kittens_32x32/` | Animated 64x64 and 32x32 cats and kittens, including Christmas, Valentine and winter accessories | https://last-tick.itch.io/animated-pixel-cats-64x64 and https://last-tick.itch.io/animated-pixel-kittens-cats-32x32 | See pages |
| `06_animated_cats/cat_pack_mochi/` | Mochi cat with furniture | https://toffeecraft.itch.io/cat-pack | See page |
| `06_animated_cats/cat_16x16_black/` | Black cat, 16x16, 33+ animations | https://bowpixel.itch.io/cat-anim-16x16-black | See page |
| `06_animated_cats/cat_sprite_sheet_elthen/` | Cat sprite sheet | https://elthen.itch.io/2d-pixel-art-cat-sprites | See page |
| `07_animated_dogs/pet_dogs_pack_CC0/` | Dog breeds. Each has idle, bark, sit, lie, sleep, lick, itch, stretch, walk and run | https://luizmelo.itch.io/pet-dogs-pack | CC0 |
| `07_animated_dogs/pixel_dogs/` | 24 pixel dog sheets | https://benvictus.itch.io/pixel-dogs | See page |
| `07_animated_dogs/dog_pack_32x32/` | 32x32 dogs | https://creedey.itch.io/free-32x32-pixel-art-pet-pack-dogs | Commercial use allowed (LICENSE.txt in the folder) |
| `08_bunny_and_other_animals/bunny_emotes_28_moods/` | **Bunny with 28 moods**: love, angry, sleepy, shocked, dizzy and more. Very cute | https://mewki.itch.io/bunny-emotes | See page |
| `08_bunny_and_other_animals/bunny_32x32_animated/` | Animated 32x32 bunny | https://last-tick.itch.io/32x32-pixel-bunnies-animated-npc | See page |
| `08_bunny_and_other_animals/fox_frog_pets_walk/` | Fox and frog, 4 directions, 12-frame walk cycles | https://gegx.itch.io/pets-companions-free | See README.txt in the folder |
| `09_cat_emoticons_CC0/` | Cat emoticons in 64px and 128px, in 2 colours | https://magory.itch.io/cat-emoticons | CC0 |

Not downloaded: a few listings (kirisoft tiny cat, pixelfight dogs, kyafupaca shiba, toffeecraft bunnies) had no free file.

## Dragons, mythical creatures, items and more characters (added later)

| Folder | Contents | Source | License |
|---|---|---|---|
| `10_dragons_and_mythical/pixel_dragons_20/` | 20 pixel dragons in different colours and styles (static) | https://michael-jay-rov.itch.io/pixel-dragons | See page |
| `10_dragons_and_mythical/baby_dragon_flying/` | Cute red baby dragon, 9-frame flying animation | https://sr-studios-kerala.itch.io/baby-dragon-pixelerated | Commercial and non-commercial use per the page |
| `10_dragons_and_mythical/dragon_pack_16x16/` | 16x16 dragon, free "basic" tier with idle animations | https://deepdivegamestudio.itch.io/dragon-asset-pack | See page |
| `10_dragons_and_mythical/phoenixling/` | Cute phoenix creature: fly, fire and rebirth animations, plus JSON frame data | https://elthen.itch.io/2d-pixel-art-phoenixling-sprites | See page |
| `10_dragons_and_mythical/swampling/` | Swamp creature sprites with JSON frame data | https://elthen.itch.io/2d-pixel-art-swampling-sprites | See page |
| `10_dragons_and_mythical/fantasy_eggs/` | Fantasy eggs, 20 PNGs and a sprite sheet (for hatching) | https://frostwindz.itch.io/fantasy-pixel-art-eggs | Frostwindz asset license (the .docx in the folder) |
| `10_dragons_and_mythical/monsters_creatures_luizmelo/` | Fantasy creatures with idle, walk, attack, take hit, death and more | https://luizmelo.itch.io/monsters-creatures-fantasy | See page |
| `11_pet_items_food_toys_beds/` | **Items:** pet beds, bowls, food, toys, cat tree, kennel, treats, photo frames, plus cats, a bunny and a golden retriever | https://toffeecraft.itch.io/pet-virtual-mobile-pixel-asset | The page says personal use. Check before commercial use |
| `12_chibi_critters_frog_chick/` | Chibi frog and chick. Sprites (128 and 256 px) in 4 directions, portraits, GIF previews. The GLB/FBX models are not copied | https://gmingassets.itch.io/chibi-critters-3d-free-sample | Free for personal and commercial use. Do not redistribute. Credit appreciated |
| `13_chibi_characters_77_sprited_CC0/` | 77 chibi characters, each with a pixel reference image and sprite sheet (greet, idle, run). The animated WebP files are not copied. AI-generated | https://kndlt.itch.io/spritedx-character-sprites | CC0 |

Not downloaded: the Baby Dragon Animations pack (thepixelgame) had no free file. The Slime Asset Pack is a Unity-only package. The Pocket Creature Tamer kit is a tileset demo.
