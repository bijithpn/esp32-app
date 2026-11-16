// Copyright (c) Meta Platforms, Inc. and affiliates. Licensed under the Apache License, Version 2.0.
// Taken unchanged from muse-gadget esp32/components/muse/muse_state.h: only the types the Muse pixel renderer needs.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    MUSE_MODE_BOOT = 0,
    MUSE_MODE_IDLE,
    MUSE_MODE_LISTENING,
    MUSE_MODE_THINKING,
    MUSE_MODE_SPEAKING,
    MUSE_MODE_ERROR,
    MUSE_MODE_OFF,       /* powering down */
    MUSE_MODE_COUNT,
} muse_mode_t;
typedef enum {
    MUSE_PERSONALITY_WARM, MUSE_PERSONALITY_PLAYFUL, MUSE_PERSONALITY_QUIET,
    MUSE_PERSONALITY_CURIOUS, MUSE_PERSONALITY_DREAMY, MUSE_PERSONALITY_COUNT,
} muse_personality_t;
typedef enum {
    MUSE_COAT_CREAM, MUSE_COAT_ROSE, MUSE_COAT_MINT, MUSE_COAT_NIGHT,
    MUSE_COAT_SKY, MUSE_COAT_SUNSET, MUSE_COAT_LAVENDER, MUSE_COAT_GOLD,
    MUSE_COAT_SNOW, MUSE_COAT_OCEAN, MUSE_COAT_CHERRY, MUSE_COAT_FOREST, MUSE_COAT_COUNT,
} muse_coat_t;
typedef enum {
    MUSE_ACCESSORY_NONE, MUSE_ACCESSORY_BOW, MUSE_ACCESSORY_SCARF, MUSE_ACCESSORY_CROWN,
    MUSE_ACCESSORY_GLASSES, MUSE_ACCESSORY_HAT, MUSE_ACCESSORY_STAR, MUSE_ACCESSORY_FLOWER,
    MUSE_ACCESSORY_HEADPHONES, MUSE_ACCESSORY_BOWTIE, MUSE_ACCESSORY_SHADES,
    MUSE_ACCESSORY_PARTY, MUSE_ACCESSORY_SPROUT, MUSE_ACCESSORY_HALO, MUSE_ACCESSORY_COUNT,
} muse_accessory_t;
typedef enum {
    MUSE_CHARACTER_MUSE, MUSE_CHARACTER_KITTY, MUSE_CHARACTER_BUNNY, MUSE_CHARACTER_BEAR,
    MUSE_CHARACTER_PANDA, MUSE_CHARACTER_ROBOT, MUSE_CHARACTER_CHICK, MUSE_CHARACTER_COUNT,
} muse_character_t;
typedef struct {
    bool autonomous;
    bool conversation_reactions;
    muse_personality_t personality;
    muse_coat_t coat;
    muse_accessory_t accessory;
    muse_character_t character;
    float intensity; /* 0.25..1.5 */
    float speed;     /* 0.5..2.0 */
    float frequency; /* 0.25..2.0 autonomous gesture frequency */
    bool sound;
    bool reduced_motion;
} muse_companion_config_t;
typedef enum {
    MUSE_EMOTION_NEUTRAL = 0,
    MUSE_EMOTION_EXCITED,
    MUSE_EMOTION_SAD,
    MUSE_EMOTION_SURPRISED,
    MUSE_EMOTION_SLEEPY,
    MUSE_EMOTION_CURIOUS,
    MUSE_EMOTION_SHY,
    MUSE_EMOTION_LOVE,
    MUSE_EMOTION_PLAYFUL,
    MUSE_EMOTION_PROUD,
    MUSE_EMOTION_WORRIED,
    MUSE_EMOTION_CALM,
    MUSE_EMOTION_ANGRY,
    MUSE_EMOTION_LAUGH,
    MUSE_EMOTION_COMFORT,
    MUSE_EMOTION_EMBARRASSED,
    MUSE_EMOTION_GREETING,
    MUSE_EMOTION_STRETCH,
    MUSE_EMOTION_DANCE,
    MUSE_EMOTION_DIZZY,      /* swirly eyes, orbiting stars: poked too much or shaken */
    MUSE_EMOTION_ANNOYED,    /* half-lidded, flat mouth: the step before angry */
    MUSE_EMOTION_COUNT,
} muse_emotion_t;
typedef enum { MUSE_TOUCH_HEAD, MUSE_TOUCH_CHEEK, MUSE_TOUCH_HAND, MUSE_TOUCH_BELLY, MUSE_TOUCH_COUNT } muse_touch_zone_t;
typedef enum { MUSE_ACTIVITY_NONE, MUSE_ACTIVITY_BREATHE, MUSE_ACTIVITY_FOCUS, MUSE_ACTIVITY_GAME, MUSE_ACTIVITY_CELEBRATE } muse_activity_t;
typedef struct {
    muse_activity_t type;
    float elapsed, remaining, progress, breath;
    int score, target;
} muse_activity_status_t;
