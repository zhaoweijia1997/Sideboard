import Foundation
import Observation

/// A file or folder in the device's shared storage.
struct DeviceFile: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var isFolder: Bool
    var size: Int64
    var modified: Date

    var id: String { path }
}

/// Browsing and changing the device's shared storage (what file manager apps see: internal
/// storage and USB drives). Changes happen only when the user asks; deleting asks first.
@MainActor @Observable
final class FilesModel {
    struct Root: Hashable, Identifiable {
        var path: String
        var isInternal: Bool
        var id: String { path }
        /// "1A2B-3C4D" for /storage/1A2B-3C4D.
        var volumeName: String { String(path.split(separator: "/").last ?? "") }
    }

    private(set) var roots: [Root] = [Root(path: "/sdcard", isInternal: true)]
    private(set) var path = "/sdcard"
    private(set) var files: [DeviceFile] = []
    /// Folder sizes, filled in on request ("Show folder sizes").
    private(set) var folderSizes: [String: Int64] = [:]
    private(set) var loading = false
    private(set) var measuring = false
    var showHidden = false
    var failure: String?

    private let adb: Adb?
    private let serial: String

    init(adb: Adb?, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    init(sample files: [DeviceFile], path: String, sizes: [String: Int64]) {
        adb = nil
        serial = "sample"
        self.files = files
        self.path = path
        folderSizes = sizes
        roots = [Root(path: "/sdcard", isInternal: true), Root(path: "/storage/1A2B-3C4D", isInternal: false)]
    }

    var visibleFiles: [DeviceFile] {
        files.filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }

    /// The root that contains the current folder, and the folders below it, for the path bar.
    var root: Root { roots.first { path == $0.path || path.hasPrefix($0.path + "/") } ?? roots[0] }

    var crumbs: [(name: String, path: String)] {
        let relative = path.dropFirst(root.path.count).split(separator: "/")
        var result: [(String, String)] = []
        var current = root.path
        for part in relative {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    var canGoUp: Bool { path != root.path }

    func go(to path: String) async {
        self.path = path
        folderSizes = [:]
        await reload()
    }

    func goUp() async {
        guard canGoUp else { return }
        await go(to: String(path[..<(path.lastIndex(of: "/") ?? path.endIndex)]))
    }

    /// `stat` one line per entry: type|size|modified|path. Names may contain anything but a
    /// line break; the path comes last, so `|` in names is fine.
    func reload() async {
        guard let adb else { return }
        loading = true
        defer { loading = false }
        let folder = Adb.quote(path)
        let command = "stat -c '%F|%s|%Y|%n' -- \(folder)/* \(folder)/.* 2>/dev/null; echo @@storage; ls /storage 2>/dev/null; true"
        guard let output = await adb.shell(serial, command, timeout: 30) else {
            failure = String(localized: "Couldn't read this folder.")
            return
        }
        var files: [DeviceFile] = []
        var storage: [String] = []
        var inStorage = false
        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line == "@@storage" {
                inStorage = true
                continue
            }
            if inStorage {
                storage.append(line)
                continue
            }
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let size = Int64(parts[1]), let seconds = Double(parts[2]) else { continue }
            let fullPath = String(parts[3])
            let name = String(fullPath.split(separator: "/").last ?? "")
            guard name != ".", name != ".." else { continue }
            files.append(DeviceFile(name: name, path: fullPath, isFolder: parts[0] == "directory", size: size,
                                    modified: Date(timeIntervalSince1970: seconds)))
        }
        self.files = files
        // USB drives and cards appear in /storage with names like 1A2B-3C4D.
        roots = [Root(path: "/sdcard", isInternal: true)]
            + storage.filter { $0.range(of: #"^[0-9A-F]{4}-[0-9A-F]{4}$"#, options: .regularExpression) != nil }
                .map { Root(path: "/storage/\($0)", isInternal: false) }
    }

    func measureFolders() async {
        guard let adb else { return }
        measuring = true
        defer { measuring = false }
        let command = "cd \(Adb.quote(path)) && du -sk -- * .[!.]* 2>/dev/null; true"
        guard let output = await adb.shell(serial, command, timeout: 300) else { return }
        var sizes: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            sizes[path + "/" + parts[1]] = kb * 1024
        }
        folderSizes = sizes
    }

    func newFolder(named name: String) async {
        guard let name = valid(name) else { return }
        await run("mkdir \(Adb.quote(path + "/" + name))")
    }

    func rename(_ file: DeviceFile, to name: String) async {
        guard let name = valid(name), name != file.name else { return }
        await run("mv -n \(Adb.quote(file.path)) \(Adb.quote(path + "/" + name))")
    }

    /// Permanently removes them from the device; the window asks first.
    func delete(_ files: [DeviceFile]) async {
        // Only ever inside shared storage, never a storage root itself.
        let paths = files.map(\.path).filter { path in
            roots.contains { path.hasPrefix($0.path + "/") } && !roots.contains { $0.path == path }
        }
        guard !paths.isEmpty else { return }
        await run("rm -rf -- " + paths.map(Adb.quote).joined(separator: " "))
    }

    private func valid(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.contains("/") || name == "." || name == ".." ? nil : name
    }

    private func run(_ command: String) async {
        guard let adb else { return }
        let output = await adb.shellOutput(serial, command + " && echo @@ok") ?? ""
        if !output.contains("@@ok") {
            failure = output.replacingOccurrences(of: "@@ok", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        await reload()
    }
}
