// ST7789 1.14" 135x240 IPS display test for ESP32 (uses Adafruit_ST7789 + Adafruit_GFX)
// Wiring (change if yours differs):
//   Display GND -> GND      Display VCC -> 3V3
//   Display SCL -> GPIO18   (SPI clock)
//   Display SDA -> GPIO23   (SPI MOSI)
//   Display RES -> GPIO4
//   Display DC  -> GPIO2
//   Display CS  -> GPIO15
//   Display BLK -> 3V3
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>

#define TFT_CS   15
#define TFT_DC   2
#define TFT_RST  4
#define TFT_SCK  18
#define TFT_MOSI 23

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

void setup() {
  Serial.begin(115200);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, TFT_CS);
  tft.init(135, 240, SPI_MODE3);
  tft.setSPISpeed(10000000);
  tft.setRotation(1);  // landscape 240x135
  Serial.println("Display init done");
}

void loop() {
  const uint16_t colors[] = {ST77XX_RED, ST77XX_GREEN, ST77XX_BLUE, ST77XX_WHITE, ST77XX_BLACK};
  for (uint16_t c : colors) {
    tft.fillScreen(c);
    delay(700);
  }
  tft.fillScreen(ST77XX_BLACK);
  tft.setTextColor(ST77XX_YELLOW);
  tft.setTextSize(3);
  tft.setCursor(10, 20);
  tft.println("Display OK!");
  tft.setTextColor(ST77XX_CYAN);
  tft.setTextSize(2);
  tft.setCursor(10, 70);
  tft.println("ESP32 + ST7789");
  delay(3000);
}
