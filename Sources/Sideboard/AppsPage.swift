import SwiftUI

/// The apps on the device: open, stop, turn off or on, uninstall (apps you added), save the APK.
struct AppsPage: View {
    enum Filter: Hashable { case added, preinstalled, turnedOff }

    let model: AppsModel
    let dashboard: DashboardModel

    @Environment(\.locale) private var locale
    @State private var filter: Filter = .added
    @State private var search = ""
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\Row.sortName)]
    @State private var confirming: Confirmation?

    private var formats: Formats { Formats(locale: locale) }
    private var timeZone: TimeZone { dashboard.status?.timeZone ?? .current }
    private var home: String? { dashboard.status?.home }

    struct Row: Identifiable {
        let app: DeviceApp
        let sortName: String
        let sortSize: Int64
        var id: String { app.package }
    }

    struct Confirmation: Identifiable {
        enum Action { case uninstall, turnOff }
        let action: Action
        let app: DeviceApp
        var id: String { "\(action)-\(app.package)" }
    }

    private var rows: [Row] {
        model.apps
            .filter { app in
                switch filter {
                case .added: !app.isSystem
                case .preinstalled: app.isSystem
                case .turnedOff: app.isDisabled
                }
            }
            .filter { app in
                search.isEmpty || app.package.localizedCaseInsensitiveContains(search)
                    || (AppNames.name(for: app.package, labels: dashboard.labels)?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .map { Row(app: $0, sortName: (AppNames.name(for: $0.package, labels: dashboard.labels) ?? $0.package).lowercased(), sortSize: $0.totalSize ?? 0) }
            .sorted(using: sortOrder)
    }

    private var selectedApp: DeviceApp? { model.apps.first { $0.package == selection } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            if !model.loaded {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the apps…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            footer
        }
        .task {
            if !model.loaded { await model.load(timeZone: timeZone) }
            await dashboard.loadIcons()
        }
        .alert(item: $confirming) { confirmation in
            switch confirmation.action {
            case .uninstall:
                Alert(
                    title: Text("Uninstall \(displayName(confirmation.app))?"),
                    message: Text("The app and its data are removed from the device."),
                    primaryButton: .destructive(Text("Uninstall")) { model.uninstall(confirmation.app, timeZone: timeZone) },
                    secondaryButton: .cancel())
            case .turnOff:
                Alert(
                    title: Text("Turn off \(displayName(confirmation.app))?"),
                    message: Text("It stops running and disappears from the home screen. Features that rely on it may stop working. You can turn it back on here any time."),
                    primaryButton: .destructive(Text("Turn Off")) { model.setEnabled(confirmation.app, false, timeZone: timeZone) },
                    secondaryButton: .cancel())
            }
        }
        .alert(Text("Something went wrong"), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(verbatim: model.failure ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker(selection: $filter) {
                Text("Added by you (\(model.apps.filter { !$0.isSystem }.count))").tag(Filter.added)
                Text("Preinstalled (\(model.apps.filter(\.isSystem).count))").tag(Filter.preinstalled)
                Text("Turned off (\(model.apps.filter(\.isDisabled).count))").tag(Filter.turnedOff)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(text: $search, prompt: Text("Search")) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Spacer()
            if model.loading || model.busy != nil {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.load(timeZone: timeZone) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(Text("Reload"))
            .disabled(model.loading)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(Text("Name"), value: \.sortName) { row in
                HStack(spacing: 8) {
                    if let icon = dashboard.icons[row.app.package] {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    } else {
                        Image(systemName: row.app.isSystem ? "gearshape.fill" : "app.fill")
                            .foregroundStyle(row.app.isSystem ? Color.secondary : Color.accentColor.opacity(0.75))
                            .frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        AppNames.text(for: row.app.package, home: home, labels: dashboard.labels).lineLimit(1)
                        if AppNames.isNamed(row.app.package, home: home, labels: dashboard.labels) {
                            Text(verbatim: row.app.package).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if row.app.isDisabled {
                        Text("Off")
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                }
                .opacity(row.app.isDisabled ? 0.6 : 1)
            }
            .width(min: 220, ideal: 320)
            TableColumn(Text("Version")) { row in
                Text(verbatim: row.app.versionName ?? row.app.versionCode.map(String.init) ?? "–")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn(Text("Updated")) { row in
                Text(verbatim: row.app.updated.map { $0.formatted(.dateTime.year().month().day().locale(locale)) } ?? "–")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn(Text("Size"), value: \.sortSize) { row in
                Text(verbatim: row.app.totalSize.map(formats.bytes) ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { packages in
            if let app = model.apps.first(where: { packages.contains($0.package) }) {
                menu(for: app)
            }
        } primaryAction: { packages in
            if let app = model.apps.first(where: { packages.contains($0.package) }), app.launcher != nil, !app.isDisabled {
                model.open(app)
            }
        }
    }

    @ViewBuilder private func menu(for app: DeviceApp) -> some View {
        Button("Open") { model.open(app) }
            .disabled(app.launcher == nil || app.isDisabled)
        Button("Force Stop") { model.forceStop(app) }
        Divider()
        if app.isDisabled {
            Button("Turn On") { model.setEnabled(app, true, timeZone: timeZone) }
        } else {
            Button("Turn Off…") { confirming = Confirmation(action: .turnOff, app: app) }
                .disabled(model.protected.contains(app.package))
        }
        if !app.isSystem {
            Button("Uninstall…") { confirming = Confirmation(action: .uninstall, app: app) }
                .disabled(model.protected.contains(app.package))
        }
        Divider()
        Button("Save APK to Mac…") { saveAPK(app) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let app = selectedApp {
                Button("Open") { model.open(app) }
                    .disabled(app.launcher == nil || app.isDisabled)
                Button("Force Stop") { model.forceStop(app) }
                if app.isDisabled {
                    Button("Turn On") { model.setEnabled(app, true, timeZone: timeZone) }
                } else {
                    Button("Turn Off…") { confirming = Confirmation(action: .turnOff, app: app) }
                        .disabled(model.protected.contains(app.package))
                }
                if !app.isSystem {
                    Button("Uninstall…") { confirming = Confirmation(action: .uninstall, app: app) }
                        .disabled(model.protected.contains(app.package))
                }
                Button("Save APK to Mac…") { saveAPK(app) }
                if model.protected.contains(app.package) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help(Text("The device needs this app to work (home screen, keyboard or a core part of Android), so Sideboard won't turn it off or remove it."))
                }
            } else {
                Text("Select an app to open, stop, turn off or uninstall it. Sizes come from Android's storage statistics, which it updates about once a day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func displayName(_ app: DeviceApp) -> String {
        AppNames.name(for: app.package, labels: dashboard.labels) ?? app.package
    }

    /// The APK (or the folder of split APKs, for Play Store apps) into a folder the user picks.
    private func saveAPK(_ app: DeviceApp) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = String(localized: "Save Here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let name = [displayName(app), app.versionName].compactMap { $0 }.joined(separator: " ").replacingOccurrences(of: "/", with: "-")
        Task {
            let paths = await model.apkPaths(app)
            guard !paths.isEmpty else {
                model.failure = String(localized: "Couldn't find the app's APK.")
                return
            }
            if paths.count == 1 {
                dashboard.download([(paths[0], name + ".apk")], to: folder)
            } else {
                var target = folder.appending(path: name)
                var number = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appending(path: "\(name) \(number)")
                    number += 1
                }
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                dashboard.download(paths.map { ($0, String($0.split(separator: "/").last ?? "split.apk")) }, to: target)
            }
        }
    }
}
