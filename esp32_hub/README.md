# ESP32 Hub

An ESP32 with a 1.8" colour TFT that runs many animated "scenes". Control it from an Android app (Flutter)
or any browser over Wi-Fi, from anywhere through MQTT, or set it up over Bluetooth.

```
esp32_hub/
├── firmware/hub/        ESP32 firmware (Arduino sketch)
│   ├── hub.ino            Wi-Fi, HTTP API, security token, OTA, scene manager, command runner
│   ├── remote.h           MQTT client + Bluetooth (BLE) Wi-Fi setup
│   ├── face.h             expressive face engine: 12 moods, robot eyes scene, talking AI buddy
│   ├── cards.h            notification + message cards, status/setup screen (Wi-Fi QR), boot screen
│   ├── music.h            now playing (generated album art, spinning record, equaliser)
│   ├── scenes.h           bounce, matrix, stars, plasma, clock, name
│   ├── scenes2.h          life, mandelbrot, pet, weather, pomodoro, ping, canvas, animation, buddy, bars, now playing, pair QR
│   ├── webpage.h          built-in browser UI
│   └── qrcode_lib.*       small vendored QR library (MIT)
├── app/                 Flutter Android app
│   ├── lib/main.dart      auto-connect start screen, Wi-Fi setup, home
│   ├── lib/theme.dart     design system + on-screen previews (face, notification, music, weather)
│   ├── lib/discovery.dart finds the board on the network (no IP typing)
│   ├── lib/phone.dart     permissions screen (notifications, music, location) + phone sync
│   ├── lib/api.dart       HTTP and MQTT connections
│   ├── lib/features.dart  pomodoro, pet, weather, AI buddy, canvas (draw/photo/animation), music
│   ├── lib/settings.dart  security, remote access, phone sync, QR scanner, Bluetooth setup
│   ├── lib/fft.dart       microphone spectrum
│   └── android/.../*.kt   notification mirror + now playing (native Android)
├── tools/hubtest.py     test every scene and command over HTTP
├── tools/mqtt_test.py   test MQTT end to end (runs its own tiny broker)
└── PLAN.md              roadmap
```

---

## 1. Hardware

| Display pin (1.8" ST7735S, "SPI 128x160 V1.1") | ESP32 pin |
|---|---|
| VCC | 3V3 |
| GND | GND |
| CS | GPIO15 |
| RESET / RST | GPIO4 |
| A0 / DC | GPIO2 |
| SDA / MOSI | GPIO23 |
| SCK | GPIO18 |
| LED / BLK | 3V3 |

Pin order along the module edge is usually `LED SCK SDA A0 RESET CS GND VCC`. Always check the printed labels.
Use a **data** micro-USB cable (charge-only cables cannot flash the board).

---

## 2. ESP32 firmware

### 2.1 Install the tools (once)

```bash
arduino-cli core update-index
arduino-cli core install esp32:esp32            # tested with 3.3.12
arduino-cli lib install "Adafruit GFX Library" "Adafruit ST7735 and ST7789 Library" "Adafruit BusIO" \
                        ArduinoJson PubSubClient NimBLE-Arduino
```
(The QR code library is already inside the sketch folder.)

### 2.2 Compile and flash

```bash
cd esp32_hub/firmware
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=min_spiffs hub
arduino-cli upload  -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32:PartitionScheme=min_spiffs hub
```
**Keep `PartitionScheme=min_spiffs`**: the default partition is too small and has no room for over-the-air updates.
Flash use is about 75% of the 1.9 MB slot.
If the port is not accessible: `sudo usermod -aG dialout $USER` and log in again. `./check_esp32.sh` (repository root) shows whether the board is detected.

> **0.4.1:** the app now tells you whether the board joined your Wi-Fi (wrong password / network not found), the board
> keeps Bluetooth on whenever its saved Wi-Fi can't be joined, and the Wi-Fi scan no longer gets stuck on an empty list.
> New endpoint: `GET /api/wifi/status`. Reflash the board to get these.

### 2.3 First boot: give it Wi-Fi

A board with no Wi-Fi saved starts **setup mode**: the screen shows `SETUP MODE`, it creates its own hotspot
**`ESP32-Hub`** (password **`hub12345`**) and also advertises over Bluetooth. Pick one:

- **Bluetooth (app):** Connect screen > *New board? Set up Wi-Fi with Bluetooth*.
- **Hotspot + browser:** join `ESP32-Hub`, open **`http://192.168.4.1`** (type the full `http://`), choose your network (2.4 GHz only), Save.
- **Hotspot + app:** join `ESP32-Hub`, enter `192.168.4.1` in the app, menu > Wi-Fi setup.

The board reboots, joins your Wi-Fi and shows its **IP address** for 6 seconds (see it again any time in the *Device Info* scene).
Then open `http://<ip>/` in a browser, or enter the IP in the app.

The browser page is a full controller: scene buttons, message box, auto-rotate, pairing QR, lock, firmware upload.

### 2.4 Security: lock, token, pairing

- By default **anyone on your Wi-Fi can control the board** (and update its firmware). Turn on the **lock** (app: Settings > Security > *Lock with token*,
  or the web page: *Lock with token*). It creates a 16-character **token**; from then on every command, Wi-Fi change and update needs the header `X-Hub-Token: <token>`.
- Setup mode (hotspot) is always open so you can recover a locked board: join the hotspot and use *Forget Wi-Fi*, or flash it over USB.
- The **Pair (QR)** scene shows a QR code with the device id, token and IP. The app's *Scan pairing QR* fills everything in. Whoever can see the screen can pair, so treat the screen like a key.
- Over MQTT and Bluetooth commands, the token is always required (MQTT) or required when locked (Bluetooth).
- The hotspot password and the OTA password are `hub12345`. Change `AP_PASS` in `hub.ino` for anything beyond a desk.

### 2.5 Remote access (MQTT)

The board connects **out** to an MQTT broker (no port forwarding needed). Enable it in the app: Settings > Remote access (broker host, port, optional user/password, TLS).
Topics (`<id>` is the device id from Settings):

| Topic | Direction | Content |
|---|---|---|
| `esp32hub/<id>/cmd` | board subscribes | JSON command with `"t":"<token>"` (same commands as HTTP `/api/cmd`) |
| `esp32hub/<id>/res` | board publishes | result of the last command |
| `esp32hub/<id>/list` | retained | device and scene list |
| `esp32hub/<id>/state` | retained, every 10 s | scene, heap, ip, rssi, uptime |
| `esp32hub/<id>/online` | retained | `1`, or `0` (last will) |

TLS is supported but the board does **not** verify the broker's certificate (it encrypts, it does not authenticate the server). Use your own broker with a username/password.
Not available in the app over MQTT: Wi-Fi setup, phone sync (it sends to the board directly over your local Wi-Fi).

### 2.6 Bluetooth, and why it is only for setup

Bluetooth takes about **70 KB of the board's 150 KB free RAM**. So the firmware keeps it only when needed: a board with no Wi-Fi saved
(first-time setup), or when you turn it on in Settings (the board reboots). In normal use it is off and the RAM goes to animations, weather and MQTT.
In setup mode with Bluetooth on, free RAM is about 30 KB, so image uploads do not work there. That is expected: set up the Wi-Fi first.

### 2.7 Over-the-air updates

The board must be on your Wi-Fi.
- **Browser:** build a `.bin` (`arduino-cli compile ... hub --output-dir out`), open `http://<ip>/`, *Firmware update*, choose `out/hub.ino.bin`. (Needs the token when locked; the page asks.)
- **Arduino CLI:** `arduino-cli upload -p <ip> --protocol network --upload-field password=hub12345 --fqbn esp32:esp32:esp32:PartitionScheme=min_spiffs hub`

### 2.8 Serial log

```bash
arduino-cli monitor -p /dev/ttyUSB0 -c baudrate=115200
```
Prints `[hub] fw ... id=... mode=... ip=... lock mqtt ble heap`, and every 15 s the scene and free memory. Weather fetches and MQTT connects are logged too.

### 2.9 Settings in the code

| Setting | Where |
|---|---|
| Wrong colours / shifted edge | `#define TAB` in `hub.ino`: `INITR_BLACKTAB` (default), `INITR_GREENTAB`, `INITR_REDTAB` |
| Hotspot name/password, OTA password | `AP_SSID`, `AP_PASS` in `hub.ino` |
| Time zone | app menu > Time zone, or `{"cmd":"tz","sec":19800}` (default India UTC+5:30) |
| Weather location | app > Weather, or `{"cmd":"loc","lat":..,"lon":..}` |

### 2.10 Scenes

| id | What it does | Needs |
|---|---|---|
| `eyes` | Robot eyes (blink, look around); moods normal/happy/sleepy/angry/sad | |
| `bounce` | Bouncing text logo with corner counter | |
| `matrix` `stars` `plasma` `life` `mandel` | Matrix rain, starfield, plasma, Game of Life, Mandelbrot zoom | |
| `clock` | Analog clock, smooth second hand | Wi-Fi (NTP) |
| `weather` | Temperature, humidity, wind, animated icon (Open-Meteo, no key) | Wi-Fi |
| `name` | Rainbow wave text | |
| `pet` | Pixel cat: feed, play, pat, sleep; gets hungry over time | |
| `pomo` | Pomodoro with progress ring | |
| `ping` | Latency graph to 1.1.1.1 | Wi-Fi |
| `buddy` | Talking face with paged text (AI Buddy) | |
| `bars` | 16-band spectrum (microphone / demo from the app) | |
| `nowplaying` | Title, artist, progress, equaliser | |
| `canvas` | Drawings and photos from the app | |
| `anim` | GIF / photo slideshow, up to 7 frames at 80x64, 256 colours, shown 2x. Erased when you switch scene (frees RAM) | |
| `pair` | Pairing QR code | |
| `message` | Pop-up text and **notification cards** (auto-return to the previous scene) | |
| `info` | Mode, Wi-Fi, IP, signal, free memory | |

### 2.11 HTTP API

Plain HTTP on port 80. POST bodies are JSON with `Content-Type: application/json`. When locked, add header `X-Hub-Token`.

| Method / path | Purpose |
|---|---|
| `GET /` | Browser UI |
| `GET /api/list` | Device id, firmware, IP, `lock`, `mqtt`, `ble`, and the scene list (always open) |
| `GET /api/status` | `heap`, `uptime`, `rssi`, `ssid`, `tz` |
| `GET /api/scan` | Wi-Fi networks seen (setup page) |
| `POST /api/wifi` | `{"ssid":"..","pass":".."}`, then reboots |
| `POST /api/cmd` | A command (below) |
| `POST /update?t=<token>` | Multipart firmware `.bin` |

Commands (all return `{"ok":true}` or `{"ok":false,"error":".."}`):

| `cmd` | Fields |
|---|---|
| `scene` | `id`, optional `args` (`{"mood":"happy"}`, `{"text":"Hi"}`) |
| `msg` | `text`, `ttl` seconds |
| `notify` | `app`, `title`, `text`, `ttl` (notification card) |
| `next`, `auto` | `auto` takes `sec` (0 = off) |
| `tz` / `loc` | `sec` / `lat`,`lon` |
| `pomo` | `action` show/start/pause/skip/reset, optional `work`, `brk` minutes |
| `pet` | `action` show/feed/play/pat/sleep/wake |
| `say` | `text` |
| `bands` | `v`: 16 numbers 0-255 |
| `nowplaying` | `title`, `artist`, `dur`, `pos` seconds, `playing`, optional `quiet` (update without switching scene) |
| `pixels` | `x`,`y`,`w`,`h`, `data` = base64 RGB565 little-endian (send 16-row strips) |
| `anim` | `action` clear / `frame` (`i`,`y`,`h`,`data` = base64 RGB332, 80 bytes per row, 32-row strips) / `play` (`delay` ms) |
| `clear` | clear the canvas |
| `lock` | `on` true/false, returns `token` when turning on |
| `token` | make a new token |
| `mqtt` | `on`, `host`, `port`, `user`, `pass`, `tls` |
| `ble` | `on` (board reboots) |
| `pair`, `forget`, `reboot` | |

```bash
curl -X POST http://<ip>/api/cmd -H 'Content-Type: application/json' -H 'X-Hub-Token: <token>' \
     -d '{"cmd":"scene","id":"eyes","args":{"mood":"happy"}}'
```

### 2.12 Tests

```bash
python3 tools/hubtest.py <board-ip>                       # every scene and command (no argument = 192.168.4.1 setup hotspot)
python3 tools/mqtt_test.py <board-ip> <this-computer-ip>  # MQTT end to end with a built-in broker
```
`hubtest.py` ends with `FAILED: none`. Lines marked `expect FAIL` are deliberate bad inputs. In setup mode with Bluetooth on it skips the image tests (too little RAM).

---

## 3. Flutter app (Android)

### 3.1 Requirements

- Flutter 3.50+ (`flutter doctor`: Android toolchain ticked), Android SDK, JDK 21
- An Android 8+ phone. Wi-Fi: on the same network as the board for local control.

Packages (already in `pubspec.yaml`): `http`, `shared_preferences`, `image_picker`, `record`, `mqtt_client`, `flutter_reactive_ble` (BSD licence),
`permission_handler`, `mobile_scanner`. (`flutter_blue_plus` was avoided on purpose: version 2 needs a paid licence for commercial use.)

### 3.2 Build and install

```bash
cd esp32_hub/app
flutter pub get
flutter run                          # phone on USB with USB debugging, or:
flutter build apk --release          # build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```
`--debug` also works. You can copy the APK to the phone and install it (allow "Install unknown apps").

> **The Android build is heavy**: it downloads Gradle and many dependencies and can use 3-4 GB of RAM. On a small PC close other apps, use
> `flutter build apk --no-daemon`, set `org.gradle.jvmargs=-Xmx1536m` in `android/gradle.properties`, or build on another computer.
> **If Gradle says "Unexpected lock protocol found in lock file"**, an interrupted build left a broken cache: stop daemons (`./gradlew --stop`) and delete the folder it names under `~/.gradle/caches`, or build with a fresh cache: `GRADLE_USER_HOME=/some/empty/dir flutter build apk`.
> The `build/` folder in this repository holds an **old** APK from an early version; build a new one.

### 3.3 First run

1. Open the app. Allow permissions when asked (Nearby devices for Bluetooth, Camera for the QR, Microphone for the visualizer).
2. **New board:** *Set up Wi-Fi with Bluetooth* > Scan > tap the board > enter your Wi-Fi > Send. Read the IP on the display.
3. **Connect:** enter the IP (or *Scan pairing QR*). If the board is locked, enter the token.
4. **Phone sync (optional):** Menu > Settings > Phone sync > *Allow* (Android "Notification access"), then switch on *Mirror notifications* and/or *Show now playing*.
5. **Remote (optional):** with the phone on the same Wi-Fi: Settings > Remote access > Enable. Then, on any network: Connect screen > *Remote (MQTT)* with the broker, device id and token.

### 3.4 Screens

| Screen | What you can do |
|---|---|
| Home | Message box, scene grid (current scene highlighted), menu: Settings, Auto-rotate, Time zone, Wi-Fi setup, Forget Wi-Fi, Reboot, Disconnect |
| Pomodoro | Focus/break length, start/pause/skip/reset |
| Pixel Pet | Feed, Play, Pat, Sleep, Wake |
| Weather | Pick a city or enter latitude/longitude |
| AI Buddy | Chat with Claude (your own API key, stored only on the phone and sent only to api.anthropic.com); answers appear on the display with a talking face. "Say" just shows your text |
| Canvas | *Draw* on a 40x32 grid, *Photo* (cropped to the screen), *Animation* (animated GIF or a photo slideshow) |
| Music | Microphone visualizer (phone mic > spectrum bars), demo animation, manual now-playing |
| Settings | Device info, pairing QR, lock/token, MQTT remote access, Bluetooth, Phone sync |

### 3.5 Phone sync (native Android code)

`HubNotificationService` (Kotlin) needs the **Notification access** permission, which you grant in Android settings (the app takes you there).
- **Mirror notifications:** new notifications become a card on the display (app, title, text). Ongoing, media and group-summary notifications are skipped.
  Use *Ignore apps containing* to block banks, OTP apps and so on.
- **Now playing:** follows the active media session of any music app (title, artist, length, position). A new track or play/pause switches the display to Now Playing; the periodic position update does not.
- It sends to the board over **local HTTP from native code**, so it keeps working when the app is closed, as long as the phone is on the same Wi-Fi.
  The address and token come from the last time you used the app. Over MQTT it does not work.

### 3.6 Android notes

- Plain HTTP is allowed (`usesCleartextTraffic`) because the board speaks HTTP on your local network.
- `esp32-hub.local` often does not resolve on Android. Use the IP address.

---

## 4. Troubleshooting

**The browser page does not open**
- Join the right network: `ESP32-Hub` in setup mode, otherwise your home Wi-Fi.
- Type the full address `http://192.168.4.1` or `http://<ip>`. Without `http://` browsers may search or force `https`, which the board does not speak.
- Android: when it says the hotspot "has no internet, stay connected?", choose **Yes/Keep**; turn off mobile data and VPN while setting up.
- Only **2.4 GHz** Wi-Fi works. Check the serial log for the mode and IP.

**White or blank screen:** check the wiring (section 1). Colours wrong or edge shifted: change `TAB`. `SPI.begin(18, -1, 23, -1)` must not be given the CS pin.

**Upload fails / port missing:** data cable, other USB port, `ls /dev/ttyUSB*`, `dialout` group, hold BOOT while it says "Connecting...".

**"locked: token required" / 401:** enter the token (Settings, or scan the pairing QR). To recover a board whose token you lost: setup mode is open, or flash over USB.

**Animation says "low memory":** Bluetooth is on (Settings > Bluetooth > Disable) or other things hold RAM. 7 frames is the limit.

**Weather says "No data":** needs Wi-Fi with internet; it retries every 15 s. The serial log shows `[weather] ok/failed`.

**MQTT does not connect:** check broker host/port/credentials in Settings, that the board shows `mqtt=1` in the serial log, and look for `[mqtt] connect ... failed`. It retries every 30 s.

**Phone sync does nothing:** grant Notification access; connect by IP (not MQTT); phone and board on the same Wi-Fi; check the board is not locked with a different token than the one the app last used.

---

## 5. What was tested and what was not

**Tested on the real board (ESP32-D0WD-V3, 1.8" ST7735S), with scripted requests:**
setup hotspot and browser page; every scene starts; every command; lock (401 without or with a wrong token, accepted with the token); weather (real data fetched from Open-Meteo);
clock, ping; notification card; pairing QR scene; GIF/slideshow frames (7 frames; the board refuses more instead of crashing); canvas pixels; MQTT end to end through a local broker (subscribe, retained list/state, commands accepted, wrong token ignored, 6.8 KB pixel strip);
BLE advertising seen from a computer; memory stays flat during the tests; no reboots.

**Not tested (no way to do it from here):**
- The pictures on the display itself (the tests cannot see the screen).
- The **Flutter app was written and passes the Dart analyser, but was never built or run**, and the Android Kotlin code was never compiled. Expect to fix small build errors on first build.
- **BLE Wi-Fi provisioning end to end** (the board advertises and the app code follows the plugin API, but no phone was available).
- **Phone sync, microphone visualizer, QR scan, GIF picking, AI Buddy** (they need a phone and, for the buddy, an API key).
- MQTT against a real internet broker, and with TLS.
- Over-the-air updates.

**Not built:** Firebase login / accounts (replaced by the token and QR pairing), a cloud dashboard, iOS support for phone sync (iOS does not allow it), an on-board microphone.

---

## Wi-Fi setup notes (firmware 0.4.1 / app 1.1.0)

- In setup mode the app sends the Wi-Fi to the board **while the hotspot stays up**, then polls `GET /api/wifi/status`
  (`connecting | ok | fail`, reason `bad_password | not_found | timeout`). The network is only saved once the join works, so a typo
  never overwrites a working saved Wi-Fi. The board restarts into normal mode 8 s after success.
- `GET /api/scan` restarts its scan by itself (an empty result no longer sticks) and returns names strongest first.
- Bluetooth setup was removed from the app; the board keeps Bluetooth off by default, which frees about 60 KB of RAM.
- The Android app pins itself to a Wi-Fi without internet (the board's hotspot) so Android does not send traffic over mobile data.
- Notification access on Android 13+ for sideloaded apps: App info > ⋮ > Allow restricted settings.
- **Pairing mode** (firmware 0.5.0): hold the board's BOOT button for 1.5 s, or use the app menu "Pairing mode", to switch the
  `ESP32-Hub` hotspot (password `hub12345`) on for 10 minutes while the board stays on your Wi-Fi. The screen shows the Wi-Fi QR.
- **First boot Wi-Fi**: copy `firmware/hub/secrets.h.example` to `secrets.h` (git-ignored) to give a new board your Wi-Fi without app setup.

