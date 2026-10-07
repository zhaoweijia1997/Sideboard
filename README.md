<p align="center"><img src="docs/icon.png" width="128" alt="Sideboard icon"></p>

# Sideboard

**English** · [简体中文](README.zh-CN.md)

See how your Android devices are doing, from your Mac. Sideboard connects to Android TVs,
boxes, phones and tablets over adb, by USB or over your home network, and shows everything
it can read: whether the screen is on, what's showing, what's playing, how long it's been
running, CPU, memory, storage, network, temperature, and the last 24 hours of screen and
app use. It's also a remote, takes screenshots, sends files and installs apps.

Nothing has to be installed on the device.

<p align="center">
  <img src="docs/screenshots/overview-en-light.png" width="760" alt="Sideboard showing a TV's screen, app, playback, uptime, CPU, memory, storage, network, volume and its last 24 hours">
</p>

> **Status: early preview (0.1).** Watches your devices and does the basics. See the roadmap
> for what's next.

## What it shows

**Overview**
- Screen: on, off (standby on TVs), screensaver; how long it's been on today
- The app in front, and what's playing (with the title, or the TV input)
- Running time since it was switched on
- CPU usage, cores and speed; temperature, if the device reports one (many TVs don't)
- Memory and storage, wired or Wi-Fi network and IP address, volume, battery

**Last 24 hours**
- When it was switched on and off, when the screen went on and off, and which apps were
  opened, with today's most-used apps. This comes from Android's own usage history, so it
  covers the time Sideboard wasn't open, too.

**Details**
- Model, Android version and security patch, build, kernel, chip, architecture
- Screen resolution, the resolution apps draw at, density, refresh rate
- CPU speed, load average, the busiest processes
- Memory in detail, internal storage and USB drives or cards
- Wi-Fi network, signal, link speed and band
- Power settings: when the screensaver starts, when it sleeps, when it turns off with no
  input, whether it stays awake while plugged in. Shown only, never changed.
- How many apps are installed, and how many you added

<p align="center">
  <img src="docs/screenshots/details-en-light.png" width="760" alt="The Details page">
</p>

## What it does (only when you click)

- **Remote**: D-pad, OK, Back, Home, volume, play/pause, sleep and wake. Arrow keys,
  Return, Esc and Space work too.
- **Screenshot**: the picture comes straight to your Mac and is saved in Pictures →
  Sideboard. Nothing is written on the device.
- **Send files**: drop files on the window (or use Send) and they go into the device's
  Download folder.
- **Install apps**: drop an `.apk` and it's installed or updated.

## Light on your devices

- Sideboard only reads. It never changes a setting on the device, standby included.
- While the window is open and the screen is on, it reads every 5 seconds. While the
  screen is off, it checks once a minute whether it came back on, so the device can rest.
  With the window closed, it reads nothing.
- The Details page samples processes only while it's open.
- Network devices are reconnected once a minute when they're off the network, which
  doesn't wake them.
- Nothing leaves your Mac: no accounts, no analytics. Screenshots in this README use
  made-up data.

## Getting started

1. **Install adb** (Google's Android platform-tools). With Homebrew:

   ```bash
   brew install --cask android-platform-tools
   ```

   Or [download platform-tools](https://developer.android.com/tools/releases/platform-tools)
   and unzip it into `~/Library/Android/sdk/platform-tools`.

2. **Turn on debugging on the device.** Open Settings → About (on TVs: Settings → System →
   About) and click Build number seven times. Then in Developer options turn on USB
   debugging, and for a network connection also Network debugging (TVs and boxes) or
   Wireless debugging (phones and tablets, Android 11 and later).

3. **Connect it.** Plug it in by USB, or click **Add Device…** and enter its IP address, or
   scan your network. The first time, the device asks whether to allow this Mac: tick
   "Always allow" and confirm.

If a network device won't connect although everything looks right, click **Restart adb**:
an adb server started by another app (such as Terminal) may not be allowed onto the local
network.

## Install

Releases aren't published yet. For now, build from source.

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

## Build from source

Requires Xcode (the Command Line Tools alone lack SwiftUI's macro plugins).

```bash
./build.sh             # builds build.noindex/Sideboard.app (universal)
./build.sh --install   # also copies it to /Applications
./build.sh --dmg       # also makes a .dmg for a release
python3 tools/check_localizations.py   # checks every translation
```

For bug reports, `Sideboard.app/Contents/MacOS/Sideboard --status` prints what Sideboard
reads from each connected device, without serial numbers, addresses or network names.
`--watch` runs the device list and dashboards for 20 seconds and prints what they saw.
`--snapshot <folder>` renders the window in every language, light and dark, with made-up
devices.

## Languages

English, 简体中文, 繁體中文, 日本語, Русский, Español, हिन्दी — switch any time from the
globe menu in the window, no restart needed.

Translations other than English and Chinese would love a review from native speakers.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

- [ ] Companion app on the device (optional): history longer than 24 hours, exact power-on
      and power-off times recorded even while the Mac is off, typing text in any language,
      a shared clipboard, app names instead of package names
- [ ] Apps: list, uninstall, turn off preinstalled apps (reversibly)
- [ ] Cleanup: app caches and large files
- [ ] Menu bar mode and notifications (for example when a device has been on all night)

## Support Sideboard

Sideboard is free and always will be. If it makes looking after your devices easier, you
can buy the developer a coffee — WeChat Pay or Alipay in China, PayPal anywhere. Thank you!

<p align="center">
  <img src="docs/donate/wechat.png" height="260" alt="WeChat Pay QR code">
  <img src="docs/donate/alipay.png" height="260" alt="Alipay QR code">
  <img src="docs/donate/paypal.png" height="260" alt="PayPal QR code">
</p>

## Contact

Bugs and ideas: [open an issue](../../issues). Email: zhaoweijia1997@gmail.com

## License

[MIT](LICENSE)
