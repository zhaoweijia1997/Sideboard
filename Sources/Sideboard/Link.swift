import CoreMedia
import Foundation
import Network
import Observation

/// Sideboard Link: devices running the Sideboard Link app (android/link) show their screen and
/// take touches over the local network, with no cable and no adb. The app announces itself with
/// Bonjour, so the Mac finds the device whatever address the router gave it; the device's owner
/// allows this Mac once, on the device, and from then on the Mac's token lets it in.
///
/// What a connection says is described in the app's LinkService.kt.
enum SideLink {
    static let serviceType = "_sideboard-link._tcp"
    /// A live screen window is opened for a serial; Link devices get made-up ones starting with this.
    static let serialPrefix = "link:"

    /// This Mac's token: made up once, and what the device remembers having allowed.
    static var token: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "linkToken"), saved.count == 32 { return saved }
        let made = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        defaults.set(made, forKey: "linkToken")
        return made
    }

    /// What the device shows its owner when asking whether to allow this Mac.
    static var macName: String {
        let name = (Host.current().localizedName ?? "Mac").filter { !$0.isNewline }
        return String(name.prefix(40))
    }

    static func isLink(_ serial: String) -> Bool { serial.hasPrefix(serialPrefix) }

    static func serial(for name: String) -> String { serialPrefix + name }
}

/// A device found on the network.
struct LinkDevice: Identifiable, Hashable {
    /// The name it announces, such as "Sideboard Link (Pixel XL)".
    let id: String
    let endpoint: NWEndpoint

    /// The device's own name, out of the announcement's brackets.
    var name: String {
        if let open = id.firstIndex(of: "("), let close = id.lastIndex(of: ")"), open < close {
            return String(id[id.index(after: open)..<close])
        }
        return id
    }

    var serial: String { SideLink.serial(for: id) }
}

/// Watches the local network for devices announcing Sideboard Link.
@MainActor @Observable
final class LinkBrowser {
    static let shared = LinkBrowser()

    private(set) var devices: [LinkDevice] = []
    /// macOS isn't letting Sideboard look on the local network (Privacy & Security → Local Network).
    private(set) var blocked = false
    private var browser: NWBrowser?
    /// Devices named by address (SIDEBOARD_LINK=host:port,…), for trying things out through a forwarded port.
    private let fixed: [LinkDevice]

    private init() {
        fixed = (ProcessInfo.processInfo.environment["SIDEBOARD_LINK"] ?? "").split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else { return nil }
            return LinkDevice(id: String(entry), endpoint: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port))
        }
        devices = fixed
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: SideLink.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> LinkDevice? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return LinkDevice(id: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                guard let self else { return }
                self.devices = self.fixed + found.sorted { $0.id < $1.id }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let denied: Bool
            switch state {
            case .waiting, .failed: denied = true
            case .ready: denied = false
            default: return
            }
            Task { @MainActor in self?.blocked = denied }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func device(serial: String) -> LinkDevice? {
        devices.first { $0.serial == serial }
    }
}

/// One connection to a device: says who this Mac is and what it wants, then hands over what
/// the device sends. Everything happens on `queue`.
final class LinkChannel: @unchecked Sendable {
    enum Progress: Sendable {
        /// The device is asking its owner whether to allow this Mac.
        case asking
        /// Let in; `line` is the device's first line about what was asked for.
        case open(line: String)
        case failed(String)
    }

    private let connection: NWConnection
    private let wish: String
    private let payload: Data?
    private let queue: DispatchQueue
    private var waitingLines: [String] = []
    private var buffer = Data()
    private var opened = false
    private var finished = false

    var onProgress: (@Sendable (Progress) -> Void)?
    /// What comes after the device's first lines.
    var onData: (@Sendable (Data) -> Void)?

    /// `payload` goes out straight after the opening lines: an update's bytes.
    init(endpoint: NWEndpoint, wish: String, queue: DispatchQueue, payload: Data? = nil) {
        self.payload = payload
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: options))
        self.wish = wish
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let hello = "SIDEBOARD-LINK 1\n\(SideLink.token)\n\(SideLink.macName)\n\(self.wish)\n"
                self.connection.send(content: Data(hello.utf8) + (self.payload ?? Data()), completion: .contentProcessed { _ in })
                self.receive()
            case let .failed(error):
                self.fail(error.localizedDescription)
            case let .waiting(error):
                // Nobody there (yet): don't sit waiting for the network to change.
                self.fail(error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        queue.async {
            self.finished = true
            self.connection.cancel()
        }
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onProgress?(.failed(reason))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if complete || error != nil {
                self.fail(error?.localizedDescription ?? String(localized: "The device closed the connection."))
            } else {
                self.receive()
            }
        }
    }

    /// First the device's lines: "pairing" while it asks its owner, then "ok" and one line about
    /// what was asked for; anything else is a refusal. After that, everything is handed over.
    private func consume(_ data: Data) {
        if opened {
            onData?(data)
            return
        }
        buffer.append(data)
        while !opened, let end = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...end)
            if waitingLines.isEmpty {
                switch line {
                case "pairing":
                    onProgress?(.asking)
                case "ok":
                    waitingLines.append(line)
                case "denied":
                    return fail(String(localized: "This Mac wasn't allowed on the device."))
                case "busy":
                    return fail(String(localized: "The device is answering another request. Try again in a moment."))
                default:
                    return fail(String(localized: "The device answered in a way Sideboard doesn't understand."))
                }
            } else {
                opened = true
                onProgress?(.open(line: line))
            }
        }
        if opened, !buffer.isEmpty {
            let rest = buffer
            buffer = Data()
            onData?(rest)
        }
    }
}

/// The device's screen as pictures, like `LiveStream`, but straight from the Link app.
final class LinkStream: @unchecked Sendable {
    enum Event: Sendable {
        case asking
        case live(width: Int, height: Int)
        case failed(String)
    }

    var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)?

    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "Sideboard.LinkStream", qos: .userInteractive)
    private var channel: LinkChannel?
    private var parser = AnnexBParser()
    private var picture: [Data] = []
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var stopped = false
    private var reads = 0
    private var pictures = 0
    /// Tries again by itself a few times: the device ends the stream when its screen is turned.
    private var quickFailures = 0
    private var started = Date.distantPast

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.channel?.stop()
            self.channel = nil
        }
    }

    /// Asks for the stream again, which begins with a whole picture.
    func restart() {
        queue.async {
            guard !self.stopped else { return }
            self.channel?.stop()
            self.open()
        }
    }

    private func open() {
        guard !stopped else { return }
        parser = AnnexBParser()
        picture = []
        format = nil
        pictures = 0
        started = Date()
        // The longest side, in pixels, and bits per second.
        let channel = LinkChannel(endpoint: endpoint, wish: "video 1600 8000000", queue: queue)
        channel.onProgress = { [weak self, weak channel] progress in
            guard let self, self.channel === channel else { return }
            switch progress {
            case .asking:
                self.onEvent?(.asking)
            case let .open(line):
                if !line.hasPrefix("video ") {
                    self.channel = nil
                    self.onEvent?(.failed(String(localized: "The device didn't allow its screen to be captured. Turn on Sideboard Link under Accessibility on the device, or confirm there when asked.")))
                }
            case let .failed(reason):
                self.ended(reason)
            }
        }
        channel.onData = { [weak self, weak channel] data in
            guard let self, self.channel === channel else { return }
            self.consume(data)
        }
        self.channel = channel
        channel.start()
    }

    private func ended(_ reason: String) {
        channel = nil
        guard !stopped else { return }
        if pictures == 0, Date().timeIntervalSince(started) < 5 {
            quickFailures += 1
            if quickFailures >= 3 { return onEvent?(.failed(reason)) ?? () }
        } else {
            quickFailures = 0
        }
        queue.asyncAfter(deadline: .now() + 0.3) { self.open() }
    }

    private func consume(_ data: Data) {
        guard !stopped else { return }
        reads += 1
        let result = parser.append(data)
        for unit in result.units { handle(unit) }
        if let header = parser.openHeader, H264.beginsPicture(header) { finishPicture() }
        // The encoder hands over whole pictures; when nothing follows for a moment, the last one is complete.
        let mark = reads
        queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.reads == mark, !self.stopped else { return }
            if let unit = self.parser.takeOpen() { self.handle(unit) }
            self.finishPicture()
        }
    }

    private func handle(_ unit: Data) {
        guard let header = unit.first else { return }
        switch header & 0x1F {
        case 1, 5:
            if H264.beginsPicture(unit) { finishPicture() }
            if format == nil, let sps, let pps, let made = H264.format(sps: sps, pps: pps) {
                format = made
                let dimensions = CMVideoFormatDescriptionGetDimensions(made)
                onEvent?(.live(width: Int(dimensions.width), height: Int(dimensions.height)))
            }
            picture.append(unit)
        case 7:
            finishPicture()
            if unit != sps { sps = unit; format = nil }
        case 8:
            finishPicture()
            if unit != pps { pps = unit; format = nil }
        case 6, 9, 10, 11:
            finishPicture()
        default:
            break
        }
    }

    private func finishPicture() {
        guard !picture.isEmpty else { return }
        defer { picture.removeAll(keepingCapacity: true) }
        guard let format, let sample = H264.sample(picture, format: format) else { return }
        pictures += 1
        onSample?(sample)
    }
}

/// Touches, keys and text for a Link device, sent as they happen.
final class LinkTouch: @unchecked Sendable {
    enum Key: UInt8 {
        case back = 0, home = 1, recents = 2, notifications = 3, quickSettings = 4, lock = 5, wake = 6
    }

    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "Sideboard.LinkTouch", qos: .userInteractive)
    private let lock = NSLock()
    private var channel: LinkChannel?
    private var ready = false
    private var touchOn = false
    private var stopped = false
    /** The device's app takes a whole tap as one message (Link 0.4 and later). */
    private var tapsWhole = false
    /** A finger that just went down and hasn't been sent yet: it may still turn out to be a tap. Used on `queue` only. */
    private var heldBack: (x: Double, y: Double, mark: Int)?
    private var marks = 0
    /** Seconds a button may stay down and still be a tap. */
    private static let hold = 0.18

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    /** Told once the device's version is known. */
    func setTapsWhole(_ whole: Bool) {
        queue.async { self.tapsWhole = whole }
    }

    /// Connected, and the device's accessibility service is on, so touches do something.
    var isReady: Bool { lock.withLock { ready && touchOn } }
    /// Connected, but the service is off on the device.
    var isOff: Bool { lock.withLock { ready && !touchOn } }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.lock.withLock { self.ready = false }
            self.channel?.stop()
            self.channel = nil
        }
    }

    private func open() {
        guard !stopped else { return }
        let channel = LinkChannel(endpoint: endpoint, wish: "control", queue: queue)
        channel.onProgress = { [weak self, weak channel] progress in
            guard let self, self.channel === channel else { return }
            switch progress {
            case .asking:
                break
            case let .open(line):
                self.lock.withLock {
                    self.ready = true
                    self.touchOn = line == "touch on"
                }
            case .failed:
                self.lock.withLock { self.ready = false }
                self.channel = nil
                // The picture's connection is the one that reports trouble; this one just tries again.
                self.queue.asyncAfter(deadline: .now() + 2) { self.open() }
            }
        }
        self.channel = channel
        channel.start()
    }

    /// `x` and `y` are fractions of the screen, from its top left corner.
    ///
    /// "Down" and "up" as two messages make a long press out of a click whenever the network
    /// dawdles between them. So a finger going down is held back for a moment: lifted again
    /// quickly without having moved, it goes out as one "tap", which the device times itself;
    /// otherwise it is sent as down after all, and what follows as it happens.
    func touch(_ action: TouchLink.Touch, x: Double, y: Double) {
        queue.async { [self] in
            guard tapsWhole else {
                // The app's own numbers, which are not the adb touch link's.
                let kind: UInt8 = switch action {
                case .down: 0
                case .move: 1
                case .up: 2
                }
                return write(Data([kind]) + Self.spot(x, y))
            }
            switch action {
            case .down:
                marks += 1
                let mark = marks
                heldBack = (x, y, mark)
                queue.asyncAfter(deadline: .now() + Self.hold) { [self] in
                    if let held = heldBack, held.mark == mark { sendHeldDown() }
                }
            case .move:
                if let held = heldBack {
                    guard abs(x - held.x) > 0.012 || abs(y - held.y) > 0.012 else { return }
                    sendHeldDown()
                }
                write(Data([1]) + Self.spot(x, y))
            case .up:
                if let held = heldBack {
                    heldBack = nil
                    write(Data([6]) + Self.spot(held.x, held.y))
                } else {
                    write(Data([2]) + Self.spot(x, y))
                }
            }
        }
    }

    private func sendHeldDown() {
        guard let held = heldBack else { return }
        heldBack = nil
        write(Data([0]) + Self.spot(held.x, held.y))
    }

    /// On `queue`.
    private func write(_ message: Data) {
        guard lock.withLock({ ready }) else { return }
        channel?.send(message)
    }

    /// A wheel turn over a point, in wheel clicks: positive is up, and to the right.
    func scroll(x: Double, y: Double, horizontal: Double, vertical: Double) {
        func distance(_ clicks: Double) -> Data {
            // A click moves the page about a twelfth of the screen.
            let value = Int16(max(-32767, min(32767, clicks / 12 * 65535)))
            return withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        send(Data([5]) + Self.spot(x, y) + distance(-horizontal) + distance(-vertical))
    }

    func press(_ key: Key) {
        send(Data([3, key.rawValue]))
    }

    func type(_ text: String) {
        let bytes = Data(text.utf8.prefix(60_000))
        send(Data([4]) + withUnsafeBytes(of: UInt16(bytes.count).bigEndian) { Data($0) } + bytes)
    }

    private func send(_ message: Data) {
        queue.async { [weak self] in
            guard let self, self.lock.withLock({ self.ready }) else { return }
            self.channel?.send(message)
        }
    }

    private static func spot(_ x: Double, _ y: Double) -> Data {
        func part(_ value: Double) -> Data {
            let scaled = UInt16(max(0, min(65535, (value * 65535).rounded())))
            return withUnsafeBytes(of: scaled.bigEndian) { Data($0) }
        }
        return part(x) + part(y)
    }
}

/// Putting the Link app on a device and looking after it.
enum LinkSetup {
    static let package = "app.sideboard.link"

    static var bundledAPK: URL? { Bundle.main.url(forResource: "SideboardLink", withExtension: "apk") }

    /// Written next to the APK by tools/build-companion.sh.
    static var bundledVersion: String? {
        guard let apk = bundledAPK else { return nil }
        return try? String(contentsOf: apk.deletingPathExtension().appendingPathExtension("version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNewer(_ version: String, than installed: String) -> Bool {
        version.compare(installed, options: .numeric) == .orderedDescending
    }

    /// The version installed on a device that is on adb; nil when it isn't there.
    static func installedVersion(_ adb: Adb, _ serial: String) async -> String? {
        guard let output = await adb.shell(serial, "dumpsys package \(package) | grep -m1 versionName="),
              let match = output.firstMatch(of: /versionName=(\S+)/) else { return nil }
        return String(match.1)
    }

    /// Over adb: installs or updates the app, gives it what only adb can give (keeping its own
    /// accessibility service on, installing its own updates, not being put to sleep), allows
    /// this Mac, and starts it. After this the device needs no cable and no adb for its screen.
    /// Returns nil on success, otherwise the reason.
    static func setUp(_ adb: Adb, _ serial: String) async -> String? {
        guard let apk = bundledAPK else { return "SideboardLink.apk is missing from Sideboard" }
        if let error = await adb.install(serial, apk: apk) { return error }
        _ = await adb.shellOutput(serial, "pm grant \(package) android.permission.WRITE_SECURE_SETTINGS")
        _ = await adb.shellOutput(serial, "appops set \(package) REQUEST_INSTALL_PACKAGES allow")
        _ = await adb.shellOutput(serial, "dumpsys deviceidle whitelist +\(package)")
        // Android 13 and later ask before an app may show notifications; this one needs its own to keep running.
        _ = await adb.shellOutput(serial, "pm grant \(package) android.permission.POST_NOTIFICATIONS 2>/dev/null")
        let name = SideLink.macName.replacingOccurrences(of: "'", with: "")
        let paired = await adb.shellOutput(serial, "am broadcast -a \(package).PAIR -n \(package)/.AdbReceiver --es token \(SideLink.token) --es name '\(name)'")
        guard paired?.contains("result=1") == true else {
            return String(localized: "The app was installed, but this Mac couldn't be allowed on the device. Open Sideboard Link on the device once and try again.")
        }
        // Opening it once starts the service; with the permission above it switches its accessibility service on by itself.
        _ = await adb.shellOutput(serial, "am start -n \(package)/.MainActivity")
        return nil
    }

    static func uninstall(_ adb: Adb, _ serial: String) async -> String? {
        await AppList.uninstall(adb, serial, package)
    }

    /// The version of the app on a Link device, asked over the network.
    static func version(of endpoint: NWEndpoint) async -> String? {
        let queue = DispatchQueue(label: "Sideboard.LinkInfo")
        return await withCheckedContinuation { continuation in
            let channel = LinkChannel(endpoint: endpoint, wish: "info", queue: queue)
            let once = Once()
            channel.onProgress = { progress in
                switch progress {
                case .asking:
                    break
                case let .open(line):
                    let found = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["version"] as? String
                    if once.take() { continuation.resume(returning: found) }
                    channel.stop()
                case .failed:
                    if once.take() { continuation.resume(returning: nil) }
                }
            }
            channel.start()
            queue.asyncAfter(deadline: .now() + 8) {
                if once.take() { continuation.resume(returning: nil) }
                channel.stop()
            }
        }
    }

    /// Sends the bundled app to a Link device, which installs it over itself. True once the
    /// device has it; the device then asks for confirmation on its screen (and answers that
    /// itself where Android lets it), and is back a moment later.
    static func sendUpdate(to endpoint: NWEndpoint) async -> Bool {
        guard let apk = bundledAPK, let data = try? Data(contentsOf: apk) else { return false }
        let queue = DispatchQueue(label: "Sideboard.LinkUpdate")
        return await withCheckedContinuation { continuation in
            let channel = LinkChannel(endpoint: endpoint, wish: "update \(data.count)", queue: queue, payload: data)
            let once = Once()
            channel.onProgress = { progress in
                switch progress {
                case .asking:
                    break
                case let .open(line):
                    if once.take() { continuation.resume(returning: line == "installing") }
                    channel.stop()
                case .failed:
                    if once.take() { continuation.resume(returning: false) }
                }
            }
            channel.start()
            queue.asyncAfter(deadline: .now() + 60) {
                if once.take() { continuation.resume(returning: false) }
                channel.stop()
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.withLock {
                if taken { return false }
                taken = true
                return true
            }
        }
    }
}
