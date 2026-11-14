// 1.8" TFT (ST7735) test using SOFTWARE SPI (bit-banged) - rules out hardware-SPI problems
// Wiring (same pins as the other projects):
//   Display GND -> GND      Display VCC -> 3V3
//   Display SCK/SCL -> GPIO18   Display SDA/MOSI -> GPIO23
//   Display RES/RESET -> GPIO4  Display A0/DC -> GPIO2
//   Display CS -> GPIO15        Display LED/BLK -> 3V3
//
// Different 1.8" modules need different init "tabs". This sketch cycles through
// BLACK, GREEN and RED tab every ~6 s and labels each one on screen.
// Note which label shows correct colors with no shifted/noisy edge,
// then set TAB_FIXED to that one (0=BLACK, 1=GREEN, 2=RED) to stop cycling.
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <SPI.h>

#define TFT_CS   15
#define TFT_DC   2
#define TFT_RST  4
#define TFT_SCK  18
#define TFT_MOSI 23

#define TAB_FIXED -1   // -1 = cycle through all tabs

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_MOSI, TFT_SCK, TFT_RST);  // software SPI

const uint8_t tabs[]      = {INITR_BLACKTAB, INITR_GREENTAB, INITR_REDTAB};
const char*   tabNames[]  = {"BLACKTAB", "GREENTAB", "REDTAB"};

void runTest(int idx) {
  Serial.printf("Init with %s\n", tabNames[idx]);
  tft.initR(tabs[idx]);
  tft.setRotation(1);               // landscape 160x128
  const uint16_t cols[] = {ST77XX_RED, ST77XX_GREEN, ST77XX_BLUE, ST77XX_WHITE, ST77XX_BLACK};
  for (uint16_t c : cols) { tft.fillScreen(c); delay(500); }

  tft.fillScreen(ST77XX_BLACK);
  tft.drawRect(0, 0, tft.width(), tft.height(), ST77XX_WHITE);   // edge check
  tft.setTextColor(ST77XX_YELLOW);
  tft.setTextSize(2);
  tft.setCursor(8, 10);  tft.println("Display OK!");
  tft.setTextColor(ST77XX_CYAN);
  tft.setTextSize(1);
  tft.setCursor(8, 40);  tft.print("Init: "); tft.println(tabNames[idx]);
  tft.setCursor(8, 55);  tft.print("Size: "); tft.print(tft.width()); tft.print("x"); tft.println(tft.height());
  // color bars
  const uint16_t bars[] = {ST77XX_RED, ST77XX_GREEN, ST77XX_BLUE, ST77XX_MAGENTA, ST77XX_YELLOW};
  for (int i = 0; i < 5; i++) tft.fillRect(8 + i * 28, 80, 24, 30, bars[i]);
  delay(3000);
}

void setup() {
  Serial.begin(115200);
  Serial.println("1.8\" TFT test start");
}

void loop() {
  if (TAB_FIXED >= 0) runTest(TAB_FIXED);
  else for (int i = 0; i < 3; i++) runTest(i);
}
