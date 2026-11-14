// Temperature / humidity dashboard on ST7789 135x240
// Choose ONE sensor:
#define USE_BME280   // I2C: SDA=21, SCL=22 (also reports pressure)
//#define USE_DHT22  // data pin = 27

#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>

#ifdef USE_BME280
  #include <Wire.h>
  #include <Adafruit_BME280.h>
  Adafruit_BME280 bme;
#else
  #include <DHT.h>
  #define DHT_PIN 27
  DHT dht(DHT_PIN, DHT22);
#endif

#define TFT_CS 15
#define TFT_DC 2
#define TFT_RST 4
#define TFT_SCK 18
#define TFT_MOSI 23

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

void message(const char* m, uint16_t c) {
  tft.fillScreen(ST77XX_BLACK);
  tft.setTextColor(c);
  tft.setTextSize(2);
  tft.setCursor(10, 55);
  tft.print(m);
}

void setup() {
  Serial.begin(115200);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, TFT_CS);
  tft.init(135, 240);
  tft.setRotation(1);
#ifdef USE_BME280
  Wire.begin(21, 22);
  if (!bme.begin(0x76) && !bme.begin(0x77)) { message("No BME280!", ST77XX_RED); while (true) delay(1000); }
#else
  dht.begin();
#endif
  tft.fillScreen(ST77XX_BLACK);
}

void loop() {
  float t, h, p = NAN;
#ifdef USE_BME280
  t = bme.readTemperature();
  h = bme.readHumidity();
  p = bme.readPressure() / 100.0F;
#else
  t = dht.readTemperature();
  h = dht.readHumidity();
#endif
  tft.fillRect(0, 0, 240, 135, ST77XX_BLACK);
  if (isnan(t) || isnan(h)) {
    message("Sensor error", ST77XX_RED);
  } else {
    tft.setTextSize(2);
    tft.setTextColor(ST77XX_WHITE);
    tft.setCursor(10, 8);
    tft.print("Temperature");
    tft.setTextSize(4);
    tft.setTextColor(ST77XX_ORANGE);
    tft.setCursor(10, 30);
    tft.printf("%.1f C", t);
    tft.setTextSize(2);
    tft.setTextColor(ST77XX_WHITE);
    tft.setCursor(10, 75);
    tft.print("Humidity");
    tft.setTextSize(3);
    tft.setTextColor(ST77XX_CYAN);
    tft.setCursor(10, 95);
    tft.printf("%.0f %%", h);
    if (!isnan(p)) {
      tft.setTextSize(2);
      tft.setTextColor(ST77XX_GREEN);
      tft.setCursor(135, 100);
      tft.printf("%.0fhPa", p);
    }
  }
  delay(2000);
}
