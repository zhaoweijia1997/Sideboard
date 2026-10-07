import SwiftUI

/// What the device has been up to: data usage per app, crashes and freezes, and what keeps it
/// busy in the background. Read when the page opens; Sideboard only reads.
struct HealthPage: View {
    let model: HealthModel
    let dashboard: DashboardModel

    @Environment(\.locale) private var locale
    @State private var usageSpan = 1

    private var formats: Formats { Formats(locale: locale) }
    private var labels: [String: String] { dashboard.labels }
    private var home: String? { dashboard.status?.home }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("A checkup of what the device has been doing. Sideboard only reads it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.loading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await model.load(timeZone: dashboard.status?.timeZone ?? .current) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(Text("Reload"))
                    .disabled(model.loading)
                }
                if let health = model.health {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)], spacing: 12) {
                        usageCard(health)
                        crashCard(health)
                        wakeupCard(health)
                        jobsCard(health)
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading the device…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .task { if model.health == nil { await model.load(timeZone: dashboard.status?.timeZone ?? .current) } }
        .alert(Text("Something went wrong"), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(verbatim: model.failure ?? "")
        }
    }

    // MARK: Data usage

    private func usageCard(_ health: DeviceHealth) -> some View {
        let rows = health.usage.map { usage -> (DeviceHealth.Usage, Int64) in
            (usage, usageSpan == 1 ? usage.day : usageSpan == 7 ? usage.week : usage.month)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        let total = rows.map(\.1).reduce(0, +)
        let top = rows.first?.1 ?? 1
        return Card(title: "Data usage", systemImage: "arrow.up.arrow.down") {
            HStack {
                Picker(selection: $usageSpan) {
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Spacer()
                Text("Total \(formats.bytes(total))").foregroundStyle(.secondary).monospacedDigit()
            }
            if rows.isEmpty {
                Text("Nothing recorded.").foregroundStyle(.secondary)
            }
            ForEach(rows.prefix(10), id: \.0.id) { usage, bytes in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        name(of: usage).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(verbatim: formats.bytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: Double(bytes) / Double(max(1, top)), warns: false)
                }
                .font(.callout)
                .padding(.vertical, 1)
            }
            Text("Everything apps sent and received, on every network. Android adds it up every two hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func name(of usage: DeviceHealth.Usage) -> Text {
        if let package = usage.packages.first {
            let name = AppNames.text(for: package, home: home, labels: labels)
            return usage.packages.count > 1 ? name + Text(verbatim: " +\(usage.packages.count - 1)") : name
        }
        switch usage.uid {
        case 0: return Text("Kernel")
        case 1000: return Text("Android system")
        case 1013, 1041, 1046: return Text("Media services")
        case 1020: return Text("Network discovery (mDNS)")
        case 1021: return Text("Location")
        case 1051, 1052: return Text("DNS")
        case 1073: return Text("Network stack")
        case 2000: return Text("adb (Sideboard and other tools)")
        case -4: return Text("Removed apps")
        case -5: return Text("Hotspot and tethering")
        default: return Text("System service (\(usage.uid))")
        }
    }

    // MARK: Crashes

    private func crashCard(_ health: DeviceHealth) -> some View {
        let week = health.crashes.filter { Date().timeIntervalSince($0.date) <= 7 * 86_400 }
        let month = health.crashes.filter { Date().timeIntervalSince($0.date) <= 30 * 86_400 }
        var byApp: [String: Int] = [:]
        for crash in month { byApp[crash.package ?? "", default: 0] += 1 }
        let worst = byApp.filter { !$0.key.isEmpty }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
        return Card(title: "Crashes and freezes", systemImage: "exclamationmark.triangle") {
            HStack(spacing: 18) {
                VStack(alignment: .leading) {
                    BigValue(verbatim: "\(week.count)")
                    Text("last 7 days").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    BigValue(verbatim: "\(month.count)")
                    Text("last 30 days").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !worst.isEmpty {
                Text("Most often").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(worst, id: \.key) { package, count in
                    HStack {
                        AppNames.text(for: package, home: home, labels: labels).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(verbatim: "× \(count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if !health.crashes.isEmpty {
                Text("Latest").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(health.crashes.prefix(6)) { crash in
                    HStack(spacing: 8) {
                        Text(verbatim: formats.dayAndTime(crash.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        kind(crash.kind)
                            .foregroundStyle(crash.kind == .appFreeze ? Color.orange : Color.red)
                            .fixedSize()
                        Group {
                            if let package = crash.package {
                                AppNames.text(for: package, home: home, labels: labels)
                            } else {
                                Text(verbatim: "")
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    .font(.callout)
                }
            } else {
                Text("No crashes on record.").foregroundStyle(.secondary)
            }
        }
    }

    private func kind(_ kind: DeviceHealth.Crash.Kind) -> Text {
        switch kind {
        case .appCrash: Text("App crashed")
        case .appFreeze: Text("Not responding")
        case .systemCrash: Text("System app crashed")
        case .nativeCrash: Text("Native crash")
        case .systemRestart: Text("System restarted")
        }
    }

    // MARK: Background

    private func wakeupCard(_ health: DeviceHealth) -> some View {
        Card(title: "Wakes the device", systemImage: "alarm") {
            if let boot = dashboard.status?.bootDate {
                Text("Alarms that woke it up, since it started \(formats.dayAndTime(boot)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if health.wakeups.isEmpty {
                Text("Nothing recorded.").foregroundStyle(.secondary)
            }
            ForEach(health.wakeups.prefix(8)) { item in
                countRow(item)
            }
            Text("Allowed to skip battery saving")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            if health.exempt.isEmpty {
                Text("No apps you added, and \(health.systemExemptCount) system parts.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(health.exempt, id: \.self) { package in
                    AppNames.text(for: package, home: home, labels: labels).font(.callout)
                }
                Text("And \(health.systemExemptCount) system parts.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func jobsCard(_ health: DeviceHealth) -> some View {
        Card(title: "Background jobs", systemImage: "gearshape.2") {
            if let since = health.recentJobsSince {
                Text("Ran since \(formats.dayAndTime(since))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if health.recentJobs.isEmpty {
                Text("Nothing recorded.").foregroundStyle(.secondary)
            }
            ForEach(health.recentJobs.prefix(6)) { item in
                countRow(item)
            }
            Text("Scheduled: \(health.jobs.map(\.count).reduce(0, +))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            ForEach(health.jobs.prefix(6)) { item in
                countRow(item)
            }
        }
    }

    private func countRow(_ item: DeviceHealth.Count) -> some View {
        HStack {
            AppNames.text(for: item.package, home: home, labels: labels).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: "\(item.count)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
