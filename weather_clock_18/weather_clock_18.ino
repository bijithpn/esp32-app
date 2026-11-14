// Wi-Fi clock + weather (Open-Meteo, no API key) on 1.8" ST7735 128x160 (landscape 160x128)
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <SPI.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <time.h>
#include "secrets.h"

#define TFT_CS 15
#define TFT_DC 2
#define TFT_RST 4
#define TFT_SCK 18
#define TFT_MOSI 23
#define TAB INITR_BLACKTAB      // try INITR_GREENTAB / INITR_REDTAB if colors/edges look wrong
#define W 160
#define H 128

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_RST);

float temp = NAN, wind = NAN;
int wcode = -1;
unsigned long lastWeather = 0;
char lastTime[16] = "";

const char* codeText(int c) {
  if (c == 0) return "Clear";
  if (c <= 3) return "Cloudy";
  if (c <= 48) return "Fog";
  if (c <= 57) return "Drizzle";
  if (c <= 67) return "Rain";
  if (c <= 77) return "Snow";
  if (c <= 82) return "Showers";
  return "Storm";
}

void status(const char* msg) {
  tft.fillScreen(ST77XX_BLACK);
  tft.setTextColor(ST77XX_WHITE);
  tft.setTextSize(2);
  tft.setCursor(10, 55);
  tft.print(msg);
}

bool fetchWeather() {
  HTTPClient http;
  String url = String("https://api.open-meteo.com/v1/forecast?latitude=") + LATITUDE +
               "&longitude=" + LONGITUDE + "&current=temperature_2m,weather_code,wind_speed_10m";
  http.begin(url);
  int code = http.GET();
  if (code != 200) { http.end(); return false; }
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, http.getString());
  http.end();
  if (err) return false;
  temp = doc["current"]["temperature_2m"];
  wind = doc["current"]["wind_speed_10m"];
  wcode = doc["current"]["weather_code"];
  return true;
}

void drawStatic() {
  tft.fillScreen(ST77XX_BLACK);
  tft.drawFastHLine(0, 58, W, ST77XX_BLUE);   // divider between clock and weather
}

void drawWeather() {
  tft.fillRect(0, 60, W, H - 60, ST77XX_BLACK);
  tft.setTextSize(3);
  tft.setTextColor(ST77XX_YELLOW);
  tft.setCursor(8, 66);
  if (isnan(temp)) tft.print("--");
  else tft.printf("%.1f C", temp);
  tft.setTextSize(2);
  tft.setTextColor(ST77XX_CYAN);
  tft.setCursor(8, 96);
  if (wcode >= 0) tft.print(codeText(wcode));
  tft.setTextSize(1);
  tft.setCursor(8, 116);
  if (wcode >= 0) tft.printf("Wind %.0f km/h", wind);
}

void setup() {
  Serial.begin(115200);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, -1);   // CS is driven by the display library, not the SPI peripheral
  tft.initR(TAB);
  tft.setRotation(1);
  status("WiFi...");
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) delay(300);
  if (WiFi.status() != WL_CONNECTED) { status("WiFi failed"); return; }
  configTime(GMT_OFFSET_SEC, 0, "pool.ntp.org", "time.google.com");
  drawStatic();
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) { delay(1000); return; }
  struct tm ti;
  if (getLocalTime(&ti, 100)) {
    char buf[16];
    strftime(buf, sizeof buf, "%H:%M:%S", &ti);
    if (strcmp(buf, lastTime) != 0) {
      strcpy(lastTime, buf);
      tft.fillRect(0, 0, W, 58, ST77XX_BLACK);
      tft.setTextColor(ST77XX_GREEN);
      tft.setTextSize(3);                 // 8 chars x 18 px = 144 px
      tft.setCursor(8, 8);
      tft.print(buf);
      char d[24];
      strftime(d, sizeof d, "%a %d %b", &ti);   // 10 chars x 12 px = 120 px
      tft.setTextSize(2);
      tft.setTextColor(ST77XX_WHITE);
      tft.setCursor(8, 38);
      tft.print(d);
    }
  }
  if (lastWeather == 0 || millis() - lastWeather > 600000UL) {
    if (fetchWeather()) { lastWeather = millis(); drawWeather(); }
    else lastWeather = millis() - 590000UL;  // retry in 10 s
  }
  delay(200);
}
