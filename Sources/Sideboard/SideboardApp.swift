import AppKit
import SwiftUI

@main
struct SideboardApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var store = DeviceStore()

    var body: some Scene {
        Window("Sideboard", id: "main") {
            ContentView(store: store)
                .environment(\.locale, language.locale)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1000, height: 760)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        // Sideboard.app/Contents/MacOS/Sideboard --snapshot <folder>
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? "."
            MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: folder)) }
            exit(0)
        }
        // Behave like a normal windowed app when started with `swift run`, too.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum StatusReport {
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
