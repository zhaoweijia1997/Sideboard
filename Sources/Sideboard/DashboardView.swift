import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    enum Page: Hashable { case overview, details, apps, files, cleanup }

    let model: DashboardModel
    let entry: DeviceStore.Entry
    @State var page: Page = .overview

    @Environment(\.locale) private var locale
    @State private var showingRemote = false
    @State private var screenshot: ScreenshotState?
    @State private var dropTargeted = false
    @State private var typing: TypingHandle?

    private struct TypingHandle: Identifiable {
        let id = UUID()
        let session: TypingSession
    }

    private var formats: Formats { Formats(locale: locale) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            Picker(selection: $page) {
                Text("Overview").tag(Page.overview)
                Text("Details").tag(Page.details)
                Text("Apps").tag(Page.apps)
                Text("Files").tag(Page.files)
                Text("Clean Up").tag(Page.cleanup)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)
            Divider()
            switch page {
            case .overview, .details:
                ScrollView {
                    Group {
                        if page == .overview {
                            OverviewPage(model: model)
                        } else {
                            DetailsPage(model: model)
                        }
                    }
                    .padding(20)
                }
            case .apps:
                AppsPage(model: model.apps, dashboard: model)
            case .files:
                FilesPage(model: model.files, dashboard: model)
            case .cleanup:
                CleanupPage(model: model.cleanup, home: model.status?.home, labels: model.labels)
            }
            if !model.transfers.isEmpty {
                Divider()
                TransfersBar(model: model)
            }
        }
        .overlay {
            if dropTargeted {
                DropOverlay(folder: page == .files ? model.files.path : nil)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // On the Files page, files go into the folder shown; elsewhere APKs are installed.
            if page == .files {
                model.upload(urls.filter(\.isFileURL), to: model.files.path)
            } else {
                model.send(urls.filter(\.isFileURL))
            }
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: page, initial: true) { _, page in
            if page == .details { model.startDetails() } else { model.stopDetails() }
        }
        .sheet(item: $screenshot) { state in
            ScreenshotView(state: state)
        }
        .sheet(item: $typing) { handle in
            TypingView(session: handle.session)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let name = entry.name ?? model.status?.model {
                        Text(verbatim: name)
                    } else {
                        Text("Android device")
                    }
                }
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                subtitle
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.unreachable {
                Label("Not answering", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            actions
        }
    }

    private var subtitle: Text {
        var parts: [Text] = []
        if let manufacturer = model.status?.manufacturer { parts.append(Text(verbatim: manufacturer)) }
        if let version = model.status?.androidVersion { parts.append(Text("Android \(version)")) }
        if let address = entry.address {
            parts.append(Text(verbatim: address))
        } else {
            parts.append(Text("USB"))
        }
        return parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { $0 + Text(verbatim: " · ") + $1 }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                showingRemote.toggle()
            } label: {
                Label("Remote", systemImage: "av.remote")
            }
            .popover(isPresented: $showingRemote, arrowEdge: .bottom) {
                RemoteView(model: model)
            }
            Button {
                if let session = model.typingSession() { typing = TypingHandle(session: session) }
            } label: {
                Label("Type Text", systemImage: "keyboard")
            }
            .disabled(model.companion == nil)
            .help(model.companion == nil ? Text("Install the companion app (Overview) to type text in any language.") : Text("Type Text"))
            Button {
                takeScreenshot()
            } label: {
                Label("Screenshot", systemImage: "camera.viewfinder")
            }
            Menu {
                Button("Send Files…") { chooseFiles(apps: false) }
                Button("Install App…") { chooseFiles(apps: true) }
            } label: {
                Label("Send", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
    }

    private func takeScreenshot() {
        screenshot = ScreenshotState()
        Task {
            let data = await model.screenshot()
            if let data, let state = screenshot {
                screenshot?.savedTo = state.save(data, deviceName: entry.name ?? model.status?.model)
            }
            screenshot?.data = data
            screenshot?.finished = true
        }
    }

    private func chooseFiles(apps: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = !apps
        if apps, let apk = UTType(filenameExtension: "apk") {
            panel.allowedContentTypes = [apk]
        }
        panel.message = apps ? String(localized: "Choose apps (.apk) to install.") : String(localized: "Choose files to copy to the device's Download folder.")
        if panel.runModal() == .OK {
            model.send(panel.urls)
        }
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    let model: DashboardModel

    @Environment(\.locale) private var locale
    private var formats: Formats { Formats(locale: locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let status = model.status {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    screenCard(status)
                    showingCard(status)
                    playingCard(status)
                    uptimeCard(status)
                    cpuCard(status)
                    memoryCard(status)
                    storageCard(status)
                    networkCard(status)
                    volumeCard(status)
                    if let level = status.batteryLevel {
                        batteryCard(level: level, charging: status.charging)
                    }
                }
                TimelineSection(model: model)
                CompanionSection(model: model)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the device…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    private func screenCard(_ status: DeviceStatus) -> some View {
        Card(title: "Screen", systemImage: "sun.max") {
            switch status.screen {
            case .on: BigValue(Text("On"))
            case .off: BigValue(Text(status.isTV ? "Standby" : "Off"))
            case .screensaver: BigValue(Text("Screensaver"))
            case .dozing: BigValue(Text("Dozing"))
            case nil: BigValue(verbatim: "–")
            }
            if let timeline = model.timeline {
                let onTime = timeline.screenOnTime(from: Calendar.current.startOfDay(for: Date()), to: Date(), screenIsOn: status.screen == .on)
                Text("On for \(formats.duration(onTime)) today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func showingCard(_ status: DeviceStatus) -> some View {
        Card(title: status.screen == .on ? "Showing" : "Last app", systemImage: "rectangle.on.rectangle") {
            if let package = status.foreground {
                BigValue(AppNames.text(for: package, home: status.home, labels: model.labels))
                if AppNames.isNamed(package, home: status.home, labels: model.labels) {
                    Text(verbatim: package)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                BigValue(verbatim: "–")
            }
        }
    }

    private func playingCard(_ status: DeviceStatus) -> some View {
        Card(title: "Now playing", systemImage: "play.rectangle") {
            if let media = status.media {
                switch media.playback {
                case .playing: BigValue(Text("Playing"))
                case .paused: BigValue(Text("Paused"))
                case .stopped: BigValue(Text("Stopped"))
                case .buffering: BigValue(Text("Loading"))
                case .other: BigValue(Text("Idle"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let title = media.title {
                        Text(verbatim: title).lineLimit(1)
                    }
                    AppNames.text(for: media.package, home: status.home, labels: model.labels)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.callout)
            } else {
                BigValue(Text("Nothing"))
            }
        }
    }

    private func uptimeCard(_ status: DeviceStatus) -> some View {
        Card(title: "Running for", systemImage: "clock") {
            if let uptime = status.uptime, let boot = status.bootDate {
                BigValue(verbatim: formats.duration(uptime))
                Text("Started \(formats.dayAndTime(boot))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                BigValue(verbatim: "–")
            }
        }
    }

    private func cpuCard(_ status: DeviceStatus) -> some View {
        Card(title: "CPU", systemImage: "cpu") {
            BigValue(verbatim: model.cpuUsage.map(formats.percent) ?? "…")
            VStack(alignment: .leading, spacing: 1) {
                if let cores = status.cores {
                    if let frequency = status.cpuFrequency {
                        Text("\(cores) cores · \(formats.frequency(megahertz: frequency))")
                    } else {
                        Text("\(cores) cores")
                    }
                }
                if let temperature = status.temperature {
                    Text("Temperature: \(formats.temperature(temperature))")
                } else {
                    Text("Temperature: not reported by this device")
                }
                if let level = status.thermalStatus, level > 0 {
                    Text("Running hot (level \(level))").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func memoryCard(_ status: DeviceStatus) -> some View {
        Card(title: "Memory", systemImage: "memorychip") {
            if let used = status.memoryUsed, let total = status.memoryTotal, let available = status.memoryAvailable {
                BigValue(verbatim: formats.percent(used))
                UsageBar(fraction: used)
                Text("\(formats.bytes(available)) free of \(formats.bytes(total))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                BigValue(verbatim: "–")
            }
        }
    }

    private func storageCard(_ status: DeviceStatus) -> some View {
        Card(title: "Storage", systemImage: "internaldrive") {
            if let used = status.storageUsed, let total = status.storageTotal, let available = status.storageAvailable {
                BigValue(verbatim: formats.bytes(available))
                UsageBar(fraction: used)
                Text("free of \(formats.bytes(total))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                BigValue(verbatim: "–")
            }
        }
    }

    private func networkCard(_ status: DeviceStatus) -> some View {
        Card(title: "Network", systemImage: "network") {
            if let address = status.addresses.first(where: { $0.kind != .other }) ?? status.addresses.first {
                switch address.kind {
                case .wired: BigValue(Text("Wired"))
                case .wifi: BigValue(Text("Wi-Fi"))
                case .mobile: BigValue(Text("Mobile data"))
                case .other: BigValue(verbatim: address.interface)
                }
                ForEach(status.addresses, id: \.address) { address in
                    Text(verbatim: address.address)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                BigValue(Text("Offline"))
            }
        }
    }

    private func volumeCard(_ status: DeviceStatus) -> some View {
        Card(title: "Volume", systemImage: "speaker.wave.2") {
            if let volume = status.volume {
                if let maximum = status.volumeMax, maximum > 0 {
                    BigValue(verbatim: "\(volume) / \(maximum)")
                } else {
                    BigValue(verbatim: "\(volume)")
                }
            } else {
                BigValue(verbatim: "–")
            }
            HStack(spacing: 6) {
                Button { model.press(.volumeDown) } label: { Image(systemName: "speaker.minus") }
                    .help(Text("Volume down"))
                Button { model.press(.mute) } label: { Image(systemName: "speaker.slash") }
                    .help(Text("Mute"))
                Button { model.press(.volumeUp) } label: { Image(systemName: "speaker.plus") }
                    .help(Text("Volume up"))
            }
            .controlSize(.small)
        }
    }

    private func batteryCard(level: Int, charging: Bool) -> some View {
        Card(title: "Battery", systemImage: charging ? "battery.100.bolt" : "battery.75") {
            BigValue(verbatim: formats.percent(Double(level) / 100))
            UsageBar(fraction: Double(level) / 100)
            if charging {
                Text("Charging").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Timeline

private struct TimelineSection: View {
    let model: DashboardModel

    @Environment(\.locale) private var locale
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var showingAll = false
    private let shortList = 25

    private var formats: Formats { Formats(locale: locale) }
    private var labels: [String: String] { model.labels }

    var body: some View {
        Card(title: model.companion != nil ? "History" : "Last 24 hours", systemImage: "calendar.day.timeline.left") {
            if let timeline = model.timeline {
                let days = availableDays(timeline)
                if days.count > 2 {
                    ScreenTimeChart(timeline: timeline, days: Array(days.prefix(7)).reversed(), selected: $day)
                        .padding(.bottom, 6)
                }
                dayHeader(timeline, days: days)
                let shown = visibleEvents(timeline)
                if shown.isEmpty {
                    Text("Nothing recorded on this day.").foregroundStyle(.secondary)
                } else {
                    events(Array(shown.prefix(showingAll ? shown.count : shortList)))
                    if shown.count > shortList {
                        Button(showingAll ? "Show fewer" : "Show all \(shown.count)") { showingAll.toggle() }
                            .buttonStyle(.link)
                            .padding(.top, 4)
                    }
                }
                Group {
                    if model.companion != nil {
                        Text("From the companion app on the device, which keeps 90 days.")
                    } else {
                        Text("From the device's own usage history, so it includes times when Sideboard wasn't open. Install the companion app to keep more than a day.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the device…").foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: day) { showingAll = false }
    }

    /// Today first, then every earlier day with events.
    private func availableDays(_ timeline: Timeline) -> [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return [today] + timeline.days.filter { $0 != today }
    }

    private func dayHeader(_ timeline: Timeline, days: [Date]) -> some View {
        let end = min(Date(), Calendar.current.date(byAdding: .day, value: 1, to: day) ?? Date())
        let onTime = timeline.screenOnTime(from: day, to: end, screenIsOn: model.status?.screen == .on)
        let apps = timeline.appTime(from: day, to: end).prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker(selection: $day) {
                    ForEach(days, id: \.self) { date in
                        dayName(date).tag(date)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                Text("Screen on \(formats.duration(onTime))")
                    .foregroundStyle(.secondary)
            }
            if !apps.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Most used:")
                        .foregroundStyle(.secondary)
                    ForEach(apps, id: \.package) { app in
                        (AppNames.text(for: app.package, home: model.status?.home, labels: labels)
                            + Text(verbatim: " ") + Text(verbatim: formats.duration(app.time)).foregroundColor(.secondary))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                .font(.callout)
            }
        }
        .padding(.bottom, 4)
    }

    private func dayName(_ date: Date) -> Text {
        if Calendar.current.isDateInToday(date) { return Text("Today") }
        if Calendar.current.isDateInYesterday(date) { return Text("Yesterday") }
        return Text(verbatim: date.formatted(.dateTime.weekday(.abbreviated).month().day().locale(locale)))
    }

    /// The chosen day, newest first. Going back to the home screen happens all the time on phones
    /// and isn't worth a line; it still counts in "Most used".
    private func visibleEvents(_ timeline: Timeline) -> [Timeline.Event] {
        let home = model.status?.home
        return timeline.events.reversed().filter { event in
            guard Calendar.current.isDate(event.date, inSameDayAs: day) else { return false }
            if case let .app(package) = event.kind { return package != home && !AppNames.homeScreens.contains(package) }
            return true
        }
    }

    private func events(_ events: [Timeline.Event]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(events) { event in
                HStack(spacing: 10) {
                    Text(verbatim: formats.time(event.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(minWidth: 72, alignment: .leading)
                    Image(systemName: symbol(event.kind))
                        .foregroundStyle(color(event.kind))
                        .frame(width: 18)
                    description(event.kind)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func description(_ kind: Timeline.Event.Kind) -> Text {
        switch kind {
        case .startup: Text("Started up")
        case .shutdown: Text("Shut down")
        case .screenOn: Text("Screen on")
        case .screenOff: Text("Screen off")
        case let .app(package): Text("Opened \(AppNames.text(for: package, home: model.status?.home, labels: labels))")
        }
    }

    private func symbol(_ kind: Timeline.Event.Kind) -> String {
        switch kind {
        case .startup: "power"
        case .shutdown: "power"
        case .screenOn: "sun.max.fill"
        case .screenOff: "moon.fill"
        case .app: "arrow.up.forward.app"
        }
    }

    private func color(_ kind: Timeline.Event.Kind) -> Color {
        switch kind {
        case .startup: .green
        case .shutdown: .red
        case .screenOn: .orange
        case .screenOff: .indigo
        case .app: .secondary
        }
    }
}

/// Screen-on hours per day, scaled to the busiest day; click a bar to see that day.
private struct ScreenTimeChart: View {
    let timeline: Timeline
    /// Oldest first.
    let days: [Date]
    @Binding var selected: Date

    @Environment(\.locale) private var locale

    var body: some View {
        let hours = days.map { day in
            let end = min(Date(), Calendar.current.date(byAdding: .day, value: 1, to: day) ?? Date())
            return (day, timeline.screenOnTime(from: day, to: end) / 3600)
        }
        let top = max(1, hours.map(\.1).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text("Screen on per day").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(hours, id: \.0) { day, value in
                    VStack(spacing: 3) {
                        Text(verbatim: value >= 0.05 ? label(value) : "")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day == selected ? Color.accentColor : Color.accentColor.opacity(0.35))
                            .frame(height: max(3, 64 * value / top))
                        Text(verbatim: day.formatted(.dateTime.weekday(.abbreviated).locale(locale)))
                            .font(.caption2)
                            .foregroundStyle(day == selected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = day }
                }
            }
            .frame(height: 100, alignment: .bottom)
        }
    }

    /// "2.4 hr", "11 hr", in the window's language.
    private func label(_ hours: Double) -> String {
        Measurement(value: hours, unit: UnitDuration.hours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(hours < 10 ? 1 : 0))).locale(locale))
    }
}

// MARK: - Transfers and dropping

private struct TransfersBar: View {
    let model: DashboardModel

    /// "/sdcard/Download/" → "Download".
    static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transfers").font(.callout.weight(.semibold))
                Spacer()
                if model.transfers.contains(where: \.state.isFinished) {
                    Button("Clear") { model.clearFinishedTransfers() }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(model.transfers.suffix(4)) { transfer in
                HStack(spacing: 8) {
                    switch transfer.state {
                    case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
                    case .running: ProgressView().controlSize(.mini)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Text(verbatim: transfer.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Group {
                        switch (transfer.kind, transfer.state) {
                        case (.install, .done): Text("Installed")
                        case let (.send(folder), .done): Text("Sent to \(Self.lastComponent(folder))")
                        case (.receive, .done): Text("Saved on this Mac")
                        case (.install, .running): Text("Installing…")
                        case (.send, .running): Text("Sending…")
                        case (.receive, .running): Text("Downloading…")
                        case (_, .waiting): Text("Waiting")
                        case let (_, .failed(reason)): Text("Failed: \(reason)")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if case let .receive(_, url) = transfer.kind, transfer.state == .done {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Show in Finder"))
                    }
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct DropOverlay: View {
    /// The Files page's folder, where dropped files go; nil elsewhere.
    let folder: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40))
                    Text("Drop to send to the device").font(.title3.weight(.semibold))
                    if let folder {
                        Text("Into \(Self.shown(folder))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Apps (.apk) are installed. Other files go into the Download folder.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    /// "/sdcard/Movies" → "/Movies".
    static func shown(_ folder: String) -> String {
        let relative = folder.replacingOccurrences(of: "/sdcard", with: "")
        return relative.isEmpty ? "/" : relative
    }
}
