/// Keep in step with pubspec.yaml (a test checks this) and with FW_VERSION in firmware/hub/hub.ino for the bundled API level.
const appVersion = '2.3.1';

/// The API level this app speaks. Firmware with a lower apiVersion still works (legacy mode: no request ids, no diagnostics).
const apiVersionWanted = 1;

/// The firmware this app release was built and tested with.
const bundledFirmware = '0.9.1';

/// Where the app looks for firmware updates (the project's own GitHub releases; no personal data is sent).
const releasesUrl = 'https://api.github.com/repos/bijithpn/esp32-app/releases';
