import AppKit
import SwiftUI

/// Renders the window in every language to PNG files, to check layouts without clicking
/// through the app, and for README screenshots:
///
///     build.noindex/Sideboard.app/Contents/MacOS/Sideboard --snapshot <folder>
///
/// Uses made-up devices and readings; no device is contacted.
@MainActor
enum Snapshots {
    static let size = NSSize(width: 1000, height: 760)

    static func render(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for language in AppLanguage.allCases where language != .system {
            let pages: [(String, DeviceStore, DashboardView.Page, CGFloat)] = [
                ("overview", .sample, .overview, 1640),
                ("details", .sample, .details, 1400),
                ("health", .sample, .health, 1000),
                ("apps", .sample, .apps, size.height),
                ("files", .sample, .files, size.height),
                ("cleanup", .sample, .cleanup, size.height),
                ("welcome", .sampleEmpty, .overview, size.height),
                ("waiting", .sampleWaiting, .overview, size.height),
                ("noadb", .sampleNoAdb, .overview, size.height),
            ]
            for (name, store, page, height) in pages {
                for dark in [false, true] {
                    let view = ContentView(store: store, initialPage: page)
                        .environment(\.locale, language.locale)
                        .frame(width: size.width, height: height)
                        // A borderless off-screen window doesn't paint its background.
                        .background(Color(nsColor: .windowBackgroundColor))
                    let file = "\(name)-\(language.rawValue)-\(dark ? "dark" : "light").png"
                    if let png = draw(view, dark: dark, height: height) {
                        try? png.write(to: folder.appending(path: file))
                    }
                }
            }
            for dark in [false, true] {
                let suffix = "\(language.rawValue)-\(dark ? "dark" : "light").png"
                let sheets: [(String, AnyView)] = [
                    ("settings", AnyView(SettingsView())),
                    ("menubar", AnyView(MenuBarPanel(store: .sample, monitor: .sample))),
                    ("add", AnyView(AddDeviceView(store: .sample))),
                    ("remote", AnyView(RemoteView(model: .sample))),
                    ("about", AnyView(AboutView())),
                ]
                for (name, sheet) in sheets {
                    let view = sheet
                        .environment(\.locale, language.locale)
                        .background(Color(nsColor: .windowBackgroundColor))
                    if let png = draw(view, dark: dark, height: nil) {
                        try? png.write(to: folder.appending(path: "\(name)-" + suffix))
                    }
                }
            }
        }
    }

    /// Draws the view in an off-screen window, so AppKit-backed controls (buttons, menus,
    /// scroll views) render too. With `height` nil, the view is drawn at its natural size.
    private static func draw(_ view: some View, dark: Bool, height: CGFloat?) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: height.map { NSSize(width: size.width, height: $0) } ?? hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish a layout pass before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension DeviceStore {
    /// A TV on the network, a phone on USB and a box that's switched off.
    static var sample: DeviceStore {
        DeviceStore(
            sample: [
                Adb.Device(serial: "192.168.1.42:5555", state: .online, model: "Living Room TV"),
                Adb.Device(serial: "usb-sample", state: .online, model: "Pixel Phone"),
            ],
            remembered: [
                RememberedDevice(address: "192.168.1.42:5555", name: "Living Room TV", isTV: true),
                RememberedDevice(address: "192.168.1.57:5555", name: "Bedroom Box", isTV: true),
            ],
            dashboards: ["192.168.1.42:5555": .sample])
    }

    static var sampleEmpty: DeviceStore {
        DeviceStore(sample: [], remembered: [], dashboards: [:])
    }

    /// The box is off: shows what a failed reconnect looks like.
    static var sampleWaiting: DeviceStore {
        let store = DeviceStore(
            sample: [],
            remembered: [
                RememberedDevice(address: "192.168.1.42:5555", name: "Living Room TV", isTV: true),
                RememberedDevice(address: "192.168.1.57:5555", name: "Bedroom Box", isTV: true),
            ],
            dashboards: [:], problems: ["192.168.1.57:5555": .unreachable])
        store.selection = "192.168.1.57:5555"
        return store
    }

    static var sampleNoAdb: DeviceStore {
        DeviceStore(sample: [], remembered: [], dashboards: [:], adbMissing: true)
    }
}

extension DashboardModel {
    static var sample: DashboardModel {
        let gib: Int64 = 1 << 30
        var status = DeviceStatus()
        status.manufacturer = "Example"
        status.model = "Living Room TV"
        status.androidVersion = "12"
        status.isTV = true
        status.uptime = 9 * 3600 + 42 * 60
        status.cores = 4
        status.cpuFrequency = 1500
        status.cpuMaxFrequency = 1800
        status.memoryTotal = 3 * gib
        status.memoryAvailable = gib + gib / 4
        status.storageTotal = 32 * gib
        status.storageAvailable = 21 * gib + gib / 2
        status.screen = .on
        status.foreground = "com.google.android.youtube.tv"
        status.home = "com.google.android.apps.tv.launcherx"
        status.media = DeviceStatus.Media(package: "com.google.android.youtube.tv", playback: .playing, title: "Ocean Waves at Sunset — Nature Channel")
        status.volume = 18
        status.volumeMax = 100
        status.addresses = [DeviceStatus.NetworkAddress(interface: "eth0", address: "192.168.1.42")]
        status.thermalStatus = 0
        status.temperature = 46

        var details = DeviceDetails()
        details.brand = "Example"
        details.device = "livingroom"
        details.sdk = 31
        details.securityPatch = "2026-05-01"
        details.build = "SAMPLE.12.0.1 release-keys"
        details.chipset = "Example Quad-Core"
        details.architecture = "arm64-v8a"
        details.kernel = "5.4.0"
        details.screenSize = "3840 × 2160"
        details.renderSize = "1920 × 1080"
        details.density = 320
        details.refreshRate = 60
        details.governor = "schedutil"
        details.loadAverage = [1.92, 1.75, 1.6]
        details.processes = [
            DeviceDetails.Process(pid: 4211, name: "com.google.android.youtube.tv", cpu: 38.5, memory: 412 * 1 << 20),
            DeviceDetails.Process(pid: 1032, name: "surfaceflinger", cpu: 12.1, memory: 46 * 1 << 20),
            DeviceDetails.Process(pid: 988, name: "media.codec", cpu: 9.4, memory: 28 * 1 << 20),
            DeviceDetails.Process(pid: 1310, name: "system_server", cpu: 4.2, memory: 210 * 1 << 20),
            DeviceDetails.Process(pid: 2240, name: "com.google.android.apps.tv.launcherx", cpu: 1.1, memory: 150 * 1 << 20),
            DeviceDetails.Process(pid: 1001, name: "audioserver", cpu: 0.9, memory: 12 * 1 << 20),
        ]
        details.memoryFree = gib / 8
        details.memoryCached = gib
        details.swapTotal = gib / 2
        details.swapFree = gib / 3
        details.volumes = [
            DeviceDetails.Volume(mount: "/data", total: 32 * gib, available: 21 * gib + gib / 2),
            DeviceDetails.Volume(mount: "/mnt/media_rw/1A2B-3C4D", total: 64 * gib, available: 40 * gib),
        ]
        details.screenOffTimeout = 600_000
        details.sleepTimeout = 14_400_000
        details.attentiveTimeout = 14_400_000
        details.stayOnWhilePluggedIn = 0
        details.screensaverEnabled = true
        details.packageCount = 214
        details.userPackageCount = 12

        // Relative to now, matching the uptime above: started 9 h 42 min ago, screen on for the last hour.
        func ago(_ hours: Int, _ minutes: Int) -> Date { Date().addingTimeInterval(-Double(hours * 3600 + minutes * 60)) }
        // A week of evenings before that, as the companion app would have kept them.
        var week: [Timeline.Event] = []
        let midnight = Calendar.current.startOfDay(for: Date())
        // Four weeks: evenings on weekdays, late mornings and afternoons at weekends.
        for day in 2...28 {
            let date = midnight.addingTimeInterval(Double(-day * 86_400))
            let weekend = [1, 7].contains(Calendar.current.component(.weekday, from: date))
            let start = date.addingTimeInterval(Double(weekend ? 10 + day % 3 : 18 + day % 3) * 3600)
            week.append(.init(date: start, kind: .screenOn))
            week.append(.init(date: start.addingTimeInterval(60), kind: .app(day % 2 == 0 ? "com.netflix.ninja" : "com.google.android.youtube.tv")))
            week.append(.init(date: start.addingTimeInterval(Double(weekend ? 4 + day % 3 : 2 + day % 3) * 3600), kind: .screenOff))
        }
        let timeline = Timeline.combine(week + [
            .init(date: ago(23, 30), kind: .screenOn),
            .init(date: ago(22, 0), kind: .app("com.netflix.ninja")),
            .init(date: ago(20, 30), kind: .screenOff),
            .init(date: ago(11, 0), kind: .screenOn),
            .init(date: ago(11, 0), kind: .app("com.google.android.apps.tv.launcherx")),
            .init(date: ago(10, 58), kind: .app("com.google.android.youtube.tv")),
            .init(date: ago(9, 50), kind: .shutdown),
            .init(date: ago(9, 42), kind: .startup),
            .init(date: ago(1, 12), kind: .screenOn),
            .init(date: ago(1, 11), kind: .app("com.android.tv.settings")),
            .init(date: ago(1, 6), kind: .app("com.google.android.youtube.tv")),
        ], bootDate: nil)
        return DashboardModel(sample: status, cpuUsage: 0.27, timeline: timeline, details: details,
                              transfers: [
                                  Transfer(name: "Holiday Photos.zip", kind: .send(folder: Adb.downloadFolder), state: .done),
                                  Transfer(name: "MediaPlayer-2.4.apk", kind: .install, state: .running),
                              ],
                              apps: .sample, files: .sample, cleanup: .sample, health: .sample,
                              companion: Companion.Info(version: "1.0", since: Date().addingTimeInterval(-20 * 86_400), events: 2_416,
                                                        usageAccess: true))
    }
}

extension AppsModel {
    static var sample: AppsModel {
        let mb: Int64 = 1_000_000
        func app(_ package: String, system: Bool = false, off: Bool = false, launcher: Bool = true, version: String?, days: Double,
                 size: Int64, data: Int64, cache: Int64) -> DeviceApp {
            DeviceApp(package: package, isSystem: system, isDisabled: off, launcher: launcher ? "\(package)/.Main" : nil,
                      versionCode: 1, versionName: version, updated: Date().addingTimeInterval(-days * 86_400),
                      appSize: size * mb, dataSize: data * mb, cacheSize: cache * mb)
        }
        return AppsModel(sample: [
            app("com.google.android.youtube.tv", version: "4.40.303", days: 3, size: 92, data: 147, cache: 48),
            app("com.netflix.ninja", version: "11.2.0", days: 12, size: 64, data: 38, cache: 12),
            app("org.videolan.vlc", version: "3.6.4", days: 40, size: 36, data: 2, cache: 1),
            app("com.spotify.tv.android", version: "1.92.0", days: 8, size: 48, data: 21, cache: 9),
            app("org.xbmc.kodi", version: "21.1", days: 90, size: 120, data: 310, cache: 4),
            app("com.example.weather", version: "2.3", days: 200, size: 14, data: 3, cache: 1),
            app("com.example.vendor.demo", system: true, off: true, version: nil, days: 500, size: 30, data: 0, cache: 0),
            app("com.android.tv.settings", system: true, version: nil, days: 500, size: 12, data: 4, cache: 0),
        ], protected: ["com.android.tv.settings"])
    }
}

extension FilesModel {
    static var sample: FilesModel {
        func item(_ name: String, folder: Bool, size: Int64 = 4096, days: Double) -> DeviceFile {
            DeviceFile(name: name, path: "/sdcard/\(name)", isFolder: folder, size: size,
                       modified: Date().addingTimeInterval(-days * 86_400))
        }
        let files = [
            item("Android", folder: true, days: 300), item("DCIM", folder: true, days: 2), item("Download", folder: true, days: 1),
            item("Movies", folder: true, days: 14), item("Music", folder: true, days: 60), item("Pictures", folder: true, days: 5),
            item("Holiday Photos.zip", folder: false, size: 182_000_000, days: 1),
            item("MediaPlayer-2.4.apk", folder: false, size: 28_400_000, days: 1),
            item("notes.txt", folder: false, size: 2_300, days: 30),
        ]
        let sizes: [String: Int64] = ["/sdcard/Android": 1_840_000_000, "/sdcard/DCIM": 92_000_000, "/sdcard/Download": 210_000_000,
                                      "/sdcard/Movies": 4_200_000_000, "/sdcard/Music": 640_000_000, "/sdcard/Pictures": 38_000_000]
        return FilesModel(sample: files, path: "/sdcard", sizes: sizes)
    }
}

extension CleanupModel {
    static var sample: CleanupModel {
        let mb: Int64 = 1_000_000
        return CleanupModel(sample: [
            CleanupCategory(kind: .appCaches, items: [
                CleanupItem(path: "com.google.android.youtube.tv", size: 48 * mb),
                CleanupItem(path: "com.netflix.ninja", size: 12 * mb),
                CleanupItem(path: "com.spotify.tv.android", size: 9 * mb),
            ], total: 412 * mb, selected: true),
            CleanupCategory(kind: .leftovers, items: [
                CleanupItem(path: "/sdcard/Android/data/com.example.oldgame", size: 860 * mb),
                CleanupItem(path: "/sdcard/Android/obb/com.example.oldgame", size: 1_240 * mb),
            ], selected: true),
            CleanupCategory(kind: .installers, items: [
                CleanupItem(path: "/sdcard/Download/MediaPlayer-2.3.apk", size: 27 * mb, modified: Date().addingTimeInterval(-60 * 86_400)),
            ], selected: true),
            CleanupCategory(kind: .thumbnails, items: [CleanupItem(path: "/sdcard/Pictures/.thumbnails", size: 18 * mb)], selected: true),
            CleanupCategory(kind: .largeFiles, items: [
                CleanupItem(path: "/sdcard/Movies/Concert.mkv", size: 3_900 * mb, modified: Date().addingTimeInterval(-14 * 86_400), selected: false),
            ], selected: false),
        ])
    }
}

extension HealthModel {
    static var sample: HealthModel {
        let mb: Int64 = 1_000_000
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        var health = DeviceHealth()
        health.usage = [
            DeviceHealth.Usage(uid: 10068, packages: ["com.google.android.youtube.tv"], day: 2_350 * mb, week: 14_800 * mb, month: 61_200 * mb),
            DeviceHealth.Usage(uid: 10071, packages: ["com.netflix.ninja"], day: 900 * mb, week: 7_400 * mb, month: 30_100 * mb),
            DeviceHealth.Usage(uid: 10090, packages: ["com.spotify.tv.android"], day: 120 * mb, week: 610 * mb, month: 2_400 * mb),
            DeviceHealth.Usage(uid: 1000, packages: [], day: 64 * mb, week: 420 * mb, month: 1_900 * mb),
            DeviceHealth.Usage(uid: 1020, packages: [], day: 38 * mb, week: 260 * mb, month: 1_100 * mb),
            DeviceHealth.Usage(uid: 2000, packages: [], day: 12 * mb, week: 40 * mb, month: 90 * mb),
            DeviceHealth.Usage(uid: 10095, packages: ["com.example.weather"], day: 2 * mb, week: 15 * mb, month: 60 * mb),
        ]
        health.crashes = [
            DeviceHealth.Crash(date: ago(3), kind: .appCrash, process: "com.example.weather"),
            DeviceHealth.Crash(date: ago(27), kind: .appFreeze, process: "com.example.weather"),
            DeviceHealth.Crash(date: ago(50), kind: .appCrash, process: "org.xbmc.kodi"),
            DeviceHealth.Crash(date: ago(200), kind: .nativeCrash, process: nil),
        ]
        health.wakeups = [
            DeviceHealth.Count(package: "android", count: 212), DeviceHealth.Count(package: "com.example.weather", count: 96),
            DeviceHealth.Count(package: "com.android.networkstack.inprocess", count: 30),
        ]
        health.exempt = ["org.xbmc.kodi"]
        health.systemExemptCount = 24
        health.recentJobs = [
            DeviceHealth.Count(package: "com.example.weather", count: 18), DeviceHealth.Count(package: "android", count: 9),
            DeviceHealth.Count(package: "com.google.android.youtube.tv", count: 4),
        ]
        health.recentJobsSince = ago(6)
        health.jobs = [
            DeviceHealth.Count(package: "android", count: 21), DeviceHealth.Count(package: "com.example.weather", count: 7),
            DeviceHealth.Count(package: "com.google.android.youtube.tv", count: 5), DeviceHealth.Count(package: "org.xbmc.kodi", count: 2),
        ]
        return HealthModel(sample: health)
    }
}

extension Monitor {
    /// Made-up readings for the menu bar panel.
    static var sample: Monitor {
        let monitor = Monitor(store: .sample)
        var tv = DeviceState()
        tv.name = "Living Room TV"
        tv.isTV = true
        tv.screen = .on
        tv.storageAvailable = 21_500_000_000
        tv.storageTotal = 32_000_000_000
        tv.screenOnToday = 2 * 3600 + 22 * 60
        var phone = DeviceState()
        phone.name = "Pixel Phone"
        phone.screen = .off
        phone.batteryLevel = 64
        phone.storageAvailable = 48_000_000_000
        phone.storageTotal = 128_000_000_000
        monitor.showForSnapshot(["192.168.1.42:5555": tv, "usb-sample": phone])
        return monitor
    }
}
