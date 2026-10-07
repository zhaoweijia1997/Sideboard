import Foundation

/// What happened on the device in the last 24 hours, from Android's own usage history
/// (`dumpsys usagestats`). Covers the time Sideboard wasn't running, too.
struct Timeline: Equatable, Sendable {
    struct Event: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            case startup
            case shutdown
            case screenOn
            case screenOff
            case app(String)
        }

        let date: Date
        let kind: Kind
        var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
    }

    /// Oldest first. Repeats of the same app in a row are merged.
    var events: [Event]

    static let command =
        "dumpsys usagestats | grep -E 'type=(ACTIVITY_RESUMED|SCREEN_INTERACTIVE|SCREEN_NON_INTERACTIVE|DEVICE_STARTUP|DEVICE_SHUTDOWN) '"

    /// Lines like
    ///
    ///     time="2026-10-07 11:11:51" type=SCREEN_INTERACTIVE package=android flags=0x0
    ///     time="2026-10-07 11:34:48" type=ACTIVITY_RESUMED package=com.example.app class=…
    ///
    /// Times are in the device's time zone. `bootDate` adds a startup event when the device's
    /// own history doesn't have one.
    static func parse(_ output: String, timeZone: TimeZone, bootDate: Date?, now: Date = Date()) -> Timeline {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var events: [Event] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            guard let match = line.firstMatch(of: /time="([^"]+)" type=(\w+) package=(\S+)/),
                  let date = formatter.date(from: String(match.1)) else { continue }
            // The dump can list the same event in more than one section.
            guard seen.insert("\(match.1) \(match.2) \(match.3)").inserted else { continue }
            let kind: Event.Kind
            switch match.2 {
            case "SCREEN_INTERACTIVE": kind = .screenOn
            case "SCREEN_NON_INTERACTIVE": kind = .screenOff
            case "DEVICE_STARTUP": kind = .startup
            case "DEVICE_SHUTDOWN": kind = .shutdown
            default:
                // System dialogs, such as the debugging prompt, aren't apps people opened.
                guard match.3 != "com.android.systemui" else { continue }
                kind = .app(String(match.3))
            }
            events.append(Event(date: date, kind: kind))
        }
        events.sort { $0.date < $1.date }

        if let bootDate, now.timeIntervalSince(bootDate) < 86_400,
           !events.contains(where: { $0.kind == .startup && abs($0.date.timeIntervalSince(bootDate)) < 300 }) {
            let index = events.firstIndex { $0.date > bootDate } ?? events.endIndex
            events.insert(Event(date: bootDate, kind: .startup), at: index)
        }

        var merged: [Event] = []
        var lastApp: String?
        for event in events {
            if case let .app(package) = event.kind {
                if package == lastApp { continue }
                lastApp = package
            } else if event.kind != .screenOn {
                // After the screen comes back, the same app opening again is worth showing.
                lastApp = nil
            }
            merged.append(event)
        }
        return Timeline(events: merged)
    }

    /// How long the screen has been on since `start` (midnight, normally).
    /// Before the first screen event, the screen was in the opposite state of that event.
    func screenOnTime(since start: Date, now: Date = Date(), screenIsOn: Bool? = nil) -> TimeInterval {
        let screenEvents = events.filter { [.screenOn, .screenOff, .startup, .shutdown].contains($0.kind) }
        var on: Bool
        if let first = screenEvents.first {
            on = first.kind == .screenOff || first.kind == .shutdown
        } else {
            on = screenIsOn ?? false
        }
        var total: TimeInterval = 0
        var mark = start
        for event in screenEvents {
            if event.date > start {
                if on { total += event.date.timeIntervalSince(max(mark, start)) }
                mark = event.date
            }
            switch event.kind {
            case .screenOn: on = true
            case .screenOff, .shutdown: on = false
            // A startup is followed by its own screen-on event; until then it counts as off.
            case .startup: on = false
            case .app: break
            }
        }
        if on, now > max(mark, start) { total += now.timeIntervalSince(max(mark, start)) }
        return total
    }

    /// Time in front per app since `start`, while the screen was on, longest first.
    func appTime(since start: Date, now: Date = Date()) -> [(package: String, time: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        var current: (package: String, since: Date)?
        func close(at date: Date) {
            if let current, date > start {
                totals[current.package, default: 0] += date.timeIntervalSince(max(current.since, start))
            }
            current = nil
        }
        for event in events {
            switch event.kind {
            case let .app(package):
                close(at: event.date)
                current = (package, event.date)
            case .screenOff, .shutdown, .startup:
                close(at: event.date)
            case .screenOn:
                break
            }
        }
        close(at: now)
        return totals.filter { $0.value >= 60 }.map { ($0.key, $0.value) }.sorted { $0.time > $1.time }
    }
}
