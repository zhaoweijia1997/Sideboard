import AppKit
import SwiftUI
import UserNotifications

@main
struct SideboardApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @AppStorage(AppSettings.backgroundModeKey) private var backgroundMode = false
    private let models = AppModels.shared
    /// Runs for reports and screenshots mustn't put an icon in the menu bar.
    private let commandLineRun = ["--status", "--watch", "--check", "--snapshot"].contains { CommandLine.arguments.contains($0) }

    var body: some Scene {
        Window("Sideboard", id: "main") {
            ContentView(store: models.store)
                .environment(\.locale, language.locale)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { DockIcon.windowOpened() }
                .onDisappear { DockIcon.windowClosed() }
        }
        .defaultSize(width: 1040, height: 780)

        WindowGroup(Text("Live Screen"), id: LiveScreenWindow.id, for: String.self) { $serial in
            if let serial {
                LiveScreenWindow(serial: serial)
                    .environment(\.locale, language.locale)
            }
        }
        .defaultSize(width: 960, height: 640)
        // No "New Live Screen Window" in the File menu: a live screen always belongs to a device.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(\.locale, language.locale)
        }

        // Only while "Run in the background with a menu bar icon" is on.
        MenuBarExtra(isInserted: commandLineRun ? .constant(false) : $backgroundMode) {
            MenuBarPanel(store: models.store, monitor: models.monitor)
                .environment(\.locale, language.locale)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.register()
        // Sideboard.app/Contents/MacOS/Sideboard --status: what Sideboard reads from each connected
        // device, as text, for bug reports. Shows no serial numbers, addresses or names of networks.
        if CommandLine.arguments.contains("--status") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await StatusReport.print()
                done.signal()
            }
            done.wait()
            exit(0)
        }
        // Sideboard.app/Contents/MacOS/Sideboard --watch: runs the device list and dashboards as the
        // window does, for 20 seconds, and prints what they saw. No serial numbers or addresses.
        if CommandLine.arguments.contains("--watch") {
            Task { @MainActor in
                await StatusReport.watch()
                exit(0)
            }
            return
        }
        // Sideboard.app/Contents/MacOS/Sideboard --check: one round of the background monitor with every
        // notification switched on, printing what it would send instead of sending it.
        if CommandLine.arguments.contains("--check") {
            Task { @MainActor in
                await StatusReport.check()
                exit(0)
            }
            return
        }
        // Sideboard.app/Contents/MacOS/Sideboard --snapshot <folder>
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? "."
            MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: folder)) }
            exit(0)
        }

        if Monitor.canNotify { UNUserNotificationCenter.current().delegate = self }
        // "Open on Android Device" in the Services menu of other apps.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        MainActor.assumeIsolated {
            AppModels.shared.store.start()
            AppModels.shared.monitor.start()
        }
        if AppSettings.backgroundMode {
            Task { _ = await Monitor.requestPermission() }
        }
        if LoginItem.launchedAtLogin && AppSettings.backgroundMode {
            // Opened at login: stay quietly in the menu bar.
            DispatchQueue.main.async {
                NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            // Behave like a normal windowed app when started with `swift run`, too.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A recording still running is finished and saved first, so its file isn't left on the device.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorders = MainActor.assumeIsolated { AppModels.shared.store.allDashboards.map(\.recorder).filter(\.isBusy) }
        guard !recorders.isEmpty else { return .terminateNow }
        Task { @MainActor in
            await ScreenRecorder.finishAll(recorders)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        LiveStream.stopAll()
    }

    /// In background mode, closing the window keeps Sideboard in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.backgroundMode
    }

    /// Opening Sideboard again (Dock, Finder) while it runs in the background shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    // MARK: Services menu

    /// Services → "Open on Android Device": opens the selected link on the device chosen in the
    /// window, or on the only one connected.
    @objc func openOnDevice(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let link = (pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty else { return }
        Task { @MainActor in
            let store = AppModels.shared.store
            // When the service started Sideboard, give adb a moment to find the devices.
            for _ in 0..<12 where !store.connected.contains(where: { $0.state == .online }) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let online = store.connected.filter { $0.state == .online }
            guard let device = online.first(where: { $0.serial == store.selection }) ?? online.first else {
                Monitor.post(title: "Sideboard", body: String(localized: "No device is connected, so the link wasn't opened."))
                return
            }
            if let failure = await store.dashboard(for: device.serial).openLink(link) {
                Monitor.post(title: device.model ?? "Sideboard", body: failure)
            }
        }
    }

    // MARK: Notifications

    /// Shown even while Sideboard is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking one opens the window on that device.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let serial = response.notification.request.content.userInfo["serial"] as? String
        await MainActor.run {
            if let serial { AppModels.shared.store.selection = serial }
            AppDelegate.showWindow()
        }
    }

    /// Reopens the window even when it was closed (in background mode).
    @MainActor
    static func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}

enum StatusReport {
    /// One monitor round with all notifications on (only for this run), printing them.
    @MainActor
    static func check() async {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in [AppSettings.alertLateNightKey, AppSettings.alertLongSessionKey, AppSettings.alertStorageKey,
                    AppSettings.alertHotKey, AppSettings.alertBatteryKey, AppSettings.alertAppsKey, AppSettings.alertOfflineKey] {
            arguments[key] = true
        }
        // "Late" from this very hour, and a long stretch after an hour, so those show up too.
        arguments[AppSettings.lateNightHourKey] = Calendar.current.component(.hour, from: Date()) < 6
            ? Calendar.current.component(.hour, from: Date()) : 0
        arguments[AppSettings.longSessionHoursKey] = 1
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let store = DeviceStore()
        store.start()
        try? await Task.sleep(for: .seconds(4))
        let monitor = Monitor(store: store)
        monitor.dryRun = true
        await monitor.tick(force: true)
        for (serial, state) in monitor.states.sorted(by: { $0.key < $1.key }) {
            let kind = store.connected.first { $0.serial == serial }?.isNetwork == true ? "network" : "USB"
            Swift.print("""
            \(state.name ?? "?") (\(kind)): screen \(state.screen.map { "\($0)" } ?? "?"), on today \(Int(state.screenOnToday ?? -60) / 60) min, \
            on since \(state.screenOnSince.map { "\($0)" } ?? "-"), storage \(state.storageAvailable ?? 0)/\(state.storageTotal ?? 0), \
            battery \(state.batteryLevel.map(String.init) ?? "-"), thermal \(state.thermalStatus.map(String.init) ?? "-")
            """)
        }
        // A second round sees the app list again, as the first one only learned it.
        Swift.print("(apps installed or removed are reported from the second look on)")
    }

    @MainActor
    static func watch() async {
        let store = DeviceStore()
        store.start()
        try? await Task.sleep(for: .seconds(5))
        Swift.print("adb: \(store.adbState), \(store.entries.count) device(s)")
        let online = store.entries.filter { $0.state == .online }
        let dashboards = online.map { store.dashboard(for: $0.id) }
        dashboards.forEach { $0.start() }
        dashboards.forEach { $0.startDetails() }
        for second in stride(from: 5, through: 15, by: 5) {
            try? await Task.sleep(for: .seconds(5))
            for (entry, model) in zip(online, dashboards) {
                let status = model.status
                Swift.print("""
                \(second)s \(entry.name ?? "?") (\(entry.isNetwork ? "network" : "USB"), TV \(entry.isTV)): \
                screen \(status?.screen.map { "\($0)" } ?? "?"), CPU \(model.cpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "?"), \
                timeline \(model.timeline?.events.count ?? -1) events, details \(model.details?.processes.count ?? -1) processes, \
                unreachable \(model.unreachable)
                """)
            }
        }
        dashboards.forEach { $0.stop() }
    }

    static func print() async {
        guard let adb = Adb.locate() else {
            Swift.print("adb not found")
            return
        }
        await adb.startServer()
        let devices = await adb.devices() ?? []
        Swift.print("\(devices.count) device(s)")
        for (number, device) in devices.enumerated() {
            Swift.print("\nDevice \(number + 1): \(device.model ?? "?"), \(device.isNetwork ? "network" : "USB"), \(device.state)")
            guard device.state == .online else { continue }
            guard let output = await adb.shell(device.serial, DeviceStatus.command) else {
                Swift.print("  status: no answer")
                continue
            }
            var status = DeviceStatus.parse(output)
            try? await Task.sleep(for: .seconds(1))
            var usage: Double?
            if let line = await adb.shell(device.serial, "head -1 /proc/stat"), let second = CPUSample(line: line), let first = status.cpu {
                usage = second.usage(since: first)
            }
            // Addresses are left out of the report.
            let networks = status.addresses.map { "\($0.interface) (\($0.kind))" }
            status.addresses = []
            Swift.print("""
              \(status.manufacturer ?? "?") \(status.model ?? "?"), Android \(status.androidVersion ?? "?"), TV: \(status.isTV)
              screen \(status.screen.map { "\($0)" } ?? "?"), foreground \(status.foreground ?? "?"), home \(status.home ?? "?")
              media \(status.media.map { "\($0.package) \($0.playback) \($0.title ?? "")" } ?? "none")
              volume \(status.volume.map(String.init) ?? "?")/\(status.volumeMax.map(String.init) ?? "?")
              uptime \(Int(status.uptime ?? 0) / 60) min, CPU \(usage.map { String(format: "%.0f%%", $0 * 100) } ?? "?"), \(status.cores ?? 0) cores at \(Int(status.cpuFrequency ?? 0))/\(Int(status.cpuMaxFrequency ?? 0)) MHz
              memory \(status.memoryAvailable ?? 0) free of \(status.memoryTotal ?? 0), storage \(status.storageAvailable ?? 0) free of \(status.storageTotal ?? 0)
              networks \(networks.joined(separator: ", ")), thermal status \(status.thermalStatus.map(String.init) ?? "?"), temperature \(status.temperature.map { String(format: "%.1f", $0) } ?? "none")
              battery \(status.batteryLevel.map { "\($0)%\(status.charging ? " charging" : "")" } ?? "none"), time zone \(status.timeZone?.identifier ?? "?")
            """)

            if let output = await adb.shell(device.serial, DeviceDetails.command, timeout: 30) {
                let details = DeviceDetails.parse(output)
                Swift.print("""
                  details: \(details.brand ?? "?") / \(details.device ?? "?"), API \(details.sdk ?? 0), patch \(details.securityPatch ?? "?"), chip \(details.chipset ?? "?"), \(details.architecture ?? "?"), kernel \(details.kernel ?? "?")
                  display \(details.screenSize ?? "?") (apps \(details.renderSize ?? "same")), \(details.density ?? 0) dpi, \(details.refreshRate ?? 0) Hz
                  governor \(details.governor ?? "?"), load \(details.loadAverage), swap \(details.swapTotal ?? 0), apps \(details.packageCount ?? 0) (\(details.userPackageCount ?? 0) user)
                  volumes \(details.volumes.map { "\($0.mount) \($0.available)/\($0.total)" }), Wi-Fi \(details.wifi.map { "signal \($0.signal ?? 0) dBm, \($0.linkSpeed ?? 0) Mbps, \($0.frequency ?? 0) MHz" } ?? "none")
                  timeouts: screen off \(details.screenOffTimeout ?? -1) ms, sleep \(details.sleepTimeout ?? -1) ms, no input \(details.attentiveTimeout ?? -1) ms, stay on \(details.stayOnWhilePluggedIn ?? -1), screensaver \(details.screensaverEnabled.map { "\($0)" } ?? "?")
                  busiest: \(details.processes.prefix(5).map { "\($0.name) \($0.cpu)%" }.joined(separator: ", "))
                """)
            }

            if let info = await Companion.info(adb, device.serial) {
                let labels = await Companion.labels(adb, device.serial)
                let history = await Companion.events(adb, device.serial, since: Date().addingTimeInterval(-91 * 86_400))
                Swift.print("  companion: version \(info.version), \(info.events) events since \(info.since.map { "\($0)" } ?? "?"), usage access \(info.usageAccess), \(labels.count) app names, \(history.count) events read")
            } else {
                Swift.print("  companion: not installed")
            }
            if let output = await adb.shell(device.serial, AppList.command, timeout: 60) {
                let result = AppList.parse(output, timeZone: status.timeZone ?? .current)
                let apps = result.apps
                Swift.print("""
                  apps: \(apps.count) (\(apps.filter { !$0.isSystem }.count) added, \(apps.filter(\.isDisabled).count) off, \
                \(apps.filter { $0.launcher != nil }.count) with a launcher, \(apps.filter { $0.totalSize != nil }.count) with sizes, \
                \(apps.filter { $0.versionName != nil }.count) with versions), protected \(result.protected.intersection(apps.map(\.package)).count)
                """)
            }
            if let output = await adb.shell(device.serial, "stat -c '%F|%s|%Y|%n' -- /sdcard/* 2>/dev/null; true") {
                Swift.print("  shared storage: \(output.split(separator: "\n").count) entries at the top")
            }
            if let output = await adb.shell(device.serial, CleanupScan.command, timeout: 300) {
                let categories = CleanupScan.parse(output)
                Swift.print("  cleanup: " + categories.map { "\($0.kind) \($0.items.count) items \($0.size / 1_000_000) MB" }.joined(separator: ", "))
            }
            if let output = await adb.shell(device.serial, DeviceHealth.command, timeout: 90) {
                let health = DeviceHealth.parse(output, timeZone: status.timeZone ?? .current)
                let week = health.crashes.filter { Date().timeIntervalSince($0.date) <= 7 * 86_400 }.count
                Swift.print("""
                  health: \(health.crashes.count) crashes on record (\(week) in 7 days), \(health.usage.count) apps with data usage, \
                \(health.wakeups.count) apps woke it, \(health.jobs.map(\.count).reduce(0, +)) jobs scheduled, \
                \(health.recentJobs.map(\.count).reduce(0, +)) ran since \(health.recentJobsSince.map { "\($0)" } ?? "?"), \
                \(health.exempt.count) user + \(health.systemExemptCount) system exempt from battery saving
                    top data (24 h / 7 d / 30 d MB): \(health.usage.prefix(4).map { "\($0.packages.first ?? "uid \($0.uid)") \($0.day / 1_000_000)/\($0.week / 1_000_000)/\($0.month / 1_000_000)" }.joined(separator: ", "))
                    top wakeups: \(health.wakeups.prefix(3).map { "\($0.package) \($0.count)" }.joined(separator: ", "))
                    latest crash: \(health.crashes.first.map { "\($0.date) \($0.kind) \($0.package ?? "-")" } ?? "none")
                """)
            }
            if let output = await adb.shell(device.serial, Timeline.command, timeout: 30) {
                let timeline = Timeline.parse(output, timeZone: status.timeZone ?? .current, bootDate: status.bootDate)
                let today = Calendar.current.startOfDay(for: Date())
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                Swift.print("  timeline: \(timeline.events.count) events, screen on today \(Int(timeline.screenOnTime(from: today, to: Date(), screenIsOn: status.screen == .on)) / 60) min")
                for event in timeline.events.suffix(12) {
                    Swift.print("    \(formatter.string(from: event.date)) \(event.kind)")
                }
                Swift.print("  app time today: \(timeline.appTime(from: today, to: Date()).map { "\($0.package) \(Int($0.time) / 60) min" }.joined(separator: ", "))")
            }
        }
    }
}
