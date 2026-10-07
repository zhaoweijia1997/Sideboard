# Changelog

## 0.2.0 — 2026-10-07

- **Apps** page: every app with version, last update and size (from Android's storage
  statistics); filter by added, preinstalled and turned off; search. Open, force stop,
  turn off and back on, uninstall apps you added, save an app's APK (or its split APKs) to
  the Mac. Apps the device needs (home screen, keyboard in use, core Android parts) are
  locked.
- **Files** page: browse internal storage and USB drives, folder sizes on request,
  download to the Mac (never replacing anything there), upload or drop files into the
  folder shown, new folder, rename, delete (asks first).
- **Clean Up** page: app caches (cleared with Android's own `pm trim-caches`), leftover
  folders of removed apps in Android/data, obb and media, downloaded installers,
  thumbnail caches, and large files for review (not selected). Shows how much was freed.
- Transfers now cover uploads into any folder and downloads to the Mac, with Show in
  Finder.
- `--status` also reports what the new pages read.

## 0.1.0 — 2026-10-07

First preview.

- **Devices**: USB and network devices in one list. Add a network device by IP address,
  by scanning the local network for devices with network debugging on, or by pairing
  (Wireless debugging, Android 11 and later). Network devices are remembered and
  reconnected once a minute.
- **Overview**: screen state and screen-on time today, the app in front, what's playing,
  running time, CPU, memory, storage, network, volume, battery, temperature when the
  device reports it.
- **Last 24 hours**: power on/off, screen on/off and apps opened, from the device's own
  usage history, with today's most-used apps.
- **Details**: device, display, CPU (with the busiest processes), memory, storage
  (including USB drives), network and Wi-Fi, power and standby settings (read-only),
  installed apps.
- **Remote**, **screenshots** (saved on the Mac, nothing left on the device), **send
  files** to Download and **install apps** by dragging them onto the window.
- Reads every 5 seconds while the screen is on, once a minute while it's off, nothing
  while the window is closed. Never changes a setting on the device.
- 7 languages: English, 简体中文, 繁體中文, 日本語, Русский, Español, हिन्दी.
