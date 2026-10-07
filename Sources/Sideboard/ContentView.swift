import SwiftUI

struct ContentView: View {
    let store: DeviceStore
    /// Snapshots open a page directly.
    var initialPage: DashboardView.Page = .overview

    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var showingAbout = false
    @State private var showingAdd = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .sheet(isPresented: $showingAdd) { AddDeviceView(store: store) }
        .onAppear { store.start() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIconImage(size: 34)
                Text(verbatim: "Sideboard")
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Text("Devices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.entries) { entry in
                        DeviceRow(entry: entry, selected: store.selection == entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { store.selection = entry.id }
                            .contextMenu {
                                if let address = entry.address {
                                    if entry.state == .disconnected {
                                        Button("Connect") { Task { await store.connect(address) } }
                                    }
                                    if entry.remembered {
                                        Button("Forget This Device") { store.forget(address) }
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Device…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(store.adbState != .ready)
                HStack {
                    LanguageMenu(language: $language)
                    Spacer()
                    Button {
                        showingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("About Sideboard"))
                }
            }
            .padding(14)
        }
        .background(Color.primary.opacity(0.025))
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch store.adbState {
        case .missing:
            AdbMissingView(store: store)
        case .starting:
            ProgressView()
        case .ready:
            if let entry = store.selectedEntry {
                if entry.state == .online {
                    DashboardView(model: store.dashboard(for: entry.id), entry: entry, page: initialPage)
                        .id(entry.id)
                } else {
                    DeviceWaitingView(store: store, entry: entry)
                }
            } else {
                WelcomeView(showingAdd: $showingAdd)
            }
        }
    }
}

private struct DeviceRow: View {
    let entry: DeviceStore.Entry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if let name = entry.name {
                        Text(verbatim: name)
                    } else {
                        Text("Android device")
                    }
                }
                .lineLimit(1)
                Group {
                    switch entry.state {
                    case .online: entry.address.map { Text(verbatim: hostOnly($0)) } ?? Text("USB")
                    case .unauthorized: Text("Waiting for approval")
                    case .offline: Text("Offline")
                    case .connecting: Text("Connecting…")
                    case .disconnected: Text("Not connected")
                    }
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var dotColor: Color {
        switch entry.state {
        case .online: .green
        case .unauthorized, .connecting: .orange
        case .offline, .disconnected: .gray.opacity(0.5)
        }
    }

    /// "192.168.1.42:5555" → "192.168.1.42"; other ports stay visible.
    private func hostOnly(_ address: String) -> String {
        address.hasSuffix(":\(NetworkScan.port)") ? String(address.dropLast(":\(NetworkScan.port)".count)) : address
    }
}

/// A device that's listed but can't be read: waiting for approval, offline or not connected.
private struct DeviceWaitingView: View {
    let store: DeviceStore
    let entry: DeviceStore.Entry

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: entry.symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Group {
                if let name = entry.name {
                    Text(verbatim: name)
                } else {
                    Text("Android device")
                }
            }
            .font(.title2.weight(.semibold))
            if let address = entry.address {
                Text(verbatim: address).foregroundStyle(.secondary).textSelection(.enabled)
            }

            switch entry.state {
            case .unauthorized:
                Text("Waiting for approval").font(.headline)
                Text("Look at the device's screen and allow debugging. Tick “Always allow from this computer” so it won't ask again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .offline:
                Text("Offline").font(.headline)
                Text("adb sees the device but can't talk to it. Try reconnecting the cable, or turning debugging off and on again on the device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            case .disconnected, .online:
                Text("Not connected").font(.headline)
                if let problem = entry.address.flatMap({ store.problems[$0] }) {
                    ConnectProblemText(problem: problem)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Sideboard tries to reconnect every minute. The device needs to be on, with network debugging turned on.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let address = entry.address {
                        Button("Connect") { Task { await store.connect(address) } }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button {
                        Task { await store.restartAdb() }
                    } label: {
                        if store.restartingAdb {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restart adb")
                        }
                    }
                    .disabled(store.restartingAdb)
                    .help(Text("Restarts adb from Sideboard, so it gets Sideboard's permission to use the local network. Every device disconnects for a moment."))
                    if let address = entry.address, entry.remembered {
                        Button("Forget This Device") { store.forget(address) }
                    }
                }
            }
        }
        .frame(maxWidth: 460)
        .padding(30)
    }
}

/// No devices yet.
private struct WelcomeView: View {
    @Binding var showingAdd: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AppIconImage(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No devices yet").font(.title2.weight(.semibold))
                    Text("Connect an Android TV, box, phone or tablet by USB, or add one on your network.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            EnableDebuggingSteps()
            Button("Add Device…") { showingAdd = true }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520)
        .padding(30)
    }
}

/// adb isn't installed.
private struct AdbMissingView: View {
    let store: DeviceStore
    private let command = "brew install --cask android-platform-tools"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("adb isn't installed", systemImage: "wrench.and.screwdriver")
                .font(.title2.weight(.semibold))
            Text("Sideboard talks to Android devices through adb, from Google's Android platform-tools. With Homebrew, install it with:")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            Text("Or download platform-tools from Google and unzip it into ~/Library/Android/sdk/platform-tools.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!) {
                    Label("Download platform-tools", systemImage: "arrow.down.circle")
                }
                Spacer()
                Button("Look Again") { store.lookForAdbAgain() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 520)
        .padding(30)
    }
}
