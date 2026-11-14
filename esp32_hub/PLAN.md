> **Status (updated):** all phases below are now implemented except a cloud account system.
> Built: scenes, Wi-Fi/BLE setup, HTTP + MQTT control, token lock and QR pairing, OTA, GIF/slideshow, microphone visualizer,
> notification mirror and now-playing (native Android), AI buddy. Replaced: Firebase login (token + QR pairing instead).
> See `README.md` for what is tested and what is not.

# ESP32 + 1.8" TFT + Flutter: Implementation Plan

Goal: turn the single-purpose sketches into one **modular firmware ("Hub")** with many scenes, controlled from a **Flutter app** over BLE and Wi-Fi.

Hardware: ESP32-D0WD (4 MB flash), ST7735S 160x128 (landscape), pins CS15 DC2 RST4 SCK18 MOSI23. Wiring never changes.

---

## 1. Architecture

```
Flutter app  <--BLE (setup, nearby control)-->  ESP32 Hub  --SPI--> TFT
             <--WebSocket/HTTP (same Wi-Fi)-->      |
             <--MQTT/Firebase (anywhere, phase 5)-->|--> sensors / buttons
```

Firmware layout (one Arduino sketch folder `hub/`, split into files):

| File | Job |
|---|---|
| `Display.h/.cpp` | TFT init, 160x128 `GFXcanvas16` double-buffer, `push()`, brightness |
| `Scene.h` | `struct Scene { begin(); update(dt); draw(canvas); onCommand(json); end(); }` |
| `SceneManager.cpp` | registry, switch scene, auto-rotate timer, FPS cap |
| `Net.cpp` | Wi-Fi connect, NTP, WebSocket server (port 81), mDNS (`esp32-hub.local`) |
| `Ble.cpp` | NimBLE service: provisioning + command characteristic |
| `Protocol.cpp` | JSON command router (shared by BLE and WebSocket) |
| `Config.cpp` | `Preferences` (NVS): Wi-Fi, name, active scene, settings |
| `Ota.cpp` | ArduinoOTA + HTTP OTA |
| `scenes/*.cpp` | one file per scene |

Why: today every project is a separate sketch that re-flashes the board. With scenes, the app switches them instantly with no cable.

### Protocol (identical over BLE and WebSocket)
```json
{"cmd":"scene","id":"eyes"}
{"cmd":"scene","id":"eyes","args":{"mood":"happy"}}
{"cmd":"msg","text":"Good morning","emoji":"sun","ttl":10}
{"cmd":"wifi","ssid":"...","pass":"..."}
{"cmd":"brightness","v":80}
{"cmd":"list"}            -> {"scenes":[{"id":"eyes","name":"Robot Eyes","args":[...]}]}
{"cmd":"pixels","x":0,"y":0,"w":16,"h":16,"data":"<base64 RGB565>"}
{"cmd":"status"}          -> heap, rssi, fw version, uptime
```
The app calls `list` on connect, so **new scenes appear in the app with no app update**.

---

## 2. Known constraints (decide these early)

| Issue | Decision |
|---|---|
| Flash: `weather_clock_18` already uses 82% of the default 1.3 MB partition; BLE + Wi-Fi + scenes will not fit | Use a bigger partition table (`Huge APP`, or custom with 2 OTA slots at ~1.9 MB each) |
| RAM: canvas = 40 KB; BLE + Wi-Fi + TLS use a lot | **NimBLE-Arduino** (not Bluedroid), one canvas only, avoid `String` churn, check `ESP.getFreeHeap()` per scene |
| BLE + Wi-Fi share one radio | BLE only for provisioning and nearby control; Wi-Fi WebSocket for streaming (pixels, audio bands) |
| Adafruit_ST7735 is slow (~15-20 fps full frame) | Set SPI to 40 MHz; push only dirty rects; if still slow, move to **LovyanGFX** (DMA) in Phase 2 |
| API keys (AI, Spotify) | Never in firmware. The **phone calls the API** and sends only results |
| Spotify / notifications | Android only (NotificationListener / media session). iOS cannot read other apps' now-playing |
| `GPIO2/15` are strapping pins | Fine now. If boot ever fails, unplug DC/CS, reset, replug |

---

## 3. Phases

### Phase 0: Foundation (do first, everything depends on it)
- [ ] Create `hub/` sketch: Display wrapper, Scene interface, SceneManager, 2 demo scenes (reuse `name_show_18`).
- [ ] Partition table + NimBLE + ArduinoJson wired up; free-heap log over Serial.
- [ ] `Config` (NVS), serial command console for testing (`scene eyes`).
- [ ] **Done when:** serial command switches scenes; FPS and free heap printed.

### Phase 1: Offline animation scenes (no network, quick wins)
| # | Scene | Notes |
|---|---|---|
| 1 | **Robot eyes** | Eye shapes from rounded rects; state machine: idle/blink/look/happy/sleepy/angry; random blink timer. Args: `mood` |
| 2 | **Bouncing logo** | Vector logo or text, color change on each wall hit, corner-hit counter |
| 3 | **Matrix rain** | Column array of drops with fading trail |
| 4 | **Plasma / Fire** | Precomputed sine LUT / heat array, palette from 256 entry table |
| 5 | **Starfield** | 3D star projection, ~60 stars |
| 6 | **Game of Life** | 80x64 grid at 2 px cells, auto-reseed when stable |
| 7 | **Mandelbrot zoom** | Fixed-point math, render in strips between frames |
| 8 | **Pixel pet** | Sprites from `mascot_assets` converted to RGB565 arrays (script below); states: idle/eat/sleep/happy; hunger timer saved to NVS |
- [ ] Asset script `tools/png2rgb565.py` (PNG -> `const uint16_t[]` header, PROGMEM).
- **Done when:** each scene runs >= 20 fps and 10 min without a heap leak.

### Phase 2: Wi-Fi scenes
| # | Scene | Notes |
|---|---|---|
| 9 | **Analog clock** | NTP (already working); anti-aliased hands; smooth second hand |
| 10 | **Weather + icons** | Open-Meteo (no key); draw sun/cloud/rain with shapes; reuse `weather_clock_18` fetch |
| 11 | **Pomodoro** | Progress ring; start/pause/skip from app or button; buzzer optional |
| 12 | **Ping / speed monitor** | Ping a host every 2 s (ESP32Ping), rolling graph; speed test = download fixed file, time it |
| 13 | **Photo frame** | TJpg_Decoder; app uploads pre-resized 160x128 JPEG (store in LittleFS) or ESP32 downloads a URL |
- **Done when:** scenes survive Wi-Fi drop and reconnect without reboot.

### Phase 3: Flutter app v1 (BLE + Wi-Fi control)
Stack: Flutter, `flutter_blue_plus`, `web_socket_channel`, `riverpod`, `shared_preferences`.

Screens:
1. **Scan / Connect.** Lists `ESP32-Hub-xxxx`, remembers last device, auto-reconnect.
2. **Provisioning.** Send Wi-Fi SSID/password over BLE (no more `secrets.h`); ESP32 replies with its IP, app switches to WebSocket.
3. **Scenes.** Grid built from the `list` response; tapping sends `scene`; per-scene controls from `args` (e.g. mood picker for eyes).
4. **Message board.** Text + emoji picker + animation style; "send as scrolling / popup".
5. **Settings.** Brightness, auto-rotate interval, rename, device status (heap, RSSI, FW version).
- [ ] Firmware: BLE service (UUIDs fixed), WebSocket server, mDNS.
- **Done when:** fresh board -> app provisions Wi-Fi -> switch every Phase 1/2 scene from the phone.

### Phase 4: App-driven interactive features
| Feature | How |
|---|---|
| **Pixel drawing pad** | Flutter `CustomPainter` 40x32 grid, send changed pixels (`pixels` cmd) over WebSocket |
| **Photo / GIF sender** | App picks image, resizes to 160x128, converts to JPEG, uploads in chunks; GIF = frame list + delay |
| **Tiny AI buddy** | App sends prompt to an LLM API (server-side key via your own small backend or user-entered key stored on phone), then sends `{"cmd":"say","text":...}`; ESP32 plays the pet's talking animation (mouth frames) while text scrolls |
| **Music visualizer** | Mode A: phone mic/audio -> FFT in Dart -> 16 band values @ 20 Hz over WebSocket. Mode B (offline): INMP441 mic + `arduinoFFT` on ESP32 |
| **Now playing** | Android notification/media listener -> title, artist, small cover (64x64 JPEG) -> `{"cmd":"nowplaying"}` scene with marquee text and progress bar |
| **Notification mirror** | Same listener, forward app name + title as popup cards |
| **Pomodoro remote** | Start/pause from app; ESP32 pushes state back so both stay in sync |
- **Done when:** each feature works for 30 min continuously without disconnects.

### Phase 5: Product-grade IoT kit (portfolio)
- [ ] **OTA** from the app (HTTP OTA with signed firmware; version check on connect).
- [ ] **Cloud:** MQTT (HiveMQ/Mosquitto) or Firebase Realtime DB so the app controls the board away from home; device and app authenticate with per-device tokens.
- [ ] **Login:** Firebase Auth; devices are claimed by an account via a QR code shown on the TFT.
- [ ] **Telemetry:** uptime, heap, RSSI, last scene to a small dashboard in the app.
- [ ] **Hardening:** BLE bonding/pairing PIN, reject unauthenticated WebSocket, rate-limit commands, watchdog + safe-mode boot if the last scene crashed 3 times.
- [ ] README with architecture diagram, demo GIFs, and a 60 s demo video for your CV.

---

## 4. Suggested order and effort

| Order | Work | Rough effort |
|---|---|---|
| 1 | Phase 0 foundation | 1-2 days |
| 2 | Eyes, bouncing logo, matrix, starfield | 1-2 days |
| 3 | Phase 3 app v1 + BLE provisioning | 3-5 days |
| 4 | Clock, weather icons, pomodoro | 1-2 days |
| 5 | Message board, drawing pad, photo sender | 2-4 days |
| 6 | Pet, AI buddy, now playing, visualizer | 4-6 days |
| 7 | Phase 5 OTA, cloud, login, polish | 4-7 days |

Build the **app and firmware together per feature**, not all firmware first: each demo gives you something showable.

## 5. Optional hardware (all cheap, none required to start)
Push buttons (2-3) for local control, passive buzzer, BME280 or DHT22 for the sensor scenes, MPU6050 for tilt/shake, INMP441 mic for the offline visualizer, a LiPo + TP4056 for a portable build.

## 6. Test checklist per scene
- 20+ fps (or a stated target) with Serial FPS print
- Free heap stable after 10 min
- Survives Wi-Fi/BLE disconnect
- Switch away and back 50 times without a leak or crash
- Looks right with `TAB` variant (colors/edges)
