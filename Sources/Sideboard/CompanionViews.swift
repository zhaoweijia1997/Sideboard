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
            VStack(alignment: .leading, spacing: 4) {
                Text("Live typing").font(.headline)
                LiveTypingField(session: session, enabled: ready)
                    .frame(height: 24)
                Text("What you type here goes straight to the device, letter by letter, in any language. Return is Enter; Delete and the arrow keys work when the field is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Or write a longer text and send it at once:").font(.callout).foregroundStyle(.secondary)
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
            session.onResult = { result in
                switch result {
                case .success: if isError { message = nil }
                case .failure(.noTextField): show("Select a text field on the device first.", error: true)
                case .failure(.noAnswer): show("The device didn't answer.", error: true)
                }
            }
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

/// A one-line field whose every keystroke goes to the device: text once it's final (after a
/// Chinese or Japanese input method has finished composing), Return as Enter, and Delete and the
/// arrow keys when the field is empty.
struct LiveTypingField: NSViewRepresentable {
    let session: TypingSession
    var enabled: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = String(localized: "Click here and type")
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let session: TypingSession

        init(session: TypingSession) {
            self.session = session
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView, editor.hasMarkedText() { return }
            let text = field.stringValue
            guard !text.isEmpty else { return }
            field.stringValue = ""
            session.enqueue(.type(text))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let empty = (control as? NSTextField)?.stringValue.isEmpty ?? true
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                session.enqueue(.key("enter"))
            case #selector(NSResponder.deleteBackward(_:)) where empty:
                session.enqueue(.key("delete"))
            case #selector(NSResponder.moveUp(_:)) where empty:
                session.enqueue(.press(.up))
            case #selector(NSResponder.moveDown(_:)) where empty:
                session.enqueue(.press(.down))
            case #selector(NSResponder.moveLeft(_:)) where empty:
                session.enqueue(.press(.left))
            case #selector(NSResponder.moveRight(_:)) where empty:
                session.enqueue(.press(.right))
            default:
                return false
            }
            return true
        }
    }
}

/// Opens a link on the device: in its browser, or in the app that handles it.
struct OpenLinkView: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var failure: String?
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a Link on the Device").font(.title2.weight(.semibold))
            Text("It opens in the device's browser, or in the app that handles that kind of link. You can also drag a link from Safari onto the window.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $link, prompt: Text(verbatim: "https://")) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
            if let failure {
                Text(verbatim: failure).foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || opening)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            // Start from a link on the Mac's clipboard, if there is one.
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.hasPrefix("http://") || clip.hasPrefix("https://"), !clip.contains("\n") {
                link = clip
            }
        }
    }

    private func open() {
        opening = true
        failure = nil
        Task {
            failure = await model.openLink(link)
            opening = false
            if failure == nil { dismiss() }
        }
    }
}
