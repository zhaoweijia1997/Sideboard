import Foundation
import Observation

/// One app on the device.
struct DeviceApp: Identifiable, Equatable, Sendable {
    var package: String
    var isSystem: Bool
    var isDisabled: Bool
    /// The activity that opens it from the launcher, if it has one.
    var launcher: String?
    var versionCode: Int?
    var versionName: String?
    var updated: Date?
    /// From Android's storage statistics, which it refreshes about once a day.
    var appSize: Int64?
    var dataSize: Int64?
    var cacheSize: Int64?

    var id: String { package }

    var totalSize: Int64? {
        let sizes = [appSize, dataSize, cacheSize].compactMap { $0 }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// Reading the app list and acting on apps. Everything that changes the device runs only
/// when the user asks, after a confirmation in the window.
enum AppList {
    static let command = [
        "echo @@all", "pm list packages --show-versioncode 2>/dev/null || pm list packages",
        "echo @@system", "pm list packages -s",
        "echo @@disabled", "pm list packages -d",
        "echo @@sizes", "dumpsys diskstats | grep -E '^(Package Names|App Sizes|App Data Sizes|Cache Sizes):'",
        "echo @@launch",
        "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null",
        "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER 2>/dev/null",
        // Version names and update times for the apps people added (a quick dumpsys each).
        "echo @@versions",
        "for p in $(pm list packages -3 | cut -d: -f2); do echo \"@$p\"; dumpsys package $p | grep -m2 -E 'versionName=|lastUpdateTime='; done",
        "echo @@protect", "settings get secure default_input_method",
        "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -1",
        "true",
    ].joined(separator: "; ")

    struct Result: Sendable {
        var apps: [DeviceApp]
        /// Apps that keep the device working: the home screen, the keyboard in use and core
        /// system parts. Sideboard offers no way to turn them off or remove them.
        var protected: Set<String>
    }

    static func parse(_ output: String, timeZone: TimeZone) -> Result {
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
        func packages(_ name: String) -> [String] {
            (sections[name] ?? []).compactMap { line in
                guard line.hasPrefix("package:") else { return nil }
                return String(line.dropFirst("package:".count).prefix { $0 != " " })
            }
        }

        let system = Set(packages("system"))
        let disabled = Set(packages("disabled"))

        // package:com.example versionCode:123
        var apps: [String: DeviceApp] = [:]
        for line in sections["all"] ?? [] where line.hasPrefix("package:") {
            let fields = line.dropFirst("package:".count).split(separator: " ")
            guard let package = fields.first.map(String.init) else { continue }
            let code = fields.first { $0.hasPrefix("versionCode:") }.flatMap { Int($0.dropFirst("versionCode:".count)) }
            apps[package] = DeviceApp(package: package, isSystem: system.contains(package), isDisabled: disabled.contains(package),
                                      versionCode: code)
        }

        // Package Names: ["a","b"] / App Sizes: [1,2] / ...
        var arrays: [String: Data] = [:]
        for line in sections["sizes"] ?? [] {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { arrays[String(parts[0])] = Data(parts[1].utf8) }
        }
        if let data = arrays["Package Names"], let names = try? JSONDecoder().decode([String].self, from: data) {
            func sizes(_ key: String) -> [Int64] {
                arrays[key].flatMap { try? JSONDecoder().decode([Int64].self, from: $0) } ?? []
            }
            let appSizes = sizes("App Sizes"), dataSizes = sizes("App Data Sizes"), cacheSizes = sizes("Cache Sizes")
            for (index, package) in names.enumerated() where apps[package] != nil {
                apps[package]?.appSize = appSizes.indices.contains(index) ? appSizes[index] : nil
                apps[package]?.dataSize = dataSizes.indices.contains(index) ? dataSizes[index] : nil
                apps[package]?.cacheSize = cacheSizes.indices.contains(index) ? cacheSizes[index] : nil
            }
        }

        //     com.example.app/.MainActivity
        for line in sections["launch"] ?? [] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("/"), !trimmed.contains(" "), let slash = trimmed.firstIndex(of: "/") else { continue }
            let package = String(trimmed[..<slash])
            if apps[package] != nil, apps[package]?.launcher == nil { apps[package]?.launcher = trimmed }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var current: String?
        for line in sections["versions"] ?? [] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@") {
                current = String(trimmed.dropFirst())
            } else if let current, trimmed.hasPrefix("versionName="), apps[current]?.versionName == nil {
                apps[current]?.versionName = String(trimmed.dropFirst("versionName=".count))
            } else if let current, trimmed.hasPrefix("lastUpdateTime=") {
                apps[current]?.updated = formatter.date(from: String(trimmed.dropFirst("lastUpdateTime=".count)))
            }
        }

        var protected = essential
        for line in sections["protect"] ?? [] {
            // com.example.ime/.Service, or a home activity
            if let slash = line.firstIndex(of: "/") {
                protected.insert(String(line[..<slash]).trimmingCharacters(in: .whitespaces))
            }
        }
        for package in apps.keys where essentialPrefixes.contains(where: package.hasPrefix) {
            protected.insert(package)
        }
        return Result(apps: Array(apps.values), protected: protected)
    }

    static let essential: Set<String> = [
        "android", "com.android.systemui", "com.android.settings", "com.android.tv.settings", "com.android.shell",
        "com.android.packageinstaller", "com.google.android.packageinstaller", "com.android.permissioncontroller",
        "com.google.android.permissioncontroller", "com.android.phone", "com.android.server.telecom",
        "com.android.externalstorage", "com.android.keychain", "com.android.location.fused", "com.android.inputdevices",
        "com.google.android.gms", "com.google.android.gsf", "com.google.android.ext.services", "com.android.vending",
        "com.android.webview", "com.google.android.webview", "com.android.se", "com.android.nfc",
    ]
    static let essentialPrefixes = [
        "com.android.providers.", "com.google.android.providers.", "com.android.networkstack", "com.google.android.networkstack",
        "com.android.wifi", "com.android.bluetooth", "com.android.ims", "com.android.cellbroadcast", "com.google.android.cellbroadcast",
    ]

    // MARK: Actions

    static func open(_ adb: Adb, _ serial: String, launcher: String) async -> String? {
        let output = await adb.shellOutput(serial, "am start -n \(Adb.quote(launcher))") ?? "adb didn't run"
        return output.contains("Error") ? output : nil
    }

    static func forceStop(_ adb: Adb, _ serial: String, _ package: String) async {
        _ = await adb.shellOutput(serial, "am force-stop \(Adb.quote(package))")
    }

    /// Turns an app off for this user (`pm disable-user`), which can be undone with `enable`.
    static func setEnabled(_ adb: Adb, _ serial: String, _ package: String, _ enabled: Bool) async -> String? {
        var command = "pm disable-user --user 0 \(Adb.quote(package))"
        if enabled { command = "pm enable \(Adb.quote(package))" }
        let output = await adb.shellOutput(serial, command) ?? "adb didn't run"
        return output.contains("new state") ? nil : output
    }

    /// Removes an app the user added, with its data.
    static func uninstall(_ adb: Adb, _ serial: String, _ package: String) async -> String? {
        let output = await adb.shellOutput(serial, "pm uninstall \(Adb.quote(package))", timeout: 120) ?? "adb didn't run"
        if output.contains("Success") { return nil }
        if let start = output.range(of: "Failure ["), let end = output[start.upperBound...].firstIndex(of: "]") {
            return String(output[start.upperBound..<end])
        }
        return output
    }

    /// The APK files of an app: base.apk, plus split APKs for apps from the Play Store.
    static func apkPaths(_ adb: Adb, _ serial: String, _ package: String) async -> [String] {
        (await adb.shell(serial, "pm path \(Adb.quote(package))") ?? "")
            .split(separator: "\n")
            .compactMap { $0.hasPrefix("package:") ? String($0.dropFirst("package:".count)).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
    }
}

/// The Apps page of one device. Read when the page opens and after each change; never polled.
@MainActor @Observable
final class AppsModel {
    private(set) var apps: [DeviceApp] = []
    private(set) var protected: Set<String> = []
    private(set) var loading = false
    private(set) var loaded = false
    /// A package being changed, and the last failure.
    private(set) var busy: String?
    var failure: String?

    private let adb: Adb?
    private let serial: String

    init(adb: Adb?, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    init(sample apps: [DeviceApp], protected: Set<String>) {
        adb = nil
        serial = "sample"
        self.apps = apps
        self.protected = protected
        loaded = true
    }

    func load(timeZone: TimeZone) async {
        guard let adb, !loading else { return }
        loading = true
        defer { loading = false }
        guard let output = await adb.shell(serial, AppList.command, timeout: 60) else {
            failure = String(localized: "Couldn't read the app list.")
            return
        }
        let result = AppList.parse(output, timeZone: timeZone)
        apps = result.apps
        protected = result.protected
        loaded = true
    }

    func open(_ app: DeviceApp) {
        guard let adb, let launcher = app.launcher else { return }
        Task { if let error = await AppList.open(adb, serial, launcher: launcher) { failure = error } }
    }

    func forceStop(_ app: DeviceApp) {
        guard let adb else { return }
        Task { await AppList.forceStop(adb, serial, app.package) }
    }

    func setEnabled(_ app: DeviceApp, _ enabled: Bool, timeZone: TimeZone) {
        change(app, timeZone: timeZone) { adb, serial in await AppList.setEnabled(adb, serial, app.package, enabled) }
    }

    func uninstall(_ app: DeviceApp, timeZone: TimeZone) {
        change(app, timeZone: timeZone) { adb, serial in await AppList.uninstall(adb, serial, app.package) }
    }

    private func change(_ app: DeviceApp, timeZone: TimeZone, _ action: @escaping (Adb, String) async -> String?) {
        guard let adb, busy == nil else { return }
        busy = app.package
        Task {
            if let error = await action(adb, serial) {
                failure = error
            }
            await load(timeZone: timeZone)
            busy = nil
        }
    }

    func apkPaths(_ app: DeviceApp) async -> [String] {
        guard let adb else { return [] }
        return await AppList.apkPaths(adb, serial, app.package)
    }
}
