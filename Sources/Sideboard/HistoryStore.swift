import CryptoKit
import Foundation

/// Sideboard's own copy of each device's power, screen and app history, kept on this Mac in
/// ~/Library/Application Support/Sideboard/History. Every reading adds to it, so the history
/// grows past Android's 24 hours (and the companion's 90 days), and stays if the companion app
/// is removed. One file per device, named after a hash of its serial number, so the number
/// itself is never written down.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    let folder: URL
    private var events: [String: [Timeline.Event]] = [:]
    private var seen: [String: Set<String>] = [:]
    private var keys: [String: String] = [:]

    /// SIDEBOARD_HISTORY_DIR replaces the folder (for tests).
    init(folder: URL? = nil) {
        if let folder {
            self.folder = folder
        } else if let path = ProcessInfo.processInfo.environment["SIDEBOARD_HISTORY_DIR"] {
            self.folder = URL(fileURLWithPath: path)
        } else {
            self.folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Sideboard/History")
        }
    }

    /// The same for a device over USB and over the network.
    func key(for serial: String, adb: Adb) async -> String? {
        if let key = keys[serial] { return key }
        guard let output = await adb.shell(serial, "getprop ro.serialno") else { return nil }
        var id = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id == "unknown" { id = serial }
        let digest = SHA256.hash(data: Data("sideboard-history:\(id)".utf8))
        let key = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        keys[serial] = key
        return key
    }

    /// Everything kept for the device together with `new`, oldest first. New events are written down.
    func merge(_ new: [Timeline.Event], key: String) -> [Timeline.Event] {
        load(key)
        var added: [Timeline.Event] = []
        for event in new where seen[key, default: []].insert(Self.identity(event)).inserted {
            added.append(event)
        }
        if !added.isEmpty {
            write(added, key: key)
            events[key, default: []].append(contentsOf: added)
            events[key]?.sort { $0.date < $1.date }
        }
        return events[key] ?? []
    }

    func stored(_ key: String) -> [Timeline.Event] {
        load(key)
        return events[key] ?? []
    }

    /// Bytes on disk, for Settings.
    var size: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init).reduce(0, +)
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: folder)
        events = [:]
        seen = [:]
    }

    // MARK: Files

    /// One JSON object per line: {"t":1791266400.5,"k":"on"} or {"t":…,"k":"app","p":"com.example"}.
    private struct Line: Codable {
        var t: Double
        var k: String
        var p: String?
    }

    static func identity(_ event: Timeline.Event) -> String {
        "\(Int(event.date.timeIntervalSince1970)) \(event.kind)"
    }

    private func file(_ key: String) -> URL { folder.appending(path: "\(key).jsonl") }

    private func load(_ key: String) {
        guard events[key] == nil else { return }
        var loaded: [Timeline.Event] = []
        if let text = try? String(contentsOf: file(key), encoding: .utf8) {
            let decoder = JSONDecoder()
            for line in text.split(separator: "\n") {
                guard let item = try? decoder.decode(Line.self, from: Data(line.utf8)) else { continue }
                let date = Date(timeIntervalSince1970: item.t)
                let kind: Timeline.Event.Kind? = switch item.k {
                case "start": .startup
                case "shut": .shutdown
                case "on": .screenOn
                case "off": .screenOff
                case "app": item.p.map { .app($0) }
                default: nil
                }
                if let kind { loaded.append(Timeline.Event(date: date, kind: kind)) }
            }
        }
        loaded.sort { $0.date < $1.date }
        events[key] = loaded
        seen[key] = Set(loaded.map(Self.identity))
    }

    private func write(_ new: [Timeline.Event], key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let lines = new.compactMap { event -> String? in
            let line: Line = switch event.kind {
            case .startup: Line(t: event.date.timeIntervalSince1970, k: "start")
            case .shutdown: Line(t: event.date.timeIntervalSince1970, k: "shut")
            case .screenOn: Line(t: event.date.timeIntervalSince1970, k: "on")
            case .screenOff: Line(t: event.date.timeIntervalSince1970, k: "off")
            case let .app(package): Line(t: event.date.timeIntervalSince1970, k: "app", p: package)
            }
            return (try? encoder.encode(line)).map { String(decoding: $0, as: UTF8.self) }
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let url = file(key)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
