import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage(AppSettings.backgroundModeKey) private var backgroundMode = false
    @AppStorage(AppSettings.alertLateNightKey) private var lateNight = true
    @AppStorage(AppSettings.lateNightHourKey) private var lateNightHour = 1
    @AppStorage(AppSettings.alertLongSessionKey) private var longSession = false
    @AppStorage(AppSettings.longSessionHoursKey) private var longSessionHours = 6
    @AppStorage(AppSettings.alertStorageKey) private var storage = true
    @AppStorage(AppSettings.alertHotKey) private var hot = true
    @AppStorage(AppSettings.alertBatteryKey) private var battery = true
    @AppStorage(AppSettings.alertAppsKey) private var apps = true
    @AppStorage(AppSettings.alertOfflineKey) private var offline = false

    @Environment(\.locale) private var locale
    @State private var loginState = LoginItem.state
    @State private var loginError: String?
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var historySize: Int64 = HistoryStore.shared.size
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Toggle("Run in the background with a menu bar icon", isOn: $backgroundMode)
                Text("Closing the window keeps Sideboard watching your devices from the menu bar, so notifications keep coming and the history keeps growing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Open at login", isOn: Binding(get: { loginState != .off }, set: { setLogin($0) }))
                if loginState == .needsApproval {
                    HStack {
                        Text("Allow Sideboard in System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text("Couldn't change the login item: \(loginError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Still on late at night", isOn: $lateNight)
                Picker(selection: $lateNightHour) {
                    ForEach([22, 23, 0, 1, 2, 3], id: \.self) { hour in
                        Text(verbatim: hourText(hour)).tag(hour)
                    }
                } label: {
                    Text("From")
                }
                .disabled(!lateNight)
                Toggle("Screen on for a long time in a row", isOn: $longSession)
                Stepper(value: $longSessionHours, in: 1...12) {
                    Text("After \(longSessionHours) h")
                }
                .disabled(!longSession)
                Toggle("Storage almost full (less than 10% free)", isOn: $storage)
                Toggle("Running hot", isOn: $hot)
                Toggle("Battery low (15% or less)", isOn: $battery)
                Toggle("Apps installed or removed", isOn: $apps)
                Toggle("A network device stops answering while its screen is on", isOn: $offline)
                if permission == .denied {
                    HStack {
                        Text("Notifications are turned off for Sideboard in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { openNotificationSettings() }
                    }
                }
                HStack {
                    Text("Notifications come while Sideboard is running, with its window open or in the menu bar. Devices are checked every 5 minutes while their screen is on, every 30 while it's off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Send a Test") {
                        Task {
                            _ = await Monitor.requestPermission()
                            permission = await Monitor.permission()
                            Monitor.post(title: "Sideboard", body: String(localized: "Notifications from Sideboard look like this."))
                        }
                    }
                }
            } header: {
                Text("Notify me when a device is…")
            }

            Section {
                LabeledContent {
                    Button("Delete History…") { confirmingDelete = true }
                        .disabled(historySize == 0)
                } label: {
                    Text("History kept on this Mac: \(Formats(locale: locale).bytes(historySize))")
                }
                Text("Power, screen and app history for each device, in ~/Library/Application Support/Sideboard. It never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("History")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: backgroundMode) { _, on in
            // Leaving background mode: bring the Dock icon back, so Sideboard can't end up invisible.
            if !on { NSApp.setActivationPolicy(.regular) }
            if on { Task { _ = await Monitor.requestPermission(); permission = await Monitor.permission() } }
        }
        .task {
            loginState = LoginItem.state
            permission = await Monitor.permission()
            historySize = HistoryStore.shared.size
        }
        .alert(Text("Delete the history kept on this Mac?"), isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                HistoryStore.shared.deleteAll()
                historySize = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The devices keep their own: Android's last 24 hours, and 90 days with the companion app.")
        }
    }

    private func hourText(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour().minute().locale(locale))
    }

    private func setLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginState = LoginItem.state
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.weijiazhao.sideboard"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
