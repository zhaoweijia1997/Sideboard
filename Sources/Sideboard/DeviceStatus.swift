import Foundation

/// CPU time counters from the first line of /proc/stat. Usage needs two samples.
struct CPUSample: Equatable, Sendable {
    let busy: Double
    let total: Double

    /// cpu  user nice system idle iowait irq softirq steal ...
    init?(line: some StringProtocol) {
        guard line.hasPrefix("cpu ") else { return nil }
        let n = line.split(separator: " ").dropFirst().prefix(8).compactMap { Double($0) }
        guard n.count >= 5 else { return nil }
        total = n.reduce(0, +)
        busy = total - n[3] - n[4]
    }

    init(busy: Double, total: Double) {
        self.busy = busy
        self.total = total
    }

    func usage(since earlier: CPUSample) -> Double? {
        let elapsed = total - earlier.total
        guard elapsed > 0 else { return nil }
        return min(1, max(0, (busy - earlier.busy) / elapsed))
    }
}

/// Everything the dashboard shows, read with one adb shell command.
/// Read-only: nothing on the device is changed.
struct DeviceStatus: Equatable, Sendable {
    enum Screen: Sendable { case on, off, screensaver, dozing }
    enum Playback: Sendable { case playing, paused, stopped, buffering, other }

    struct Media: Equatable, Sendable {
        var package: String
        var playback: Playback
        var title: String?
    }

    struct NetworkAddress: Equatable, Sendable {
        enum Kind: Sendable { case wired, wifi, mobile, other }
        var interface: String
        var address: String

        var kind: Kind {
            if interface.hasPrefix("eth") { return .wired }
            if interface.hasPrefix("wlan") { return .wifi }
            if interface.hasPrefix("rmnet") || interface.hasPrefix("ccmni") { return .mobile }
            return .other
        }
    }

    var manufacturer: String?
    var model: String?
    var androidVersion: String?
    var isTV = false
    var timeZone: TimeZone?
    var uptime: TimeInterval?
    var cpu: CPUSample?
    var cores: Int?
    /// MHz, the fastest core right now.
    var cpuFrequency: Double?
    var cpuMaxFrequency: Double?
    var memoryTotal: Int64?
    var memoryAvailable: Int64?
    var storageTotal: Int64?
    var storageAvailable: Int64?
    var screen: Screen?
    /// Package of the app in front.
    var foreground: String?
    /// Package of the home screen (launcher).
    var home: String?
    var media: Media?
    var volume: Int?
    var volumeMax: Int?
    var addresses: [NetworkAddress] = []
    /// Android's overheating level: 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown.
    var thermalStatus: Int?
    /// °C. Many TVs don't report any temperature at all.
    var temperature: Double?
    /// Only for devices with a battery.
    var batteryLevel: Int?
    var charging = false

    /// Measured on the Mac's clock, so it moves a little between readings.
    var bootDate: Date? { uptime.map { Date().addingTimeInterval(-$0) } }

    var memoryUsed: Double? {
        guard let total = memoryTotal, let available = memoryAvailable, total > 0 else { return nil }
        return 1 - Double(available) / Double(total)
    }

    var storageUsed: Double? {
        guard let total = storageTotal, let available = storageAvailable, total > 0 else { return nil }
        return 1 - Double(available) / Double(total)
    }

    /// One adb call; `@@name` lines start each section. Errors from commands the device lacks
    /// are dropped, and the last command always succeeds so adb reports success.
    static let command = [
        "cat /proc/uptime",
        "echo @@stat", "head -1 /proc/stat",
        "echo @@cores", "grep -c ^processor /proc/cpuinfo",
        "echo @@freq", "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null",
        "echo @@maxfreq", "cat /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq 2>/dev/null",
        "echo @@mem", "grep -E 'MemTotal|MemAvailable' /proc/meminfo",
        "echo @@df", "df /data 2>/dev/null | tail -1",
        "echo @@power", "dumpsys power | grep -E 'mWakefulness='",
        "echo @@focus", "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'",
        "echo @@home", "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -1",
        "echo @@media", "dumpsys media_session | grep -E 'package=|active=|state=PlaybackState|metadata:'",
        "echo @@volume", "cmd media_session volume --stream 3 --get 2>/dev/null",
        "echo @@net", "ip -4 -o addr show 2>/dev/null",
        "echo @@thermal", "dumpsys thermalservice 2>/dev/null",
        "echo @@zones", "cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null",
        "echo @@battery", "dumpsys battery | grep -E '^  (present|level|status):'",
        "echo @@props", "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release",
        "getprop persist.sys.timezone; getprop ro.build.characteristics",
        "true",
    ].joined(separator: "; ")

    static func parse(_ output: String) -> DeviceStatus {
        var sections: [String: [String]] = [:]
        var name = "uptime"
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("@@") {
                name = String(line.dropFirst(2))
            } else if !line.isEmpty {
                sections[name, default: []].append(line)
            }
        }
        func lines(_ name: String) -> [String] { sections[name] ?? [] }
        func trimmed(_ text: some StringProtocol) -> String { text.trimmingCharacters(in: .whitespaces) }

        var status = DeviceStatus()

        // /proc/uptime: "76370.97 253208.07" (seconds since boot, idle)
        status.uptime = lines("uptime").first?.split(separator: " ").first.flatMap { Double($0) }

        status.cpu = lines("stat").first.flatMap { CPUSample(line: $0) }
        status.cores = lines("cores").first.flatMap { Int(trimmed($0)) }
        // kHz per core.
        status.cpuFrequency = lines("freq").compactMap { Double(trimmed($0)) }.max().map { $0 / 1000 }
        status.cpuMaxFrequency = lines("maxfreq").compactMap { Double(trimmed($0)) }.max().map { $0 / 1000 }

        // MemTotal:        3000000 kB
        for line in lines("mem") {
            let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            guard parts.count >= 2, let kb = Int64(parts[1]) else { continue }
            if parts[0] == "MemTotal" { status.memoryTotal = kb * 1024 }
            if parts[0] == "MemAvailable" { status.memoryAvailable = kb * 1024 }
        }

        // /dev/block/mmcblk0p50  49000000 3000000  46000000   7% /data/user/0   (1K blocks)
        if let line = lines("df").first {
            let fields = line.split(separator: " ")
            if fields.count >= 4, let total = Int64(fields[1]), let available = Int64(fields[3]) {
                status.storageTotal = total * 1024
                status.storageAvailable = available * 1024
            }
        }

        // mWakefulness=Awake
        if let line = lines("power").first(where: { $0.contains("mWakefulness=") }) {
            switch trimmed(line).dropFirst("mWakefulness=".count) {
            case "Awake": status.screen = .on
            case "Asleep": status.screen = .off
            case "Dreaming": status.screen = .screensaver
            case "Dozing": status.screen = .dozing
            default: break
            }
        }

        // mFocusedApp=ActivityRecord{a39cdd6 u0 com.example.app/.MainActivity t2882}
        // mCurrentFocus=Window{fa186cc u0 com.example.app/com.example.app.MainActivity}
        func package(in line: String?) -> String? {
            guard let line else { return nil }
            return line.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" })
                .first { $0.contains("/") }
                .map { String($0.prefix { $0 != "/" }) }
        }
        let focus = lines("focus")
        status.foreground = package(in: focus.first { $0.contains("mFocusedApp=") })
            ?? package(in: focus.first { $0.contains("mCurrentFocus=") })

        // com.example.launcher/.ui.MainActivity
        status.home = package(in: lines("home").last.map { " \($0)" })

        status.media = parseMedia(lines("media"))

        // [V] volume is 22 in range [0..100]
        if let line = lines("volume").first(where: { $0.contains("volume is") }),
           let match = line.firstMatch(of: /volume is (\d+) in range \[(\d+)\.\.(\d+)\]/) {
            status.volume = Int(match.1)
            status.volumeMax = Int(match.3)
        }

        // 11: eth0    inet 192.168.1.42/24 brd 192.168.1.255 scope global eth0 ...
        status.addresses = lines("net").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let inet = fields.firstIndex(of: "inet"), inet > 0, inet + 1 < fields.count else { return nil }
            let interface = String(fields[inet - 1])
            guard interface != "lo" else { return nil }
            return NetworkAddress(interface: interface, address: String(fields[inet + 1].prefix { $0 != "/" }))
        }

        let thermal = parseThermal(lines("thermal"))
        status.thermalStatus = thermal.status
        status.temperature = thermal.temperature ?? lines("zones").compactMap { zone -> Double? in
            // Millidegrees on most devices, whole degrees on a few. Skip sensors that report nonsense.
            guard let raw = Double(trimmed(zone)) else { return nil }
            let celsius = raw > 1000 ? raw / 1000 : raw
            return (5...125).contains(celsius) ? celsius : nil
        }.max()

        //   present: true / level: 85 / status: 2 (2 charging, 5 full)
        var battery: [String: String] = [:]
        for line in lines("battery") {
            let parts = line.split(separator: ":", maxSplits: 1).map(trimmed)
            if parts.count == 2 { battery[parts[0]] = parts[1] }
        }
        if battery["present"] == "true" {
            status.batteryLevel = battery["level"].flatMap { Int($0) }
            status.charging = battery["status"] == "2" || battery["status"] == "5"
        }

        let props = lines("props").map(trimmed)
        func prop(_ index: Int) -> String? { props.indices.contains(index) && !props[index].isEmpty ? props[index] : nil }
        status.manufacturer = prop(0)
        status.model = prop(1)
        status.androidVersion = prop(2)
        status.timeZone = prop(3).flatMap(TimeZone.init(identifier:))
        status.isTV = prop(4)?.split(separator: ",").contains("tv") ?? false
        return status
    }

    /// The session list from `dumpsys media_session`, filtered to these lines per session:
    ///
    ///     package=com.example.player
    ///     active=true
    ///     state=PlaybackState {state=3, position=-1, …}
    ///     metadata: size=2, description=Title, Subtitle, null
    ///
    /// Picks the first session that's playing, otherwise the first active one.
    static func parseMedia(_ lines: [String]) -> Media? {
        var sessions: [(media: Media, active: Bool)] = []
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("package=") {
                sessions.append((Media(package: String(line.dropFirst("package=".count)), playback: .other), false))
            } else if !sessions.isEmpty, line.hasPrefix("active=") {
                sessions[sessions.count - 1].active = line == "active=true"
            } else if !sessions.isEmpty, let match = line.firstMatch(of: /state=PlaybackState \{state=(\d+)/) {
                let playback: Playback = switch Int(match.1) {
                case 3: .playing
                case 2: .paused
                case 1: .stopped
                case 6, 8: .buffering
                default: .other
                }
                sessions[sessions.count - 1].media.playback = playback
            } else if !sessions.isEmpty, let range = line.range(of: "description=") {
                let parts = line[range.upperBound...].components(separatedBy: ", ").filter { $0 != "null" && !$0.isEmpty }
                sessions[sessions.count - 1].media.title = parts.isEmpty ? nil : parts.joined(separator: " — ")
            }
        }
        return (sessions.first { $0.media.playback == .playing } ?? sessions.first { $0.active })?.media
    }

    /// `dumpsys thermalservice`:
    ///
    ///     Thermal Status: 0
    ///     Current temperatures from HAL:
    ///         Temperature{mValue=56.2, mType=0, mName=cpu0, mStatus=0}
    ///
    /// Type 0 is CPU, 3 is the device's skin. Prefers live readings over cached ones.
    static func parseThermal(_ lines: [String]) -> (status: Int?, temperature: Double?) {
        var status: Int?
        var current: [(type: Int, value: Double)] = []
        var cached: [(type: Int, value: Double)] = []
        var block = ""
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Thermal Status:") {
                status = Int(line.dropFirst("Thermal Status:".count).trimmingCharacters(in: .whitespaces))
            } else if let match = line.firstMatch(of: /Temperature\{mValue=([-\d.]+), mType=(\d+)/),
                      let value = Double(match.1), let type = Int(match.2) {
                if block.hasPrefix("Current temperatures") { current.append((type, value)) }
                if block.hasPrefix("Cached temperatures") { cached.append((type, value)) }
            } else if line.hasSuffix(":") {
                block = line
            }
        }
        let readings = current.isEmpty ? cached : current
        let preferred = readings.filter { $0.type == 0 }.isEmpty ? readings.filter { $0.type == 3 } : readings.filter { $0.type == 0 }
        let temperature = (preferred.isEmpty ? readings : preferred).map(\.value).filter { (5...125).contains($0) }.max()
        return (status, temperature)
    }
}
