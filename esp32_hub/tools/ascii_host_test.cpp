// Host test for firmware/hub/ascii_engine.h: runs every animal, checks nothing goes wrong and prints a frame.
// g++ -std=c++17 -O1 -Wall -I../firmware/hub ascii_host_test.cpp -o /tmp/ascii_host_test && /tmp/ascii_host_test [animal] [seconds]
#include <cstdio>
#include <cstdlib>
#include "ascii_engine.h"
using namespace asc;

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

static void dump() {
  printf("+"); for (int i = 0; i < ACOLS; i++) printf("-"); printf("+\n");
  for (int r = 0; r < AROWS; r++) {
    printf("|");
    for (int c = 0; c < ACOLS; c++) { int i = r * ACOLS + c; putchar(cFlag[i] ? cGlyph[i] : (cTrail[i] ? '\'' : ' ')); }
    printf("|\n");
  }
}

int main(int argc, char** argv) {
  int only = argc > 1 ? atoi(argv[1]) : -1;
  float secs = argc > 2 ? atof(argv[2]) : 10;
  for (int a = 0; a < NANIMALS; a++) {
    if (only >= 0 && a != only) continue;
    setAnimal(a);
    long cellsSum = 0; int frames = 0, minCells = 99999;
    for (float t = 0; t < secs; t += 0.04f) {
      if (t > 3 && t < 3.05f) startle(80, 64);
      step(0.04f); render(0.04f);
      int n = 0; for (int i = 0; i < ANC; i++) if (cFlag[i]) n++;
      cellsSum += n; frames++; if (t > 2 && n < minCells) minCells = n;
      for (int k = 0; k < ncr; k++) {
        CHECK(isfinite(cr[k].x) && isfinite(cr[k].y) && isfinite(cr[k].heading), "%s: creature %d went NaN at t=%.2f", ANIMALS[a].id, k, t);
        CHECK(fabsf(cr[k].x) < 2000 && fabsf(cr[k].y) < 2000, "%s: creature %d flew off to %.0f,%.0f", ANIMALS[a].id, k, cr[k].x, cr[k].y);
      }
    }
    printf("== %s: %d creatures, avg %ld cells, min %d cells\n", ANIMALS[a].id, ncr, cellsSum / frames, minCells);
    CHECK(cellsSum / frames > 8, "%s: nearly nothing is drawn", ANIMALS[a].id);
    CHECK(ncr == targetCount(), "%s: wrong creature count", ANIMALS[a].id);
    if (only >= 0) dump();
  }
  // every tuning extreme must stay finite
  for (int a = 0; a < NANIMALS; a++) {
    setAnimal(a); const Animal& A = ANIMALS[a];
    T.density = 4; T.speed = 3; T.size = 2.5f; T.hue = 180; T.corner = false; T.direction = 200; restyle();
    for (int k = 0; k < 3; k++) T.k[k] = A.kmax[k];
    for (int i = 0; i < 400; i++) { if (i == 100) startle(20, 20); step(0.04f); render(0.04f); }
    for (int k = 0; k < ncr; k++) CHECK(isfinite(cr[k].x) && isfinite(cr[k].y), "%s max: NaN", A.id);
    T.density = 0.1f; T.speed = 0.1f; T.size = 0.3f; for (int k = 0; k < 3; k++) T.k[k] = A.kmin[k];
    for (int i = 0; i < 400; i++) { step(0.04f); render(0.04f); }
    for (int k = 0; k < ncr; k++) CHECK(isfinite(cr[k].x) && isfinite(cr[k].y), "%s min: NaN", A.id);
  }
  printf(fails ? "%d FAILURES\n" : "all ok\n", fails);
  return fails ? 1 : 0;
}
