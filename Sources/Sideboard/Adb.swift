import Foundation

/// Runs adb, the Android Debug Bridge from Google's platform-tools. Sideboard does
/// everything through it, so nothing has to be installed on the Android device.
struct Adb: Sendable {
    let path: String

    /// Where platform-tools usually end up: the Android SDK, then Homebrew (Apple silicon, Intel).
    static func locate() -> Adb? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        for variable in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let sdk = ProcessInfo.processInfo.environment[variable] {
                candidates.insert("\(sdk)/platform-tools/adb", at: 0)
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(Adb.init)
    }

    // MARK: Devices

    struct Device: Identifiable, Hashable, Sendable {
        enum State: Sendable { case online, unauthorized, offline }

        /// adb's name for the device: host:port over the network, a serial number over USB.
        /// USB serial numbers are never shown in the window.
        let serial: String
        let state: State
        let model: String?

        var id: String { serial }
        var isNetwork: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
    }

    /// Starts the background adb server on its own, with nothing attached to its output.
    func startServer() async {
        _ = await execute(["start-server"], timeout: 20)
    }

    /// A server started by another app (Terminal, Android Studio) may not be allowed onto
    /// the local network, so network devices fail with "No route to host". Restarting it
    /// from Sideboard gives it Sideboard's permission. Every device disconnects for a moment.
    func restartServer() async {
        _ = await execute(["kill-server"], timeout: 10)
        await startServer()
    }

    func devices() async -> [Device]? {
        guard let output = await execute(["devices", "-l"]), output.succeeded else { return nil }
        return Self.parseDevices(output.text)
    }

    /// `adb devices -l`:
    ///
    ///     List of devices attached
    ///     192.168.1.42:5555      device product:… model:Example_TV device:… transport_id:1
    static func parseDevices(_ text: String) -> [Device] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let state: Device.State
            switch fields[1] {
            case "device": state = .online
            case "unauthorized": state = .unauthorized
            case "offline", "authorizing", "connecting": state = .offline
            default: return nil  // recovery, sideload, bootloader
            }
            let model = fields.first { $0.hasPrefix("model:") }
                .map { $0.dropFirst("model:".count).replacingOccurrences(of: "_", with: " ") }
            return Device(serial: String(fields[0]), state: state, model: model)
        }
    }

    // MARK: Connecting over the network

    enum ConnectResult: Equatable, Sendable {
        case connected
        /// The device shows a prompt and is listed as unauthorized until someone allows it.
        case needsApproval
        /// Nothing listens on that port: network debugging is off.
        case refused
        /// Wrong address, device off, or macOS keeping adb off the local network.
        case unreachable
        case timedOut
        case failed(String)
    }

    func connect(_ address: String) async -> ConnectResult {
        guard let output = await execute(["connect", address], timeout: 20) else { return .failed("adb didn't run") }
        if output.timedOut { return .timedOut }
        let text = output.message.lowercased()
        if text.contains("failed to authenticate") { return .needsApproval }
        if text.hasPrefix("connected to") || text.hasPrefix("already connected") { return .connected }
        if text.contains("refused") { return .refused }
        if ["no route to host", "host is down", "network is unreachable"].contains(where: text.contains) { return .unreachable }
        if text.contains("timed out") { return .timedOut }
        return .failed(output.message)
    }

    func disconnect(_ address: String) async {
        _ = await execute(["disconnect", address])
    }

    /// Wireless debugging on Android 11 and later: pair once with the code the device shows.
    /// Returns nil on success, otherwise adb's message.
    func pair(_ address: String, code: String) async -> String? {
        guard let output = await execute(["pair", address, code], timeout: 30) else { return "adb didn't run" }
        if output.message.lowercased().contains("successfully paired") { return nil }
        return output.timedOut ? "timed out" : output.message
    }

    // MARK: Commands on a device

    func shell(_ serial: String, _ command: String, timeout: TimeInterval = 15) async -> String? {
        guard let output = await execute(["-s", serial, "shell", command], timeout: timeout), output.succeeded else { return nil }
        return output.text
    }

    /// The screen as PNG. Protected video (most streaming apps) comes out black.
    func screenshot(_ serial: String) async -> Data? {
        guard let output = await execute(["-s", serial, "exec-out", "screencap", "-p"], timeout: 30), output.succeeded,
              output.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        return output.data
    }

    func press(_ serial: String, key: Int) async {
        _ = await execute(["-s", serial, "shell", "input", "keyevent", String(key)], timeout: 10)
    }

    /// Installs or updates an app. Returns nil on success, otherwise the reason,
    /// such as INSTALL_FAILED_VERSION_DOWNGRADE.
    func install(_ serial: String, apk: URL) async -> String? {
        guard let output = await execute(["-s", serial, "install", "-r", apk.path], timeout: 900) else { return "adb didn't run" }
        if output.succeeded && output.message.contains("Success") { return nil }
        if output.timedOut { return "timed out" }
        let message = output.message
        if let start = message.range(of: "Failure ["), let end = message[start.upperBound...].firstIndex(of: "]") {
            return String(message[start.upperBound..<end])
        }
        return Self.lastLine(message)
    }

    /// Copies a file or folder into the device's Download folder. Returns nil on success,
    /// otherwise the reason.
    func push(_ serial: String, _ url: URL, to folder: String = Adb.downloadFolder) async -> String? {
        guard let output = await execute(["-s", serial, "push", url.path, folder], timeout: 3600) else { return "adb didn't run" }
        if output.succeeded { return nil }
        return output.timedOut ? "timed out" : Self.lastLine(output.message)
    }

    static let downloadFolder = "/sdcard/Download/"

    /// Copies a file or folder from the device to `local` (the full destination path).
    /// Returns nil on success, otherwise the reason.
    func pull(_ serial: String, _ remote: String, to local: URL) async -> String? {
        guard let output = await execute(["-s", serial, "pull", remote, local.path], timeout: 3600) else { return "adb didn't run" }
        if output.succeeded { return nil }
        return output.timedOut ? "timed out" : Self.lastLine(output.message)
    }

    /// Runs a shell command and returns its output whatever the exit status, for commands whose
    /// messages matter ("Success", "Failure [...]"). Nil only if adb couldn't run or timed out.
    func shellOutput(_ serial: String, _ command: String, timeout: TimeInterval = 30) async -> String? {
        guard let output = await execute(["-s", serial, "shell", command], timeout: timeout), !output.timedOut else { return nil }
        return output.message
    }

    /// Single-quotes a path or name for the device's shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "adb: error: ", with: "") } ?? text
    }

    // MARK: Long-running commands

    /// Starts adb and returns at once, for commands that run until they're stopped (screen
    /// recording). Output arrives line by line through `onOutput`; `onExit` gets the exit status.
    /// The adb server is already running by then, so the pipe can't be inherited by it.
    func launch(_ arguments: [String], onOutput: @escaping @Sendable (String) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                onOutput(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            onExit(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        return process
    }

    // MARK: Running adb

    struct Output: Sendable {
        let status: Int32
        let data: Data
        let error: String
        let timedOut: Bool

        var text: String { String(decoding: data, as: UTF8.self) }
        var succeeded: Bool { status == 0 && !timedOut }
        /// stdout and stderr together: adb prints its messages to either.
        var message: String { (text + error).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func execute(_ arguments: [String], timeout: TimeInterval = 15) async -> Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: executeNow(arguments, timeout: timeout))
            }
        }
    }

    /// Output goes to temporary files rather than pipes: when a command has to start the adb
    /// server, the server lives on in the background and would hold a pipe open forever.
    private func executeNow(_ arguments: [String], timeout: TimeInterval) -> Output? {
        let folder = FileManager.default.temporaryDirectory
        let outURL = folder.appending(path: "sideboard-\(UUID().uuidString).out")
        let errURL = folder.appending(path: "sideboard-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // A device that drops off the network can leave adb waiting for minutes.
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        try? out.close()
        try? err.close()
        return Output(
            status: process.terminationStatus,
            data: (try? Data(contentsOf: outURL)) ?? Data(),
            error: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
            timedOut: timedOut)
    }
}
