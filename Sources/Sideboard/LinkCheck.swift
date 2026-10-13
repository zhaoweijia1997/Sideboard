import CoreMedia
import Foundation
import Network

/// `--link-check [host:port [serial]]`: Sideboard Link from the Mac's side, without the window.
/// With nothing after it, looks on the network for five seconds and lists who announces the
/// app. With an address, asks that device for its screen and counts the pictures that arrive
/// (the device asks its owner the first time). With the device's adb name as well (an emulator
/// with the port forwarded), also drags, presses Home and types, and looks through adb at what
/// that did.
enum LinkCheck {
    /// `--link-log [host:port]`: what a device's Link app wrote down about itself. With no address,
    /// every device found on the network (or remembered and still answering) in five seconds.
    static func log(target: String?) async {
        var places: [(String, NWEndpoint)] = []
        if let target, let endpoint = LinkMemory.endpoint(target.contains(":") ? target : target + ":47600") {
            places = [(target, endpoint)]
        } else {
            let browser = await LinkBrowser.shared
            await browser.start()
            try? await Task.sleep(for: .seconds(5))
            places = await browser.devices.map { ($0.name, $0.endpoint) }
            if places.isEmpty { print("No Link device found on the network") }
        }
        for (name, endpoint) in places {
            print("== \(name)")
            print(await LinkSetup.journal(of: endpoint) ?? "No log: the device didn't answer, hasn't allowed this Mac, or runs a Link older than 0.6.")
        }
    }

    static func run(target: String?, serial: String?) async {
        var failures = 0
        func expect(_ what: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        guard let target else {
            print("On the network")
            let browser = await LinkBrowser.shared
            await browser.start()
            try? await Task.sleep(for: .seconds(5))
            let found = await browser.devices
            for device in found { print("  \(device.name)") }
            if await browser.blocked { print("  macOS isn't letting this copy of Sideboard look on the local network (Privacy & Security → Local Network)") }
            print(found.isEmpty ? "Nobody announces Sideboard Link" : "\(found.count) found")
            return
        }
        let parts = target.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else {
            print("Expected host:port")
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(String(parts[0])), port: port)

        print("Screen")
        let stream = LinkStream(endpoint: endpoint)
        let counted = Counter()
        stream.onSample = { _ in counted.add() }
        stream.onEvent = { event in
            switch event {
            case .asking: print("  …the device is asking its owner; allow this Mac there")
            case let .live(width, height): counted.size = "\(width) × \(height)"
            case let .failed(reason): counted.failure = reason
            }
        }
        let started = Date()
        stream.start()
        // Time for the owner to answer, the first time.
        while counted.count == 0, counted.failure == nil, Date().timeIntervalSince(started) < 70 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        expect("a first picture", counted.count > 0, counted.failure ?? String(format: "%.1f s, %@", Date().timeIntervalSince(started), counted.size ?? "?"))
        let first = counted.count
        try? await Task.sleep(for: .seconds(4))
        expect("pictures keep coming", counted.count > first, "\(counted.count - first) in 4 s")

        print("Touches")
        let touch = LinkTouch(endpoint: endpoint)
        touch.start()
        for _ in 0..<30 where !touch.isReady && !touch.isOff { try? await Task.sleep(for: .milliseconds(100)) }
        expect("connected", touch.isReady || touch.isOff)
        expect("the device's accessibility service is on", touch.isReady)

        if touch.isReady, let serial, let adb = Adb.locate() {
            func screenText() async -> String {
                _ = await adb.shell(serial, "uiautomator dump /data/local/tmp/sideboard-check.xml >/dev/null 2>&1")
                let xml = await adb.shell(serial, "cat /data/local/tmp/sideboard-check.xml; rm -f /data/local/tmp/sideboard-check.xml") ?? ""
                return xml.matches(of: /text="([^"]+)"/).map { String($0.1) }.joined(separator: "|")
            }
            _ = await adb.shell(serial, "am force-stop com.android.settings; am start -a android.settings.SETTINGS >/dev/null")
            try? await Task.sleep(for: .seconds(2))
            let before = await screenText()
            // Looking at the screen through adb (uiautomator) switches accessibility services off
            // for a few seconds; give ours time to come back before each touch.
            try? await Task.sleep(for: .seconds(4))
            let beforeDrag = counted.count
            touch.touch(.down, x: 0.5, y: 0.75)
            for step in 1...24 {
                try? await Task.sleep(for: .milliseconds(16))
                touch.touch(.move, x: 0.5, y: 0.75 - 0.5 * Double(step) / 24)
            }
            touch.touch(.up, x: 0.5, y: 0.25)
            try? await Task.sleep(for: .seconds(2))
            let after = await screenText()
            expect("a drag scrolled the list", !before.isEmpty && before != after,
                   "\(before.split(separator: "|").prefix(3).joined(separator: ", ")) → \(after.split(separator: "|").prefix(3).joined(separator: ", "))")
            expect("and the pictures showed it", counted.count - beforeDrag > 10, "\(counted.count - beforeDrag) pictures")
            try? await Task.sleep(for: .seconds(4))
            touch.scroll(x: 0.5, y: 0.5, horizontal: 0, vertical: 4)
            try? await Task.sleep(for: .seconds(2))
            let wheeled = await screenText()
            expect("the wheel scrolled it back", wheeled != after)
            try? await Task.sleep(for: .seconds(4))
            touch.press(.home)
            try? await Task.sleep(for: .seconds(1.5))
            let front = await adb.shell(serial, "dumpsys activity activities | grep -m1 ResumedActivity") ?? ""
            expect("Home went home", front.contains("auncher"), front.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        touch.stop()
        stream.stop()
        try? await Task.sleep(for: .milliseconds(500))
        print(failures == 0 ? "All checks passed" : "\(failures) checks FAILED")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var pictures = 0
        private var sizeText: String?
        private var failed: String?

        func add() { lock.withLock { pictures += 1 } }
        var count: Int { lock.withLock { pictures } }
        var size: String? {
            get { lock.withLock { sizeText } }
            set { lock.withLock { sizeText = newValue } }
        }
        var failure: String? {
            get { lock.withLock { failed } }
            set { lock.withLock { failed = newValue } }
        }
    }
}
