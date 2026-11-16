/*
 * What each character and personality does when touched or left alone. Pure
 * functions with no hardware or OS dependencies, shared by the full firmware, the
 * companion firmware and the simulator so they always behave the same.
 */
#pragma once

#include "muse_state.h"

/* Added to the number of quick taps before Muse reacts: positive means grumpier. */
static inline int muse_touch_bias(muse_personality_t personality)
{
    switch (personality) {
    case MUSE_PERSONALITY_PLAYFUL: return -1;   /* takes poking as a game */
    case MUSE_PERSONALITY_QUIET: return 1;      /* likes calm, tires of poking sooner */
    case MUSE_PERSONALITY_DREAMY: return 0;
    default: return 0;
    }
}

/* Quick taps in a row before Muse gets dizzy. */
static inline int muse_dizzy_taps(muse_personality_t personality)
{
    return personality == MUSE_PERSONALITY_DREAMY ? 7 : personality == MUSE_PERSONALITY_PLAYFUL ? 9 : 8;
}

/* How a character answers one gentle tap in `zone`. MUSE_EMOTION_NEUTRAL means "the usual". */
static inline muse_emotion_t muse_tap_reply(muse_character_t character, muse_touch_zone_t zone)
{
    switch (character) {
    case MUSE_CHARACTER_KITTY:
        return zone == MUSE_TOUCH_HEAD ? MUSE_EMOTION_LOVE : zone == MUSE_TOUCH_BELLY ? MUSE_EMOTION_PLAYFUL : MUSE_EMOTION_NEUTRAL;
    case MUSE_CHARACTER_BUNNY:
        return zone == MUSE_TOUCH_HEAD ? MUSE_EMOTION_PLAYFUL : zone == MUSE_TOUCH_HAND ? MUSE_EMOTION_EXCITED : MUSE_EMOTION_NEUTRAL;
    case MUSE_CHARACTER_BEAR:
        return zone == MUSE_TOUCH_HEAD ? MUSE_EMOTION_COMFORT : zone == MUSE_TOUCH_HAND ? MUSE_EMOTION_GREETING : MUSE_EMOTION_NEUTRAL;
    case MUSE_CHARACTER_PANDA:
        return zone == MUSE_TOUCH_BELLY ? MUSE_EMOTION_SLEEPY : zone == MUSE_TOUCH_HEAD ? MUSE_EMOTION_COMFORT : MUSE_EMOTION_NEUTRAL;
    case MUSE_CHARACTER_ROBOT:
        return zone == MUSE_TOUCH_HEAD ? MUSE_EMOTION_CURIOUS : zone == MUSE_TOUCH_BELLY || zone == MUSE_TOUCH_CHEEK ? MUSE_EMOTION_SURPRISED : MUSE_EMOTION_PROUD;
    case MUSE_CHARACTER_CHICK:
        return zone == MUSE_TOUCH_HEAD || zone == MUSE_TOUCH_HAND ? MUSE_EMOTION_EXCITED : MUSE_EMOTION_NEUTRAL;
    default:
        return MUSE_EMOTION_NEUTRAL;
    }
}

/* The little things a character does on its own, four per character. */
static inline muse_emotion_t muse_character_idle(muse_character_t character, unsigned cycle)
{
    static const muse_emotion_t KITTY[4] = { MUSE_EMOTION_STRETCH, MUSE_EMOTION_CURIOUS, MUSE_EMOTION_SLEEPY, MUSE_EMOTION_PLAYFUL };
    static const muse_emotion_t BUNNY[4] = { MUSE_EMOTION_PLAYFUL, MUSE_EMOTION_CURIOUS, MUSE_EMOTION_DANCE, MUSE_EMOTION_GREETING };
    static const muse_emotion_t BEAR[4] = { MUSE_EMOTION_CALM, MUSE_EMOTION_STRETCH, MUSE_EMOTION_COMFORT, MUSE_EMOTION_SLEEPY };
    static const muse_emotion_t PANDA[4] = { MUSE_EMOTION_SLEEPY, MUSE_EMOTION_CALM, MUSE_EMOTION_COMFORT, MUSE_EMOTION_PLAYFUL };
    static const muse_emotion_t ROBOT[4] = { MUSE_EMOTION_CURIOUS, MUSE_EMOTION_SURPRISED, MUSE_EMOTION_PROUD, MUSE_EMOTION_GREETING };
    static const muse_emotion_t CHICK[4] = { MUSE_EMOTION_EXCITED, MUSE_EMOTION_PLAYFUL, MUSE_EMOTION_DANCE, MUSE_EMOTION_CURIOUS };
    switch (character) {
    case MUSE_CHARACTER_KITTY: return KITTY[cycle % 4];
    case MUSE_CHARACTER_BUNNY: return BUNNY[cycle % 4];
    case MUSE_CHARACTER_BEAR: return BEAR[cycle % 4];
    case MUSE_CHARACTER_PANDA: return PANDA[cycle % 4];
    case MUSE_CHARACTER_ROBOT: return ROBOT[cycle % 4];
    case MUSE_CHARACTER_CHICK: return CHICK[cycle % 4];
    default: return MUSE_EMOTION_NEUTRAL;
    }
}
