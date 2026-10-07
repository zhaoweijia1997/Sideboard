import Foundation
import Observation

/// The Health page: data usage per app, crashes and freezes, and what keeps the device busy in
/// the background. Read in one adb call when the page opens; never polled, never changes anything.
struct DeviceHealth: Equatable, Sendable {
    struct Crash: Equatable, Sendable, Identifiable {
        enum Kind: Sendable { case appCrash, appFreeze, systemCrash, nativeCrash, systemRestart }
        var date: Date
        var kind: Kind
        /// The process, which for apps is the package name (sometimes with ":service" after it).
        var process: String?
        var id: String { "\(date.timeIntervalSince1970)-\(kind)-\(process ?? "")" }
        var package: String? { process.map { String($0.prefix { $0 != ":" }) } }
    }

    struct Usage: Equatable, Sendable, Identifiable {
        /// Android's user id for the app; below 10000 for system services, negative for "removed apps".
        var uid: Int
        var packages: [String]
        var day: Int64
        var week: Int64
        var month: Int64
        var id: Int { uid }
    }

    struct Count: Equatable, Sendable, Identifiable {
        var package: String
        var count: Int
        var id: String { package }
    }

    var crashes: [Crash] = []
    /// Alarms that woke the device, per app, since it started.
    var wakeups: [Count] = []
    /// Background jobs apps have scheduled.
    var jobs: [Count] = []
    /// Jobs that ran recently, from Android's job history (the last hundred or so).
    var recentJobs: [Count] = []
    var recentJobsSince: Date?
    /// Apps the user allowed to skip battery saving (Doze).
    var exempt: [String] = []
    var systemExemptCount = 0
    var usage: [Usage] = []

    static let crashTags = "data_app_crash|data_app_anr|system_app_crash|system_app_anr|data_app_native_crash|"
        + "system_app_native_crash|SYSTEM_TOMBSTONE|system_server_crash|system_server_anr|system_server_watchdog|SYSTEM_RESTART"

    /// One call. Data usage is added up on the device (awk), so only a line per app comes back:
    /// uid, bytes in the last 24 hours, 7 days and 30 days.
    static let command = [
        "echo @@crashes",
        "dumpsys dropbox 2>/dev/null | grep -A1 -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} (\(crashTags)) '",
        "echo @@alarms", "dumpsys alarm 2>/dev/null | grep -E '^  (u0a[0-9]+|[0-9]+):[^ ]+ [+].* running, [0-9]+ wakeups:$'",
        "echo @@jobs", "dumpsys jobscheduler 2>/dev/null | grep -E '^  JOB #'",
        "echo @@history", "dumpsys jobscheduler 2>/dev/null | sed -n '/^  Job history:/,/^  [A-Z]/p' | grep 'START:'",
        "echo @@idle", "dumpsys deviceidle whitelist 2>/dev/null",
        "echo @@uids", "pm list packages -U 2>/dev/null",
        "echo @@net",
        "dumpsys netstats --full --uid 2>/dev/null | awk -v now=$(date +%s) "
            + "'/^UID stats:/{u=1;next} /^UID tag stats:/{u=0} "
            + "u&&/ uid=/{match($0,/uid=-?[0-9]+/);id=substr($0,RSTART+4,RLENGTH-4);next} "
            + "u&&/st=/{st=0;b=0;for(i=1;i<=NF;i++){split($i,kv,\"=\");if(kv[1]==\"st\")st=kv[2];if(kv[1]==\"rb\"||kv[1]==\"tb\")b+=kv[2]} "
            + "a=now-st;if(a<=86400)d[id]+=b;if(a<=604800)w[id]+=b;if(a<=2592000)m[id]+=b} "
            + "END{for(k in m)print k,d[k]+0,w[k]+0,m[k]+0}'",
        "true",
    ].joined(separator: "; ")

    static func parse(_ output: String, timeZone: TimeZone, now: Date = Date()) -> DeviceHealth {
        var sections: [String: [String]] = [:]
        var name = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("@@") {
                name = String(line.dropFirst(2))
            } else if !line.isEmpty {
                sections[name, default: []].append(line)
            }
        }
        func lines(_ name: String) -> [String] { sections[name] ?? [] }
        var health = DeviceHealth()

        // 2026-10-06 15:07:17 data_app_crash (text, 2776 bytes)
        //     Process: com.example.app/PID: 4811/UID: 10192/Flags: ...
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let crashLines = lines("crashes")
        for (index, line) in crashLines.enumerated() {
            guard let match = line.firstMatch(of: /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (\S+) \(/),
                  let date = formatter.date(from: String(match.1)) else { continue }
            let kind: Crash.Kind = switch match.2 {
            case "data_app_crash", "system_app_crash": match.2.hasPrefix("data") ? .appCrash : .systemCrash
            case "data_app_anr", "system_app_anr": .appFreeze
            case "data_app_native_crash", "system_app_native_crash", "SYSTEM_TOMBSTONE": .nativeCrash
            case "SYSTEM_RESTART", "system_server_watchdog": .systemRestart
            default: .systemCrash
            }
            var process: String?
            if index + 1 < crashLines.count, let found = crashLines[index + 1].firstMatch(of: /^\s+Process: ([^\/\s]+)/) {
                process = String(found.1)
            }
            health.crashes.append(Crash(date: date, kind: kind, process: process))
        }
        health.crashes.sort { $0.date > $1.date }

        //   1000:com.android.networkstack.inprocess +136ms running, 30 wakeups:
        var wakeups: [String: Int] = [:]
        for line in lines("alarms") {
            if let match = line.firstMatch(of: /^  (?:u0a\d+|\d+):(\S+) \+.* running, (\d+) wakeups:$/), let count = Int(match.2), count > 0 {
                wakeups[String(match.1), default: 0] += count
            }
        }
        health.wakeups = counts(wakeups)

        //   JOB #u0a68/8193: 4a4dae2 com.example.app/.SomeJobService
        var jobs: [String: Int] = [:]
        for line in lines("jobs") {
            if let match = line.firstMatch(of: /^  JOB #\S+: \S+ ([^\/\s]+)\//) { jobs[String(match.1), default: 0] += 1 }
        }
        health.jobs = counts(jobs)

        //      -2h13m39s867ms   START: #u0a36/2 com.example.app/.SomeJobService
        var recent: [String: Int] = [:]
        var oldest: TimeInterval = 0
        for line in lines("history") {
            guard let match = line.firstMatch(of: /^\s+-(\S+)\s+START: #\S+ ([^\/\s]+)\//) else { continue }
            recent[String(match.2), default: 0] += 1
            oldest = max(oldest, duration(String(match.1)))
        }
        health.recentJobs = counts(recent)
        health.recentJobsSince = oldest > 0 ? now.addingTimeInterval(-oldest) : nil

        // system-excidle,com.example,10027 / system,… / user,com.example,10123
        for line in lines("idle") {
            let parts = line.split(separator: ",")
            guard parts.count >= 2 else { continue }
            if parts[0] == "user" { health.exempt.append(String(parts[1])) } else { health.systemExemptCount += 1 }
        }

        // package:com.example uid:10068
        var packagesByUID: [Int: [String]] = [:]
        for line in lines("uids") {
            if let match = line.firstMatch(of: /^package:(\S+) uid:(\d+)/), let uid = Int(match.2) {
                packagesByUID[uid, default: []].append(String(match.1))
            }
        }
        // uid day week month
        health.usage = lines("net").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 4, let uid = Int(fields[0]), let day = Int64(fields[1]), let week = Int64(fields[2]),
                  let month = Int64(fields[3]), month > 0 else { return nil }
            return Usage(uid: uid, packages: (packagesByUID[uid] ?? []).sorted(), day: day, week: week, month: month)
        }
        .sorted { $0.month > $1.month }
        return health
    }

    private static func counts(_ dictionary: [String: Int]) -> [Count] {
        dictionary.map { Count(package: $0.key, count: $0.value) }.sorted { ($0.count, $1.package) > ($1.count, $0.package) }
    }

    /// "2h13m41s535ms", "45s123ms", "1d2h" → seconds.
    static func duration(_ text: String) -> TimeInterval {
        var total: TimeInterval = 0
        for match in text.matches(of: /(\d+)(ms|d|h|m|s)/) {
            let value = Double(match.1) ?? 0
            switch match.2 {
            case "d": total += value * 86_400
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case "ms": total += value / 1000
            default: break
            }
        }
        return total
    }
}

@MainActor @Observable
final class HealthModel {
    private(set) var health: DeviceHealth?
    private(set) var loading = false
    var failure: String?

    private let adb: Adb?
    private let serial: String

    init(adb: Adb?, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    init(sample: DeviceHealth) {
        adb = nil
        serial = "sample"
        health = sample
    }

    func load(timeZone: TimeZone) async {
        guard let adb, !loading else { return }
        loading = true
        defer { loading = false }
        guard let output = await adb.shell(serial, DeviceHealth.command, timeout: 90) else {
            failure = String(localized: "Couldn't read the device.")
            return
        }
        health = DeviceHealth.parse(output, timeZone: timeZone)
    }
}
