import Foundation

/// `--touch-check [serial]`: the touch link's messages against scrcpy's own examples, and, with
/// a device's adb name, a real round on that device: connect, drag a finger up the middle of
/// the screen, disconnect, and look for anything left behind. Use an emulator for the round.
/// With `--connect-only` nothing is touched on the device: connect, disconnect, look.
enum TouchLinkCheck {
    static func run(serial: String?) async {
        let touches = !CommandLine.arguments.contains("--connect-only")
        var failures = 0
        func expect(_ what: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        print("Messages")
        // The examples in scrcpy's test_control_msg_serialize.c.
        let touch = TouchLink.touchMessage(.down, x: 100, y: 200, screen: (1080, 1920))
        expect("touch", touch.count == 32 && Array(touch[0..<2]) == [2, 0]
            && Array(touch[2..<10]) == [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe]
            && Array(touch[10..<22]) == [0, 0, 0, 0x64, 0, 0, 0, 0xc8, 0x04, 0x38, 0x07, 0x80]
            && Array(touch[22..<24]) == [0xff, 0xff] && touch[24...].allSatisfy { $0 == 0 })
        expect("a lifted finger presses nothing", Array(TouchLink.touchMessage(.up, x: 1, y: 1, screen: (10, 10))[22..<24]) == [0, 0])
        let scroll = TouchLink.scrollMessage(x: 260, y: 1026, screen: (1080, 1920), horizontal: 16, vertical: -16)
        expect("scroll", Array(scroll) == [3, 0, 0, 0x01, 0x04, 0, 0, 0x04, 0x02, 0x04, 0x38, 0x07, 0x80, 0x7f, 0xff, 0x80, 0x00, 0, 0, 0, 0])
        let key = TouchLink.keyMessage(down: false, keycode: 66)
        expect("key", Array(key) == [0, 1, 0, 0, 0, 0x42, 0, 0, 0, 0, 0, 0, 0, 0])
        expect("the server is in the app", TouchLink.bundledServer != nil)

        if let serial, let adb = Adb.locate() {
            print("On the device")
            let size = await adb.shell(serial, "wm size")?.firstMatch(of: /(\d+)x(\d+)/)
            guard let size, let width = Int(size.1), let height = Int(size.2) else {
                expect("read the screen size", false)
                return
            }
            func screenText() async -> String {
                _ = await adb.shell(serial, "uiautomator dump /data/local/tmp/sideboard-check.xml >/dev/null 2>&1")
                let xml = await adb.shell(serial, "cat /data/local/tmp/sideboard-check.xml; rm -f /data/local/tmp/sideboard-check.xml") ?? ""
                return xml.matches(of: /text="([^"]+)"/).map { String($0.1) }.joined(separator: "|")
            }
            if touches {
                _ = await adb.shell(serial, "am start -a android.settings.SETTINGS >/dev/null")
                try? await Task.sleep(for: .seconds(2))
            }
            let before = touches ? await screenText() : ""

            let link = TouchLink(adb: adb, serial: serial)
            let started = Date()
            let ready = await link.start()
            expect("connect", ready, String(format: "%.1f s", Date().timeIntervalSince(started)))
            if ready, touches {
                let x = width / 2
                link.touch(.down, x: x, y: height * 3 / 4, screen: (width, height))
                for step in 1...24 {
                    try? await Task.sleep(for: .milliseconds(12))
                    link.touch(.move, x: x, y: height * 3 / 4 - height / 2 * step / 24, screen: (width, height))
                }
                link.touch(.up, x: x, y: height / 4, screen: (width, height))
                try? await Task.sleep(for: .seconds(2))
                let after = await screenText()
                expect("a drag scrolled the list", !before.isEmpty && before != after,
                       "\(before.split(separator: "|").prefix(3).joined(separator: ", ")) → \(after.split(separator: "|").prefix(3).joined(separator: ", "))")
                link.scroll(x: x, y: height / 2, screen: (width, height), horizontal: 0, vertical: 6)
                try? await Task.sleep(for: .seconds(1))
                let wheeled = await screenText()
                expect("the wheel scrolled it back", wheeled != after)
                link.press(RemoteKey.home.rawValue)
                try? await Task.sleep(for: .seconds(1))
                let focus = await adb.shell(serial, "dumpsys window | grep -m1 mCurrentFocus") ?? ""
                expect("Home went home", !focus.contains("ettings"), focus.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if ready {
                let running = await adb.shell(serial, "ps -A -o ARGS | grep -c '[s]crcpy.Server'; true") ?? ""
                expect("the server runs while connected", (Int(running.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0)
            }
            link.stop()
            try? await Task.sleep(for: .seconds(3))
            let left = await adb.shell(serial, "ls \(TouchLink.devicePrefix)* 2>/dev/null; ps -A -o ARGS 2>/dev/null | grep -c '[s]crcpy'; true") ?? ""
            let lines = left.split(separator: "\n").map(String.init)
            expect("nothing left on the device", lines == ["0"], lines.joined(separator: " / "))
        }
        print(failures == 0 ? "All checks passed" : "\(failures) checks FAILED")
    }
}
