import Foundation

/// The Details page: everything else Sideboard can read, in one adb call. Heavier than
/// DeviceStatus (it samples CPU for a second), so it's only read while the page is open.
/// Read-only like everything else: the power settings are shown, never changed.
/// Leaves out serial numbers, MAC addresses and other identifiers.
struct DeviceDetails: Equatable, Sendable {
    struct Process: Equatable, Sendable, Identifiable {
        var pid: Int
        var name: String
        /// Percent of one core, as `top` reports it.
        var cpu: Double
        var memory: Int64?
        var id: Int { pid }
    }

    struct Volume: Equatable, Sendable, Identifiable {
        var mount: String
        var total: Int64
        var available: Int64
        var id: String { mount }
        var isInternal: Bool { mount == "/data" }
    }

    struct WiFi: Equatable, Sendable {
        var network: String?
        /// dBm.
        var signal: Int?
        /// Mbps.
        var linkSpeed: Int?
        /// MHz.
        var frequency: Int?
    }

    var brand: String?
    var device: String?
    var sdk: Int?
    var securityPatch: String?
    var build: String?
    var chipset: String?
    var architecture: String?
    var kernel: String?

    var screenSize: String?
    /// The size apps draw at, when it differs from the panel (TVs often render at 1080p).
    var renderSize: String?
    var density: Int?
    var refreshRate: Double?

    var governor: String?
    var loadAverage: [Double] = []
    var processes: [Process] = []

    var memoryFree: Int64?
    var memoryCached: Int64?
    var swapTotal: Int64?
    var swapFree: Int64?

    var volumes: [Volume] = []
    var wifi: WiFi?

    /// Milliseconds; nil when the device doesn't have the setting.
    var screenOffTimeout: Int?
    var sleepTimeout: Int?
    var attentiveTimeout: Int?
    var stayOnWhilePluggedIn: Int?
    var screensaverEnabled: Bool?

    var packageCount: Int?
    var userPackageCount: Int?

    static let command = [
        "echo @@props",
        "getprop ro.product.brand; getprop ro.product.device; getprop ro.build.version.sdk",
        "getprop ro.build.version.security_patch; getprop ro.build.display.id",
        "getprop ro.soc.model; getprop ro.board.platform; getprop ro.product.cpu.abi; uname -r",
        "echo @@wm", "wm size 2>/dev/null; wm density 2>/dev/null",
        "echo @@fps", "dumpsys display 2>/dev/null | grep -m1 -oE 'fps=[0-9.]+'",
        "echo @@gov", "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null",
        "echo @@load", "cat /proc/loadavg",
        // Two rounds a second apart (the first has no CPU figures yet), sorted by the 2nd column, CPU.
        "echo @@top", "top -b -n 2 -d 1 -m 10 -s 2 -o PID,%CPU,RES,NAME 2>/dev/null",
        "echo @@mem", "grep -E '^(MemFree|Cached|SwapTotal|SwapFree):' /proc/meminfo",
        "echo @@df", "df 2>/dev/null | grep -E ' /data$| /mnt/media_rw/| /storage/[0-9A-F]{4}-'",
        "echo @@wifi", "dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo'",
        "echo @@settings",
        "settings get system screen_off_timeout; settings get secure sleep_timeout; settings get secure attentive_timeout",
        "settings get global stay_on_while_plugged_in; settings get secure screensaver_enabled",
        "echo @@packages", "pm list packages 2>/dev/null | wc -l; pm list packages -3 2>/dev/null | wc -l",
        "true",
    ].joined(separator: "; ")

    static func parse(_ output: String) -> DeviceDetails {
        var sections: [String: [String]] = [:]
        var name = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("@@") {
                name = String(line.dropFirst(2))
            } else {
                sections[name, default: []].append(line)
            }
        }
        func lines(_ name: String) -> [String] { sections[name] ?? [] }
        func value(_ name: String, _ index: Int) -> String? {
            let lines = lines(name)
            guard lines.indices.contains(index) else { return nil }
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            return text.isEmpty || text == "null" ? nil : text
        }

        var details = DeviceDetails()
        details.brand = value("props", 0)
        details.device = value("props", 1)
        details.sdk = value("props", 2).flatMap { Int($0) }
        details.securityPatch = value("props", 3)
        details.build = value("props", 4)
        details.chipset = value("props", 5) ?? value("props", 6)
        details.architecture = value("props", 7)
        details.kernel = value("props", 8)

        // Physical size: 3840x2160 / Override size: 1920x1080 / Physical density: 320
        for line in lines("wm") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Physical size": details.screenSize = parts[1].replacingOccurrences(of: "x", with: " × ")
            case "Override size": details.renderSize = parts[1].replacingOccurrences(of: "x", with: " × ")
            case "Physical density": details.density = details.density ?? Int(parts[1])
            case "Override density": details.density = Int(parts[1])
            default: break
            }
        }
        details.refreshRate = lines("fps").first.flatMap { Double($0.dropFirst("fps=".count)) }.map { ($0 * 100).rounded() / 100 }
        details.governor = value("gov", 0)
        details.loadAverage = lines("load").first?.split(separator: " ").prefix(3).compactMap { Double($0) } ?? []
        details.processes = parseTop(lines("top"))

        for line in lines("mem") {
            let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            guard parts.count >= 2, let kb = Int64(parts[1]) else { continue }
            switch parts[0] {
            case "MemFree": details.memoryFree = kb * 1024
            case "Cached": details.memoryCached = kb * 1024
            case "SwapTotal": details.swapTotal = kb * 1024
            case "SwapFree": details.swapFree = kb * 1024
            default: break
            }
        }

        // /dev/block/mmcblk0p50  49000000 3000000  46000000   7% /data   (1K blocks)
        var seen = Set<String>()
        details.volumes = lines("df").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 6, let total = Int64(fields[1]), let available = Int64(fields[3]), total > 0 else { return nil }
            let mount = String(fields[5])
            // A USB drive shows up under both /mnt/media_rw and /storage.
            let key = mount.split(separator: "/").last.map(String.init) ?? mount
            guard seen.insert(key).inserted else { return nil }
            return Volume(mount: mount, total: total * 1024, available: available * 1024)
        }

        // mWifiInfo SSID: "Home", BSSID: …, RSSI: -55, Link speed: 433Mbps, Frequency: 5180MHz, …
        if let line = lines("wifi").first, line.contains("SSID") {
            var wifi = WiFi()
            if let match = line.firstMatch(of: /SSID: "?([^",]*)"?,/) {
                let network = String(match.1)
                wifi.network = network.isEmpty || network == "<unknown ssid>" ? nil : network
            }
            wifi.signal = line.firstMatch(of: /RSSI: (-?\d+)/).flatMap { Int($0.1) }
            wifi.linkSpeed = line.firstMatch(of: /Link speed: (\d+)/).flatMap { Int($0.1) }
            wifi.frequency = line.firstMatch(of: /Frequency: (\d+)/).flatMap { Int($0.1) }
            // A disconnected Wi-Fi reports RSSI -127.
            if wifi.network != nil || (wifi.signal ?? -127) > -127 { details.wifi = wifi }
        }

        details.screenOffTimeout = value("settings", 0).flatMap { Int($0) }
        details.sleepTimeout = value("settings", 1).flatMap { Int($0) }
        details.attentiveTimeout = value("settings", 2).flatMap { Int($0) }
        details.stayOnWhilePluggedIn = value("settings", 3).flatMap { Int($0) }
        details.screensaverEnabled = value("settings", 4).flatMap { Int($0) }.map { $0 != 0 }

        details.packageCount = value("packages", 0).flatMap { Int($0) }
        details.userPackageCount = value("packages", 1).flatMap { Int($0) }
        return details
    }

    /// `top -b -n 2 -s 2 -o PID,%CPU,RES,NAME`: uses the rows after the last header.
    ///
    ///       PID[%CPU] RES NAME
    ///      2744 12.5 136M zygote
    static func parseTop(_ lines: [String]) -> [Process] {
        guard let header = lines.lastIndex(where: { $0.contains("PID") && $0.contains("%CPU") }) else { return [] }
        return lines[(header + 1)...].compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1]) else { return nil }
            let name = String(fields[3]).trimmingCharacters(in: .whitespaces)
            // top itself, sampling.
            guard name != "top" else { return nil }
            return Process(pid: pid, name: name, cpu: cpu, memory: parseSize(String(fields[2])))
        }
        .sorted { $0.cpu > $1.cpu }
    }

    /// "136M", "4.6M", "1.2G", "980K", "512" (bytes).
    static func parseSize(_ text: String) -> Int64? {
        let units: [Character: Double] = ["K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024]
        if let last = text.last, let unit = units[last], let number = Double(text.dropLast()) {
            return Int64(number * unit)
        }
        return Int64(text)
    }
}
