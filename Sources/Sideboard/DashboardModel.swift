import AppKit
import Foundation
import Observation

/// Android key codes for the remote.
enum RemoteKey: Int, CaseIterable {
    case home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, ok = 23
    case volumeUp = 24, volumeDown = 25, power = 26, menu = 82, playPause = 85
    case mute = 164, sleep = 223, wake = 224
}

/// A file being sent or an app being installed.
struct Transfer: Identifiable, Equatable {
    enum Kind { case send, install }
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
    private(set) var unreachable = false
    var transfers: [Transfer] = []
    var onStatus: ((DeviceStatus) -> Void)?

    private let adb: Adb?
    private let live: Bool
    private var statusTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var refreshing = false
    private var lastTimeline = Date.distantPast

    static let awakeInterval: Double = 5
    /// While the screen is off: just enough to notice it coming back on.
    static let asleepInterval: Double = 60

    init(serial: String, adb: Adb?) {
        self.serial = serial
        self.adb = adb
        live = true
    }

    /// Made-up readings for screenshots.
    init(sample status: DeviceStatus, cpuUsage: Double, timeline: Timeline, details: DeviceDetails, transfers: [Transfer] = []) {
        serial = "sample"
        adb = nil
        live = false
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

        let timelineInterval: Double = isAwake ? 120 : 600
        if Date().timeIntervalSince(lastTimeline) > timelineInterval {
            lastTimeline = Date()
            if let output = await adb.shell(serial, Timeline.command, timeout: 30) {
                timeline = Timeline.parse(output, timeZone: status?.timeZone ?? .current, bootDate: status?.bootDate)
            }
        }
        return isAwake ? Self.awakeInterval : Self.asleepInterval
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

    /// PNG data.
    func screenshot() async -> Data? {
        await adb?.screenshot(serial)
    }

    /// APKs are installed; everything else goes into the device's Download folder.
    func send(_ urls: [URL]) {
        for url in urls {
            let kind: Transfer.Kind = url.pathExtension.lowercased() == "apk" ? .install : .send
            transfers.append(Transfer(name: url.lastPathComponent, kind: kind))
            pending.append((transfers[transfers.count - 1].id, url))
        }
        processTransfers()
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state.isFinished }
    }

    private var pending: [(id: UUID, url: URL)] = []

    /// One at a time, in the order they were dropped.
    private func processTransfers() {
        guard let adb, transferTask == nil else { return }
        transferTask = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                let (id, url) = self.pending.removeFirst()
                guard let index = self.transfers.firstIndex(where: { $0.id == id }) else { continue }
                self.transfers[index].state = .running
                let failure = self.transfers[index].kind == .install
                    ? await adb.install(self.serial, apk: url)
                    : await adb.push(self.serial, url)
                if let index = self.transfers.firstIndex(where: { $0.id == id }) {
                    self.transfers[index].state = failure.map { .failed($0) } ?? .done
                }
            }
            self?.transferTask = nil
        }
    }
}
