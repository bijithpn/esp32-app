# Muse character: third-party notice

The Muse character (pixel renderer, character behaviour tables, sprite artwork and customisation options) comes from the
Muse gadget project and is used under the Apache License 2.0. Copyright (c) Meta Platforms, Inc. and affiliates.

- `firmware/hub/muse_pixel.c`, `muse_pixel.h`, `muse_state.h`, `muse_character_behavior.h`: from `esp32/` in muse-gadget.
  The renderer is unchanged apart from allocating its buffers and tables on first use (see the note at the top of the file).
- `app/assets/muse/look/*.png`: character and outfit sprites from `companion/assets/muse/look/` in muse-gadget.
- `app/lib/core/muse_look.dart`: option lists taken from `companion/lib/core/muse_look.dart`.
