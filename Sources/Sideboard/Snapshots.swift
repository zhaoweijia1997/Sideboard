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
                ("overview", .sample, .overview, 1060),
                ("details", .sample, .details, 1400),
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
        let timeline = Timeline(events: [
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
        ])
        return DashboardModel(sample: status, cpuUsage: 0.27, timeline: timeline, details: details,
                              transfers: [
                                  Transfer(name: "Holiday Photos.zip", kind: .send, state: .done),
                                  Transfer(name: "MediaPlayer-2.4.apk", kind: .install, state: .running),
                              ])
    }
}
