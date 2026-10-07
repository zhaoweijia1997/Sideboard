import AppKit
import Foundation
import Observation

/// Android key codes for the remote.
enum RemoteKey: Int, CaseIterable {
    case home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, ok = 23
    case volumeUp = 24, volumeDown = 25, power = 26, menu = 82, playPause = 85
    case mute = 164, recentApps = 187, sleep = 223, wake = 224
}

/// A file going to or coming from the device, or an app being installed.
struct Transfer: Identifiable, Equatable {
    enum Kind: Equatable {
        case install
        /// Into a folder on the device.
        case send(folder: String)
        /// To this full path on the Mac.
        case receive(from: String, to: URL)
    }
    enum State: Equatable {
        case waiting, running, done, failed(String)

        var isFinished: Bool {
            switch self {
            case .done, .failed: true
            case .waiting, .running: false
            }
        }
    }

    let id = UUID()
    let name: String
    let kind: Kind
    var state: State = .waiting
}

/// One device's dashboard. Reads often while the screen is on and the window is open, and
/// rarely while the device sleeps, so it can rest. Never changes any setting on the device.
@MainActor @Observable
final class DashboardModel {
    let serial: String
    private(set) var status: DeviceStatus?
    private(set) var cpuUsage: Double?
    private(set) var timeline: Timeline?
    private(set) var details: DeviceDetails?
    private(set) var readingDetails = false
    /// When the status was last read; the monitor reuses fresh readings.
    private(set) var lastRead: Date?
    var isRunning: Bool { statusTask != nil }
    private(set) var unreachable = false
    var transfers: [Transfer] = []
    /// Counts finished transfers, so the Files page can reload after an upload.
    private(set) var finishedTransfers = 0
    var onStatus: ((DeviceStatus) -> Void)?
    let apps: AppsModel
    let files: FilesModel
    let cleanup: CleanupModel
    let health: HealthModel
    let recorder: ScreenRecorder
    private(set) var companion: Companion.Info?
    private(set) var companionChecked = false
    private(set) var companionBusy = false
    var companionFailure: String?
    /// App names and icons from the companion app.
    private(set) var labels: [String: String] = [:]
    private(set) var icons: [String: NSImage] = [:]

    private let adb: Adb?
    private let live: Bool
    private var statusTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var refreshing = false
    private var lastTimeline = Date.distantPast
    /// From Android's usage history (24 hours) and from the companion app (90 days).
    private var recentEvents: [Timeline.Event] = []
    private var history: [Timeline.Event] = []

    static let awakeInterval: Double = 5
    /// While the screen is off: just enough to notice it coming back on.
    static let asleepInterval: Double = 60

    init(serial: String, adb: Adb?) {
        self.serial = serial
        self.adb = adb
        live = true
        apps = AppsModel(adb: adb, serial: serial)
        files = FilesModel(adb: adb, serial: serial)
        cleanup = CleanupModel(adb: adb, serial: serial)
        health = HealthModel(adb: adb, serial: serial)
        recorder = ScreenRecorder(adb: adb, serial: serial)
    }

    /// Made-up readings for screenshots.
    init(sample status: DeviceStatus, cpuUsage: Double, timeline: Timeline, details: DeviceDetails, transfers: [Transfer] = [],
         apps: AppsModel, files: FilesModel, cleanup: CleanupModel, health: HealthModel, companion: Companion.Info? = nil) {
        serial = "sample"
        adb = nil
        live = false
        self.apps = apps
        self.files = files
        self.cleanup = cleanup
        self.health = health
        recorder = ScreenRecorder(adb: nil, serial: "sample")
        self.companion = companion
        companionChecked = true
        self.status = status
        self.cpuUsage = cpuUsage
        self.timeline = timeline
        self.details = details
        self.transfers = transfers
    }

    var isAwake: Bool { status?.screen == .on || status?.screen == .screensaver }

    // MARK: Reading

    func start() {
        guard live, statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.refresh() else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        statusTask?.cancel()
        statusTask = nil
        stopDetails()
    }

    /// Reads the status and, now and then, the timeline. Returns when to read again.
    @discardableResult
    func refresh() async -> Double {
        guard let adb, !refreshing else { return Self.awakeInterval }
        refreshing = true
        defer { refreshing = false }

        var readEverything = true
        if let previous = status, !isAwake {
            // Asleep: only check whether it woke up.
            guard let output = await adb.shell(serial, Self.sleepCheck, timeout: 10) else {
                unreachable = true
                return Self.asleepInterval
            }
            unreachable = false
            let check = DeviceStatus.parse(output)
            var status = previous
            status.screen = check.screen ?? previous.screen
            status.uptime = check.uptime ?? previous.uptime
            self.status = status
            readEverything = isAwake
        }
        if readEverything {
            guard let output = await adb.shell(serial, DeviceStatus.command, timeout: 15) else {
                unreachable = true
                return isAwake ? Self.awakeInterval : Self.asleepInterval
            }
            unreachable = false
            let status = DeviceStatus.parse(output)
            lastRead = Date()
            if let sample = status.cpu, let previous = self.status?.cpu {
                cpuUsage = sample.usage(since: previous)
            }
            self.status = status
            onStatus?(status)
            if cpuUsage == nil, let first = status.cpu {
                // The first reading: sample again a second later, rather than show nothing for 5 seconds.
                try? await Task.sleep(for: .seconds(1))
                if let line = await adb.shell(serial, "head -1 /proc/stat"), let second = CPUSample(line: line) {
                    cpuUsage = second.usage(since: first)
                    self.status?.cpu = second
                }
            }
        }

        // Asleep, little happens: every half hour is plenty, and it leaves the companion app alone.
        let timelineInterval: Double = isAwake ? 120 : 1800
        if Date().timeIntervalSince(lastTimeline) > timelineInterval {
            lastTimeline = Date()
            await refreshCompanion()
            if let output = await adb.shell(serial, Timeline.command, timeout: 30) {
                recentEvents = Timeline.events(from: output, timeZone: status?.timeZone ?? .current)
            }
            if companion != nil {
                // The first time all 90 days, then only what's new (with an hour of overlap).
                let since = history.last.map { $0.date.addingTimeInterval(-3600) } ?? Date().addingTimeInterval(-91 * 86_400)
                let new = await Companion.events(adb, serial, since: since)
                history = history.filter { $0.date < since } + new
            }
            await rebuildTimeline()
        }
        return isAwake ? Self.awakeInterval : Self.asleepInterval
    }

    /// Android's 24 hours and the companion's history, added to what this Mac has kept.
    private func rebuildTimeline() async {
        var events = history + recentEvents
        if let adb, let key = await HistoryStore.shared.key(for: serial, adb: adb) {
            events = HistoryStore.shared.merge(events, key: key)
        }
        timeline = Timeline.combine(events, bootDate: status?.bootDate)
    }

    // MARK: Companion app

    /// Whether the companion app is installed, and what it has recorded. Names are read once.
    func refreshCompanion() async {
        guard let adb else { return }
        companion = await Companion.info(adb, serial)
        companionChecked = true
        if companion != nil, labels.isEmpty {
            labels = await Companion.labels(adb, serial)
        }
    }

    /// Icons for the Apps page, read once when it opens.
    func loadIcons() async {
        guard let adb, companion != nil, icons.isEmpty else { return }
        icons = await Companion.icons(adb, serial)
    }

    func installCompanion() async {
        guard let adb, !companionBusy else { return }
        companionBusy = true
        defer { companionBusy = false }
        if let error = await Companion.install(adb, serial) {
            companionFailure = error
            return
        }
        await refreshCompanion()
        lastTimeline = .distantPast
        await refresh()
    }

    func allowCompanionUsageAccess() async {
        guard let adb else { return }
        await Companion.allowUsageAccess(adb, serial)
        await refreshCompanion()
    }

    func uninstallCompanion() async {
        guard let adb, !companionBusy else { return }
        companionBusy = true
        defer { companionBusy = false }
        if let error = await Companion.uninstall(adb, serial) {
            companionFailure = error
        }
        history = []
        labels = [:]
        icons = [:]
        await refreshCompanion()
        await rebuildTimeline()
    }

    func typingSession() -> TypingSession? {
        guard let adb, companion != nil else { return nil }
        return TypingSession(adb: adb, serial: serial)
    }

    static let sleepCheck = "cat /proc/uptime; echo @@power; dumpsys power | grep -E 'mWakefulness='; true"

    /// While the Details page is open. Processes are sampled every 10 seconds while the screen
    /// is on; asleep, the page is read once.
    func startDetails() {
        guard live, detailsTask == nil else { return }
        detailsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.readDetails()
                repeat {
                    try? await Task.sleep(for: .seconds(10))
                } while !Task.isCancelled && !self.isAwake
            }
        }
    }

    func stopDetails() {
        detailsTask?.cancel()
        detailsTask = nil
    }

    func readDetails() async {
        guard let adb else { return }
        readingDetails = true
        if let output = await adb.shell(serial, DeviceDetails.command, timeout: 30) {
            details = DeviceDetails.parse(output)
        }
        readingDetails = false
    }

    // MARK: Actions (only when you click)

    func press(_ key: RemoteKey) {
        guard let adb else { return }
        Task {
            await adb.press(serial, key: key.rawValue)
            // Show the effect (screen on, volume) without waiting for the next reading.
            if [.power, .sleep, .wake, .volumeUp, .volumeDown, .mute, .playPause].contains(key) {
                try? await Task.sleep(for: .seconds(0.8))
                await refresh()
            }
        }
    }

    /// Opens a web link (or any link an app on the device handles) in the device's browser or app.
    /// Returns nil when it opened, otherwise why not.
    func openLink(_ text: String) async -> String? {
        guard let adb else { return String(localized: "The device didn't answer.") }
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !link.contains("\n") else { return String(localized: "That doesn't look like a link.") }
        if !link.contains(":") { link = "https://" + link }
        guard let output = await adb.shellOutput(serial, "am start -a android.intent.action.VIEW -d \(Adb.quote(link))") else {
            return String(localized: "The device didn't answer.")
        }
        if output.contains("unable to resolve Intent") || output.contains("No Activity found") {
            return String(localized: "No app on the device can open this link.")
        }
        return output.contains("Error") ? output : nil
    }

    /// The screen, live, for a window of its own.
    func liveScreen() -> LiveScreen {
        LiveScreen(adb: adb, serial: serial)
    }

    /// PNG data.
    func screenshot() async -> Data? {
        await adb?.screenshot(serial)
    }

    /// APKs are installed; everything else goes into the device's Download folder.
    func send(_ urls: [URL]) {
        for url in urls {
            enqueue(Transfer(name: url.lastPathComponent,
                             kind: url.pathExtension.lowercased() == "apk" ? .install : .send(folder: Adb.downloadFolder)), url)
        }
    }

    /// Copies files from the Mac into a folder on the device (the Files page).
    func upload(_ urls: [URL], to folder: String) {
        for url in urls {
            enqueue(Transfer(name: url.lastPathComponent, kind: .send(folder: folder.hasSuffix("/") ? folder : folder + "/")), url)
        }
    }

    /// Copies files or folders from the device into a folder on the Mac, never replacing
    /// anything there: "Name 2", "Name 3"… when the name is taken.
    func download(_ paths: [(path: String, name: String)], to folder: URL) {
        var taken = Set<String>()
        for item in paths {
            var target = folder.appending(path: item.name)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) || taken.contains(target.path) {
                let base = (item.name as NSString).deletingPathExtension
                let ext = (item.name as NSString).pathExtension
                let suffix = ext.isEmpty ? "" : "." + ext
                target = folder.appending(path: "\(base) \(number)\(suffix)")
                number += 1
            }
            taken.insert(target.path)
            enqueue(Transfer(name: target.lastPathComponent, kind: .receive(from: item.path, to: target)), nil)
        }
    }

    private func enqueue(_ transfer: Transfer, _ url: URL?) {
        transfers.append(transfer)
        pending.append((transfer.id, url))
        processTransfers()
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state.isFinished }
    }

    private var pending: [(id: UUID, url: URL?)] = []

    /// One at a time, in the order they were dropped.
    private func processTransfers() {
        guard let adb, transferTask == nil else { return }
        transferTask = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                let (id, url) = self.pending.removeFirst()
                guard let index = self.transfers.firstIndex(where: { $0.id == id }) else { continue }
                self.transfers[index].state = .running
                let failure: String?
                switch self.transfers[index].kind {
                case .install: failure = await adb.install(self.serial, apk: url!)
                case let .send(folder): failure = await adb.push(self.serial, url!, to: folder)
                case let .receive(from, to): failure = await adb.pull(self.serial, from, to: to)
                }
                if let index = self.transfers.firstIndex(where: { $0.id == id }) {
                    self.transfers[index].state = failure.map { .failed($0) } ?? .done
                }
                self.finishedTransfers += 1
            }
            self?.transferTask = nil
        }
    }
}
