import Foundation
import Observation

/// Junk on the device that's safe to remove. Nothing is removed until the user picks what
/// and confirms; app caches are cleared by Android itself and rebuilt by the apps.
struct CleanupItem: Identifiable, Hashable, Sendable {
    var path: String
    var size: Int64
    var modified: Date?
    var selected = true
    var id: String { path }
    var name: String { String(path.split(separator: "/").last ?? "") }
}

struct CleanupCategory: Identifiable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// Every app's cache, cleared with `pm trim-caches`. Items are shown for information.
        case appCaches
        /// Android/data, obb and media folders of apps that are no longer installed.
        case leftovers
        /// .apk files outside Android/ (downloaded installers).
        case installers
        /// .thumbnails folders, rebuilt by the gallery when needed.
        case thumbnails
        /// Files over 100 MB, for review. Not selected by default.
        case largeFiles
    }

    var kind: Kind
    var items: [CleanupItem]
    /// For app caches: the total Android reports, which can be more than the listed apps.
    var total: Int64?
    var selected: Bool

    var id: String { kind.rawValue }
    var size: Int64 { total ?? items.map(\.size).reduce(0, +) }
    var selectedSize: Int64 {
        guard selected else { return 0 }
        return kind == .appCaches ? size : items.filter(\.selected).map(\.size).reduce(0, +)
    }
}

enum CleanupScan {
    static let largeFileMegabytes = 100

    static let command = [
        "echo @@packages", "pm list packages -u",
        "echo @@caches", "dumpsys diskstats | grep -E '^(Package Names|Cache Sizes|App Cache Size):'",
        "echo @@folders", "du -sk /sdcard/Android/data/* /sdcard/Android/obb/* /sdcard/Android/media/* 2>/dev/null",
        "echo @@apks", "find /sdcard/ -type f -iname '*.apk' -not -path '/sdcard/Android/*' -exec stat -c '%s|%Y|%n' {} + 2>/dev/null",
        "echo @@thumbs", "du -sk /sdcard/DCIM/.thumbnails /sdcard/Pictures/.thumbnails /sdcard/Movies/.thumbnails 2>/dev/null",
        "echo @@large", "find /sdcard/ -type f -size +\(largeFileMegabytes)M -not -path '/sdcard/Android/obb/*' -exec stat -c '%s|%Y|%n' {} + 2>/dev/null",
        "echo @@free", "df /data | tail -1",
        "true",
    ].joined(separator: "; ")

    static func parse(_ output: String) -> [CleanupCategory] {
        var sections: [String: [String]] = [:]
        var name = ""
        for line in output.split(separator: "\n") {
            let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("@@") {
                name = String(line.dropFirst(2))
            } else {
                sections[name, default: []].append(line)
            }
        }
        func du(_ line: String) -> CleanupItem? {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            return CleanupItem(path: String(parts[1]), size: kb * 1024)
        }
        func stat(_ line: String) -> CleanupItem? {
            let parts = line.split(separator: "|", maxSplits: 2)
            guard parts.count == 3, let size = Int64(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return CleanupItem(path: String(parts[2]), size: size, modified: Date(timeIntervalSince1970: seconds))
        }

        let installed = Set((sections["packages"] ?? []).compactMap {
            $0.hasPrefix("package:") ? String($0.dropFirst("package:".count)) : nil
        })

        // Cache sizes per app, and Android's total.
        var arrays: [String: Data] = [:]
        var cacheTotal: Int64?
        for line in sections["caches"] ?? [] {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "App Cache Size" { cacheTotal = Int64(parts[1]) } else { arrays[parts[0]] = Data(parts[1].utf8) }
        }
        var caches: [CleanupItem] = []
        if let names = arrays["Package Names"].flatMap({ try? JSONDecoder().decode([String].self, from: $0) }),
           let sizes = arrays["Cache Sizes"].flatMap({ try? JSONDecoder().decode([Int64].self, from: $0) }) {
            // The package name stands in for the path; shown as the app's name.
            caches = zip(names, sizes).filter { $0.1 >= 1_000_000 }.map { CleanupItem(path: $0.0, size: $0.1) }
                .sorted { $0.size > $1.size }
        }

        // A folder named after a package that isn't installed (even kept-data uninstalls count as installed).
        let leftovers = (sections["folders"] ?? []).compactMap(du).filter { item in
            let package = item.name
            return package.contains(".") && !installed.contains(package) && item.size > 0
        }

        let installers = (sections["apks"] ?? []).compactMap(stat)
        let thumbnails = (sections["thumbs"] ?? []).compactMap(du).filter { $0.size > 0 }
        let installerPaths = Set(installers.map(\.path))
        var large = (sections["large"] ?? []).compactMap(stat).filter { !installerPaths.contains($0.path) }
        for index in large.indices { large[index].selected = false }

        return [
            CleanupCategory(kind: .appCaches, items: caches, total: cacheTotal, selected: (cacheTotal ?? 0) > 0),
            CleanupCategory(kind: .leftovers, items: leftovers.sorted { $0.size > $1.size }, selected: true),
            CleanupCategory(kind: .installers, items: installers.sorted { $0.size > $1.size }, selected: true),
            CleanupCategory(kind: .thumbnails, items: thumbnails, selected: true),
            CleanupCategory(kind: .largeFiles, items: large.sorted { $0.size > $1.size }, selected: false),
        ]
    }

    /// Free bytes on /data from `df /data | tail -1` (1K blocks).
    static func free(_ output: String) -> Int64? {
        guard let line = output.split(separator: "\n").last(where: { !$0.isEmpty }) else { return nil }
        let fields = line.split(separator: " ")
        return fields.count >= 4 ? Int64(fields[3]).map { $0 * 1024 } : nil
    }
}

@MainActor @Observable
final class CleanupModel {
    enum State: Equatable { case idle, scanning, scanned, cleaning, cleaned(freed: Int64?) }

    private(set) var state: State = .idle
    var categories: [CleanupCategory] = []
    var failure: String?

    private let adb: Adb?
    private let serial: String

    init(adb: Adb?, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    init(sample categories: [CleanupCategory]) {
        adb = nil
        serial = "sample"
        self.categories = categories
        state = .scanned
    }

    var selectedSize: Int64 { categories.map(\.selectedSize).reduce(0, +) }

    func scan() async {
        guard let adb else { return }
        state = .scanning
        guard let output = await adb.shell(serial, CleanupScan.command, timeout: 300) else {
            failure = String(localized: "Couldn't scan the device.")
            state = .idle
            return
        }
        categories = CleanupScan.parse(output)
        state = .scanned
    }

    /// Removes what's selected. Paths are limited to shared storage.
    func clean() async {
        guard let adb else { return }
        state = .cleaning
        let before = await adb.shell(serial, "df /data | tail -1").flatMap(CleanupScan.free)
        for category in categories where category.selected {
            if category.kind == .appCaches {
                // Asks Android to free this much by clearing app caches: in practice, all of them.
                _ = await adb.shellOutput(serial, "pm trim-caches 999G", timeout: 300)
                continue
            }
            let paths = category.items.filter(\.selected).map(\.path)
                .filter { $0.hasPrefix("/sdcard/") && $0.split(separator: "/").count > 2 }
            for batch in stride(from: 0, to: paths.count, by: 50).map({ Array(paths[$0..<min($0 + 50, paths.count)]) }) {
                _ = await adb.shellOutput(serial, "rm -rf -- " + batch.map(Adb.quote).joined(separator: " "), timeout: 300)
            }
        }
        let after = await adb.shell(serial, "df /data | tail -1").flatMap(CleanupScan.free)
        state = .cleaned(freed: before.flatMap { before in after.map { max(0, $0 - before) } })
        categories = []
    }
}
