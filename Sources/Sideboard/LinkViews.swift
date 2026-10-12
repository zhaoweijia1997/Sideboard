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
    }
}
