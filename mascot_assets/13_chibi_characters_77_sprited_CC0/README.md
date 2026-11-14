# Free Animated Character Sprites by Sprited

v0.1.1 · 2026-09-11

77 AI-generated chibi characters, each with greet, idle and run animated WebP clips. These are the existing SpriteDX Explore exports, with their original pixel-inspired appearance.

## Start here

Extract the ZIP and open preview.html in a modern browser. Pick a character and view its three animations. The preview works offline. You can also open each transparent_*.webp directly.

For game engines, 77 characters include spritesheet_pixel.png and entity_pixel.json. See manifest.json for exact files. The JSON textures[].frames entries specify x/y/w/h crop rectangles and durations in milliseconds. Frame names group actions such as greet_0, idle_0 and run_0. Use the recorded dimensions and timing rather than assuming a fixed FPS. This is a custom atlas format, not an engine-specific importer.

The animated WebP clips and pixel spritesheets are distinct existing exports; they are not guaranteed to have identical resolution or timing. Each file's dimensions, frame count, duration and SHA-256 are recorded in manifest.json.

## License and provenance

Character assets retain the CC0 1.0 designation shown on SpriteDX Explore. The full legal text is in LICENSE-CC0.txt; the original download URL is recorded per character. Attribution is not required under CC0; a SpriteDX link is appreciated. See the license for its scope and limitations. The small offline preview code is MIT-licensed (LICENSE-CODE.txt).

## Generation and quality

These images and animations were generated with AI and processed through SpriteDX. They are pixel-inspired, not hand-drawn or guaranteed pixel-perfect. Some clips have dithering, soft edges, flicker, changing details or imperfect loop seams. This release preserves those exports; it does not apply ESRGAN or regenerate their style. Review a clip at your intended display size before using it.

## Versions

This download is a fixed v0.1.1 snapshot. Future updates should receive new versioned archives and changelog entries; refer to version + character ID + filename when reporting a problem.

Browse more: https://spritedx.com/explore
See characters in a room: https://lunamachi.sprited.ai/white
