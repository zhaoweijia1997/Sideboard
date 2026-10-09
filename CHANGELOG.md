# Changelog

## 0.6.1 — 2026-10-09

- **Deep sleep** on the Details page (Power and standby): how long the device has been in deep
  sleep since it started, from the difference between Android's two clocks (one stops in deep
  sleep, one doesn't), and why the screen last went off. Many TVs and devices on USB never deep
  sleep with the screen off.
- Fixed: running Sideboard from the command line (`--status`, `--watch`, `--check`,
  `--snapshot`) could leave the menu bar icon hidden — macOS remembered it as hidden in the
  user's settings. Those runs now happen before the app starts.

## 0.6.0 — 2026-10-07

- **Live screen** (the first button in a device's header): the device's screen in a window of its
  own, streamed as H.264 by Android's `screenrecord` straight to the Mac (`adb exec-out`). Nothing
  is installed or written on the device, and the recorder there ends when the window closes. Click
  to tap, drag to swipe, scroll, right-click for Back, and use the arrow keys, Return and Esc as
  the D-pad; Back, Home, Recent apps and the remote are in the window. The window takes the
  screen's shape, the stream pauses while the window is hidden, and Android's 3-minute limit per
  recording is bridged by starting the next one. HDMI inputs and protected video show black, and
  there's no sound.
- Quitting while a recording runs finishes and saves it first, so its temporary file isn't left on
  the device.
- Screenshot and recording file names use the Mac's time zone (they used UTC).

## 0.5.0 — 2026-10-07

- **Screen recording** (the record button next to Screenshot): records the device's screen
  with Android's `screenrecord`, up to 3 minutes and without sound, showing the elapsed time.
  Stopping sends it an interrupt so the video is finished properly; it then comes to the Mac
  (Movies → Sideboard) with a preview, and the temporary file on the device is deleted. The
  3-minute limit ends it the same way. HDMI inputs and protected video come out black.

## 0.4.0 — 2026-10-07

- **Menu bar and notifications** (Settings): keep running with a menu bar icon after the window
  closes, open at login, and get notified when a device is still on late at night, on for many
  hours in a row, almost out of storage, running hot, low on battery, getting apps installed or
  removed, or no longer answering. The panel shows every device at a glance. Devices are checked
  every 5 minutes while their screen is on and every 30 while it's off; a device whose page is
  open isn't checked twice.
- **History on the Mac**: every reading adds to a per-device history in
  ~/Library/Application Support/Sideboard (file names are a hash of the serial number), so the
  history grows past 24 hours without the companion app. Delete it from Settings.
- **Screen time** for a week or a month, with total and daily average, and a heatmap of when the
  screen is on (last four weeks).
- **Health** page: data usage per app (24 hours, 7 days, 30 days, added up on the device),
  crashes and freezes, alarms that woke the device, background jobs, apps allowed to skip
  battery saving. Read when opened, never polled.
- **Open links on the device**: Send → Open a Link on the Device, drop a link on the window, or
  Services → Open on Android Device from any app.
- **Live typing** in the Type Text window: letters go to the device as you type (after an input
  method finishes composing), with Return, Delete and the arrow keys.
- `--check` runs the monitor once and prints the notifications it would send.

## 0.3.0 — 2026-10-07

- **Companion app** (optional, `android/`, about 120 KB), installed from the Overview page.
  Sideboard installs it over adb and allows usage access, so nothing has to be set up on the
  device. It keeps 90 days of power, screen and app history (copied from Android's usage
  events by a job a few times a day; no background service), and gives app names and icons.
  Uninstall removes it with its history.
- **History**: with the companion, a week of screen time per day, and any day's events.
  Without it, the last 24 hours as before.
- **Type Text** (keyboard button): type in any language, Return and Delete, send text to the
  device's clipboard or get it from there. While the window is open the device uses the
  companion's invisible keyboard; closing it restores the device's own keyboard and turns the
  companion's off again. Text travels base64-encoded, so nothing is interpreted by the shell.
- The Apps page shows app icons and names from the companion.
- While a device sleeps, the history is refreshed every 30 minutes instead of 10.
- `--status` also reports the companion app.

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
