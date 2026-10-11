import Darwin
import Foundation

/// Touches, scrolling and keys sent to the device the moment they happen, so a drag on the Mac
/// is a finger moving on the device and not one swipe replayed afterwards.
///
/// `adb shell input` starts a program on the device for every command, which takes a good part
/// of a second. This uses the device-side server of scrcpy instead
/// (https://github.com/Genymobile/scrcpy, Apache License 2.0; bundled unchanged as
/// Resources/scrcpy-server): one program started once, listening on a socket that adb forwards
/// to the Mac. It runs with video and audio off, as the shell user, changes no setting on the
/// device, and ends when the socket closes; its file in the device's temporary folder is
/// removed again.
final class TouchLink: @unchecked Sendable {
    /// The scrcpy release the bundled server is from. The server refuses any other number.
    static let serverVersion = "5.0.1"
    /// Where the server's file goes on the device. Each link adds its own number to this, so one
    /// link tidying up can't remove the file of the next.
    static let devicePrefix = "/data/local/tmp/sideboard-touch-"

    /// SIDEBOARD_TOUCH_SERVER names the file instead, for tests run outside the app bundle.
    static var bundledServer: URL? {
        ProcessInfo.processInfo.environment["SIDEBOARD_TOUCH_SERVER"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "scrcpy-server", withExtension: nil)
    }

    enum Touch: UInt8 {
        case down = 0, up = 1, move = 2
    }

    private let adb: Adb
    private let serial: String
    /// Names this link's socket and file on the device.
    private let id = UInt32.random(in: 1..<0x7FFF_FFFF)
    private var devicePath: String { Self.devicePrefix + String(format: "%08x.jar", id) }
    /// Writes go out in order, off the main thread.
    private let queue = DispatchQueue(label: "Sideboard touch link", qos: .userInteractive)
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var port: Int?
    private var process: Process?
    private var stopped = false

    /// Called once, from another thread, when the device's side went away by itself.
    var onClosed: (@Sendable () -> Void)?

    init(adb: Adb, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    var isReady: Bool { lock.withLock { socket >= 0 } }

    /// Puts the server on the device, starts it and connects. False when any step fails: an old
    /// Android, no room, a device that doesn't let the shell start programs.
    func start() async -> Bool {
        guard let server = Self.bundledServer else { return false }
        guard let pushed = await adb.execute(["-s", serial, "push", server.path, devicePath], timeout: 30), pushed.succeeded,
              !isStopped else { return await giveUp() }
        // Any free port on the Mac; adb prints the one it took.
        let name = String(format: "scrcpy_%08x", id)
        guard let forwarded = await adb.execute(["-s", serial, "forward", "tcp:0", "localabstract:\(name)"]), forwarded.succeeded,
              let port = Int(forwarded.text.trimmingCharacters(in: .whitespacesAndNewlines)), !isStopped else { return await giveUp() }
        lock.withLock { self.port = port }

        let command = "CLASSPATH=\(devicePath) app_process / com.genymobile.scrcpy.Server \(Self.serverVersion) "
            + Self.options(id: id).joined(separator: " ")
        let process = adb.launch(["-s", serial, "shell", command], onOutput: { _ in }, onExit: { _ in })
        lock.withLock { self.process = process }
        guard process != nil else { return await giveUp() }

        // The server needs a moment before it listens. adb accepts the connection either way,
        // and hangs up if nobody's there; the server says hello with one byte.
        for _ in 0..<40 {
            if isStopped { break }
            if let descriptor = Self.connect(port: port) {
                let taken = lock.withLock { () -> Bool in
                    guard !stopped else { return false }
                    socket = descriptor
                    return true
                }
                guard taken else {
                    close(descriptor)
                    break
                }
                listen(descriptor)
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await giveUp()
    }

    /// What the server is asked to do: listen for control only, and leave the device as it is.
    static func options(id: UInt32) -> [String] {
        [
            String(format: "scid=%08x", id), "log_level=warn", "tunnel_forward=true",
            "video=false", "audio=false", "control=true",
            // Nothing on the device changes because the Mac is looking at it.
            "power_on=false", "stay_awake=false", "show_touches=false", "power_off_on_close=false",
            "clipboard_autosync=false", "cleanup=true", "send_device_meta=false",
        ]
    }

    func stop() {
        let (descriptor, port, process) = lock.withLock { () -> (Int32, Int?, Process?) in
            stopped = true
            defer {
                socket = -1
                self.port = nil
                self.process = nil
            }
            return (socket, self.port, self.process)
        }
        // Closing the socket is what ends the server on the device.
        if descriptor >= 0 { queue.async { close(descriptor) } }
        if let process, process.isRunning { process.terminate() }
        let adb = adb, serial = serial, devicePath = devicePath
        Task.detached {
            if let port { _ = await adb.execute(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5) }
            // The server removes its file when it ends; this is for the times it couldn't.
            _ = await adb.shell(serial, "rm -f \(devicePath)", timeout: 5)
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func giveUp() async -> Bool {
        stop()
        return false
    }

    // MARK: Sending

    /// `x` and `y` in the device's own screen coordinates.
    func touch(_ action: Touch, x: Int, y: Int, screen: (width: Int, height: Int)) {
        send(Self.touchMessage(action, x: x, y: y, screen: screen))
    }

    /// A mouse wheel over that point: positive `vertical` scrolls up, in wheel clicks.
    func scroll(x: Int, y: Int, screen: (width: Int, height: Int), horizontal: Double, vertical: Double) {
        send(Self.scrollMessage(x: x, y: y, screen: screen, horizontal: horizontal, vertical: vertical))
    }

    /// An Android key code, pressed and let go.
    func press(_ keycode: Int) {
        send(Self.keyMessage(down: true, keycode: keycode) + Self.keyMessage(down: false, keycode: keycode))
    }

    private func send(_ message: Data) {
        queue.async { [self] in
            let descriptor = lock.withLock { socket }
            guard descriptor >= 0 else { return }
            message.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                    if count <= 0 { break }
                    sent += count
                }
            }
        }
    }

    // MARK: Messages (scrcpy's control protocol, big-endian)

    /// A finger, not a mouse: apps then scroll, fling and long-press as they do under a finger.
    static let finger = UInt64(bitPattern: -2)

    static func touchMessage(_ action: Touch, x: Int, y: Int, screen: (width: Int, height: Int)) -> Data {
        var data = Data([2, action.rawValue])
        data.append(bigEndian: finger)
        data.append(position(x: x, y: y, screen: screen))
        // Pressure, 0…1 in 16 bits: a finger that left the glass presses nothing.
        data.append(bigEndian: action == .up ? UInt16(0) : UInt16.max)
        // The button that changed, and the buttons held: none, for a finger.
        data.append(bigEndian: UInt32(0))
        data.append(bigEndian: UInt32(0))
        return data
    }

    static func scrollMessage(x: Int, y: Int, screen: (width: Int, height: Int), horizontal: Double, vertical: Double) -> Data {
        // -16…16 clicks squeezed into a signed 16-bit fraction.
        func fraction(_ clicks: Double) -> Int16 {
            Int16(clamping: Int((min(max(clicks / 16, -1), 1) * 32768).rounded(.towardZero)))
        }
        var data = Data([3])
        data.append(position(x: x, y: y, screen: screen))
        data.append(bigEndian: fraction(horizontal))
        data.append(bigEndian: fraction(vertical))
        data.append(bigEndian: UInt32(0))
        return data
    }

    static func keyMessage(down: Bool, keycode: Int) -> Data {
        var data = Data([0, down ? 0 : 1])
        data.append(bigEndian: UInt32(clamping: keycode))
        // Not a repeat, no modifier keys.
        data.append(bigEndian: UInt32(0))
        data.append(bigEndian: UInt32(0))
        return data
    }

    private static func position(x: Int, y: Int, screen: (width: Int, height: Int)) -> Data {
        var data = Data()
        data.append(bigEndian: Int32(clamping: x))
        data.append(bigEndian: Int32(clamping: y))
        data.append(bigEndian: UInt16(clamping: screen.width))
        data.append(bigEndian: UInt16(clamping: screen.height))
        return data
    }

    // MARK: The socket

    /// Connects to the forwarded port and waits for the server's first byte. Nil when nobody
    /// answers (yet).
    private static func connect(port: Int) -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        // A broken connection is an error to handle, not a signal that ends Sideboard.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Each touch goes out at once instead of waiting to be bundled with the next.
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var hello: UInt8 = 1
        guard connected == 0, read(descriptor, &hello, 1) == 1 else {
            close(descriptor)
            return nil
        }
        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    /// The server may write back (the device's clipboard, when asked); nothing here asks, but
    /// what arrives must be read, and the end of the stream is how its leaving is noticed.
    private func listen(_ descriptor: Int32) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(descriptor, &buffer, buffer.count) > 0 {}
            guard let self else { return }
            let wasOpen = self.lock.withLock { () -> Bool in
                guard self.socket == descriptor else { return false }
                self.socket = -1
                return true
            }
            if wasOpen {
                close(descriptor)
                self.onClosed?()
            }
        }
        thread.name = "Sideboard touch link"
        thread.start()
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
