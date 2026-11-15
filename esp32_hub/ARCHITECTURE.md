# ESP32 Hub: architecture, audit and verification (app 2.0.0, firmware 0.6.0)

## 1. Audit: what was wrong in 1.5.0 / 0.5.1, and the fix

| # | Finding (root cause) | Fix |
|---|---|---|
| 1 | `PhoneBridge.bindWifi(force)` pinned the **whole process** to the Wi-Fi (`bindProcessToNetwork`) on every start, lifecycle resume and manual connect, and was only undone in some paths. Leaves mobile data / MQTT / Anthropic calls on the wrong network, and keeps the app bound to a dead hotspot. | Nothing is bound process-wide. `NativeNet.kt` sends every Hub request through `Network.openConnection` / `bindSocket` of the Wi-Fi (or hotspot-session) `Network`. |
| 2 | Connection state lived in three places (`StartPage`, `HomePage._online/_fails`, `Discovery`), with duplicated token handling; "Connected" was shown after `/api/list` alone. | `ConnectionManager` is the only owner; "connected" requires identity (`hello`), auth and `list`. |
| 3 | Discovery accepted any HTTP 200 with `device:"ESP32-Hub"`; sweep of all 254 hosts x 48 workers on every search; `esp32-hub.local` fixed name (clashes with a second board). | Identity = marker + id + firmware; multi-strategy with UDP/mDNS first and the sweep delayed and chunked; per-board hostname `esp32-hub-<id>.local`. |
| 4 | Hotspot password `hub12345` shared by every board, hard-coded in app and firmware; OTA password the same. | 8-char per-board code generated with `esp_random`, stored in NVS, shown on the display / QR. |
| 5 | Wi-Fi join failures collapsed into three reasons; timeouts reported as "not_found". | Board classifies bad password, not found, unsupported security, association refused, weak signal, DHCP timeout, router dropped; `/api/wifi/status` exposes `phase` and `reason`. |
| 6 | Setup progress was lost if the app was closed; no way back in. | Non-sensitive progress (id, ssid, step, time; never the password) is persisted; `resume()` rediscovers the board by id. |
| 7 | Token stored in plain `SharedPreferences` (also copied to a native prefs file); Anthropic key and MQTT password in plain preferences. | Android Keystore AES-256-GCM (`SecureStore.kt`); legacy values are migrated and deleted. `allowBackup=false`. |
| 8 | Token compared with `==`, no rate limit, unlimited body size. | Constant-time compare, 6 wrong tokens/minute -> 30 s block (HTTP 429), 9000-byte command limit. |
| 9 | Background sender queued every notification behind failing 3 s timeouts and replayed stale ones after reconnecting; media listener registered twice on reconnect. | Bounded queue (6), TTL (20 s notifications / 30 s media), newest-only media, back-off, request ids, `requestRebind`, listener removed before re-adding. |
| 10 | `HomePage` polled `/api/list` + `/api/status` every 3 s forever, in the background too. | `/api/ping` (tiny) every 5 s on the dashboard, 20 s elsewhere, 1.5 s while degraded, **paused in the background**; the scene list is re-read only when the board's `rev` counter moves. |
| 11 | Commands retried or not at random; no ids; a lost reply could run "feed" twice. | `CommandQueue` + firmware idempotency ring (request id, 2 min). |
| 12 | OTA accepted any upload with a valid token, no size/model/header/MD5 checks, no status. | Header magic + chip id, size vs free slot, optional `X-Hub-Model`, `X-Hub-Md5` verified by `Update`, progress, stall timeout, explicit failure codes. |
| 13 | Hotspot (pairing) window fixed at 10 min; a failed STA with saved Wi-Fi could keep the setup hotspot up forever. | Window configurable 60-1800 s, can be ended, and a fallback hotspot idle for 30 min restarts to retry the saved network. |
| 14 | Crash loops invisible. | Reset reason, consecutive/total crash counters, safe mode after 3 unclean resets (skips saved scene and MQTT), counter cleared after 60 s of clean running. |

Not changed on purpose: the captive-portal answers (`/generate_204`, `/hotspot-detect.html`, ...). They are kept so phones do not treat the hotspot as broken; provisioning no longer *depends* on them because the app uses `WifiNetworkSpecifier`.

## 2. Architecture

```
Flutter                                                     Kotlin                         ESP32
-------                                                     ------                         -----
screens/*  features/*  (read ConnectionManager via HubScope)
      |
core/connection.dart  ConnectionManager (single source of truth)
  |- registry.dart       paired Hubs (prefs) + tokens (Keystore)
  |- discovery.dart      known IP/hostname | UDP | mDNS | hotspot | sweep, all verified
  |- command_queue.dart  priority, dedupe, retry policy, request ids, stale drop
  |- provisioning.dart   6-step setup, 12 join phases, recovery
  |- diagnostics.dart    redacted log (400 lines), history (100 events)
  `- bridge.dart --MethodChannel/EventChannel--> MainActivity, NativeNet, NetworkMonitor, SecureStore
                                                 HubNotificationService + HubSender (background)
                                                                     |  HTTP /api/* (Network-bound), UDP 41234, mDNS _esp32hub._tcp
                                                                     v
                                                  hub.ino + hubcore.h (+ scenes, face, cards, music, remote)
```

State machine: `disconnected, discovering, deviceFound, connecting, authenticating, connected, degraded, reconnecting, provisioning, networkSwitching, authenticationRequired, firmwareUpdating, unavailable, error`. The table (`core/models.dart: connStates`) gives each state a label, meaning, timeout and its valid next states; invalid moves are rejected and logged. `test/models_test.dart` and `test/connection_test.dart` cover it.

Reconnect: 500 ms, 1 s, 2 s, 4 s, 8 s, 15 s (+-20 % jitter), reset only after 20 s of stable connection, 40 attempts then `unavailable`, paused while the app is in the background and while the phone has no Wi-Fi; the Android network callback (`NetworkMonitor`) restarts it immediately when Wi-Fi returns or the phone's address changes.

### Firmware API v1 (additive)
`GET /api/hello` (open: id, name, fw, apiVersion, ap, lock, authRequired, caps, never the token) | `GET /api/ping` | `GET /api/capabilities` | `GET /api/diag` (token if locked) | `GET /api/networks` (ssid, rssi, channel, auth, secure, supported) | `GET /api/wifi/status` (state, phase, reason, discReason) | `GET /api/ota/status` | `POST /api/cmd` (adds `rid`, returns `success, deviceId, requestId, errorCode` next to `ok/error`) | `POST /update` (multipart, headers `X-Hub-Token`, `X-Hub-Model`, `X-Hub-Size`, `X-Hub-Md5`) | UDP `ESP32_HUB_DISCOVER_V1` on 41234. New commands: `state`, `dim`, `name`, `sched`, `safe`, `pairing {sec|off}`, `noop`.

**Event transport decision:** efficient polling (`/api/ping` + `rev`). Arduino `WebServer` is single-threaded and blocking, so SSE/WebSocket would hold the only handler for a long-lived socket and cost RAM; a 5 s ping is ~200 bytes. Revisit only with `ESPAsyncWebServer`.

**Display profile:** only the ST7735S profile exists in the firmware (no ST7789 code path), so there is no configurable profile to preserve. Capabilities report driver and size.

## 3. Security considerations
- Local control is **plain HTTP**; the token authorises commands but traffic is not encrypted. This is not end-to-end encryption. Anyone who can sniff your Wi-Fi can read it. Do not expose the Hub to the internet; use MQTT with your own broker and TLS for remote use. The Hub's TLS client uses `setInsecure()` for MQTT (no certificate pinning).
- Pairing: per-board hotspot code (physical access to the screen), token created during pairing while the phone is on the hotspot, stored in the Keystore. The `Pair (QR)` scene shows the token on the board's own screen and should only be shown to someone present.
- Not done (and why): **signed firmware** and **verified rollback**. Signing needs a key hierarchy/secure boot; the stock Arduino bootloader is built without app-rollback support, so although `min_spiffs` has two OTA slots, an image that boots but misbehaves is not reverted automatically. The app says so before every install, and the capabilities report `otaRollback:false, otaSigned:false`.
- Token rotation exists (`token` command / Settings); no per-phone tokens, no token expiry.
- Cleartext traffic is allowed in the manifest because the Hub speaks HTTP; Android cannot restrict cleartext to private IP ranges without a hostname list.

## 4. Performance and memory
Measured on this machine (build, not hardware):

| | 0.5.1 | 0.6.0 |
|---|---|---|
| Flash (min_spiffs, 1,966,080 B slot) | 1,531,835 B (77 %) | 1,557,739 B (79 %) |
| Static RAM (globals) | 81,636 B | 82,292 B (+656 B) |

Run-time cost added: schedule table 8 x 24 B, idempotency ring 8 entries, 5 KB-free design for dimming (the 2.5 KB strip buffer exists only while dimming is on). Runtime heap, p95 latency, discovery time on a real LAN, 24 h soak and OTA were **not measured**: there was no board or phone in this session. `/api/diag` and the app's Diagnostics screen expose free/min/max-block heap, fragmentation, stack high-water mark, frame time and the longest loop gap so they can be measured; the connection test reports median/slowest of 7 pings.

Performance targets from the brief (200 ms restore, <1 s reachability, 3-5 s loss detection, 5 s recovery) are design targets; the code paths are: registry restore is a local read; reachability uses one `/api/hello` with a 1.5 s limit; loss is declared after 3 failed pings at 1.5 s spacing (~4.5-5 s); the network callback restarts discovery immediately.

## 5. Verification actually done
- `arduino-cli compile` for `esp32:esp32:esp32:PartitionScheme=min_spiffs` passes (numbers above).
- `flutter analyze`: no errors or warnings (only existing-style infos, e.g. the `material.dart` deprecation notice the project already had).
- `flutter test`: 76 tests pass (state table, identity parsing, command queue, connection manager incl. reconnect/network loss/auth/wrong device, discovery, provisioning incl. wrong password and recovery, registry migration, redaction, backup, firmware manifest, imaging, widget tests, and consistency checks that every firmware scene exists in the app, the 13 moods, and that app/firmware versions agree).
- The Flutter app was **not built or run** (as requested). The Kotlin code was **not compiled** (it is only built with the app); it was written against documented APIs and reviewed by reading, so compile errors are possible.

## 6. Needs a physical device (not verified)
Real board: hotspot join with `WifiNetworkSpecifier` on Android 10-15 (and the Android 9 manual path), DHCP delay, AP+STA channel behaviour, per-board password flow, UDP/mDNS discovery on multicast-filtering routers, router restart and IP change recovery, OTA from the app and a failed/interrupted OTA, safe mode, schedule after NTP, software dimming appearance, 24 h soak and heap trend, notification/music sync under Doze, Keystore on the phone models you use, CI release workflows (`firmware-release.yml` has never run), and the manifest/asset naming the Firmware screen expects.

## 7. Known limits
- Hidden SSIDs are joined by typing the name (the board cannot list hidden networks). WPA3-only networks are shown as unsupported (not verified on this SDK configuration); WPA2/WPA3 mixed works as WPA2.
- OTA upload uses `dart:io` directly (1.5 MB does not fit a method channel), so it needs the Hub on the phone's default network.
- Scene previews are illustrations from shared colours/motion, not a framebuffer stream; real state (scene, mood, timer, pet, weather) comes from the Hub.
- Per-frame duration for animations is global (the firmware has one delay); loop mode is forward or ping-pong.
- The scheduler needs the Hub's clock (NTP); after a power cut it waits until time is synced.
- A watchdog task was not added: the Arduino loop task is not watched by default, and enabling it without hardware testing risked reboot loops; instead resets are counted and safe mode protects against loops.
