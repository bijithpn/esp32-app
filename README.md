# ESP32 + ST7789 (135x240) display projects

Each folder is a separate "mode". Flash one at a time; flashing a new one replaces the previous one on the board.

## Display wiring (all modes)

| Display | ESP32 |
|---|---|
| GND | GND |
| VCC | 3V3 |
| SCL | GPIO18 |
| SDA | GPIO23 |
| RES | GPIO4 |
| DC  | GPIO2 |
| CS  | GPIO15 |
| BLK | 3V3 |

Display: 1.14" IPS, ST7789 driver, 135x240, 4-wire SPI. Code uses landscape (rotation 1, 240x135).

## Modes

| Folder | What it does | Needs |
|---|---|---|
| `display_test` | Cycles red/green/blue/white/black, then shows "Display OK!". Use it to check the wiring. | Nothing |
| `name_show` | Animated "AFSAL" slideshow (5 scenes, see below). | Nothing |
| `weather_clock` | NTP clock + date, plus temperature, conditions and wind from Open-Meteo (refreshes every 10 min). | Wi-Fi (2.4 GHz) |
| `sensor_dashboard` | Temperature, humidity (and pressure with BME280). | BME280 or DHT22 sensor |

### display_test
Quick sanity check of the screen and wiring.

### name_show
Loops through five scenes:
1. **Typewriter** - letters appear one by one in different colors, with a blinking cursor.
2. **Fly-in** - letters slide in from top and bottom alternately and settle.
3. **Rainbow wave** - letters bob while colors cycle; an underline sweeps across.
4. **Neon** - cyan glow with a bright core, inside two pulsing borders.
5. **Ripples** - colored rings expand behind white text with a soft shadow.

Change the name: edit `NAME` and `NLEN` in `name_show/name_show.ino`. At `TSIZE 7` about 5 letters fit; lower `TSIZE` for longer names. Speed is controlled by the `delay(25)` values in each scene.

### weather_clock
Copy `weather_clock/secrets.h.example` to `weather_clock/secrets.h` and fill in:
- `WIFI_SSID`, `WIFI_PASS` (2.4 GHz network only)
- `LATITUDE`, `LONGITUDE` (default is Kochi)
- `GMT_OFFSET_SEC` (default 19800 = IST, UTC+5:30)

Screen shows "WiFi..." while connecting, or "WiFi failed" if it cannot connect.

### sensor_dashboard
Choose the sensor at the top of `sensor_dashboard/sensor_dashboard.ino`:
- `#define USE_BME280` - I2C: VCC=3V3, GND=GND, SDA=GPIO21, SCL=GPIO22 (address 0x76 or 0x77)
- `#define USE_DHT22` - data pin = GPIO27

Shows "No BME280!" if the sensor is not found, and "Sensor error" if a reading fails.

## Setup (once)

    # install arduino-cli (https://arduino.github.io/arduino-cli/), then:
    export PATH=$HOME/.local/bin:$PATH
    arduino-cli core update-index
    arduino-cli core install esp32:esp32
    arduino-cli lib install "Adafruit GFX Library" "Adafruit ST7735 and ST7789 Library" "Adafruit BusIO" \
        ArduinoJson "Adafruit BME280 Library" "Adafruit Unified Sensor" "DHT sensor library"

## Build and flash a mode

    export PATH=$HOME/.local/bin:$PATH
    cd ~/develop/esp32-display-projects
    arduino-cli compile --fqbn esp32:esp32:esp32 <mode>
    arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32 <mode>

Replace `<mode>` with `display_test`, `name_show`, `weather_clock` or `sensor_dashboard`.
Upload does not recompile, so run compile after every code change.

## Troubleshooting

- **Serial monitor:** `arduino-cli monitor -p /dev/ttyUSB0 -c baudrate=115200`
- **Upload stuck on "Connecting......":** hold the BOOT button until writing starts.
- **No `/dev/ttyUSB0`:** re-plug the board or try another data-capable USB cable (`ls /dev/ttyUSB*`).
- **Blank screen:** recheck SCL, SDA, DC, CS, RES wires and that BLK is on 3V3.

## 1.8" TFT variant (ST7735, 128x160, module "SPI 128x160 V1.1")

Same pins as above (CS=15, DC/A0=2, RST=4, SCK=18, SDA/MOSI=23, LED=3V3). Use these folders with the 1.8" display instead of the ST7789 ones:

| Folder | Replaces |
|---|---|
| `tft18_test` | `display_test` (cycles init variants BLACK/GREEN/RED tab and labels each) |
| `tft18_swspi` | Fallback: same test with software SPI, slow but independent of the SPI peripheral |
| `name_show_18` | `name_show` |
| `weather_clock_18` | `weather_clock` (needs its own `secrets.h`, copied from the original) |
| `sensor_dashboard_18` | `sensor_dashboard` |

Notes:
- If colors are wrong or an edge looks shifted, change `#define TAB` (`INITR_BLACKTAB`, `INITR_GREENTAB`, `INITR_REDTAB`).
- The sketches call `SPI.begin(18, -1, 23, -1)`: CS must NOT be passed to the SPI peripheral, otherwise it fights the display library over GPIO15 and the screen stays white.

## ESP32 Hub (multi-scene firmware + Flutter app)

See [`esp32_hub/README.md`](esp32_hub/README.md) for the complete setup of the firmware (many animated scenes, browser UI,
OTA) and the Android app that controls it over Wi-Fi.
