// Copyright (c) Meta Platforms, Inc. and affiliates. Licensed under the Apache License, Version 2.0.
// Ported unchanged from muse-gadget esp32/avatar/muse_pixel.c. Hub changes: the frame buffers are allocated on first use
// (muse_pixel_init) instead of being static, because 8 KB of static data left too little heap at boot on this board.

#include "muse_pixel.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define W MUSE_PX_W
#define H MUSE_PX_H
#define TAU 6.2831853f

/* ---------------------------------------------------------------------------
 * Palette
 * ------------------------------------------------------------------------- */

enum {
    C_BG = 0,
    C_OUT,       /* outline */
    C_OUT2,      /* soft outline where the hood tucks around the face */
    C_BD,        /* fur dark */
    C_BM,        /* fur mid */
    C_BL,        /* fur light */
    C_BH,        /* fur highlight */
    C_RIM,       /* state-tinted rim light */
    C_SKIND,     /* face panel shade */
    C_SKIN,
    C_SKINL,
    C_IRIS,      /* bead eyes */
    C_SHINE,
    C_BROW,
    C_BLUSH,
    C_BLUSHD,
    C_MOUTH,
    C_TONGUE,
    C_G0,        /* state glow ramp, bright ... */
    C_G1,
    C_G2,
    C_G3,        /* ... deep */
    C_AURA1,
    C_AURA2,
    C_SPK,
    C_ACC,
    C_SHADOW,
    C_HEART,
    C_WHITE,
    C_LEAF,      /* sprout / forest accents */
    C_BEAK,      /* chick beak and tuft */
    C_GOLD,      /* halo */
    C_COUNT,
};

typedef struct {
    float r, g, b;
} rgb_t;

/* Per-mode glow ramp (bright -> deep) and accent. */
typedef struct {
    uint32_t f[4];
    uint32_t acc;
} scheme_t;

static const scheme_t SCHEMES[MUSE_MODE_COUNT] = {
    [MUSE_MODE_BOOT]      = { { 0xffffff, 0xcfe0ff, 0x8fa8ff, 0x5a5fe0 }, 0xa9c0ff },
    [MUSE_MODE_IDLE]      = { { 0xf4e8ff, 0xc7a4ff, 0x9a6bff, 0x5b3fd9 }, 0xa77dff },
    [MUSE_MODE_LISTENING] = { { 0xe8faff, 0x8fdcff, 0x3fa2ff, 0x2a5bd7 }, 0x5cb8ff },
    [MUSE_MODE_THINKING]  = { { 0xffe6ff, 0xff9cf0, 0xd35bff, 0x7a2bd9 }, 0xe07bff },
    [MUSE_MODE_SPEAKING]  = { { 0xeafff4, 0x9ff5cf, 0x3fd9a0, 0x1f9a7a }, 0x6ff0bf },
    [MUSE_MODE_ERROR]     = { { 0xffd6d6, 0xff6b6b, 0xc7304a, 0x6b1a3a }, 0xff5c5c },
    [MUSE_MODE_OFF]       = { { 0xd8d4ff, 0x8f86d9, 0x5a4fb0, 0x2e2870 }, 0x7c72d0 },
};

/* Cream fur and a peach face. */
static const uint32_t FIXED[C_COUNT] = {
    [C_BG] = 0x000000,
    [C_OUT] = 0x594136,
    [C_OUT2] = 0xa18870,
    [C_BD] = 0xae987e,
    [C_BM] = 0xcfbc9f,
    [C_BL] = 0xe6d7bd,
    [C_BH] = 0xf8eedc,
    [C_SKIND] = 0xedcbb5,
    [C_SKIN] = 0xffe4cb,
    [C_SKINL] = 0xfff1df,
    [C_IRIS] = 0x120d0b,
    [C_SHINE] = 0xffffff,
    [C_BROW] = 0x6b5444,
    [C_BLUSH] = 0xffb7b5,
    [C_BLUSHD] = 0xf599a7,
    [C_MOUTH] = 0x3a1f1a,
    [C_TONGUE] = 0xe86a7a,
    [C_SHADOW] = 0x16101f,
    [C_HEART] = 0xff4f8b,
    [C_WHITE] = 0xffffff,
    [C_LEAF] = 0x6fcf6a,
    [C_BEAK] = 0xffb347,
    [C_GOLD] = 0xffd84a,
};

static rgb_t s_scheme[5];      /* live, blended: f0..f3, acc */
static bool s_scheme_init;
static uint16_t s_pal[C_COUNT];
static uint16_t s_pal_dim[C_COUNT];

#define MAP_MAX 512
static uint8_t *s_fb, *s_mask, *s_map;

static const uint8_t BAYER4[4][4] = {
    { 0, 8, 2, 10 },
    { 12, 4, 14, 6 },
    { 3, 11, 1, 9 },
    { 15, 7, 13, 5 },
};

/*
 * The per-pixel work is fixed point (Q12: ONE = 1.0), with tables for the
 * powers and roots: chips without an FPU (ESP32-C6) emulate float in
 * software, which made a frame take 250 ms. At 64 px the quantisation is
 * invisible.
 */
#define Q 12
#define ONE (1 << Q)
#define QF(v) ((int32_t)((v) * ONE))
#define POW_LUT_N 256
#define POW_LUT_MAX_Q QF(1.2f)          /* body_field() bails out beyond this */
#define SQRT_LUT_N 1024                 /* indexed by x >> 2 */
static int16_t *s_pow_dome;   /* |u|^2.7, POW_LUT_N + 1 entries (heap: see muse_pixel_init) */
static int16_t *s_pow_base;   /* |u|^3.6 */
static int16_t *s_sqrt;       /* SQRT_LUT_N + 1 entries */

bool muse_pixel_init(void)
{
    if (!s_fb) { s_fb = (uint8_t *)calloc(W * H, 1); }
    if (!s_mask) { s_mask = (uint8_t *)calloc(W * H, 1); }
    if (!s_pow_dome) {
        /* One block for the three lookup tables and the screen map. */
        size_t n16 = (POW_LUT_N + 1) * 2 + (SQRT_LUT_N + 1);
        int16_t *blk = (int16_t *)calloc(n16 * sizeof(int16_t) + MAP_MAX, 1);
        if (blk) {
            s_pow_dome = blk;
            s_pow_base = blk + (POW_LUT_N + 1);
            s_sqrt = blk + 2 * (POW_LUT_N + 1);
            s_map = (uint8_t *)(blk + n16);
        }
    }
    return s_fb && s_mask && s_pow_dome;
}

static void init_luts(void)
{
    for (int i = 0; i <= POW_LUT_N; i++) {
        float u = (float)i * POW_LUT_MAX_Q / POW_LUT_N / ONE;
        s_pow_dome[i] = (int16_t)(powf(u, 2.7f) * ONE);
        s_pow_base[i] = (int16_t)(powf(u, 3.6f) * ONE);
    }
    for (int i = 0; i <= SQRT_LUT_N; i++) {
        s_sqrt[i] = (int16_t)(sqrtf((float)i / SQRT_LUT_N) * ONE);
    }
}

/* a in [0, POW_LUT_MAX_Q] */
static inline int32_t pow_q(const int16_t *lut, int32_t a)
{
    return lut[(a * (POW_LUT_N * 65536 / POW_LUT_MAX_Q)) >> 16];
}

/* sqrt of x in [0, ONE] */
static inline int32_t sqrt_q(int32_t x)
{
    return s_sqrt[x >> 2];
}

static inline int32_t bayer_q(int x, int y)
{
    return BAYER4[y & 3][x & 3] * (ONE / 16) + ONE / 32;
}

static inline float bayer(int x, int y)
{
    return (BAYER4[y & 3][x & 3] + 0.5f) / 16.0f;
}

static inline rgb_t hex_rgb(uint32_t c)
{
    return (rgb_t){ (float)((c >> 16) & 0xff), (float)((c >> 8) & 0xff), (float)(c & 0xff) };
}

static inline rgb_t mix(rgb_t a, rgb_t b, float t)
{
    return (rgb_t){ a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t };
}

static inline rgb_t scale_rgb(rgb_t a, float k)
{
    return (rgb_t){ a.r * k, a.g * k, a.b * k };
}

static inline uint16_t to565(rgb_t c)
{
    int r = (int)(c.r + 0.5f), g = (int)(c.g + 0.5f), b = (int)(c.b + 0.5f);
    r = r < 0 ? 0 : (r > 255 ? 255 : r);
    g = g < 0 ? 0 : (g > 255 ? 255 : g);
    b = b < 0 ? 0 : (b > 255 ? 255 : b);
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

uint32_t muse_pixel_accent(muse_mode_t mode)
{
    return SCHEMES[mode < MUSE_MODE_COUNT ? mode : MUSE_MODE_IDLE].acc;
}

static const uint32_t COATS[][4] = {
    { 0xb59b83, 0xddc3a5, 0xf2ddbf, 0xfff1dc },
    { 0xad667e, 0xcf8ea6, 0xe8b5c6, 0xffdfe9 },
    { 0x568f87, 0x8abdb0, 0xb9dfca, 0xe0f5e8 },
    { 0x393859, 0x626484, 0x9198bb, 0xc6cdef },
    { 0x5e86ad, 0x8fb4d6, 0xbcd8ee, 0xe4f2fc },
    { 0xc57a52, 0xe3a07a, 0xf3c7a4, 0xffe6cf },
    { 0x7d6aa6, 0xa996cc, 0xcabfe6, 0xece6fa },
    { 0xb08a2e, 0xdab45a, 0xeed38f, 0xfbeeb9 },
    { 0xa9aeb8, 0xd2d6de, 0xe9ecf2, 0xffffff },
    { 0x2f7f93, 0x55aebf, 0x8fd3dc, 0xcdf1f4 },
    { 0xa03a48, 0xd0626f, 0xea939c, 0xffcdd2 },
    { 0x3f7a45, 0x6aa86b, 0x9bd096, 0xcdecc6 },
};

uint32_t muse_pixel_coat_color(int coat)
{
    return COATS[coat >= 0 && coat < MUSE_COAT_COUNT ? coat : 0][1];
}

static void update_palette(const scheme_t *target, float dt, muse_coat_t coat)
{
    rgb_t tgt[5];
    for (int i = 0; i < 4; i++) {
        tgt[i] = hex_rgb(target->f[i]);
    }
    tgt[4] = hex_rgb(target->acc);

    float k = s_scheme_init ? 1.0f - expf(-dt * 7.0f) : 1.0f;
    for (int i = 0; i < 5; i++) {
        s_scheme[i] = mix(s_scheme[i], tgt[i], k);
    }
    s_scheme_init = true;

    rgb_t pal[C_COUNT];
    for (int i = 0; i < C_COUNT; i++) {
        pal[i] = hex_rgb(FIXED[i]);
    }
    for (int i = 0; i < 4; i++) { pal[C_BD + i] = hex_rgb(COATS[coat][i]); }
    rgb_t acc = s_scheme[4];
    pal[C_G0] = s_scheme[0];
    pal[C_G1] = s_scheme[1];
    pal[C_G2] = s_scheme[2];
    pal[C_G3] = s_scheme[3];
    pal[C_ACC] = acc;
    pal[C_RIM] = mix(pal[C_BL], acc, 0.45f);
    pal[C_AURA1] = scale_rgb(acc, 0.16f);
    pal[C_AURA2] = scale_rgb(acc, 0.34f);
    pal[C_SPK] = mix(acc, pal[C_WHITE], 0.45f);

    for (int i = 0; i < C_COUNT; i++) {
        s_pal[i] = to565(pal[i]);
        /* A light edge keeps the pixel-art texture without a dark screen-door grid. */
        s_pal_dim[i] = to565(scale_rgb(pal[i], 0.93f));
    }
}

/* ---------------------------------------------------------------------------
 * Primitive helpers
 * ------------------------------------------------------------------------- */

static inline void px(int x, int y, uint8_t c)
{
    if ((unsigned)x < W && (unsigned)y < H) {
        s_fb[y * W + x] = c;
    }
}

static inline uint8_t get_px(int x, int y)
{
    if ((unsigned)x < W && (unsigned)y < H) {
        return s_fb[y * W + x];
    }
    return C_BG;
}

static inline int iround(float v)
{
    return (int)floorf(v + 0.5f);
}

static inline float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline float fracf(float v)
{
    return v - floorf(v);
}

/* Cheap deterministic pseudo-random for idle behaviour. */
static uint32_t s_rng = 0x9e3779b9u;
static float frand(void)
{
    s_rng ^= s_rng << 13;
    s_rng ^= s_rng >> 17;
    s_rng ^= s_rng << 5;
    return (float)(s_rng & 0xffffff) / (float)0x1000000;
}

/* Draw a small bitmap given as rows of '.'/'#'/'o' characters. */
/* Three-colour sprite: '#' edge, 'f' fill, 'i' inner detail. */
static void stamp3(const char *const *rows, int nrows, int x0, int y0, uint8_t edge, uint8_t fill, uint8_t inner)
{
    for (int r = 0; r < nrows; r++) {
        for (int c = 0; rows[r][c]; c++) {
            char ch = rows[r][c];
            if (ch == '#') { px(x0 + c, y0 + r, edge); }
            else if (ch == 'f') { px(x0 + c, y0 + r, fill); }
            else if (ch == 'i') { px(x0 + c, y0 + r, inner); }
        }
    }
}

/* Ears and tufts bend: row r moves by `shear` * (how far it is from the base), so
 * a drooping ear flops outward while its base stays put. */
static void stamp3_ex(const char *const *rows, int nrows, int width, int x0, int y0, bool mirror,
                      float shear, uint8_t edge, uint8_t fill, uint8_t inner)
{
    for (int r = 0; r < nrows; r++) {
        int off = nrows > 1 ? iround(shear * (float)(nrows - 1 - r) / (float)(nrows - 1)) : 0;
        for (int c = 0; rows[r][c]; c++) {
            char ch = rows[r][c];
            uint8_t colour = ch == '#' ? edge : ch == 'f' ? fill : ch == 'i' ? inner : 255;
            if (colour != 255) { px(x0 + (mirror ? width - 1 - c : c) + off, y0 + r, colour); }
        }
    }
}

static void stamp(const char *const *rows, int nrows, int x0, int y0, uint8_t fill, uint8_t alt)
{
    for (int r = 0; r < nrows; r++) {
        for (int c = 0; rows[r][c]; c++) {
            char ch = rows[r][c];
            if (ch == '#') {
                px(x0 + c, y0 + r, fill);
            } else if (ch == 'o') {
                px(x0 + c, y0 + r, alt);
            }
        }
    }
}

/* ---------------------------------------------------------------------------
 * Idle behaviour: blinking and gaze
 * ------------------------------------------------------------------------- */

typedef struct {
    float next_blink;
    float blink_start;
    float next_gaze;
    float gx, gy;          /* current gaze, -1..1 */
    float tgx, tgy;        /* target gaze */
    float last_t;
} eyes_t;

static eyes_t s_eyes = { .next_blink = 1.5f, .blink_start = -10, .next_gaze = 1.0f };

static float eyes_update(const muse_pose_t *p, float dt)
{
    eyes_t *e = &s_eyes;

    if (p->t >= e->next_blink) {
        e->blink_start = p->t;
        /* Occasionally double-blink. */
        e->next_blink = p->t + (frand() < 0.2f ? 0.28f : 2.2f + frand() * 3.0f);
    }

    if (p->t >= e->next_gaze) {
        e->next_gaze = p->t + 1.2f + frand() * 2.4f;
        if (frand() < 0.35f) {
            e->tgx = 0;
            e->tgy = 0;
        } else {
            e->tgx = frand() * 2 - 1;
            e->tgy = (frand() * 2 - 1) * 0.6f;
        }
    }

    float tgx = e->tgx, tgy = e->tgy;
    switch (p->mode) {
    case MUSE_MODE_LISTENING:
        tgx = 0;
        tgy = 0.1f;
        break;
    case MUSE_MODE_THINKING:
        tgx = 0.75f * sinf(p->mode_t * 1.3f) + 0.25f;
        tgy = -0.85f;
        break;
    case MUSE_MODE_SPEAKING:
        tgx *= 0.3f;
        tgy = 0;
        break;
    default:
        break;
    }
    if (p->gaze_active && p->mode != MUSE_MODE_OFF) {
        tgx = p->gaze_x;
        tgy = p->gaze_y;
    }
    if (p->emotion == MUSE_EMOTION_EMBARRASSED && p->emotion_t < 3.0f) {
        tgx = -0.9f; tgy = 0.65f;
    }
    float k = 1.0f - expf(-dt * 10.0f);
    e->gx += (tgx - e->gx) * k;
    e->gy += (tgy - e->gy) * k;

    /* Blink curve: 0 = open, 1 = shut. */
    float bt = (p->t - e->blink_start) / 0.16f;
    if (bt < 0 || bt > 1) {
        return 0;
    }
    return 1.0f - fabsf(bt * 2 - 1);
}

/* ---------------------------------------------------------------------------
 * Scene layers
 * ------------------------------------------------------------------------- */

static void draw_aura(float cx, float cy, float radius, float strength)
{
    int x0 = (int)(cx - radius - 1), x1 = (int)(cx + radius + 1);
    int y0 = (int)(cy - radius - 1), y1 = (int)(cy + radius + 1);
    /* Distances in 1/16 px; the root of d2 / r2 comes from the table. */
    int32_t cx16 = (int32_t)(cx * 16), r2 = (int32_t)(radius * radius * 256);
    int32_t to_idx = (int32_t)((float)SQRT_LUT_N * 65536 / r2);
    int32_t str = QF(strength);
    for (int y = y0; y <= y1; y++) {
        int32_t dy = (int32_t)((y + 0.5f - cy) * 1.1f * 16);
        int32_t dy2 = dy * dy;
        if (dy2 >= r2) {
            continue;
        }
        for (int x = x0; x <= x1; x++) {
            int32_t dx = x * 16 + 8 - cx16;
            int32_t d2 = dx * dx + dy2;
            if (d2 >= r2) {
                continue;
            }
            int32_t i = ((ONE - s_sqrt[(d2 * to_idx) >> 16]) * str) >> Q;
            int32_t b = bayer_q(x, y);
            if (i > QF(0.55f) + ((b * QF(0.35f)) >> Q)) {
                px(x, y, C_AURA2);
            } else if (i > (b * QF(0.9f)) >> Q) {
                px(x, y, C_AURA1);
            }
        }
    }
}

/* Expanding dotted rings (listening / speaking). */
static void draw_rings(float cx, float cy, float t, float level, float speed)
{
    for (int k = 0; k < 2; k++) {
        float ph = fracf(t * speed + k * 0.5f);
        float r = 20 + ph * 11;
        float fade = (1 - ph) * (0.35f + level);
        int n = (int)(r * 2.2f);
        for (int i = 0; i < n; i++) {
            float a = i * TAU / n;
            int x = iround(cx + cosf(a) * r);
            int y = iround(cy + sinf(a) * r * 0.92f);
            if (get_px(x, y) == C_BG || get_px(x, y) == C_AURA1) {
                if (bayer(x, y) < fade) {
                    px(x, y, fade > 0.6f ? C_ACC : C_AURA2);
                }
            }
        }
    }
}

static void draw_shadow(float cx, float y, float half_w)
{
    for (int row = 0; row < 3; row++) {
        float hw = half_w * (row == 1 ? 1.0f : 0.72f);
        for (int x = iround(cx - hw); x <= iround(cx + hw); x++) {
            float edge = fabsf(x + 0.5f - cx) / hw;
            if (bayer(x, (int)y + row) > edge * 0.8f) {
                px(x, (int)y + row, C_SHADOW);
            }
        }
    }
}

/* Stable per-position hash (0..65535) so fur tufts don't shimmer as the avatar moves. */
static inline int32_t hash16(int x, int y)
{
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return (int32_t)((h ^ (h >> 16)) & 0xffff);
}

/*
 * The avatar: a tall furry hood shaped like a rounded bullet, with a smooth peach
 * face panel, bead eyes, rosy cheeks, stubby arms and two little feet.
 */
typedef struct {
    float cx, cy;   /* body centre */
    float a, b;     /* half width, half height */
    float fx, fy;   /* face panel centre */
    float fa, fb;   /* face panel half extents */
} avatar_t;

/* Per-row parts of the body and face fields, in Q12. */
typedef struct {
    int32_t v;          /* body: normalised y */
    int32_t inv_a;      /* 1 / half width at this row */
    const int16_t *lut;
    bool body;          /* |v| inside the table */
    int32_t v_pow;      /* |v|^n */
    int32_t fv, fv4;    /* face: normalised y, and its 4th power */
} row_t;

static inline void row_setup(const avatar_t *j, float y, row_t *r)
{
    float v = (y - j->cy) / j->b;
    float a = j->a * (1 + 0.07f * clampf(v, -1, 1));   /* widens a touch at the base */
    r->v = QF(v);
    r->inv_a = QF(1.0f / a);
    r->lut = v < 0 ? s_pow_dome : s_pow_base;
    r->body = abs(r->v) <= POW_LUT_MAX_Q;
    r->v_pow = r->body ? pow_q(r->lut, abs(r->v)) : 0;
    float fv = clampf((y - j->fy) / j->fb, -8, 8);
    r->fv = QF(fv);
    r->fv4 = QF(fminf(fv * fv * fv * fv, 16));
}

/* Superellipse field for the body: round dome on top, squarer bottom. */
static inline int32_t body_field(const row_t *r, int32_t dx, int32_t *ux)
{
    int32_t u = (dx * r->inv_a) >> Q;
    *ux = u;
    if (!r->body || abs(u) > POW_LUT_MAX_Q) {
        return 2 * ONE;
    }
    return pow_q(r->lut, abs(u)) + r->v_pow;
}

/* Fur tone from a surface normal, with vertical streaks for texture. */
static uint8_t fur(int32_t nx, int32_t ny, int x, int y, int ox, int oy)
{
    int32_t r2 = (nx * nx + ny * ny) >> Q;
    int32_t nz = r2 >= ONE ? 0 : sqrt_q(ONE - r2);
    int32_t l = (-QF(0.40f) * nx - QF(0.50f) * ny + QF(0.76f) * nz) >> Q;
    int32_t b = bayer_q(x, y);
    int rx = x - ox, ry = y - oy;
    int32_t streak = (hash16(rx, (ry + (rx & 1) * 2) / 3) >> 4) - ONE / 2;
    int32_t lv = l + (((b - ONE / 2) * QF(0.2f)) >> Q) + ((streak * QF(0.22f)) >> Q);
    if (r2 > QF(0.86f) && ((nx * QF(0.6f) + ny * QF(0.8f)) >> Q) > QF(0.72f) && b < QF(0.4f)) {
        return C_RIM;
    }
    return lv > QF(0.95f) ? C_BH : lv > QF(0.62f) ? C_BL : lv > QF(0.28f) ? C_BM : C_BD;
}

typedef struct {
    float x, y;
    float angle;    /* radians; positive tips the bottom outward to the right */
} limb_t;

/* A limb ellipse, set up for Q12 hit tests. */
typedef struct {
    int32_t x, y, c, s, inv_rx, inv_ry, r;
} limb_q_t;

static void limb_setup(const limb_t *l, float rx, float ry, limb_q_t *q)
{
    q->x = QF(l->x);
    q->y = QF(l->y);
    q->c = QF(cosf(l->angle));
    q->s = QF(sinf(l->angle));
    q->inv_rx = QF(1.0f / rx);
    q->inv_ry = QF(1.0f / ry);
    q->r = QF(rx > ry ? rx : ry);
}

static inline bool in_limb(const limb_q_t *l, int32_t x, int32_t y, int32_t *lx, int32_t *ly)
{
    int32_t dx = x - l->x, dy = y - l->y;
    if (abs(dx) > l->r || abs(dy) > l->r) {
        return false;
    }
    int32_t u = ((((dx * l->c) >> Q) + ((dy * l->s) >> Q)) * l->inv_rx) >> Q;
    int32_t v = ((((dy * l->c) >> Q) - ((dx * l->s) >> Q)) * l->inv_ry) >> Q;
    *lx = u;
    *ly = v;
    return u * u + v * v <= ONE * ONE;
}

enum { M_NONE, M_BODY, M_ARM, M_FOOT, M_FACE };

static void draw_avatar(const avatar_t *j, const limb_t arms[2], const limb_t feet[2])
{
    memset(s_mask, 0, W * H);
    limb_q_t arm_q[2], foot_q[2];
    for (int i = 0; i < 2; i++) {
        limb_setup(&arms[i], 2.9f, 5.2f, &arm_q[i]);
        limb_setup(&feet[i], 4.4f, 2.6f, &foot_q[i]);
    }
    /* Only rows/columns that can hold the avatar are shaded. */
    int x0 = (int)(j->cx - j->a * 1.1f - 8), x1 = (int)(j->cx + j->a * 1.1f + 8);
    int y0 = (int)(j->cy - j->b - 8), y1 = (int)(j->cy + j->b + 5);
    x0 = x0 < 0 ? 0 : x0;
    y0 = y0 < 0 ? 0 : y0;
    x1 = x1 >= W ? W - 1 : x1;
    y1 = y1 >= H ? H - 1 : y1;
    int ox = iround(j->cx), oy = iround(j->cy);
    int32_t cx = QF(j->cx), fcx = QF(j->fx), inv_fa = QF(1.0f / j->fa);

    for (int y = y0; y <= y1; y++) {
        row_t row;
        row_setup(j, y + 0.5f, &row);
        int32_t fy = y * ONE + ONE / 2;
        for (int x = x0; x <= x1; x++) {
            int32_t fx = x * ONE + ONE / 2;
            int32_t lx, ly;

            /* Arms sit in front of the body. */
            bool arm = false;
            for (int a = 0; a < 2 && !arm; a++) {
                if (in_limb(&arm_q[a], fx, fy, &lx, &ly)) {
                    s_mask[y * W + x] = M_ARM;
                    int32_t nx = ((lx * QF(0.85f)) >> Q) + (a ? QF(0.25f) : -QF(0.25f));
                    px(x, y, fur(nx, (ly * QF(0.8f)) >> Q, x, y, ox, oy));
                    arm = true;
                }
            }
            if (arm) {
                continue;
            }

            int32_t ux, uy = row.v;
            int32_t v = body_field(&row, fx - cx, &ux);
            /* Fuzzy silhouette: tufts poke in and out along the edge. */
            int32_t tuft = ((hash16(x - ox, y - oy) - 32768) * QF(0.16f)) >> 16;
            if (v <= ONE + tuft) {
                int32_t fu = ((fx - fcx) * inv_fa) >> Q;
                fu = fu > 3 * ONE ? 3 * ONE : fu < -3 * ONE ? -3 * ONE : fu;
                int32_t fu2 = (fu * fu) >> Q;
                int32_t ff = ((fu2 * fu2) >> Q) + row.fv4;
                int32_t b = bayer_q(x, y);
                if (ff <= ONE) {
                    s_mask[y * W + x] = M_FACE;
                    int32_t fv = row.fv, fv1 = fv + QF(0.15f);
                    uint8_t c = C_SKIN;
                    if (fv < -QF(0.55f) && b < ((-fv - QF(0.45f)) * QF(1.8f)) >> Q) {
                        c = C_SKIND;   /* the hood shades the top of the face */
                    } else if (((fu2 * QF(1.4f)) >> Q) + ((fv1 * fv1) >> Q) < QF(0.32f) && b < QF(0.55f)) {
                        c = C_SKINL;
                    } else if (fv > QF(0.75f) && b < QF(0.4f)) {
                        c = C_SKIND;
                    }
                    px(x, y, c);
                } else {
                    s_mask[y * W + x] = M_BODY;
                    /* Fur darkens where it tucks around the face. */
                    if (ff < QF(1.75f) && (ff < QF(1.3f) || b < ((QF(1.75f) - ff) * QF(1.4f)) >> Q)) {
                        px(x, y, ff < QF(1.3f) ? C_OUT2 : C_BD);
                    } else {
                        px(x, y, fur((ux * QF(0.95f)) >> Q, (uy * QF(0.95f)) >> Q, x, y, ox, oy));
                    }
                }
                continue;
            }

            for (int f = 0; f < 2; f++) {
                if (in_limb(&foot_q[f], fx, fy, &lx, &ly)) {
                    s_mask[y * W + x] = M_FOOT;
                    px(x, y, ly < -QF(0.2f) ? C_BM : C_BD);
                    break;
                }
            }
        }
    }

    /* Hard outline on the silhouette, and seams where parts overlap. */
    static const int8_t N4[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            uint8_t m = s_mask[y * W + x];
            if (m == M_NONE || m == M_FACE) {
                continue;
            }
            for (int k = 0; k < 4; k++) {
                int xx = x + N4[k][0], yy = y + N4[k][1];
                uint8_t n = ((unsigned)xx < W && (unsigned)yy < H) ? s_mask[yy * W + xx] : M_NONE;
                if (n == M_NONE || (m == M_ARM && (n == M_BODY || n == M_FACE)) || (m == M_BODY && n == M_FOOT)) {
                    px(x, y, C_OUT);
                    break;
                }
            }
        }
    }
}

typedef enum {
    EYES_NORMAL,
    EYES_WIDE,
    EYES_HAPPY,
    EYES_X,
    EYES_HEART,
    EYES_DIZZY,
} eye_style_t;

static int s_spin_frame;   /* swirly eyes alternate between two frames */

/* The eyes are small glossy black beads. */
static void draw_eye(float ex, float ey, float openness, eye_style_t style, float gx, float gy)
{
    int cx = iround(ex + gx * 0.8f), cy = iround(ey + gy * 0.7f);

    if (style == EYES_HEART) {
        static const char *const HEART[] = { "#.#", "###", ".#." };
        stamp(HEART, 3, iround(ex) - 1, iround(ey) - 1, C_HEART, C_HEART);
        return;
    }
    if (style == EYES_HAPPY) {
        static const char *const HAPPY[] = { ".##.", "#..#" };
        stamp(HAPPY, 2, iround(ex) - 2, iround(ey), C_IRIS, C_IRIS);
        return;
    }
    if (style == EYES_DIZZY) {
        static const char *const RING[] = { ".###.", "#...#", "#.#.#", "#...#", ".###." };
        int x0 = iround(ex) - 2, y0 = iround(ey) - 2;
        stamp(RING, 5, x0, y0, C_IRIS, C_IRIS);
        /* A gap travels round the ring so the eye seems to spin. */
        static const int GAP[4][2] = { { 2, 0 }, { 4, 2 }, { 2, 4 }, { 0, 2 } };
        px(x0 + GAP[s_spin_frame & 3][0], y0 + GAP[s_spin_frame & 3][1], C_SKIN);
        return;
    }
    if (style == EYES_X) {
        static const char *const XS[] = { "#..#", ".##.", ".##.", "#..#" };
        stamp(XS, 4, iround(ex) - 2, iround(ey) - 1, C_IRIS, C_IRIS);
        return;
    }
    if (openness < 0.3f) {
        static const char *const SHUT[] = { "#..#", ".##." };
        stamp(SHUT, 2, iround(ex) - 2, iround(ey) + 1, C_IRIS, C_IRIS);
        return;
    }

    static const char *const BEAD[] = { ".###.", "#oo##", "#o###", "###o#", ".###." };
    static const char *const BIG[] = { ".###.", "#oo##", "#o###", "#####", "###o#", ".###." };
    const char *const *rows = style == EYES_WIDE ? BIG : BEAD;
    int n = style == EYES_WIDE ? 6 : 5;
    /* Lids close from the top: skip the upper rows as openness drops. */
    int skip = iround((1 - openness) * (n - 1));
    stamp(rows + skip, n - skip, cx - 2, cy - 2 + skip, C_IRIS, skip ? C_IRIS : C_SHINE);
}

static void draw_blush(int x, int y, float strength)
{
    static const char *const CHEEK[] = { ".##.", "####", ".##." };
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 4; i++) {
            if (CHEEK[j][i] != '#') {
                continue;
            }
            float b = bayer(x + i, y + j);
            if (b < strength) {
                px(x - 2 + i, y + j, (j == 1 && b < strength * 0.5f) ? C_BLUSHD : C_BLUSH);
            }
        }
    }
}

typedef enum {
    MOUTH_SMILE,
    MOUTH_O,
    MOUTH_HMM,
    MOUTH_TALK,
    MOUTH_GRIN,
    MOUTH_FLAT,
    MOUTH_FROWN,
} mouth_t;

static void draw_mouth(int x, int y, mouth_t m, float open)
{
    switch (m) {
    case MOUTH_FROWN: {
        static const char *const S[] = { ".##.", "#..#" };
        stamp(S, 2, x - 2, y, C_MOUTH, C_MOUTH);
        break;
    }
    case MOUTH_SMILE: {
        static const char *const S[] = { "#..#", ".##." };
        stamp(S, 2, x - 2, y, C_MOUTH, C_MOUTH);
        break;
    }
    case MOUTH_O: {
        static const char *const S[] = { ".##.", "#oo#", ".##." };
        stamp(S, 3, x - 2, y - 1, C_MOUTH, C_TONGUE);
        break;
    }
    case MOUTH_HMM: {
        static const char *const S[] = { "..#", "##." };
        stamp(S, 2, x - 1, y, C_MOUTH, C_MOUTH);
        break;
    }
    case MOUTH_TALK: {
        int h = 1 + iround(clampf(open, 0, 1) * 3.0f);
        int w = h > 2 ? 4 : 3;
        for (int j = 0; j < h; j++) {
            int inset = (j == 0 || j == h - 1) && h > 2 ? 1 : 0;
            for (int i = inset; i < w - inset; i++) {
                bool tongue = h >= 3 && j == h - 2 && i > inset && i < w - inset - 1;
                px(x - w / 2 + i, y + j, tongue ? C_TONGUE : C_MOUTH);
            }
        }
        break;
    }
    case MOUTH_GRIN: {
        static const char *const S[] = { "#####", ".#o#.", "..#.." };
        stamp(S, 3, x - 2, y, C_MOUTH, C_TONGUE);
        break;
    }
    case MOUTH_FLAT: {
        static const char *const S[] = { "##" };
        stamp(S, 1, x - 1, y + 1, C_MOUTH, C_MOUTH);
        break;
    }
    }
}

static void draw_sparkle(int x, int y, float twinkle, bool front)
{
    uint8_t arm = front ? C_ACC : C_AURA2;
    uint8_t core = front ? C_WHITE : C_SPK;
    if (twinkle > 0.8f) {
        px(x, y, core);
        for (int k = 1; k <= 2; k++) {
            uint8_t c = k == 1 ? (front ? C_SPK : arm) : arm;
            px(x + k, y, c);
            px(x - k, y, c);
            px(x, y + k, c);
            px(x, y - k, c);
        }
    } else if (twinkle > 0.45f) {
        px(x, y, front ? C_SPK : arm);
        px(x + 1, y, arm);
        px(x - 1, y, arm);
        px(x, y + 1, arm);
        px(x, y - 1, arm);
    } else if (twinkle > 0.15f) {
        px(x, y, arm);
    }
}

static void draw_sparkles(const muse_pose_t *p, float cx, float cy, bool front, float speed, int count)
{
    for (int i = 0; i < count; i++) {
        float a = p->t * speed + i * TAU / count;
        float s = sinf(a);
        if ((s > 0) != front) {
            continue;
        }
        float rr = 25.0f + 2.0f * sinf(i * 1.9f + p->t * 0.7f);
        int x = iround(cx + cosf(a) * rr);
        int y = iround(cy - 3 + s * rr * 0.42f);
        float tw = 0.5f + 0.5f * sinf(p->t * 5.0f + i * 1.7f);
        draw_sparkle(x, y, tw, front);
    }
}

/* Sound waves either side of the head. */
static void draw_waves(float cx, float cy, float body_rx, float level, float t)
{
    int n = 1 + (int)(clampf(level, 0, 1) * 3.2f);
    if (n > 3) {
        n = 3;
    }
    for (int k = 0; k < n; k++) {
        float r = body_rx + 5.0f + k * 3.0f;
        int span = 2 + k;
        float flick = 0.5f + 0.5f * sinf(t * 12.0f - k * 1.4f);
        for (int side = -1; side <= 1; side += 2) {
            for (int j = -span; j <= span; j++) {
                float xo = r - (float)(j * j) / (2.0f * r) * 3.0f;
                int x = iround(cx + side * xo);
                int y = iround(cy - 2 + j);
                if (k == 0 || bayer(x, y) < 0.35f + flick * 0.65f) {
                    px(x, y, k == 0 ? C_ACC : (k == 1 ? C_G1 : C_G2));
                }
            }
        }
    }
}

static void draw_thought_dots(float x, float y, float t)
{
    int active = (int)(fracf(t * 1.6f) * 3.0f);
    for (int i = 0; i < 3; i++) {
        int bx = iround(x + i * 4);
        int by = iround(y - i * 3) - (i == active ? 1 : 0);
        uint8_t c = i == active ? C_G0 : C_ACC;
        px(bx, by, c);
        px(bx + 1, by, c);
        px(bx, by + 1, c);
        px(bx + 1, by + 1, i == active ? C_G1 : C_G2);
    }
}

static void draw_hearts(float cx, float top, float t, float amount)
{
    static const char *const HEART[] = { ".#.#.", "#o###", "#####", ".###.", "..#.." };
    for (int i = 0; i < 2; i++) {
        float ph = fracf(t * 0.9f + i * 0.5f);
        if (ph > amount) {
            continue;
        }
        int hx = iround(cx + (i ? 13 : -18) + sinf(ph * TAU + i) * 2);
        int hy = iround(top - ph * 10);
        stamp(HEART, 5, hx, hy, C_HEART, C_WHITE);
    }
}

static void draw_alert(int x, int y)
{
    static const char *const BANG[] = { ".##.", ".##.", ".##.", ".##.", "....", ".##." };
    stamp(BANG, 6, x - 2, y, C_ACC, C_ACC);
}

/* ---------------------------------------------------------------------------
 * Frame
 * ------------------------------------------------------------------------- */

/*
 * Screen pixel -> grid cell, with 0x80 set on a cell's last screen pixel. When
 * cells are 3+ pixels, that edge is drawn dimmer so the pixel grid shows.
 */
static int s_size;

int muse_pixel_size(void)
{
    return s_size;
}

void muse_pixel_set_size(int px)
{
    if (!muse_pixel_init()) { return; }
    s_size = px < MAP_MAX ? px : MAP_MAX;
    bool grid = s_size >= 3 * W;
    for (int i = 0; i < s_size; i++) {
        int cell = i * W / s_size;
        bool edge = grid && (i + 1) * W / s_size != cell;
        s_map[i] = (uint8_t)(cell | (edge ? 0x80 : 0));
    }
}

void muse_pixel_scale(uint16_t *dst, int stride_px, int x0, int x1, int y0, int y1)
{
    if (!s_fb) { return; }
    int n = x1 - x0 + 1;
    const uint8_t *xmap = &s_map[x0];
    const uint16_t *prev = NULL;
    uint8_t prev_m = 0;
    for (int y = y0; y <= y1; y++, dst += stride_px) {
        uint8_t m = s_map[y];
        if (prev && m == prev_m) {
            memcpy(dst, prev, n * sizeof(uint16_t));
            continue;
        }
        const uint8_t *row = &s_fb[(m & 0x7f) * W];
        if (m & 0x80) {
            for (int i = 0; i < n; i++) {
                dst[i] = s_pal_dim[row[xmap[i] & 0x7f]];
            }
        } else {
            for (int i = 0; i < n; i++) {
                uint8_t xm = xmap[i];
                uint8_t c = row[xm & 0x7f];
                dst[i] = xm & 0x80 ? s_pal_dim[c] : s_pal[c];
            }
        }
        prev = dst;
        prev_m = m;
    }
}

void muse_pixel_render(const muse_pose_t *p)
{
    /* Older preview callers omit companion fields; retain normal motion. */
    muse_pose_t normalized = *p;
    if (!(normalized.companion.speed >= 0.5f && normalized.companion.speed <= 2)) { normalized.companion.speed = 1; }
    if (!(normalized.companion.intensity >= 0.25f && normalized.companion.intensity <= 1.5f)) { normalized.companion.intensity = 1; }
    if (normalized.companion.coat < 0 || normalized.companion.coat >= MUSE_COAT_COUNT) { normalized.companion.coat = MUSE_COAT_CREAM; }
    if (normalized.companion.character < 0 || normalized.companion.character >= MUSE_CHARACTER_COUNT) { normalized.companion.character = MUSE_CHARACTER_MUSE; }
    if (normalized.companion.accessory < 0 || normalized.companion.accessory >= MUSE_ACCESSORY_COUNT) { normalized.companion.accessory = MUSE_ACCESSORY_NONE; }
    p = &normalized;
    if (!muse_pixel_init()) { return; }
    static bool s_luts;
    if (!s_luts) {
        init_luts();
        s_luts = true;
    }
    float dt = s_eyes.last_t > 0 ? clampf(p->t - s_eyes.last_t, 0, 0.2f) : 0.04f;
    s_eyes.last_t = p->t;

    muse_mode_t mode = p->mode;
    /* Powering down: the avatar waves, then nods off as the glow fades. */
    float fade = mode == MUSE_MODE_OFF ? clampf(1.0f - p->mode_t / 1.3f, 0, 1) : 1.0f;
    /* Expressions yield to shutdown and error so those states stay readable. */
    muse_emotion_t emotion = (mode == MUSE_MODE_OFF || mode == MUSE_MODE_ERROR)
                            ? MUSE_EMOTION_NEUTRAL : p->emotion;
    bool reacting = p->happy > 0 && mode != MUSE_MODE_OFF && mode != MUSE_MODE_ERROR;
    if (reacting) { emotion = MUSE_EMOTION_LOVE; }
    float happy = emotion == MUSE_EMOTION_EXCITED ? 1.0f : 0.0f;
    float affection = emotion == MUSE_EMOTION_LOVE ? (reacting ? p->happy : 1.0f) : 0;
    float affection_t = reacting ? p->affection_t : p->t;
    affection *= fminf(p->companion.intensity, 1.0f);
    happy *= fminf(p->companion.intensity, 1.0f);
    float level = p->level;
    float personality_rate = p->companion.personality == MUSE_PERSONALITY_PLAYFUL ? 1.15f :
                             p->companion.personality == MUSE_PERSONALITY_CURIOUS ? 1.08f :
                             p->companion.personality == MUSE_PERSONALITY_QUIET ? 0.75f :
                             p->companion.personality == MUSE_PERSONALITY_DREAMY ? 0.6f : 1;
    float t = p->t * p->companion.speed * personality_rate;
    float et = fmodf(p->emotion_t, 14.0f);

    update_palette(&SCHEMES[mode], dt, p->companion.coat);
    float blink = eyes_update(p, dt);

    /* How Muse's character reacts: ears and tufts perk up when curious, excited or
     * listening and droop when sad, sleepy or shy. Eased so it never snaps. */
    static float s_perk;
    {
        float target = 0;
        switch (emotion) {
        case MUSE_EMOTION_EXCITED: case MUSE_EMOTION_SURPRISED: case MUSE_EMOTION_CURIOUS:
        case MUSE_EMOTION_GREETING: case MUSE_EMOTION_LOVE: case MUSE_EMOTION_PLAYFUL:
        case MUSE_EMOTION_DANCE: case MUSE_EMOTION_LAUGH: case MUSE_EMOTION_PROUD: target = 1; break;
        case MUSE_EMOTION_SAD: case MUSE_EMOTION_WORRIED: case MUSE_EMOTION_SLEEPY:
        case MUSE_EMOTION_EMBARRASSED: case MUSE_EMOTION_SHY: case MUSE_EMOTION_COMFORT: target = -1; break;
        case MUSE_EMOTION_ANGRY: target = -1.6f; break;
        case MUSE_EMOTION_ANNOYED: target = -0.6f; break;
        case MUSE_EMOTION_DIZZY: target = -1.0f; break;
        default: break;
        }
        if (mode == MUSE_MODE_LISTENING) { target = 1; }
        else if (mode == MUSE_MODE_THINKING) { target = 0.5f; }
        else if (mode == MUSE_MODE_ERROR || mode == MUSE_MODE_OFF) { target = -1; }
        s_perk += (target - s_perk) * (1.0f - expf(-dt * 6.0f));
    }
    const float perk = s_perk;

    memset(s_fb, C_BG, W * H);

    /* ---- body motion ---- */
    float bob, breathe_rate = 2.0f, lean = 0, hop = 0;
    switch (mode) {
    case MUSE_MODE_LISTENING:
        bob = sinf(t * 3.0f) * 0.6f;
        break;
    case MUSE_MODE_THINKING:
        bob = sinf(t * 2.4f) * 0.8f;
        lean = sinf(t * (p->mode_t > 8 ? 0.7f : 1.3f)) * (p->mode_t > 8 ? 0.6f : 1.2f);
        break;
    case MUSE_MODE_SPEAKING:
        bob = sinf(t * 5.0f) * 0.6f - level * 1.5f;
        break;
    case MUSE_MODE_ERROR:
        bob = 1.0f;
        lean = sinf(t * 18.0f) * (p->mode_t < 0.6f ? 1.0f : 0.0f);
        break;
    default:
        bob = sinf(t * 1.8f) * 1.0f;
        break;
    }
    if (happy > 0) {
        hop = fabsf(sinf(t * 9.0f)) * 3.0f * happy;
    }

    if (emotion == MUSE_EMOTION_SAD) { bob += 3.0f; lean = -1.0f; }
    if (emotion == MUSE_EMOTION_SLEEPY) { bob = 2.0f + sinf(t) * 0.4f; breathe_rate = 1.0f; }
    if (emotion == MUSE_EMOTION_CURIOUS) { lean = 2.0f + sinf(t * 1.4f); }
    if (emotion == MUSE_EMOTION_SHY) { lean = sinf(t * 1.2f) * 1.5f; }
    if (emotion == MUSE_EMOTION_SURPRISED) { hop = 1.5f + sinf(t * 3.0f) * 0.4f; }

    if (emotion == MUSE_EMOTION_LOVE) {
        lean = sinf(t * 1.6f) * 1.8f * affection;
        bob = sinf(t * 2.0f) * 0.45f;
        hop = affection_t < 2.0f ? fabsf(sinf(affection_t * 5.0f)) * 2.0f : 0;
    }
    if (emotion == MUSE_EMOTION_PLAYFUL) { lean = sinf(t * 4.0f) * 2.8f; hop = fabsf(sinf(t * 4.0f)) * 2; }
    if (emotion == MUSE_EMOTION_PROUD) { bob = -1.5f; lean = 0; }
    if (emotion == MUSE_EMOTION_WORRIED) { lean = sinf(t * 6) * 0.9f; bob = 1; }
    if (emotion == MUSE_EMOTION_CALM) { breathe_rate = 1.0f; bob = sinf(t) * 0.4f; }
    if (emotion == MUSE_EMOTION_ANGRY) { lean = sinf(t * 22) * 1.1f; bob = -0.8f + sinf(t * 31) * 0.3f; }   /* trembling with fury */
    if (emotion == MUSE_EMOTION_ANNOYED) { lean = -1.2f; bob = -0.3f; breathe_rate = 3.0f; }   /* a huff, turned half away */
    if (emotion == MUSE_EMOTION_DIZZY) {
        /* Reels in a slow circle, getting steadier as the stars fade. */
        float fade = clampf((5.0f - et) / 2.5f, 0.25f, 1.0f);
        lean = sinf(t * 3.4f) * 3.6f * fade;
        bob = cosf(t * 3.4f) * 1.3f * fade + 1.0f;
    }

    if (emotion == MUSE_EMOTION_LAUGH) {
        float energy = et < 1 ? et : et < 5 ? 1 : clampf((8 - et) / 3, 0, 1);
        hop = fabsf(sinf(t * 10)) * 2.3f * energy;
        lean = sinf(t * 7) * energy;
    }
    if (emotion == MUSE_EMOTION_COMFORT) {
        lean = sinf(t * 1.2f) * 0.9f;
        bob = 1.0f; breathe_rate = 1.2f;
    }
    if (emotion == MUSE_EMOTION_EMBARRASSED) { lean = -1.8f; bob = 1.0f; }
    if (emotion == MUSE_EMOTION_GREETING) {
        hop = et < 1 ? sinf(et * 3.1416f) * 2 : 0;
        lean = sinf(t * 2) * 0.6f;
    }
    if (emotion == MUSE_EMOTION_STRETCH) { bob = -1.0f - sinf(et * 0.5f); breathe_rate = 1; }
    if (emotion == MUSE_EMOTION_DANCE) { lean = sinf(t * 5) * 3; hop = fabsf(sinf(t * 5)) * 2; }
    if (p->activity.type == MUSE_ACTIVITY_BREATHE) { bob = -p->activity.breath * 1.2f; breathe_rate = 0.6f; }
    /* Each character moves in its own way, and personality sets how bouncy it is. */
    switch (p->companion.character) {
    case MUSE_CHARACTER_BUNNY: hop *= 1.5f; break;                       /* hops higher */
    case MUSE_CHARACTER_KITTY:
        if (emotion == MUSE_EMOTION_LOVE || emotion == MUSE_EMOTION_COMFORT) { lean += sinf(t * 38.0f) * 0.35f; }   /* purring */
        break;
    case MUSE_CHARACTER_CHICK:
        if (emotion == MUSE_EMOTION_NEUTRAL && mode == MUSE_MODE_IDLE && fmodf(t, 4.1f) < 0.3f) { bob += sinf(fmodf(t, 4.1f) / 0.3f * 3.1416f) * 2.0f; }   /* a peck */
        break;
    case MUSE_CHARACTER_ROBOT:
        if (emotion == MUSE_EMOTION_DIZZY || emotion == MUSE_EMOTION_ANGRY || mode == MUSE_MODE_ERROR) { lean += (float)(((int)(t * 20.0f)) % 3 - 1); }   /* glitching */
        break;
    case MUSE_CHARACTER_BEAR: case MUSE_CHARACTER_PANDA:
        if (mode == MUSE_MODE_IDLE && emotion == MUSE_EMOTION_NEUTRAL) { lean += sinf(t * 0.9f) * 0.8f; }   /* a slow sway */
        break;
    default: break;
    }
    if (p->companion.personality == MUSE_PERSONALITY_PLAYFUL) { hop += fabsf(sinf(t * 3.0f)) * 0.8f; bob *= 1.2f; }
    else if (p->companion.personality == MUSE_PERSONALITY_QUIET || p->companion.personality == MUSE_PERSONALITY_DREAMY) { bob *= 0.6f; hop *= 0.7f; }

    /* Ease body motion across selections instead of snapping between poses. */
    static float smooth_lean, smooth_bob, smooth_hop;
    float ease = 1.0f - expf(-dt * 7.0f);
    smooth_lean += (lean - smooth_lean) * ease;
    smooth_bob += (bob - smooth_bob) * ease;
    smooth_hop += (hop - smooth_hop) * ease;
    lean = smooth_lean * p->companion.intensity; bob = smooth_bob * p->companion.intensity; hop = smooth_hop * p->companion.intensity;
    if (p->gaze_active && mode == MUSE_MODE_IDLE && emotion == MUSE_EMOTION_NEUTRAL) {
        lean += s_eyes.gx * 0.8f;
    }

    /* Boot: the avatar pops up from a squash, then opens their eyes. */
    float boot = mode == MUSE_MODE_BOOT ? clampf(p->mode_t / 1.4f, 0, 1) : 1.0f;
    float pop = mode == MUSE_MODE_BOOT ? clampf(p->mode_t / 0.6f, 0, 1) : 1.0f;
    float squash = 1.0f - (1.0f - pop) * 0.35f + sinf(pop * 3.1416f) * 0.06f;

    if (p->companion.reduced_motion) { lean *= 0.2f; bob *= 0.2f; hop = 0; }
    float breathe = sinf(t * breathe_rate + 1.0f) * 0.03f;
    if (p->activity.type == MUSE_ACTIVITY_BREATHE) { breathe = p->activity.breath * 0.045f; }
    avatar_t j;
    j.a = 17.0f * (1 + breathe) * (2.0f - squash) + level * 0.8f;
    j.b = 21.0f * (1 - breathe) * squash;
    j.cx = 32.0f + lean;
    j.cy = 56.5f - j.b + bob * 0.5f - hop;   /* feet stay near the ground */
    j.fa = j.a * 0.69f;
    j.fb = 8.2f * squash;
    j.fx = j.cx + lean * 0.3f + s_eyes.gx * 0.8f;
    j.fy = j.cy - j.b * 0.30f + bob * 0.3f + s_eyes.gy * 0.35f;

    /* ---- background layers ---- */
    float aura_r = (p->activity.type == MUSE_ACTIVITY_BREATHE ? 24 + p->activity.breath * 6 : 29.0f) + level * 4.0f + sinf(t * 1.5f) * 1.0f;
    float aura_s = (0.75f * boot + level * 0.4f) * fade;
    draw_aura(j.cx, j.cy - 3, aura_r, aura_s);
    if (mode == MUSE_MODE_LISTENING) {
        draw_rings(j.cx, j.fy + 2, t, level, 0.9f);
    } else if (mode == MUSE_MODE_SPEAKING) {
        draw_rings(j.cx, j.fy + 2, t, level, 0.6f);
    }
    draw_shadow(j.cx, 58.5f, 13.0f - hop * 0.8f);

    float spk_speed = mode == MUSE_MODE_THINKING ? 2.8f : mode == MUSE_MODE_LISTENING ? 1.2f
                    : mode == MUSE_MODE_SPEAKING ? 1.5f : 0.6f;
    int spk_count = mode == MUSE_MODE_BOOT ? (int)(boot * 6) : (int)(6 * fade);
    draw_sparkles(p, j.cx, j.cy, false, spk_speed, spk_count);

    /* ---- limbs ---- */
    float base = j.cy + j.b;
    limb_t feet[2];
    float step = mode == MUSE_MODE_SPEAKING ? sinf(t * 5.0f) * 0.6f : 0.0f;
    feet[0] = (limb_t){ j.cx - 7.0f, base - 0.5f + (happy > 0 ? hop * 0.3f : step), -0.15f };
    feet[1] = (limb_t){ j.cx + 7.0f, base - 0.5f + (happy > 0 ? hop * 0.3f : -step), 0.15f };

    limb_t arms[2];
    float adx = j.a + 0.3f;
    float ay = j.cy + 4.0f;
    switch (mode) {
    case MUSE_MODE_LISTENING:
        /* Hands raised beside the face, like cupping an ear. */
        arms[0] = (limb_t){ j.cx - adx + 1.0f, j.fy + 5.0f, 0.55f };
        arms[1] = (limb_t){ j.cx + adx - 1.0f, j.fy + 5.0f, -0.55f };
        break;
    case MUSE_MODE_THINKING:
        /* One paw up to the chin. */
        arms[0] = (limb_t){ j.cx - adx, ay, -0.35f };
        arms[1] = (limb_t){ j.cx + 7.5f, j.fy + j.fb + 3.5f, -1.1f };
        break;
    case MUSE_MODE_OFF: {
        float w = sinf(t * 12.0f) * 0.35f * fade;
        arms[0] = (limb_t){ j.cx - adx, ay, -0.3f };
        arms[1] = (limb_t){ j.cx + adx + 1.0f, j.cy - 4.0f, -2.3f - w };
        break;
    }
    case MUSE_MODE_SPEAKING: {
        float w = sinf(t * 7.0f) * (0.25f + level * 0.45f);
        arms[0] = (limb_t){ j.cx - adx, ay - 1.0f, -0.4f - w };
        arms[1] = (limb_t){ j.cx + adx, ay - 1.0f, 0.4f - w };
        break;
    }
    default: {
        float sway = sinf(t * 1.8f + 0.6f) * 0.08f;
        if (happy > 0) {
            /* Arms up and wiggling. */
            float wig = sinf(t * 14.0f) * 0.25f;
            arms[0] = (limb_t){ j.cx - adx - 1.0f, j.cy - 4.0f, 2.4f + wig };
            arms[1] = (limb_t){ j.cx + adx + 1.0f, j.cy - 4.0f, -2.4f - wig };
        } else {
            arms[0] = (limb_t){ j.cx - adx, ay, -0.3f + sway };
            arms[1] = (limb_t){ j.cx + adx, ay, 0.3f - sway };
        }
        break;
    }
    }
    if (emotion == MUSE_EMOTION_SHY) {
        arms[0] = (limb_t){ j.cx - 5.0f, j.fy + 8.0f, 0.8f };
        arms[1] = (limb_t){ j.cx + 5.0f, j.fy + 8.0f, -0.8f };
    } else if (emotion == MUSE_EMOTION_SURPRISED) {
        arms[0] = (limb_t){ j.cx - adx, j.fy + 2.0f, 2.0f };
        arms[1] = (limb_t){ j.cx + adx, j.fy + 2.0f, -2.0f };
    }
    if (emotion == MUSE_EMOTION_LOVE) {
        /* A greeting wave becomes a cuddle, then a gentle goodbye wave. */
        if (reacting && (affection_t < 2 || affection_t > 9)) {
            arms[1] = (limb_t){ j.cx + adx, j.fy + 1, -2.2f + sinf(t * 8) * 0.35f };
        } else {
            arms[0] = (limb_t){ j.cx - 4.0f, j.fy + 10.0f, 1.2f };
            arms[1] = (limb_t){ j.cx + 4.0f, j.fy + 10.0f, -1.2f };
        }
    } else if (emotion == MUSE_EMOTION_PLAYFUL) {
        arms[0] = (limb_t){ j.cx - adx, j.cy - 3, 2.0f + sinf(t * 6) * 0.4f };
    } else if (emotion == MUSE_EMOTION_PROUD) {
        arms[0] = (limb_t){ j.cx - adx + 3, ay, -1.0f };
        arms[1] = (limb_t){ j.cx + adx - 3, ay, 1.0f };
    } else if (emotion == MUSE_EMOTION_WORRIED) {
        arms[1] = (limb_t){ j.cx + 6, j.fy + 6, -1.5f };
    }
    if (emotion == MUSE_EMOTION_LAUGH) {
        arms[0] = (limb_t){ j.cx - 6, j.cy + 8 + sinf(t * 10) * 0.6f, 0.7f };
        arms[1] = (limb_t){ j.cx + 6, j.cy + 8, -0.7f };
    } else if (emotion == MUSE_EMOTION_COMFORT) {
        float reach = clampf(et / 2, 0, 1);
        arms[0] = (limb_t){ j.cx - adx + reach * 9, j.fy + 11, 1.0f };
        arms[1] = (limb_t){ j.cx + adx - reach * 9, j.fy + 11, -1.0f };
    } else if (emotion == MUSE_EMOTION_EMBARRASSED && et < 4) {
        float peek = et > 2 ? sinf(t * 2) * 1.5f : 0;
        arms[0] = (limb_t){ j.fx - 5 - peek, j.fy + 2, 1.5f };
        arms[1] = (limb_t){ j.fx + 5 + peek, j.fy + 2, -1.5f };
    }
    if (emotion == MUSE_EMOTION_GREETING) {
        arms[1] = (limb_t){ j.cx + adx, j.fy - 2, -2.2f + sinf(t * 9) * 0.35f };
    }
    if (mode == MUSE_MODE_LISTENING && level > 0.12f) {
        j.fy += sinf(t * 4) * 0.4f; /* tiny acknowledgment while hearing speech */
    }
    if (emotion == MUSE_EMOTION_STRETCH) {
        float lift = sinf(clampf(et / 6, 0, 1) * 3.1416f);
        arms[0] = (limb_t){ j.cx - adx, j.cy - 3 - lift * 8, 2.4f };
        arms[1] = (limb_t){ j.cx + adx, j.cy - 3 - lift * 8, -2.4f };
    } else if (emotion == MUSE_EMOTION_DANCE) {
        arms[0] = (limb_t){ j.cx - adx, j.fy + sinf(t * 5) * 4, 2.2f };
        arms[1] = (limb_t){ j.cx + adx, j.fy - sinf(t * 5) * 4, -2.2f };
    }
    /* Tails sit behind the body, so only the part past its outline shows. */
    {
        int tx = iround(j.cx + j.a) - 1, ty_ = iround(j.cy + j.b * 0.45f);
        float swing = sinf(t * (mode == MUSE_MODE_IDLE ? 2.2f : 4.0f)) * (perk >= 0 ? 1.4f : 0.5f);
        switch (p->companion.character) {
        case MUSE_CHARACTER_KITTY: {
            static const char *const TAIL[] = { "..##", ".#ff#", "#ff#.", "#ff#.", "#ff#.", ".##.." };
            stamp3_ex(TAIL, 6, 5, tx, ty_ - 6, false, swing, C_OUT, C_BM, C_BM);
            break;
        }
        case MUSE_CHARACTER_BUNNY: {
            static const char *const POM[] = { ".###.", "#fff#", "#fff#", "#fff#", ".###." };
            stamp3_ex(POM, 5, 5, tx, ty_ - 1, false, 0, C_OUT, C_WHITE, C_WHITE);
            break;
        }
        case MUSE_CHARACTER_BEAR: case MUSE_CHARACTER_PANDA: {
            static const char *const NUB[] = { ".##.", "#ff#", ".##." };
            stamp3_ex(NUB, 3, 4, tx, ty_, false, 0, C_OUT, p->companion.character == MUSE_CHARACTER_PANDA ? C_OUT : C_BM, C_BM);
            break;
        }
        case MUSE_CHARACTER_CHICK: {
            static const char *const FEATHER[] = { "#.#", "#f#", ".#." };
            stamp3_ex(FEATHER, 3, 3, tx, ty_ - 1, false, swing, C_OUT, C_BEAK, C_BEAK);
            break;
        }
        default: break;
        }
    }
    draw_avatar(&j, arms, feet);

    /* ---- face ---- */
    float eye_y = j.fy - 0.5f;
    float eye_dx = j.fa * 0.48f;
    eye_style_t style = EYES_NORMAL;
    float open = 1.0f - blink;
    mouth_t mouth = MOUTH_SMILE;
    float mouth_open = 0;

    switch (mode) {
    case MUSE_MODE_BOOT:
        open = p->mode_t < 0.9f ? 0.0f : clampf((p->mode_t - 0.9f) / 0.3f, 0, 1);
        break;
    case MUSE_MODE_LISTENING:
        style = EYES_WIDE;
        mouth = MOUTH_O;
        break;
    case MUSE_MODE_THINKING:
        open *= 0.85f;
        mouth = MOUTH_HMM;
        break;
    case MUSE_MODE_SPEAKING:
        mouth = MOUTH_TALK;
        mouth_open = level * 1.3f + 0.1f * (0.5f + 0.5f * sinf(t * 22.0f));
        break;
    case MUSE_MODE_ERROR:
        style = EYES_X;
        mouth = MOUTH_FLAT;
        break;
    case MUSE_MODE_OFF:
        open = clampf((1.0f - p->mode_t / 1.0f) * 1.5f, 0, 1);
        mouth = MOUTH_SMILE;
        break;
    default:
        break;
    }
    if (happy > 0.2f && mode != MUSE_MODE_ERROR) {
        style = EYES_HAPPY;
        mouth = MOUTH_GRIN;
    }

    switch (emotion) {
    case MUSE_EMOTION_SAD: open *= 0.65f; mouth = MOUTH_FROWN; break;
    case MUSE_EMOTION_SURPRISED: style = EYES_WIDE; mouth = MOUTH_O; break;
    case MUSE_EMOTION_SLEEPY: open = 0.15f; mouth = MOUTH_O; break;
    case MUSE_EMOTION_CURIOUS: style = EYES_WIDE; mouth = MOUTH_HMM; break;
    case MUSE_EMOTION_SHY: open *= 0.6f; mouth = MOUTH_SMILE; break;
    case MUSE_EMOTION_LOVE: style = affection_t < 3 ? EYES_HEART : EYES_HAPPY; mouth = MOUTH_GRIN; break;
    case MUSE_EMOTION_PLAYFUL: style = EYES_HAPPY; mouth = MOUTH_GRIN; break;
    case MUSE_EMOTION_PROUD: open *= 0.75f; mouth = MOUTH_GRIN; break;
    case MUSE_EMOTION_WORRIED: open *= 0.8f; mouth = MOUTH_HMM; break;
    case MUSE_EMOTION_CALM: open = 0.15f; mouth = MOUTH_SMILE; break;
    case MUSE_EMOTION_ANGRY: open *= 0.55f; mouth = MOUTH_FROWN; break;
    case MUSE_EMOTION_ANNOYED: open *= 0.5f; mouth = MOUTH_FLAT; break;
    case MUSE_EMOTION_DIZZY:
        style = EYES_DIZZY; mouth = MOUTH_O; mouth_open = 0.45f + 0.3f * sinf(t * 6);
        s_spin_frame = ((int)(t * 8)) & 3;
        break;
    case MUSE_EMOTION_DANCE: style = EYES_HAPPY; mouth = MOUTH_GRIN; break;
    case MUSE_EMOTION_STRETCH: open = 0.2f; mouth = MOUTH_O; break;
    case MUSE_EMOTION_GREETING: style = EYES_HAPPY; mouth = MOUTH_GRIN; break;
    case MUSE_EMOTION_LAUGH:
        style = et < 5 ? EYES_HAPPY : EYES_NORMAL;
        mouth = et < 5 ? MOUTH_TALK : MOUTH_GRIN;
        mouth_open = 0.5f + 0.4f * sinf(t * 10);
        break;
    case MUSE_EMOTION_COMFORT:
        open *= 0.65f; mouth = et < 2 ? MOUTH_HMM : MOUTH_SMILE; break;
    case MUSE_EMOTION_EMBARRASSED:
        open *= et < 3 ? 0.4f : 0.8f; mouth = et < 3 ? MOUTH_HMM : MOUTH_SMILE; break;
    default: break;
    }
    if (mode != MUSE_MODE_ERROR && mode != MUSE_MODE_OFF && p->blend_weight > 0) {
        float weight = clampf(p->blend_weight, 0, 1);
        float second_open = 1;
        if (p->blend == MUSE_EMOTION_SLEEPY || p->blend == MUSE_EMOTION_CALM) {
            second_open = 0.15f;
            if (weight > 0.35f) { style = EYES_NORMAL; }
        } else if (p->blend == MUSE_EMOTION_SAD || p->blend == MUSE_EMOTION_SHY) { second_open = 0.6f; }
        else if (p->blend == MUSE_EMOTION_CURIOUS || p->blend == MUSE_EMOTION_SURPRISED) {
            if (weight > 0.5f) { style = EYES_WIDE; }
        } else if (p->blend == MUSE_EMOTION_LOVE && weight > 0.65f) { style = EYES_HEART; }
        open += (second_open - open) * weight;
    }
    /* Ease lids without delaying the natural blink. */
    static float smooth_open = 1;
    smooth_open += (open - smooth_open) * (1.0f - expf(-dt * 12));
    open = fminf(smooth_open, 1.0f - blink);
    /* Keep speech synchronized even with a selected expression. */
    if (mode == MUSE_MODE_SPEAKING) {
        mouth = MOUTH_TALK;
        mouth_open = level * 1.3f + 0.1f * (0.5f + 0.5f * sinf(t * 22.0f));
    }

    draw_eye(j.fx - eye_dx, eye_y, open, style, s_eyes.gx, s_eyes.gy);
    draw_eye(j.fx + eye_dx, eye_y, emotion == MUSE_EMOTION_PLAYFUL ? 0.0f : open,
             emotion == MUSE_EMOTION_PLAYFUL ? EYES_NORMAL : style, s_eyes.gx, s_eyes.gy);

    /* Tiny brows for the expressive states. */
    int bl = iround(j.fx - eye_dx), br = iround(j.fx + eye_dx), by = iround(eye_y) - 4;
    if (mode == MUSE_MODE_THINKING) {
        px(bl - 1, by + 1, C_BROW); px(bl, by + 1, C_BROW);
        px(br - 1, by, C_BROW); px(br, by - 1, C_BROW);
    } else if (mode == MUSE_MODE_LISTENING) {
        px(bl - 1, by - 1, C_BROW); px(bl, by - 1, C_BROW);
        px(br - 1, by - 1, C_BROW); px(br, by - 1, C_BROW);
    }

    if (emotion == MUSE_EMOTION_SAD) {
        px(bl - 1, by + 1, C_BROW); px(bl, by, C_BROW);
        px(br, by, C_BROW); px(br + 1, by + 1, C_BROW);
        int tear_y = iround(eye_y + 3) + (int)(t * 3.0f) % 4;
        px(bl, tear_y, C_SHINE); px(bl, tear_y + 1, C_SHINE);
    } else if (emotion == MUSE_EMOTION_CURIOUS || emotion == MUSE_EMOTION_SURPRISED) {
        px(bl - 1, by - 1, C_BROW); px(bl, by - 1, C_BROW);
        px(br, by - 2, C_BROW); px(br + 1, by - 2, C_BROW);
    }

    if (emotion == MUSE_EMOTION_ANNOYED) {
        px(bl - 1, by + 1, C_BROW); px(bl, by + 1, C_BROW); px(bl + 1, by + 1, C_BROW);
        px(br - 1, by + 1, C_BROW); px(br, by + 1, C_BROW); px(br + 1, by + 1, C_BROW);
    }
    if (emotion == MUSE_EMOTION_ANGRY) {
        px(bl - 2, by - 1, C_BROW); px(bl - 1, by, C_BROW); px(bl, by + 1, C_BROW);
        px(br, by + 1, C_BROW); px(br + 1, by, C_BROW); px(br + 2, by - 1, C_BROW);
    } else if (emotion == MUSE_EMOTION_WORRIED) {
        px(bl - 1, by + 1, C_BROW); px(bl, by, C_BROW);
        px(br, by, C_BROW); px(br + 1, by + 1, C_BROW);
    }
    float blush = 0.72f + happy * 0.28f + (mode == MUSE_MODE_SPEAKING ? 0.15f : 0.0f);
    if (emotion == MUSE_EMOTION_SHY || emotion == MUSE_EMOTION_LOVE || emotion == MUSE_EMOTION_EMBARRASSED || emotion == MUSE_EMOTION_ANGRY) { blush = 1.0f; }
    draw_blush(iround(j.fx - j.fa * 0.72f), iround(eye_y + 2), blush);
    draw_blush(iround(j.fx + j.fa * 0.72f), iround(eye_y + 2), blush);

    draw_mouth(iround(j.fx), iround(eye_y + 3), mouth, mouth_open);

    if (emotion == MUSE_EMOTION_EMBARRASSED && et < 4) {
        /* Foreground paws hide the eyes, then part to reveal a peek. */
        static const char *const PAW[] = {
            "..###..", ".#ooo#.", "#ooooo#", "#ooooo#", "#ooooo#", ".#ooo#.", "..###.."
        };
        float part = et < 2 ? 0 : (et - 2) * 2.0f;
        stamp(PAW, 7, iround(j.fx - eye_dx - part) - 3, iround(eye_y) - 2, C_OUT, C_BM);
        stamp(PAW, 7, iround(j.fx + eye_dx + part) - 3, iround(eye_y) - 2, C_OUT, C_BM);
    }

    /* ---- character: ears, antenna, noses and other species features ---- */
    {
        int ty = iround(j.cy - j.b), cxi = iround(j.cx), fyi = iround(j.fy);
        int ex = iround(j.fx), ey = iround(eye_y);
        float droop = perk < 0 ? -perk : 0;          /* 0..1.6, ears flop outward */
        int lift = perk > 0.5f ? 1 : 0;              /* alert ears rise a pixel */
        float sway = sinf(t * 1.7f) * 0.8f;
        bool flick = fmodf(t, 5.3f) < 0.2f;          /* one ear twitches now and then */
        bool beat = sinf(t * (mode == MUSE_MODE_THINKING ? 9.0f : 3.0f)) > 0;
        switch (p->companion.character) {
        case MUSE_CHARACTER_KITTY: {
            static const char *const EAR[] = { "#....", "##...", "#f#..", "#fi#.", "#fii#", "#####" };
            stamp3_ex(EAR, 6, 5, cxi - 12, ty - 3 - lift, false, -droop * 2.0f, C_OUT, C_BL, C_HEART);
            stamp3_ex(EAR, 6, 5, cxi + 8, ty - 3 - lift + (flick ? 2 : 0), true, droop * 2.0f + (flick ? 1.0f : 0), C_OUT, C_BL, C_HEART);
            /* nose and whiskers */
            static const char *const NOSE[] = { "###", ".#." };
            stamp(NOSE, 2, ex - 1, ey + 1, C_HEART, C_HEART);
            for (int i = 0; i < 3; i++) {
                int wy = fyi + 1 + i * 2, wob = (mode == MUSE_MODE_SPEAKING && beat) ? 1 : 0;
                for (int k = 0; k < 5; k++) {
                    int dy = (k > 2 ? (i - 1) : 0) + (k > 2 ? wob : 0);
                    px(cxi - 12 - k, wy + dy, C_OUT);
                    px(cxi + 12 + k, wy + dy, C_OUT);
                }
            }
            break;
        }
        case MUSE_CHARACTER_BUNNY: {
            static const char *const EAR[] = { ".###.", "#fff#", "#fif#", "#fif#", "#fif#", "#fif#", "#fif#", "#fff#", "#####" };
            float bend = droop * 4.0f;
            stamp3_ex(EAR, 9, 5, cxi - 11, ty - 9 - lift + (droop > 0.5f ? 3 : 0), false, -bend + sway, C_OUT, C_BL, C_HEART);
            stamp3_ex(EAR, 9, 5, cxi + 7, ty - 9 - lift + (droop > 0.5f ? 3 : 0), true, bend - sway * 0.6f + (flick ? 1.5f : 0), C_OUT, C_BL, C_HEART);
            static const char *const NOSE[] = { "##", "##" };
            stamp(NOSE, 2, ex, ey + 1, C_HEART, C_HEART);
            px(ex - 1, ey + 1, C_HEART);
            px(ex + 2, ey + 1, C_HEART);
            /* two front teeth */
            px(ex - 1, ey + 6, C_WHITE); px(ex, ey + 6, C_WHITE);
            px(ex + 1, ey + 6, C_WHITE); px(ex + 2, ey + 6, C_WHITE);
            px(ex, ey + 6, C_OUT2); px(ex + 1, ey + 6, C_OUT2);
            px(ex - 1, ey + 7, C_WHITE); px(ex, ey + 7, C_WHITE);
            px(ex + 1, ey + 7, C_WHITE); px(ex + 2, ey + 7, C_WHITE);
            break;
        }
        case MUSE_CHARACTER_BEAR: case MUSE_CHARACTER_PANDA: {
            bool panda = p->companion.character == MUSE_CHARACTER_PANDA;
            static const char *const EAR[] = { "..###..", ".#fff#.", "#ffiff#", "#fiiif#", "#ffiff#", ".#fff#.", "..###.." };
            int dy = droop > 0.5f ? 1 : 0;
            stamp3_ex(EAR, 7, 7, cxi - 16, ty - 2 + dy, false, -droop, C_OUT, panda ? C_OUT : C_BL, panda ? C_OUT : C_BH);
            stamp3_ex(EAR, 7, 7, cxi + 10, ty - 2 + dy + (flick ? 1 : 0), true, droop, C_OUT, panda ? C_OUT : C_BL, panda ? C_OUT : C_BH);
            /* muzzle and nose */
            static const char *const MUZZLE[] = { ".###.", "#fff#", "#fff#", ".###." };
            stamp3_ex(MUZZLE, 4, 5, ex - 2, ey + 1, false, 0, C_OUT2, C_SKINL, C_SKINL);
            static const char *const NOSE[] = { "###", ".#." };
            stamp(NOSE, 2, ex - 1, ey + 2, C_OUT, C_OUT);
            if (panda) {
                /* dark patches just below the eyes */
                for (int side = -1; side <= 1; side += 2) {
                    int px0 = ex + side * iround(eye_dx);
                    px(px0 - 3, ey + 3, C_OUT); px(px0 - 2, ey + 4, C_OUT); px(px0 - 1, ey + 4, C_OUT);
                    px(px0, ey + 4, C_OUT); px(px0 + 1, ey + 4, C_OUT); px(px0 + 2, ey + 4, C_OUT); px(px0 + 3, ey + 3, C_OUT);
                }
            }
            break;
        }
        case MUSE_CHARACTER_ROBOT: {
            static const char *const BALL[] = { "..###..", ".#iii#.", "#iiiii#", ".#iii#.", "..###.." };
            bool lit = mode == MUSE_MODE_ERROR ? beat : (mode == MUSE_MODE_IDLE ? fmodf(t, 2.0f) < 1.4f : true);
            uint8_t glow = mode == MUSE_MODE_ERROR ? C_HEART : (lit ? C_WHITE : C_ACC);
            stamp3_ex(BALL, 5, 7, cxi - 3, ty - 9 - lift, false, 0, C_OUT, glow, glow);
            for (int y = ty - 4 - lift; y <= ty; y++) { px(cxi, y, C_OUT); px(cxi + 1, y, C_OUT); }
            static const char *const BOLT[] = { "###", "#i#", "#i#", "###" };
            stamp3_ex(BOLT, 4, 3, cxi - 19, fyi - 1, false, 0, C_OUT, C_ACC, C_WHITE);
            stamp3_ex(BOLT, 4, 3, cxi + 16, fyi - 1, false, 0, C_OUT, C_ACC, C_WHITE);
            /* status LEDs on the cheeks and a speaker grille instead of a nose */
            uint8_t led = (mode == MUSE_MODE_SPEAKING || mode == MUSE_MODE_LISTENING) && beat ? C_WHITE : C_ACC;
            px(ex - iround(eye_dx) - 5, ey + 3, led); px(ex - iround(eye_dx) - 4, ey + 3, led);
            px(ex + iround(eye_dx) + 4, ey + 3, led); px(ex + iround(eye_dx) + 5, ey + 3, led);
            break;
        }
        case MUSE_CHARACTER_CHICK: {
            static const char *const TUFT[] = { "#..#..#", "#f.#f.#", ".#ffff#.", "..#ff#..", "...##..." };
            int hop = (perk > 0.5f && beat) ? 1 : 0;
            stamp3_ex(TUFT, 5, 8, cxi - 4, ty - 5 - hop, false, sway * 0.8f, C_OUT, C_BEAK, C_BEAK);
            bool open = mode == MUSE_MODE_SPEAKING && beat;
            static const char *const BEAK[] = { "#####", ".#f#.", "..#.." };
            static const char *const BEAK_OPEN[] = { "#####", "#fff#", "#...#", ".###." };
            if (open) { stamp3_ex(BEAK_OPEN, 4, 5, ex - 2, ey + 2, false, 0, C_OUT, C_BEAK, C_BEAK); }
            else { stamp3_ex(BEAK, 3, 5, ex - 2, ey + 2, false, 0, C_OUT, C_BEAK, C_BEAK); }
            /* little wings */
            static const char *const WING[] = { ".##", "#ff", "#ff", ".##" };
            int flap = (mode == MUSE_MODE_SPEAKING || perk > 0.5f) && beat ? 2 : 0;
            stamp3_ex(WING, 4, 3, cxi - 21, fyi + 3 - flap, false, 0, C_OUT, C_BEAK, C_BEAK);
            stamp3_ex(WING, 4, 3, cxi + 18, fyi + 3 - flap, true, 0, C_OUT, C_BEAK, C_BEAK);
            break;
        }
        default: break;
        }
    }

    if (p->companion.accessory == MUSE_ACCESSORY_BOW) {
        static const char *const BOW[] = { "##...##", "###.###", ".#####.", "###.###", "##...##" };
        stamp(BOW, 5, iround(j.cx + 7), iround(j.cy - j.b + 4), C_HEART, C_WHITE);
    } else if (p->companion.accessory == MUSE_ACCESSORY_SCARF) {
        static const char *const SCARF[] = { "###############", "###############", "....###........", "....###........", "....###........" };
        stamp(SCARF, 5, iround(j.cx) - 7, iround(j.fy + j.fb + 2), C_ACC, C_WHITE);
    } else if (p->companion.accessory == MUSE_ACCESSORY_CROWN) {
        static const char *const CROWN[] = { "#...#...#", "##.###.##", "#########", "#########" };
        stamp(CROWN, 4, iround(j.cx) - 4, iround(j.cy - j.b), C_ACC, C_WHITE);
    } else if (p->companion.accessory == MUSE_ACCESSORY_GLASSES) {
        /* Round frames centred on each eye, joined by a bridge. */
        static const char *const LENS[] = { ".#####.", "#.....#", "#.....#", "#.....#", ".#####." };
        int ly = iround(eye_y) - 2;
        stamp(LENS, 5, iround(j.fx - eye_dx) - 3, ly, C_OUT, C_OUT);
        stamp(LENS, 5, iround(j.fx + eye_dx) - 3, ly, C_OUT, C_OUT);
        px(iround(j.fx), ly + 2, C_OUT);
    } else if (p->companion.accessory == MUSE_ACCESSORY_HAT) {
        static const char *const HAT[] = { "..#####..", ".#fffff#.", ".#iiiii#.", ".#fffff#.", "#########" };
        stamp3(HAT, 5, iround(j.cx) - 4, iround(j.cy - j.b) - 4, C_OUT, C_ACC, C_HEART);
    } else if (p->companion.accessory == MUSE_ACCESSORY_STAR) {
        static const char *const STAR[] = { "..#..", "..#..", "#####", ".###.", "##.##" };
        stamp(STAR, 5, iround(j.cx + 8), iround(j.cy - j.b) + 1, C_ACC, C_WHITE);
    } else if (p->companion.accessory == MUSE_ACCESSORY_FLOWER) {
        static const char *const FLOWER[] = { ".#.#.", "#####", "##o##", "#####", ".#.#." };
        stamp(FLOWER, 5, iround(j.cx - 11), iround(j.cy - j.b) + 3, C_HEART, C_WHITE);
    } else if (p->companion.accessory == MUSE_ACCESSORY_HEADPHONES) {
        static const char *const BAND[] = { "..#########..", ".#.........#.", "#...........#" };
        stamp(BAND, 3, iround(j.cx) - 6, iround(j.cy - j.b) - 2, C_OUT, C_OUT);
        static const char *const CUP[] = { ".###.", "#iii#", "#iii#", "#iii#", ".###." };
        stamp3(CUP, 5, iround(j.cx) - 19, iround(j.fy) - 3, C_OUT, C_ACC, C_ACC);
        stamp3(CUP, 5, iround(j.cx) + 15, iround(j.fy) - 3, C_OUT, C_ACC, C_ACC);
    } else if (p->companion.accessory == MUSE_ACCESSORY_BOWTIE) {
        static const char *const TIE[] = { "##...##", "#f#.#f#", "#ff#ff#", "#f#.#f#", "##...##" };
        stamp3(TIE, 5, iround(j.cx) - 3, iround(j.fy + j.fb) + 2, C_OUT, C_HEART, C_HEART);
    } else if (p->companion.accessory == MUSE_ACCESSORY_SHADES) {
        static const char *const LENS[] = { "#######", "#######", "#######", ".#####." };
        int ly = iround(eye_y) - 2;
        stamp(LENS, 4, iround(j.fx - eye_dx) - 3, ly, C_OUT, C_OUT);
        stamp(LENS, 4, iround(j.fx + eye_dx) - 3, ly, C_OUT, C_OUT);
        for (int x = iround(j.fx - eye_dx) + 4; x < iround(j.fx + eye_dx) - 3; x++) { px(x, ly, C_OUT); }
    } else if (p->companion.accessory == MUSE_ACCESSORY_PARTY) {
        static const char *const PARTY[] = { "..i..", "..#..", ".###.", ".#f#.", "#####" };
        stamp3(PARTY, 5, iround(j.cx) - 2, iround(j.cy - j.b) - 5, C_OUT, C_HEART, C_ACC);
    } else if (p->companion.accessory == MUSE_ACCESSORY_SPROUT) {
        static const char *const LEAF[] = { ".##..##.", "#ff##ff#", "#ffffff#", ".#.##.#.", "...##..." };
        stamp3(LEAF, 5, iround(j.cx) - 4, iround(j.cy - j.b) - 3, C_OUT, C_LEAF, C_LEAF);
    } else if (p->companion.accessory == MUSE_ACCESSORY_HALO) {
        static const char *const HALO[] = { ".#####.", "#.....#", ".#####." };
        stamp(HALO, 3, iround(j.cx) - 3, iround(j.cy - j.b) - 5, C_GOLD, C_GOLD);
    }

    if (p->activity.type == MUSE_ACTIVITY_GAME) {
        draw_sparkle(iround(j.cx), iround(p->activity.target == MUSE_TOUCH_HEAD ? j.cy - j.b + 5 : j.cy + 8), 1, true);
    }
    /* ---- foreground ---- */
    draw_sparkles(p, j.cx, j.cy, true, spk_speed, spk_count);

    float top = j.cy - j.b;
    if (emotion == MUSE_EMOTION_DIZZY) {
        /* Stars orbit the head, slowing as the dizziness wears off. */
        float fade = clampf((5.0f - et) / 2.5f, 0.0f, 1.0f);
        static const char *const STAR[] = { ".#.", "###", ".#." };
        for (int k = 0; k < 3; k++) {
            float a = t * (2.0f + 3.0f * fade) + k * 2.094f;
            if (fade <= 0 && k == 2) { continue; }
            stamp(STAR, 3, iround(j.cx + cosf(a) * 13.0f) - 1, iround(top + 1 + sinf(a) * 3.0f) - 1, C_GOLD, C_GOLD);
        }
    }
    if (emotion == MUSE_EMOTION_ANGRY) {
        /* A throbbing anger mark and puffs of steam. */
        if (((int)(t * 4)) & 1) {
            static const char *const VEIN[] = { "#.#", ".#.", "#.#" };
            (void)VEIN;
            static const char *const MARK[] = { "##.##", "#...#", ".....", "#...#", "##.##" };
            stamp(MARK, 5, iround(j.cx + j.a * 0.55f), iround(top) - 2, C_HEART, C_HEART);
        }
        for (int k = 0; k < 2; k++) {
            float age = fmodf(t * 1.4f + k * 0.5f, 1.0f);
            int sx = iround(j.cx + (k ? 1 : -1) * (j.a * 0.8f + age * 3.0f)), sy = iround(top + 6 - age * 12.0f);
            px(sx, sy, C_WHITE); px(sx + 1, sy, C_WHITE); px(sx, sy + 1, C_WHITE);
            if (age < 0.6f) { px(sx + 1, sy + 1, C_WHITE); }
        }
    }
    if (emotion == MUSE_EMOTION_ANNOYED) {
        /* A single sweat drop of impatience. */
        int dy = (int)(fmodf(t * 3.0f, 3.0f));
        px(iround(j.cx + j.a * 0.7f), iround(top + 5) + dy, C_SHINE);
        px(iround(j.cx + j.a * 0.7f), iround(top + 6) + dy, C_SHINE);
    }
    if (mode == MUSE_MODE_LISTENING || mode == MUSE_MODE_SPEAKING) {
        draw_waves(j.cx, j.fy + 2, j.a, level, t);
    }
    if (mode == MUSE_MODE_THINKING) {
        draw_thought_dots(j.cx + 14, top + 2, t);
    }
    if (emotion == MUSE_EMOTION_COMFORT && et > 2) {
        draw_hearts(j.cx, j.fy + 8, t * 0.22f, 0.65f);
    }
    if (emotion == MUSE_EMOTION_LAUGH && et < 5) {
        draw_sparkle(iround(j.cx - 21), iround(j.fy + 1), 0.8f, true);
        draw_sparkle(iround(j.cx + 21), iround(j.fy - 3), 0.8f, true);
    }
    if (affection > 0) {
        /* Heart held between the paws, with a soft heartbeat. */
        static const char *const HEART[] = { ".##.##.", "#######", "#######", ".#####.", "..###..", "...#..." };
        int heart_y = iround(j.fy + 9 + sinf(t * 4) * 0.5f);
        stamp(HEART, 6, iround(j.cx) - 3, heart_y, C_HEART, C_WHITE);
        draw_hearts(j.cx, top + 4, t * 0.55f, affection);
        draw_hearts(j.cx, j.fy + 10, t * 0.4f + 0.7f, affection);
    }
    if (emotion == MUSE_EMOTION_SLEEPY) {
        static const char *const Z[] = { "###", "..#", ".#.", "###" };
        stamp(Z, 4, iround(j.cx + 15), iround(top + 2 - fracf(t * 0.3f) * 6), C_SHINE, C_SHINE);
    }
    if (emotion == MUSE_EMOTION_PROUD) { draw_sparkle(iround(j.cx + 19), iround(j.fy - 5), 1, true); }
    if (emotion == MUSE_EMOTION_WORRIED) { px(br + 5, by + 3, C_SHINE); px(br + 5, by + 4, C_SHINE); }
    if (happy > 0) {
        draw_hearts(j.cx, top + 1, t, happy);
    }
    if (mode == MUSE_MODE_ERROR) {
        draw_alert(iround(j.cx + 18), iround(top - 1));
    }

}
