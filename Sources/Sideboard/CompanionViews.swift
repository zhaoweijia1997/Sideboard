import SwiftUI

/// The companion app's card on the Overview page: install it, or what it has recorded.
struct CompanionSection: View {
    let model: DashboardModel

    @Environment(\.locale) private var locale
    @State private var confirmingUninstall = false

    var body: some View {
        if model.companionChecked, model.companion != nil || Companion.bundledAPK != nil {
            Card(title: "Companion app", systemImage: "puzzlepiece.extension") {
                if let info = model.companion {
                    installed(info)
                } else {
                    notInstalled
                }
            }
            .alert(Text("Uninstall the companion app?"), isPresented: $confirmingUninstall) {
                Button("Uninstall", role: .destructive) { Task { await model.uninstallCompanion() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's removed from the device together with the history it kept.")
            }
            .alert(Text("Something went wrong"), isPresented: Binding(get: { model.companionFailure != nil },
                                                                    set: { if !$0 { model.companionFailure = nil } })) {
                Button("OK") { model.companionFailure = nil }
            } message: {
                Text(verbatim: model.companionFailure ?? "")
            }
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install the small Sideboard companion app on this device to keep 90 days of power, screen and app history, see app names and icons, and type text in any language from your Mac. It wakes up a few times a day for a moment, changes no settings and sends nothing anywhere.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install Companion App") { Task { await model.installCompanion() } }
                    .disabled(model.companionBusy)
                if model.companionBusy {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func installed(_ info: Companion.Info) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Installed, version \(info.version)")
            }
            if let since = info.since {
                let date = since.formatted(.dateTime.year().month().day().locale(locale))
                Text("Recording since \(date) · \(info.events) events kept")
                    .foregroundStyle(.secondary)
            }
            if !info.usageAccess {
                HStack {
                    Text("Usage access isn't allowed, so nothing new is recorded.")
                        .foregroundStyle(.orange)
                    Button("Allow Again") { Task { await model.allowCompanionUsageAccess() } }
                }
            }
            HStack {
                if let apk = Companion.bundledAPK, isNewer(apk: apk, than: info.version) {
                    Button("Update") { Task { await model.installCompanion() } }
                        .disabled(model.companionBusy)
                }
                Button("Uninstall…") { confirmingUninstall = true }
                    .disabled(model.companionBusy)
                if model.companionBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
        }
    }

    /// The bundled APK's version is written next to it by tools/build-companion.sh.
    private func isNewer(apk: URL, than installed: String) -> Bool {
        guard let bundled = try? String(contentsOf: apk.deletingPathExtension().appendingPathExtension("version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return bundled.compare(installed, options: .numeric) == .orderedDescending
    }
}

/// Typing on the device and using its clipboard, through the companion app's invisible keyboard.
struct TypingView: View {
    let session: TypingSession

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: LocalizedStringKey?
    @State private var isError = false
    @State private var ready = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type on the Device").font(.title2.weight(.semibold))
            Text("Select a text field on the device (with the remote), write here, then click Type. Any language works.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            HStack {
                Button("Type") { run { await session.type(text) } success: { text = "" } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.isEmpty || !ready)
                Button { run { await session.key("enter") } } label: { Label("Return", systemImage: "return") }
                    .disabled(!ready)
                Button { run { await session.key("delete") } } label: { Label("Delete", systemImage: "delete.left") }
                    .disabled(!ready)
                Spacer()
                Button("Send to Device Clipboard") {
                    Task {
                        let ok = await session.setClipboard(text)
                        show(ok ? "Copied to the device's clipboard." : "The device didn't answer.", error: !ok)
                    }
                }
                .disabled(text.isEmpty || !ready)
                Button("Get Device Clipboard") {
                    Task {
                        if let clip = await session.clipboard() {
                            text = clip
                            show(clip.isEmpty ? "The device's clipboard is empty." : "Got the device's clipboard.", error: false)
                        } else {
                            show("The device didn't answer.", error: true)
                        }
                    }
                }
                .disabled(!ready)
            }
            .controlSize(.small)
            Group {
                if let message {
                    Text(message).foregroundStyle(isError ? Color.orange : Color.secondary)
                } else if !ready {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Switching the device to Sideboard's keyboard…").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            Text("While this window is open, the device uses Sideboard's keyboard, which shows nothing on screen. Closing it switches back to the device's own keyboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            await session.begin()
            ready = true
        }
        .onDisappear {
            Task { await session.end() }
        }
    }

    private func run(_ action: @escaping () async -> Result<Void, TypingSession.Failure>, success: @escaping () -> Void = {}) {
        Task {
            switch await action() {
            case .success:
                message = nil
                success()
            case .failure(.noTextField):
                show("Select a text field on the device first.", error: true)
            case .failure(.noAnswer):
                show("The device didn't answer.", error: true)
            }
        }
    }

    private func show(_ text: LocalizedStringKey, error: Bool) {
        message = text
        isError = error
    }
}
