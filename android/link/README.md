# Sideboard Link

The optional Android app that lets Sideboard on the Mac show a device's screen and use it with
the mouse over the local network, with no cable and no adb. About 90 KB, no libraries,
Android 8 and later. Sideboard installs it from a device's Overview page (Set Up Sideboard
Link) while the device is still on adb.

## What it does

- **Waits for the Mac** (`LinkService.kt`): a small foreground service listening on port 47600
  (or any free one) and announcing `_sideboard-link._tcp` by mDNS, so the Mac needs no address.
  What a connection says is described at the top of that file.
- **Asks before letting a Mac in** (`Pairing.kt`): a Mac sends a random token it made up once;
  the first time, the owner is asked on the device (a notification with Allow and Deny, and the
  app's own screen). `AdbReceiver.kt` lets a Mac that already has the device on adb allow
  itself; only the adb shell can call it.
- **Shows the screen** (`ScreenCast.kt`, `CaptureActivity.kt`): Android's screen capture into
  one H.264 encoder whose pictures go to everybody watching; its bit rate follows how well
  the network keeps up. Android asks before an app may capture the screen;
  the accessibility service answers that question when it was asked on the Mac's behalf.
- **Takes touches** (`TouchService.kt`): an accessibility service that turns the Mac's
  messages into gestures (a drag is one gesture that keeps being continued), the Back, Home
  and Recents actions, and text for the field with the cursor. On the lock screen's PIN pad,
  which ignores such gestures, a tap or a typed digit presses the key itself; a touch also
  turns the screen on and keeps it on for half a minute while the device is locked.
- **Looks after itself** (`Keeper.kt`, `Updater.kt`): switches its accessibility service back
  on when Android switched it off, and installs a newer copy of itself sent by the Mac.
- Everything is marked to run before the first unlock after a restart.

## Permissions

- `INTERNET`, `CHANGE_WIFI_MULTICAST_STATE`: listening on the local network and announcing
  itself there. The app connects to nothing; it only answers.
- `FOREGROUND_SERVICE` (connected device, media projection), `POST_NOTIFICATIONS`: the service
  and its notification, which says so while the screen is being watched.
- `RECEIVE_BOOT_COMPLETED`: waiting again after a restart.
- `WAKE_LOCK`: turning the screen on when a viewer asks for it. The lock screen stays.
- `WRITE_SECURE_SETTINGS` (given over adb by Sideboard: `pm grant`): only used to put its own
  accessibility service back in the list of enabled ones.
- `REQUEST_INSTALL_PACKAGES` (allowed over adb: `appops set … REQUEST_INSTALL_PACKAGES allow`):
  installing its own update. Android accepts it only if it is signed with the same key.
- **No microphone and no camera permission, on purpose.** The app captures the screen's
  picture and nothing else; keep it that way.

## What to know

- The connection is not encrypted. It is meant for a home network you trust.
- Android asks before an app captures the screen, each time the app starts. Set-up from
  Sideboard switches that question off for this app (`appops set app.sideboard.link
  PROJECT_MEDIA allow`), which is what makes a restarted, still locked device visible. Undo
  it with `appops set app.sideboard.link PROJECT_MEDIA default`.
- Looking at the screen through adb (`uiautomator dump`) switches every accessibility service
  off for a few seconds, this one included.

## Trying it without the Mac app

```bash
../../tools/link_client.py DEVICE-ADDRESS info
../../tools/link_client.py DEVICE-ADDRESS video 10 screen.h264
../../tools/link_client.py DEVICE-ADDRESS swipe 0.5 0.8 0.5 0.3
```

and from the Mac app's side: `Sideboard --link-check [address:port [adb name]]`.

## Building

`../tools/build-companion.sh` builds this app together with the companion and copies it to
`Resources/SideboardLink.apk`. Signing is the same as the companion's (see `../README.md`).
