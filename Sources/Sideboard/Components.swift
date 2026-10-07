import SwiftUI

/// Number, size, time and duration formatting in the window's language.
struct Formats {
    let locale: Locale

    func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        return Duration.seconds(seconds - seconds % 60)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    /// Settings such as screen timeouts, which can be seconds.
    func setting(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds))
            .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// "15:07" today, "Oct 6, 15:07" on other days.
    func dayAndTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? time(date) : date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    func frequency(megahertz: Double) -> String {
        megahertz >= 1000
            ? Measurement(value: megahertz / 1000, unit: UnitFrequency.gigahertz)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))).locale(locale))
            : Measurement(value: megahertz, unit: UnitFrequency.megahertz)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }

    /// "2026-10-07T231509", in the Mac's time zone, for file names. ISO 8601 styles use UTC
    /// unless they're given a time zone.
    static func fileStamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
    }

    func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }
}

/// A rounded box with a title, used for every reading.
struct Card<Content: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

/// A thin bar for a fraction (memory, storage).
struct UsageBar: View {
    let fraction: Double
    /// Turns orange above 90%, for things filling up (memory, storage); off for rankings.
    var warns = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(warns && fraction > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

/// The big number in a card.
struct BigValue: View {
    let text: Text

    init(_ text: Text) { self.text = text }
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.system(size: 24, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// A label and a value on one line, for the Details page.
struct InfoRow: View {
    let label: LocalizedStringKey
    let value: Text

    init(_ label: LocalizedStringKey, _ value: Text) {
        self.label = label
        self.value = value
    }

    init(_ label: LocalizedStringKey, verbatim value: String?) {
        self.label = label
        self.value = value.map { Text(verbatim: $0) } ?? Text(verbatim: "–")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}

struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Language switcher, as in the sidebar.
struct LanguageMenu: View {
    @Binding var language: AppLanguage

    var body: some View {
        Menu {
            Picker(selection: $language) {
                Text("Follow System").tag(AppLanguage.system)
                Divider()
                ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                    Text(verbatim: language.nativeName).tag(language)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                if language == .system {
                    Text("Follow System")
                } else {
                    Text(verbatim: language.nativeName)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onChange(of: language) { _, newValue in newValue.persistForNextLaunch() }
    }
}

/// What a failed connection means and what to try.
struct ConnectProblemText: View {
    let problem: Adb.ConnectResult

    var body: some View {
        Group {
            switch problem {
            case .connected:
                EmptyView()
            case .needsApproval:
                Text("Look at the device's screen and allow debugging. Tick “Always allow from this computer” so it won't ask again.")
            case .refused:
                Text("Nothing answered on that port. Turn on network debugging on the device (Developer options), or check the port.")
            case .unreachable:
                Text("The device didn't answer. Check that it's on, on the same network, and that the address is right. If all of that is fine, macOS may be keeping adb off the local network: try Restart adb.")
            case .timedOut:
                Text("The device took too long to answer. Check that it's on and on the same network.")
            case let .failed(message):
                Text("Couldn't connect: \(message)")
            }
        }
        .font(.callout)
        .foregroundStyle(problem == .needsApproval ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Steps for turning on debugging, on TVs, boxes, phones and tablets.
struct EnableDebuggingSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. On the device, open Settings → About (on TVs: Settings → System → About) and click Build number seven times to unlock Developer options.")
            Text("2. In Developer options, turn on USB debugging. To connect over the network, also turn on Network debugging (TVs and boxes) or Wireless debugging (phones and tablets, Android 11 and later).")
            Text("3. Connect it by USB, or add it here by its IP address (Settings → Network shows it).")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension DeviceStore.Entry {
    var symbol: String { isTV ? "tv" : "candybarphone" }
}
