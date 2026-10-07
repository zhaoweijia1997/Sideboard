import SwiftUI

/// A remote control. Keys go to the device as if pressed on its own remote.
struct RemoteView: View {
    let model: DashboardModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                key(.sleep, "moon.fill", "Sleep")
                key(.wake, "sun.max.fill", "Wake up")
            }

            // D-pad
            VStack(spacing: 6) {
                key(.up, "chevron.up", "Up")
                HStack(spacing: 6) {
                    key(.left, "chevron.left", "Left")
                    Button { model.press(.ok) } label: {
                        Text("OK").font(.headline).frame(width: 44, height: 36)
                    }
                    .help(Text("OK"))
                    key(.right, "chevron.right", "Right")
                }
                key(.down, "chevron.down", "Down")
            }

            HStack(spacing: 10) {
                key(.back, "arrow.uturn.backward", "Back")
                key(.home, "house", "Home")
                key(.menu, "line.3.horizontal", "Menu")
            }
            HStack(spacing: 10) {
                key(.volumeDown, "speaker.minus", "Volume down")
                key(.mute, "speaker.slash", "Mute")
                key(.volumeUp, "speaker.plus", "Volume up")
                key(.playPause, "playpause", "Play/Pause")
            }

            Text("Arrow keys, Return, Esc and Space work too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            let mapping: [KeyEquivalent: RemoteKey] = [
                .upArrow: .up, .downArrow: .down, .leftArrow: .left, .rightArrow: .right,
                .return: .ok, .escape: .back, .space: .playPause, .delete: .back,
            ]
            guard let key = mapping[press.key] else { return .ignored }
            model.press(key)
            return .handled
        }
    }

    private func key(_ key: RemoteKey, _ symbol: String, _ help: LocalizedStringKey) -> some View {
        Button { model.press(key) } label: {
            Image(systemName: symbol).frame(width: 36, height: 28)
        }
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// The screenshot sheet: loading, then the picture. The picture comes straight to the Mac
/// (adb exec-out) and is saved in Pictures → Sideboard; nothing is written on the device.
struct ScreenshotState: Identifiable {
    let id = UUID()
    var data: Data?
    var savedTo: URL?
    var finished = false
    let date = Date()

    static var folder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "Sideboard")
    }

    /// Saves into Pictures → Sideboard. Returns where, or nil if it couldn't.
    func save(_ data: Data, deviceName: String?) -> URL? {
        let stamp = Formats.fileStamp(date)
        let name = "\(deviceName ?? "Android") \(stamp).png".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = Self.folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

struct ScreenshotView: View {
    let state: ScreenshotState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let data = state.data, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
                } else if state.finished {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text("Couldn't take a screenshot.")
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Taking a screenshot…").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 640, height: 360)

            VStack(spacing: 2) {
                if state.savedTo != nil {
                    Text("Saved on this Mac in Pictures → Sideboard. Nothing is kept on the device.")
                } else if state.data != nil {
                    Text("Couldn't save it in the Pictures folder.").foregroundStyle(.orange)
                }
                Text("Protected video, such as most streaming apps, comes out black.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack {
                Button("Copy") { copy() }
                    .disabled(state.data == nil)
                if let url = state.savedTo {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else if state.data != nil {
                    Button("Save…") { saveAs() }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func copy() {
        guard let data = state.data else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }

    private func saveAs() {
        guard let data = state.data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Screenshot.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}
