// Wi-Fi clock + weather (Open-Meteo, no API key) on ST7789 135x240
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
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

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

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
}

void drawWeather() {
  tft.fillRect(0, 70, 240, 65, ST77XX_BLACK);
  tft.setTextSize(3);
  tft.setTextColor(ST77XX_YELLOW);
  tft.setCursor(10, 75);
  if (isnan(temp)) tft.print("--");
  else tft.printf("%.1f C", temp);
  tft.setTextSize(2);
  tft.setTextColor(ST77XX_CYAN);
  tft.setCursor(10, 110);
  if (wcode >= 0) tft.printf("%s  %.0f km/h", codeText(wcode), wind);
}

void setup() {
  Serial.begin(115200);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, TFT_CS);
  tft.init(135, 240);
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
      tft.fillRect(0, 0, 240, 70, ST77XX_BLACK);
      tft.setTextColor(ST77XX_GREEN);
      tft.setTextSize(4);
      tft.setCursor(10, 8);
      tft.print(buf);
      char d[24];
      strftime(d, sizeof d, "%a %d %b %Y", &ti);
      tft.setTextSize(2);
      tft.setTextColor(ST77XX_WHITE);
      tft.setCursor(10, 48);
      tft.print(d);
    }
  }
  if (lastWeather == 0 || millis() - lastWeather > 600000UL) {
    if (fetchWeather()) { lastWeather = millis(); drawWeather(); }
    else lastWeather = millis() - 590000UL;  // retry in 10 s
  }
  delay(200);
}
