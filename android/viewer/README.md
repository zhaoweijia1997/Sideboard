# Sideboard Viewer

An Android app that shows another Android device's screen and lets you use it by touch, over
the local network: the other device runs [Sideboard Link](../link/README.md), this one is what
Sideboard on the Mac is to it, in your hand. About 90 KB, no libraries, Android 8 and later.

- **Finds the other device by itself** (`MainActivity.kt`): it lists whoever announces
  `_sideboard-link._tcp` on the network; an address can be typed too.
- **The picture** (`ViewerActivity.kt`): the other device's H.264 stream, decoded straight onto
  the screen. It comes back by itself after the other device's screen is turned or the
  connection drops.
- **Touches**: a finger on the picture is a finger there, as it moves. Below the picture are
  Back, Home, Recents and Type (text for the field that has the cursor on the other device).
- **Asking first** (`LinkClient.kt`): the first time, the other device asks its owner whether
  to let this one in, and remembers the answer.

No microphone and no camera permission, on purpose. The connection is not encrypted; it is
meant for a home network you trust.

## Building

```bash
cd android && ./gradlew :viewer:assembleRelease   # viewer/build/outputs/apk/release/viewer-release.apk
```

Signing is the same as the other two apps' (see `../README.md`).
