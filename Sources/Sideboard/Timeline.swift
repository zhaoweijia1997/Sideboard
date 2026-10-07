import Foundation

/// What happened on the device: power, screen and apps. Comes from Android's own usage history
/// (`dumpsys usagestats`, the last 24 hours, so it covers the time Sideboard wasn't running) and,
/// with the companion app installed, from the 90 days it keeps.
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
    /// Times are in the device's time zone.
    static func events(from output: String, timeZone: TimeZone) -> [Event] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return output.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /time="([^"]+)" type=(\w+) package=(\S+)/),
                  let date = formatter.date(from: String(match.1)) else { return nil }
            switch match.2 {
            case "SCREEN_INTERACTIVE": return Event(date: date, kind: .screenOn)
            case "SCREEN_NON_INTERACTIVE": return Event(date: date, kind: .screenOff)
            case "DEVICE_STARTUP": return Event(date: date, kind: .startup)
            case "DEVICE_SHUTDOWN": return Event(date: date, kind: .shutdown)
            default: return Event(date: date, kind: .app(String(match.3)))
            }
        }
    }

    static func parse(_ output: String, timeZone: TimeZone, bootDate: Date?, now: Date = Date()) -> Timeline {
        combine(events(from: output, timeZone: timeZone), bootDate: bootDate, now: now)
    }

    /// Puts events from any source in order: drops duplicates (the dump lists some events twice,
    /// and the companion's copy overlaps Android's), adds a startup at `bootDate` when none is
    /// near it, and merges repeats of the same app.
    static func combine(_ events: [Event], bootDate: Date?, now: Date = Date()) -> Timeline {
        var seen = Set<String>()
        var sorted = events.filter { event in
            // System dialogs, such as the debugging prompt, aren't apps people opened.
            if case let .app(package) = event.kind, package == "com.android.systemui" || package.isEmpty { return false }
            return seen.insert("\(Int(event.date.timeIntervalSince1970)) \(event.kind)").inserted
        }
        .sorted { $0.date < $1.date }

        if let bootDate, bootDate < now,
           !sorted.contains(where: { $0.kind == .startup && abs($0.date.timeIntervalSince(bootDate)) < 300 }) {
            let index = sorted.firstIndex { $0.date > bootDate } ?? sorted.endIndex
            sorted.insert(Event(date: bootDate, kind: .startup), at: index)
        }

        var merged: [Event] = []
        var lastApp: String?
        for event in sorted {
            if case let .app(package) = event.kind {
                if package == lastApp { continue }
                lastApp = package
            } else if event.kind != .screenOn {
                // After the screen comes back, the same app opening again is worth showing.
                lastApp = nil
            }
            // A startup a few minutes after another one is the same start (Android's and the companion's).
            if event.kind == .startup, let previous = merged.last(where: { $0.kind == .startup }),
               event.date.timeIntervalSince(previous.date) < 300 { continue }
            merged.append(event)
        }
        return Timeline(events: merged)
    }

    /// Days with events, newest first (midnight of each).
    var days: [Date] {
        var result: [Date] = []
        for event in events.reversed() {
            let day = Calendar.current.startOfDay(for: event.date)
            if result.last != day { result.append(day) }
        }
        return result
    }

    /// The stretches of time the screen was on between `start` and `end`. Before the first screen
    /// event, the screen was in the opposite state of that event.
    func onIntervals(from start: Date, to end: Date, screenIsOn: Bool? = nil) -> [(start: Date, end: Date)] {
        let screenEvents = events.filter { [.screenOn, .screenOff, .startup, .shutdown].contains($0.kind) }
        var on: Bool
        if let first = screenEvents.first {
            on = first.kind == .screenOff || first.kind == .shutdown
        } else {
            on = screenIsOn ?? false
        }
        var result: [(start: Date, end: Date)] = []
        var mark = start
        for event in screenEvents {
            if event.date >= end { break }
            if event.date > start {
                if on, event.date > max(mark, start) { result.append((max(mark, start), event.date)) }
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
        if on, end > max(mark, start) { result.append((max(mark, start), end)) }
        return result
    }

    /// How long the screen was on between `start` and `end`.
    func screenOnTime(from start: Date, to end: Date, screenIsOn: Bool? = nil) -> TimeInterval {
        onIntervals(from: start, to: end, screenIsOn: screenIsOn).map { $0.end.timeIntervalSince($0.start) }.reduce(0, +)
    }

    /// The share of each hour the screen was on, by weekday (Calendar weekday 1…7) and hour (0…23),
    /// averaged over the days between `start` and `end`.
    func onShareByHour(from start: Date, to end: Date) -> [[Double]] {
        let calendar = Calendar.current
        var seconds = Array(repeating: Array(repeating: 0.0, count: 24), count: 8)
        var dayCount = Array(repeating: 0.0, count: 8)
        var day = calendar.startOfDay(for: start)
        while day < end {
            dayCount[calendar.component(.weekday, from: day)] += 1
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        for interval in onIntervals(from: start, to: end) {
            var cursor = interval.start
            while cursor < interval.end {
                let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
                let hourEnd = min(interval.end, hourStart.addingTimeInterval(3600))
                seconds[calendar.component(.weekday, from: cursor)][calendar.component(.hour, from: cursor)] += hourEnd.timeIntervalSince(cursor)
                cursor = hourEnd
            }
        }
        return (0..<8).map { weekday in
            seconds[weekday].map { dayCount[weekday] > 0 ? min(1, $0 / (3600 * dayCount[weekday])) : 0 }
        }
    }

    /// Time in front per app between `start` and `end`, while the screen was on, longest first.
    func appTime(from start: Date, to end: Date) -> [(package: String, time: TimeInterval)] {
        var totals: [String: TimeInterval] = [:]
        var current: (package: String, since: Date)?
        func close(at date: Date) {
            let date = min(date, end)
            if let current, date > start, date > current.since {
                totals[current.package, default: 0] += date.timeIntervalSince(max(current.since, start))
            }
            current = nil
        }
        for event in events {
            if event.date >= end { break }
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
        close(at: end)
        return totals.filter { $0.value >= 60 }.map { ($0.key, $0.value) }.sorted { $0.time > $1.time }
    }
}
