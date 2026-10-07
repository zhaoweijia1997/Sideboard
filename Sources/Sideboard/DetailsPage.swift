import SwiftUI

/// Everything else Sideboard can read. Settings are shown, never changed.
struct DetailsPage: View {
    let model: DashboardModel

    @Environment(\.locale) private var locale
    private var formats: Formats { Formats(locale: locale) }

    var body: some View {
        if let details = model.details, let status = model.status {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                deviceSection(details, status)
                displaySection(details)
                cpuSection(details, status)
                processesSection(details, status)
                memorySection(details, status)
                storageSection(details)
                networkSection(details, status)
                powerSection(details, status)
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Reading the device…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func deviceSection(_ details: DeviceDetails, _ status: DeviceStatus) -> some View {
        Card(title: "Device", systemImage: status.isTV ? "tv" : "candybarphone") {
            InfoRow("Manufacturer", verbatim: status.manufacturer)
            InfoRow("Model", verbatim: status.model)
            InfoRow("Brand", verbatim: details.brand)
            InfoRow("Code name", verbatim: details.device)
            InfoRow("Android version", verbatim: status.androidVersion.map { version in
                details.sdk.map { "\(version) (API \($0))" } ?? version
            })
            InfoRow("Security patch", verbatim: details.securityPatch)
            InfoRow("Build", verbatim: details.build)
            InfoRow("Kernel", verbatim: details.kernel)
            if let count = details.packageCount {
                InfoRow("Apps installed", Text("\(count) (\(details.userPackageCount ?? 0) added by you)"))
            }
        }
    }

    private func displaySection(_ details: DeviceDetails) -> some View {
        Card(title: "Display", systemImage: "display") {
            InfoRow("Screen resolution", verbatim: details.screenSize)
            if let render = details.renderSize {
                InfoRow("Apps draw at", verbatim: render)
            }
            InfoRow("Density", verbatim: details.density.map { "\($0) dpi" })
            InfoRow("Refresh rate", verbatim: details.refreshRate.map { "\(formats.number($0, digits: $0.rounded() == $0 ? 0 : 2)) Hz" })
        }
    }

    private func cpuSection(_ details: DeviceDetails, _ status: DeviceStatus) -> some View {
        Card(title: "CPU", systemImage: "cpu") {
            InfoRow("Chip", verbatim: details.chipset)
            InfoRow("Architecture", verbatim: details.architecture)
            InfoRow("Cores", verbatim: status.cores.map(String.init))
            InfoRow("Speed now", verbatim: status.cpuFrequency.map { formats.frequency(megahertz: $0) })
            InfoRow("Top speed", verbatim: status.cpuMaxFrequency.map { formats.frequency(megahertz: $0) })
            InfoRow("Usage", verbatim: model.cpuUsage.map(formats.percent))
            InfoRow("Load average", verbatim: details.loadAverage.isEmpty ? nil
                : details.loadAverage.map { formats.number($0, digits: 2) }.joined(separator: "  "))
            InfoRow("Governor", verbatim: details.governor)
            if let temperature = status.temperature {
                InfoRow("Temperature", verbatim: formats.temperature(temperature))
            } else {
                InfoRow("Temperature", Text("Not reported"))
            }
        }
    }

    private func processesSection(_ details: DeviceDetails, _ status: DeviceStatus) -> some View {
        Card(title: "Busiest processes", systemImage: "list.number") {
            if details.processes.isEmpty {
                Text("Not available on this device.").foregroundStyle(.secondary)
            } else {
                ForEach(details.processes.prefix(8)) { process in
                    HStack(spacing: 8) {
                        processName(process.name, home: status.home)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let memory = process.memory {
                            Text(verbatim: formats.bytes(memory))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(verbatim: "\(formats.number(process.cpu, digits: 1))%")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 1)
                }
                Text("CPU is the share of one core, so a busy process can pass 100%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// App processes are named after their package, sometimes with ":service" after it.
    private func processName(_ name: String, home: String?) -> Text {
        let package = String(name.prefix { $0 != ":" })
        return AppNames.isNamed(package, home: home) ? AppNames.text(for: package, home: home) : Text(verbatim: name)
    }

    private func memorySection(_ details: DeviceDetails, _ status: DeviceStatus) -> some View {
        Card(title: "Memory", systemImage: "memorychip") {
            InfoRow("Total", verbatim: status.memoryTotal.map(formats.bytes))
            InfoRow("Available", verbatim: status.memoryAvailable.map(formats.bytes))
            InfoRow("Unused", verbatim: details.memoryFree.map(formats.bytes))
            InfoRow("Cached", verbatim: details.memoryCached.map(formats.bytes))
            if let total = details.swapTotal, total > 0 {
                let used = total - (details.swapFree ?? 0)
                InfoRow("Swap used", Text("\(formats.bytes(used)) of \(formats.bytes(total))"))
            }
        }
    }

    private func storageSection(_ details: DeviceDetails) -> some View {
        Card(title: "Storage", systemImage: "internaldrive") {
            if details.volumes.isEmpty {
                Text("Not available on this device.").foregroundStyle(.secondary)
            }
            ForEach(details.volumes) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if volume.isInternal {
                            Text("Internal storage")
                        } else {
                            Text("USB drive or card")
                        }
                        Spacer()
                        Text("\(formats.bytes(volume.available)) free of \(formats.bytes(volume.total))")
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: 1 - Double(volume.available) / Double(volume.total))
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func networkSection(_ details: DeviceDetails, _ status: DeviceStatus) -> some View {
        Card(title: "Network", systemImage: "network") {
            ForEach(status.addresses, id: \.address) { address in
                InfoRow(addressLabel(address.kind), Text(verbatim: "\(address.address)  (\(address.interface))"))
            }
            if status.addresses.isEmpty {
                InfoRow("IP address", verbatim: nil)
            }
            if let wifi = details.wifi {
                InfoRow("Wi-Fi network", verbatim: wifi.network)
                InfoRow("Signal", verbatim: wifi.signal.map { "\($0) dBm" })
                InfoRow("Link speed", verbatim: wifi.linkSpeed.map { "\($0) Mbps" })
                InfoRow("Band", verbatim: wifi.frequency.map { $0 >= 5900 ? "6 GHz" : $0 >= 4900 ? "5 GHz" : "2.4 GHz" })
            }
        }
    }

    private func addressLabel(_ kind: DeviceStatus.NetworkAddress.Kind) -> LocalizedStringKey {
        switch kind {
        case .wired: "Wired"
        case .wifi: "Wi-Fi"
        case .mobile: "Mobile data"
        case .other: "IP address"
        }
    }

    /// Android's own settings, read-only.
    private func powerSection(_ details: DeviceDetails, _ status: DeviceStatus) -> some View {
        Card(title: "Power and standby", systemImage: "powersleep") {
            InfoRow("Screen", screenText(status.screen, isTV: status.isTV))
            InfoRow(details.screensaverEnabled == true ? "Screensaver starts after" : "Screen turns off after",
                    timeoutText(details.screenOffTimeout))
            if details.screensaverEnabled == true {
                InfoRow("Sleeps after the screensaver", timeoutText(details.sleepTimeout))
            }
            if details.attentiveTimeout != nil {
                InfoRow("Turns off with no input after", timeoutText(details.attentiveTimeout))
            }
            InfoRow("Stays awake while plugged in", Text(details.stayOnWhilePluggedIn.map { $0 != 0 } == true ? "On" : "Off"))
            Text("Sideboard only reads these settings and never changes them. While the screen is off it checks in once a minute, so the device can rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func screenText(_ screen: DeviceStatus.Screen?, isTV: Bool) -> Text {
        switch screen {
        case .on: Text("On")
        case .off: Text(isTV ? "Standby" : "Off")
        case .screensaver: Text("Screensaver")
        case .dozing: Text("Dozing")
        case nil: Text(verbatim: "–")
        }
    }

    /// Milliseconds; 0 or negative (or huge) means never.
    private func timeoutText(_ milliseconds: Int?) -> Text {
        guard let milliseconds else { return Text(verbatim: "–") }
        guard milliseconds > 0, milliseconds < Int(Int32.max) else { return Text("Never") }
        return Text(verbatim: formats.setting(Double(milliseconds) / 1000))
    }
}
