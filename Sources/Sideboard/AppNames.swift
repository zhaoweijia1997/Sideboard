import SwiftUI

/// Names for package names. adb can't read an app's label without installing something on
/// the device, so Sideboard knows a few common apps and shows the package name for the rest.
enum AppNames {
    /// Brand names stay the same in every language.
    static let known: [String: String] = [
        "com.google.android.youtube.tv": "YouTube",
        "com.google.android.youtube": "YouTube",
        "com.google.android.youtube.tvkids": "YouTube Kids",
        "com.google.android.youtube.tvmusic": "YouTube Music",
        "com.google.android.videos": "Google TV",
        "com.google.android.apps.youtube.music": "YouTube Music",
        "com.netflix.ninja": "Netflix",
        "com.netflix.mediaclient": "Netflix",
        "com.amazon.amazonvideo.livingroom": "Prime Video",
        "com.disney.disneyplus": "Disney+",
        "com.apple.atve.androidtv.appletv": "Apple TV",
        "com.wbd.stream": "Max",
        "com.hulu.livingroomplus": "Hulu",
        "com.spotify.tv.android": "Spotify",
        "com.spotify.music": "Spotify",
        "com.plexapp.android": "Plex",
        "org.jellyfin.androidtv": "Jellyfin",
        "org.xbmc.kodi": "Kodi",
        "org.videolan.vlc": "VLC",
        "com.android.chrome": "Chrome",
        "com.google.android.apps.photos": "Google Photos",
        "com.google.android.gm": "Gmail",
        "com.google.android.apps.maps": "Google Maps",
        "com.android.vending": "Google Play",
        "com.tencent.mm": "WeChat",
        "com.ktcp.video": "云视听极光",
        "com.xiaodianshi.tv.yst": "云视听小电视",
        "com.gitvdemo.video": "银河奇异果",
    ]

    static let homeScreens: Set<String> = [
        "com.google.android.tvlauncher", "com.google.android.apps.tv.launcherx", "com.android.launcher3",
        "com.google.android.apps.nexuslauncher",
    ]

    /// System apps, named in the window's language.
    static let system: [String: LocalizedStringKey] = [
        "com.android.tv.settings": LocalizedStringKey("Settings"),
        "com.android.settings": LocalizedStringKey("Settings"),
        "com.sony.dtv.settings": LocalizedStringKey("Settings"),
        "com.android.packageinstaller": LocalizedStringKey("App installer"),
        "com.google.android.packageinstaller": LocalizedStringKey("App installer"),
        "com.sony.dtv.tvx": LocalizedStringKey("TV & inputs"),
        "com.google.android.tv": LocalizedStringKey("TV & inputs"),
        "com.android.tv": LocalizedStringKey("TV & inputs"),
        "android": LocalizedStringKey("System"),
        "com.android.systemui": LocalizedStringKey("System"),
    ]

    /// `home` is the device's current home screen app, which may be any launcher. `labels` are the
    /// names the companion app read on the device, when it's installed.
    static func text(for package: String, home: String?, labels: [String: String] = [:]) -> Text {
        if package == home || homeScreens.contains(package) { return Text("Home screen") }
        if let name = system[package] { return Text(name) }
        if let name = known[package] ?? labels[package] { return Text(verbatim: name) }
        return Text(verbatim: package)
    }

    /// A name for sorting and searching; nil when only the package name is known.
    static func name(for package: String, labels: [String: String] = [:]) -> String? { known[package] ?? labels[package] }

    /// True when `text(for:)` shows something friendlier than the package name.
    static func isNamed(_ package: String, home: String?, labels: [String: String] = [:]) -> Bool {
        package == home || homeScreens.contains(package) || known[package] != nil || system[package] != nil || labels[package] != nil
    }
}
