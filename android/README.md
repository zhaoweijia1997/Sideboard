# Sideboard companion app

The optional Android app that Sideboard on the Mac installs on a device (Overview page →
Install Companion App). About 120 KB, no libraries, Android 8 and later, phones and TVs.

## What it does

- **History** (`History.kt`, `RecordJob.kt`, `BootReceiver.kt`): every few hours a scheduled
  job copies screen, power and app events from Android's own usage history (which Android keeps
  for only about a week) into a small database, kept for 90 days. At boot it notes the exact
  start-up time. There is no service running in between.
- **Provider** (`SideboardProvider.kt`): what Sideboard reads with `adb shell content query`:
  `info`, `events?since=ms`, `apps` (names) and `icons` (64 px PNG, base64).
- **Keyboard** (`TypingService.kt`): an input method with no keys. Sideboard switches the
  device to it while its typing window is open, sends text, Return/Delete and clipboard
  requests with `am broadcast`, and switches back afterwards. If that doesn't happen, it
  switches back by itself after five idle minutes.
- **Screen** (`MainActivity.kt`): explains itself on the device, shows whether it's recording,
  and has a field to try typing into.

The provider and the keyboard's broadcasts require `android.permission.DUMP`, which the adb
shell has and ordinary apps can't get, so other apps on the device can't read the history or
type through it. The app has no network code.

## Permissions

- `PACKAGE_USAGE_STATS` (usage access): to read the usage history. Sideboard allows it with
  `appops set com.weijiazhao.sideboard GET_USAGE_STATS allow` when it installs the app.
- `RECEIVE_BOOT_COMPLETED`: to note the start-up time and keep the job scheduled.
- `QUERY_ALL_PACKAGES`: for app names and icons.

## Building

```bash
../tools/build-companion.sh   # builds, then copies the APK to ../Resources/SideboardCompanion.apk
```

Needs Android Studio (its Java is used) and the Android SDK (`local.properties` with `sdk.dir`,
or `ANDROID_HOME`). Release builds are signed with the maintainer's key, which is kept outside
the repository; without it they are signed with your debug key. A device that has the published
companion installed won't accept an update signed with another key: uninstall it first.
