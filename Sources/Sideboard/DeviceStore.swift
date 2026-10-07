import Foundation
import Observation

/// A network device Sideboard has connected to before, reconnected to on its own.
struct RememberedDevice: Codable, Hashable, Identifiable, Sendable {
    var address: String
    var name: String?
    var isTV: Bool?
    var id: String { address }
}

/// The sidebar: devices adb sees (USB and network) plus remembered network devices.
@MainActor @Observable
final class DeviceStore {
    enum AdbState { case starting, missing, ready }

    struct Entry: Identifiable, Hashable {
        enum State { case online, unauthorized, offline, disconnected, connecting }

        /// adb's serial, or the remembered address.
        let id: String
        var name: String?
        var isNetwork: Bool
        var isTV: Bool
        var state: State
        var remembered: Bool

        /// host:port for network devices. USB serial numbers are never shown.
        var address: String? { isNetwork ? id : nil }
    }

    private(set) var adbState: AdbState = .starting
    private(set) var connected: [Adb.Device] = []
    private(set) var remembered: [RememberedDevice]
    var selection: String?
    private(set) var connecting: Set<String> = []
    /// The last failed attempt per address, shown until a connection works.
    private(set) var problems: [String: Adb.ConnectResult] = [:]
    private(set) var restartingAdb = false

    private var adb: Adb?
    private let live: Bool
    private var dashboards: [String: DashboardModel] = [:]
    private var loop: Task<Void, Never>?
    private var lastReconnect = Date.distantPast
    /// Forgotten in this session: not remembered again while adb is still disconnecting them.
    private var forgotten: Set<String> = []
    private static let rememberedKey = "rememberedDevices"

    init() {
        live = true
        adb = Adb.locate()
        remembered = (UserDefaults.standard.data(forKey: Self.rememberedKey))
            .flatMap { try? JSONDecoder().decode([RememberedDevice].self, from: $0) } ?? []
    }

    /// Made-up devices for screenshots; never runs adb or touches preferences.
    init(sample connected: [Adb.Device], remembered: [RememberedDevice], dashboards: [String: DashboardModel],
         problems: [String: Adb.ConnectResult] = [:], adbMissing: Bool = false) {
        live = false
        adbState = adbMissing ? .missing : .ready
        self.connected = connected
        self.remembered = remembered
        self.dashboards = dashboards
        self.problems = problems
        selection = connected.first?.serial
    }

    var entries: [Entry] {
        var result = connected.map { device in
            let memory = remembered.first { $0.address == device.serial }
            let state: Entry.State = switch device.state {
            case .online: .online
            case .unauthorized: .unauthorized
            case .offline: .offline
            }
            return Entry(id: device.serial, name: device.model ?? memory?.name, isNetwork: device.isNetwork,
                         isTV: dashboards[device.serial]?.status?.isTV ?? memory?.isTV ?? false,
                         state: state, remembered: memory != nil)
        }
        for memory in remembered where !connected.contains(where: { $0.serial == memory.address }) {
            result.append(Entry(id: memory.address, name: memory.name, isNetwork: true, isTV: memory.isTV ?? false,
                                state: connecting.contains(memory.address) ? .connecting : .disconnected, remembered: true))
        }
        return result
    }

    var selectedEntry: Entry? { entries.first { $0.id == selection } }

    /// False for the made-up stores of screenshots.
    var isLive: Bool { live }
    var adbHandle: Adb? { adb }

    /// The device's page model if it was opened, without creating one.
    func existingDashboard(_ serial: String) -> DashboardModel? { dashboards[serial] }

    func dashboard(for serial: String) -> DashboardModel {
        if let model = dashboards[serial] { return model }
        let model = DashboardModel(serial: serial, adb: adb)
        model.onStatus = { [weak self] status in self?.learn(serial, from: status) }
        dashboards[serial] = model
        return model
    }

    // MARK: Watching adb

    func start() {
        guard live, loop == nil else { return }
        guard let adb else {
            adbState = .missing
            return
        }
        loop = Task { [weak self] in
            await adb.startServer()
            self?.adbState = .ready
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDevices()
                if Date().timeIntervalSince(self.lastReconnect) > 60 {
                    self.lastReconnect = Date()
                    self.reconnectRemembered()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// After installing platform-tools while Sideboard is open.
    func lookForAdbAgain() {
        guard live else { return }
        adb = Adb.locate()
        if adb != nil {
            adbState = .starting
            dashboards = [:]
            start()
        }
    }

    /// Asks adb which devices it has. Runs on the Mac only: the devices aren't contacted.
    func refreshDevices() async {
        guard let adb, let devices = await adb.devices() else { return }
        connected = devices
        for device in devices where device.state == .online {
            problems[device.serial] = nil
            // Network devices connected some other way (Terminal, another app) are remembered too,
            // so Sideboard reconnects them later. Wireless-debugging names reconnect by themselves.
            guard device.isNetwork, device.serial.contains(":"), !forgotten.contains(device.serial) else { continue }
            if let index = remembered.firstIndex(where: { $0.address == device.serial }) {
                if let model = device.model, remembered[index].name != model {
                    remembered[index].name = model
                    save()
                }
            } else {
                remembered.append(RememberedDevice(address: device.serial, name: device.model))
                save()
            }
        }
        if selection == nil || !entries.contains(where: { $0.id == selection }) {
            selection = entries.first { $0.state == .online }?.id ?? entries.first?.id
        }
    }

    private func reconnectRemembered() {
        for memory in remembered where !connected.contains(where: { $0.serial == memory.address }) && !connecting.contains(memory.address) {
            Task { await connect(memory.address, quietly: true) }
        }
    }

    // MARK: Connecting

    /// "192.168.1.42" becomes "192.168.1.42:5555".
    static func normalize(_ input: String) -> String {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.contains(":") ? address : "\(address):\(NetworkScan.port)"
    }

    /// `quietly`: a background retry, which doesn't add the device or replace an earlier problem.
    @discardableResult
    func connect(_ input: String, quietly: Bool = false) async -> Adb.ConnectResult {
        guard let adb else { return .failed("adb") }
        let address = Self.normalize(input)
        connecting.insert(address)
        defer { connecting.remove(address) }
        let result = await adb.connect(address)
        switch result {
        case .connected, .needsApproval:
            problems[address] = nil
            if !quietly {
                remember(address)
                selection = address
            }
        default:
            if !quietly || problems[address] == nil { problems[address] = result }
        }
        await refreshDevices()
        return result
    }

    func pair(_ address: String, code: String) async -> String? {
        guard let adb else { return "adb" }
        return await adb.pair(address.trimmingCharacters(in: .whitespaces), code: code.trimmingCharacters(in: .whitespaces))
    }

    func forget(_ address: String) {
        forgotten.insert(address)
        remembered.removeAll { $0.address == address }
        problems[address] = nil
        save()
        if let adb, connected.contains(where: { $0.serial == address }) {
            Task {
                await adb.disconnect(address)
                await refreshDevices()
            }
        }
    }

    func restartAdb() async {
        guard let adb else { return }
        restartingAdb = true
        await adb.restartServer()
        problems = [:]
        for memory in remembered {
            await connect(memory.address, quietly: true)
        }
        await refreshDevices()
        restartingAdb = false
    }

    /// Network addresses that answer on adb's port and aren't connected yet.
    func scan() async -> [String] {
        await NetworkScan.scan().filter { address in !connected.contains { $0.serial == address } }
    }

    // MARK: Remembering

    private func remember(_ address: String) {
        forgotten.remove(address)
        guard !remembered.contains(where: { $0.address == address }) else { return }
        remembered.append(RememberedDevice(address: address))
        save()
    }

    private func learn(_ serial: String, from status: DeviceStatus) {
        guard let index = remembered.firstIndex(where: { $0.address == serial }) else { return }
        if remembered[index].isTV != status.isTV {
            remembered[index].isTV = status.isTV
            save()
        }
    }

    private func save() {
        guard live, let data = try? JSONEncoder().encode(remembered) else { return }
        UserDefaults.standard.set(data, forKey: Self.rememberedKey)
    }
}
