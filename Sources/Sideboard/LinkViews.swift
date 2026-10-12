import SwiftUI

/// The sidebar's list of devices found through Sideboard Link. A click opens the device's
/// screen; there is no dashboard for them, as everything else Sideboard does goes by adb.
struct LinkDevicesSection: View {
    @Environment(\.openWindow) private var openWindow
    private let browser = LinkBrowser.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !browser.devices.isEmpty {
                Text("Without adb")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                ForEach(browser.devices) { device in
                    Button {
                        openWindow(id: LiveScreenWindow.id, value: device.serial)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 16))
                                .frame(width: 26)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: device.name).lineLimit(1)
                                Text("Sideboard Link · open its screen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Shows this device's screen and lets you use it with the mouse, over your local network."))
                }
            }
        }
        .onAppear { browser.start() }
        .task {
            // SIDEBOARD_OPEN_LINK=<part of a name>: opens that device's screen at launch, for trying the window from a script.
            guard let wanted = ProcessInfo.processInfo.environment["SIDEBOARD_OPEN_LINK"] else { return }
            for _ in 0..<40 {
                if let device = browser.devices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) {
                    openWindow(id: LiveScreenWindow.id, value: device.serial)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// The Link app's card on the Overview page of a device that is on adb: put it there, so the
/// device's screen can be seen and used without the cable from then on.
struct LinkSection: View {
    let serial: String

    @State private var installed: String?
    @State private var checked = false
    @State private var busy = false
    @State private var failure: String?
    @State private var confirmingUninstall = false

    var body: some View {
        if checked, LinkSetup.bundledAPK != nil || installed != nil {
            Card(title: "Sideboard Link", systemImage: "dot.radiowaves.left.and.right") {
                VStack(alignment: .leading, spacing: 10) {
                    if let installed {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Installed, version \(installed)")
                        }
                        Text("This device now also appears under “Without adb” in the sidebar whenever it is on your network, with or without a cable.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Install the Sideboard Link app to see this device's screen and use it with the mouse over your local network, with no cable and no adb. It takes a moment while the cable is still in; after that the device finds your Mac by itself, even at a new address.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The app never uses the microphone or the camera, sends nothing outside your network, and lets in only a Mac allowed on the device. The connection isn't encrypted, so use it on a network you trust.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if installed != nil, LinkBrowser.shared.blocked {
                        Text("macOS isn't letting Sideboard look for devices on your network. Allow it in System Settings → Privacy & Security → Local Network.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if installed == nil {
                            Button("Set Up Sideboard Link") { setUp() }.disabled(busy)
                        } else {
                            if let bundled = LinkSetup.bundledVersion, let installed, LinkSetup.isNewer(bundled, than: installed) {
                                Button("Update") { setUp() }.disabled(busy)
                            } else {
                                Button("Set Up Again") { setUp() }.disabled(busy)
                                    .help(Text("Installs it again, gives it its permissions and allows this Mac."))
                            }
                            Button("Uninstall…") { confirmingUninstall = true }.disabled(busy)
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .controlSize(installed == nil ? .regular : .small)
                }
            }
            .alert(Text("Uninstall Sideboard Link?"), isPresented: $confirmingUninstall) {
                Button("Uninstall", role: .destructive) { uninstall() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The device's screen can then only be seen over adb.")
            }
            .alert(Text("Something went wrong"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: {
                Text(verbatim: failure ?? "")
            }
        } else {
            Color.clear.frame(height: 0).task(id: serial) { await check() }
        }
    }

    private func check() async {
        guard let adb = Adb.locate() else { return }
        installed = await LinkSetup.installedVersion(adb, serial)
        checked = true
        if installed != nil { LinkBrowser.shared.start() }
    }

    private func setUp() {
        guard let adb = Adb.locate() else { return }
        busy = true
        Task {
            failure = await LinkSetup.setUp(adb, serial)
            installed = await LinkSetup.installedVersion(adb, serial)
            busy = false
            LinkBrowser.shared.start()
        }
    }

    private func uninstall() {
        guard let adb = Adb.locate() else { return }
        busy = true
        Task {
            failure = await LinkSetup.uninstall(adb, serial)
            installed = await LinkSetup.installedVersion(adb, serial)
            busy = false
        }
    }
}
