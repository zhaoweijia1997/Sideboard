import AppKit
import Foundation
import Observation
import UserNotifications

/// Watches the devices while Sideboard runs, with the window closed too (background mode), keeps
/// their history on this Mac and sends the notifications chosen in Settings. Light on the devices:
/// a quick look every 5 minutes while the screen is on and every 30 while it's off, nothing that
/// keeps them awake, and nothing at all for a device whose page is open (it reads already).
@MainActor @Observable
final class Monitor {
    struct DeviceState: Equatable {
        var name: String?
        var isTV = false
        var screen: DeviceStatus.Screen?
        var storageAvailable: Int64?
        var storageTotal: Int64?
        var batteryLevel: Int?
        var charging = false
        var thermalStatus: Int?
        var checked: Date?
        /// When the screen came on, as far as the history tells.
        var screenOnSince: Date?
        var screenOnToday: TimeInterval?

        var isAwake: Bool { screen == .on || screen == .screensaver }
    }

    private(set) var states: [String: DeviceState] = [:]
    /// Printed instead of sent, for `--check`.
    var dryRun = false

    private let store: DeviceStore
    private var loop: Task<Void, Never>?
    private var memory: [String: Memory] = [:]
    private var packages: [String: Set<String>] = [:]
    private var lastHistory: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var checking = false

    static let awakeInterval: TimeInterval = 300
    static let asleepInterval: TimeInterval = 1800
    static let historyInterval: TimeInterval = 3 * 3600

    /// What has been notified, so each notification comes once until things change.
    private struct Memory {
        var lateNight: Date?
        var longSession = false
        var storage = false
        var hot = false
        var battery = false
        var offline = false
    }

    init(store: DeviceStore) {
        self.store = store
    }

    /// Made-up readings for screenshots.
    func showForSnapshot(_ states: [String: DeviceState]) {
        self.states = states
    }

    func start() {
        guard loop == nil, store.isLive else { return }
        loop = Task { [weak self] in
            // Give adb a moment to list the devices.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// One round: every device whose next look is due.
    func tick(force: Bool = false) async {
        guard let adb = store.adbHandle, !checking else { return }
        checking = true
        defer { checking = false }
        let now = Date()
        let online = store.connected.filter { $0.state == .online }
        for device in online {
            lastSeen[device.serial] = now
            await check(device, adb: adb, now: now, force: force)
        }
        checkOffline(online: Set(online.map(\.serial)), now: now)
    }

    // MARK: One device

    static let command = [
        "cat /proc/uptime",
        "echo @@power", "dumpsys power | grep -E 'mWakefulness='",
        "echo @@df", "df /data 2>/dev/null | tail -1",
        "echo @@battery", "dumpsys battery | grep -E '^  (present|level|status):'",
        "echo @@thermal", "dumpsys thermalservice 2>/dev/null | grep -E 'Thermal Status:'",
        "echo @@props", "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release",
        "getprop persist.sys.timezone; getprop ro.build.characteristics",
        "true",
    ].joined(separator: "; ")

    private func check(_ device: Adb.Device, adb: Adb, now: Date, force: Bool) async {
        let serial = device.serial
        let previous = states[serial]
        let interval = previous?.isAwake == true ? Self.awakeInterval : Self.asleepInterval
        if !force, let checked = previous?.checked, now.timeIntervalSince(checked) < interval { return }

        // The device's page reads every few seconds while it's open: use that.
        let status: DeviceStatus
        if let dashboard = store.existingDashboard(serial), dashboard.isRunning, let fresh = dashboard.status,
           let read = dashboard.lastRead, now.timeIntervalSince(read) < 90 {
            status = fresh
        } else {
            guard let output = await adb.shell(serial, Self.command, timeout: 15) else { return }
            status = DeviceStatus.parse(output)
        }

        var state = DeviceState()
        state.name = device.model ?? status.model
        state.isTV = status.isTV
        state.screen = status.screen
        state.storageAvailable = status.storageAvailable
        state.storageTotal = status.storageTotal
        state.batteryLevel = status.batteryLevel
        state.charging = status.charging
        state.thermalStatus = status.thermalStatus
        state.checked = now
        state.screenOnSince = previous?.screenOnSince
        state.screenOnToday = previous?.screenOnToday

        // History: every few hours while awake (Android keeps 24 hours; this keeps it all).
        if state.isAwake, force || now.timeIntervalSince(lastHistory[serial] ?? .distantPast) >= Self.historyInterval {
            lastHistory[serial] = now
            if let timeline = await collectHistory(serial, adb: adb, status: status) {
                state.screenOnToday = timeline.screenOnTime(from: Calendar.current.startOfDay(for: now), to: now,
                                                            screenIsOn: state.screen == .on)
                state.screenOnSince = timeline.events.last { [.screenOn, .startup].contains($0.kind) }?.date
            }
        }
        // Asleep clears it, so waking up starts a new stretch (unless the history knew better).
        if !state.isAwake {
            state.screenOnSince = nil
        } else if state.screenOnSince == nil {
            state.screenOnSince = now
        }

        // New or removed apps: only while awake (listing them runs a small Java process).
        if state.isAwake, AppSettings.flag(AppSettings.alertAppsKey),
           let output = await adb.shell(serial, "pm list packages 2>/dev/null; true") {
            let current = Set(output.split(separator: "\n").compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)) : nil })
            if let before = packages[serial], !current.isEmpty, before != current {
                announceApps(added: current.subtracting(before), removed: before.subtracting(current), serial: serial, name: state.name)
            }
            if !current.isEmpty { packages[serial] = current }
        }

        states[serial] = state
        evaluate(serial: serial, state: state, now: now)
    }

    /// Android's last 24 hours, plus the companion app's history when it's installed, into the history store.
    private func collectHistory(_ serial: String, adb: Adb, status: DeviceStatus) async -> Timeline? {
        guard let key = await HistoryStore.shared.key(for: serial, adb: adb) else { return nil }
        var events: [Timeline.Event] = []
        if let output = await adb.shell(serial, Timeline.command, timeout: 30) {
            events = Timeline.events(from: output, timeZone: status.timeZone ?? .current)
        }
        if await Companion.info(adb, serial) != nil {
            let since = HistoryStore.shared.stored(key).last?.date.addingTimeInterval(-3600) ?? Date().addingTimeInterval(-91 * 86_400)
            events += await Companion.events(adb, serial, since: since)
        }
        return Timeline.combine(HistoryStore.shared.merge(events, key: key), bootDate: status.bootDate)
    }

    // MARK: Notifications

    private func evaluate(serial: String, state: DeviceState, now: Date) {
        var memory = memory[serial] ?? Memory()
        let name = state.name ?? String(localized: "Android device")
        let formats = Formats(locale: .current)

        if AppSettings.flag(AppSettings.alertLateNightKey), state.screen == .on, let night = Self.night(of: now) {
            if memory.lateNight != night {
                memory.lateNight = night
                let time = formats.time(now)
                if let since = state.screenOnSince {
                    let start = formats.time(since)
                    send(name, String(localized: "Still on at \(time). The screen has been on since \(start)."), serial)
                } else {
                    send(name, String(localized: "Still on at \(time)."), serial)
                }
            }
        }

        let hours = max(1, AppSettings.number(AppSettings.longSessionHoursKey))
        if state.screen == .on, let since = state.screenOnSince, now.timeIntervalSince(since) >= Double(hours) * 3600 {
            if AppSettings.flag(AppSettings.alertLongSessionKey), !memory.longSession {
                let length = formats.duration(now.timeIntervalSince(since))
                send(name, String(localized: "The screen has been on for \(length) in a row."), serial)
            }
            memory.longSession = true
        } else if state.screen != .on {
            memory.longSession = false
        }

        if let free = state.storageAvailable, let total = state.storageTotal, total > 0 {
            let fraction = Double(free) / Double(total)
            if fraction < 0.10 {
                if AppSettings.flag(AppSettings.alertStorageKey), !memory.storage {
                    send(name, String(localized: "Storage is almost full: \(formats.bytes(free)) free."), serial)
                }
                memory.storage = true
            } else if fraction > 0.15 {
                memory.storage = false
            }
        }

        if let level = state.thermalStatus {
            if level >= 2 {
                if AppSettings.flag(AppSettings.alertHotKey), !memory.hot {
                    send(name, String(localized: "It's running hot (level \(level))."), serial)
                }
                memory.hot = true
            } else if level == 0 {
                memory.hot = false
            }
        }

        if let level = state.batteryLevel {
            if level <= 15, !state.charging {
                if AppSettings.flag(AppSettings.alertBatteryKey), !memory.battery {
                    let percent = formats.percent(Double(level) / 100)
                    send(name, String(localized: "Battery is low: \(percent)."), serial)
                }
                memory.battery = true
            } else if state.charging || level > 20 {
                memory.battery = false
            }
        }

        if memory.offline {
            memory.offline = false
            if AppSettings.flag(AppSettings.alertOfflineKey) {
                send(name, String(localized: "It's answering again."), serial)
            }
        }
        self.memory[serial] = memory
    }

    /// A device that was on and stopped answering for 10 minutes. Devices switched off normally
    /// (screen off or standby first) don't count.
    private func checkOffline(online: Set<String>, now: Date) {
        for (serial, state) in states where !online.contains(serial) {
            guard state.isAwake, let seen = lastSeen[serial], now.timeIntervalSince(seen) >= 600 else { continue }
            var memory = memory[serial] ?? Memory()
            if !memory.offline {
                memory.offline = true
                if AppSettings.flag(AppSettings.alertOfflineKey) {
                    let time = Formats(locale: .current).time(seen)
                    send(state.name ?? String(localized: "Android device"),
                         String(localized: "It stopped answering at \(time) while its screen was on."), serial)
                }
            }
            self.memory[serial] = memory
        }
    }

    private func announceApps(added: Set<String>, removed: Set<String>, serial: String, name: String?) {
        let labels = store.existingDashboard(serial)?.labels ?? [:]
        func names(_ packages: Set<String>) -> String {
            packages.sorted().prefix(5).map { AppNames.name(for: $0, labels: labels) ?? $0 }.joined(separator: ", ")
                + (packages.count > 5 ? " …" : "")
        }
        let title = name ?? String(localized: "Android device")
        if !added.isEmpty { send(title, String(localized: "Installed: \(names(added))"), serial) }
        if !removed.isEmpty { send(title, String(localized: "Removed: \(names(removed))"), serial) }
    }

    /// The evening a late-night moment belongs to, or nil outside the late hours (until 6:00).
    static func night(of date: Date, from hour: Int = AppSettings.number(AppSettings.lateNightHourKey)) -> Date? {
        let calendar = Calendar.current
        let now = calendar.component(.hour, from: date)
        let late = hour >= 12 ? (now >= hour || now < 6) : (now >= hour && now < 6)
        guard late else { return nil }
        let day = calendar.startOfDay(for: date)
        return now < 12 ? calendar.date(byAdding: .day, value: -1, to: day) : day
    }

    // MARK: Sending

    private func send(_ title: String, _ body: String, _ serial: String) {
        if dryRun {
            Swift.print("  would notify: \(title): \(body)")
            return
        }
        Self.post(title: title, body: body, serial: serial)
    }

    /// Only a real app bundle may use the notification center (not `swift run` builds).
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func post(title: String, body: String, serial: String? = nil) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let serial { content.userInfo = ["serial": serial] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func requestPermission() async -> Bool {
        guard canNotify else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func permission() async -> UNAuthorizationStatus {
        guard canNotify else { return .notDetermined }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
