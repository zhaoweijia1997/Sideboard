import AppKit
import Foundation

/// The optional companion app (android/ in this repository), bundled as SideboardCompanion.apk.
/// It keeps 90 days of screen, power and app history, knows app names and icons, and can type
/// text and use the clipboard. Sideboard talks to it over adb only.
enum Companion {
    static let package = "com.weijiazhao.sideboard"
    static let provider = "content://com.weijiazhao.sideboard.provider"
    static let keyboard = "com.weijiazhao.sideboard/.TypingService"

    static var bundledAPK: URL? { Bundle.main.url(forResource: "SideboardCompanion", withExtension: "apk") }

    struct Info: Equatable, Sendable {
        var version: String
        var since: Date?
        var events: Int
        var usageAccess: Bool
    }

    /// `content query` prints "Row: 0 name=value, name=value"; the last column may contain ", ".
    static func rows(_ output: String, columns: [String]) -> [[String: String]] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("Row: "), let start = line.firstIndex(of: " ").flatMap({ line[line.index(after: $0)...].firstIndex(of: " ") })
            else { return nil }
            var rest = line[line.index(after: start)...]
            var row: [String: String] = [:]
            for (index, column) in columns.enumerated() {
                guard rest.hasPrefix(column + "=") else { return nil }
                rest = rest.dropFirst(column.count + 1)
                if index == columns.count - 1 {
                    row[column] = String(rest)
                } else {
                    guard let comma = rest.range(of: ", " + columns[index + 1] + "=") else { return nil }
                    row[column] = String(rest[..<comma.lowerBound])
                    rest = rest[rest.index(comma.lowerBound, offsetBy: 2)...]
                }
            }
            return row
        }
    }

    /// Nil when the companion isn't installed (or can't be read).
    static func info(_ adb: Adb, _ serial: String) async -> Info? {
        guard let output = await adb.shell(serial, "content query --uri \(provider)/info 2>/dev/null; true"),
              let row = rows(output, columns: ["version", "since", "events", "usage_access", "last_read"]).first else { return nil }
        let since = row["since"].flatMap(Double.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return Info(version: row["version"] ?? "?", since: since, events: Int(row["events"] ?? "") ?? 0,
                    usageAccess: row["usage_access"] == "1")
    }

    /// Screen, power and app events since `date`, as timeline events.
    static func events(_ adb: Adb, _ serial: String, since date: Date) async -> [Timeline.Event] {
        let since = Int64(date.timeIntervalSince1970 * 1000)
        guard let output = await adb.shell(serial, "content query --uri '\(provider)/events?since=\(since)' 2>/dev/null; true", timeout: 60)
        else { return [] }
        return rows(output, columns: ["time", "type", "package"]).compactMap { row in
            guard let time = row["time"].flatMap(Double.init), let type = row["type"].flatMap(Int.init) else { return nil }
            let date = Date(timeIntervalSince1970: time / 1000)
            switch type {
            case 1: return row["package"].map { Timeline.Event(date: date, kind: .app($0)) }
            case 15: return Timeline.Event(date: date, kind: .screenOn)
            case 16: return Timeline.Event(date: date, kind: .screenOff)
            case 26: return Timeline.Event(date: date, kind: .shutdown)
            case 27, 1000: return Timeline.Event(date: date, kind: .startup)
            default: return nil
            }
        }
    }

    static func labels(_ adb: Adb, _ serial: String) async -> [String: String] {
        guard let output = await adb.shell(serial, "content query --uri \(provider)/apps 2>/dev/null; true", timeout: 60) else { return [:] }
        var labels: [String: String] = [:]
        for row in rows(output, columns: ["package", "label"]) {
            if let package = row["package"], let label = row["label"], label != package, !label.isEmpty { labels[package] = label }
        }
        return labels
    }

    static func icons(_ adb: Adb, _ serial: String) async -> [String: NSImage] {
        guard let output = await adb.shell(serial, "content query --uri \(provider)/icons 2>/dev/null; true", timeout: 120) else { return [:] }
        var icons: [String: NSImage] = [:]
        for row in rows(output, columns: ["package", "png"]) {
            if let package = row["package"], let data = row["png"].flatMap({ Data(base64Encoded: $0) }), let image = NSImage(data: data) {
                icons[package] = image
            }
        }
        return icons
    }

    /// Installs or updates it, then allows usage access, which a person would otherwise have to
    /// find in Settings. Returns nil on success, otherwise the reason.
    static func install(_ adb: Adb, _ serial: String) async -> String? {
        guard let apk = bundledAPK else { return "SideboardCompanion.apk is missing from Sideboard" }
        if let error = await adb.install(serial, apk: apk) { return error }
        _ = await adb.shellOutput(serial, "appops set \(package) GET_USAGE_STATS allow")
        return nil
    }

    static func allowUsageAccess(_ adb: Adb, _ serial: String) async {
        _ = await adb.shellOutput(serial, "appops set \(package) GET_USAGE_STATS allow")
    }

    /// Removes it and the history it kept.
    static func uninstall(_ adb: Adb, _ serial: String) async -> String? {
        await AppList.uninstall(adb, serial, package)
    }
}

/// Typing on the device in any language, and its clipboard. While the typing window is open,
/// the device's keyboard is switched to the companion's (which shows nothing on screen); closing
/// the window switches back to the keyboard it had and turns the companion's off again.
@MainActor
final class TypingSession {
    enum Failure: Error { case noTextField, noAnswer }

    private let adb: Adb
    private let serial: String
    private var previous: String?

    init(adb: Adb, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    func begin() async {
        let current = (await adb.shell(serial, "settings get secure default_input_method") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        previous = current.isEmpty || current == "null" || current == Companion.keyboard ? previous : current
        _ = await adb.shellOutput(serial, "ime enable \(Companion.keyboard); ime set \(Companion.keyboard)")
    }

    func end() async {
        var command = "ime disable \(Companion.keyboard)"
        if let previous { command = "ime set \(Adb.quote(previous)); " + command }
        _ = await adb.shellOutput(serial, command)
    }

    /// Types into the text field that has focus on the device.
    func type(_ text: String) async -> Result<Void, Failure> {
        await send("TYPE", "--es b64 \(Data(text.utf8).base64EncodedString())").map { _ in }
    }

    func key(_ name: String) async -> Result<Void, Failure> {
        await send("KEY", "--es code \(name)").map { _ in }
    }

    func setClipboard(_ text: String) async -> Bool {
        if case .success = await send("SET_CLIP", "--es b64 \(Data(text.utf8).base64EncodedString())") { return true }
        return false
    }

    func clipboard() async -> String? {
        guard case let .success(data) = await send("GET_CLIP", ""), let data, let decoded = Data(base64Encoded: data) else { return nil }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// `Broadcast completed: result=1, data="…"`. 2 means no text field has focus; 0, that the
    /// companion's keyboard didn't get it (not active).
    private func send(_ action: String, _ extras: String) async -> Result<String?, Failure> {
        let command = "am broadcast -p \(Companion.package) -a \(Companion.package).\(action) \(extras)"
        guard let output = await adb.shellOutput(serial, command), let match = output.firstMatch(of: /result=(-?\d+)(?:, data="([^"]*)")?/) else {
            return .failure(.noAnswer)
        }
        switch match.1 {
        case "1": return .success(match.2.map(String.init))
        case "2": return .failure(.noTextField)
        default: return .failure(.noAnswer)
        }
    }
}
