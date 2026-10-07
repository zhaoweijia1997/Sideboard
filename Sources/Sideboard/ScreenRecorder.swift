import AVKit
import Foundation
import Observation
import SwiftUI

/// Records the device's screen with Android's own `screenrecord`: up to 3 minutes, no sound.
/// It writes to a temporary file on the device; stopping sends it an interrupt so the video is
/// finished properly, then the file comes to the Mac (Movies → Sideboard) and is deleted on the
/// device. HDMI inputs and protected video come out black, as with screenshots.
@MainActor @Observable
final class ScreenRecorder {
    enum State: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case saving
        case saved(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Android's own maximum for one recording.
    nonisolated static let limit: TimeInterval = 180
    nonisolated static let remotePath = "/data/local/tmp/sideboard-recording.mp4"

    private let adb: Adb?
    private let serial: String
    /// Recordings shorter than Android's limit, for tests.
    private let timeLimit: Int
    private var process: Process?
    private var pid: String?
    private var output = ""
    private var finishing = false

    init(adb: Adb?, serial: String, timeLimit: Int = Int(ScreenRecorder.limit)) {
        self.adb = adb
        self.serial = serial
        self.timeLimit = timeLimit
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .starting, .recording, .saving: true
        default: false
        }
    }

    // MARK: Recording

    /// `name` becomes the start of the file name on the Mac.
    func start(name: String?) async {
        guard let adb, !isBusy else { return }
        state = .starting
        output = ""
        pid = nil
        finishing = false
        fileName = Self.fileName(name)
        // A leftover from an interrupted recording, if any.
        _ = await adb.shellOutput(serial, "rm -f \(Self.remotePath)")
        // `exec` keeps the shell's process id, printed first, so exactly this recording can be stopped.
        let command = "echo SIDEBOARD_PID=$$; exec screenrecord --bit-rate 8M --time-limit \(timeLimit) \(Self.remotePath)"
        let process = adb.launch(["-s", serial, "shell", command], onOutput: { [weak self] text in
            Task { @MainActor in self?.received(text) }
        }, onExit: { [weak self] status in
            Task { @MainActor in await self?.exited(status) }
        })
        guard let process else {
            state = .failed(String(localized: "adb didn't start."))
            return
        }
        self.process = process
        // Give screenrecord a moment to report a problem (no encoder for this screen, and so on).
        try? await Task.sleep(for: .milliseconds(1200))
        if state == .starting { state = .recording(since: Date()) }
    }

    func stop() async {
        guard isRecording, let adb else { return }
        state = .saving
        if let pid {
            _ = await adb.shellOutput(serial, "kill -INT \(pid)")
        } else {
            _ = await adb.shellOutput(serial, "pkill -INT screenrecord")
        }
        // screenrecord finishes the file and quits; then the adb command on the Mac ends too.
        for _ in 0..<150 where process?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process?.isRunning == true { process?.terminate() }
        await finish()
    }

    func dismiss() {
        state = .idle
    }

    private func received(_ text: String) {
        output += text
        if pid == nil, let match = output.firstMatch(of: /SIDEBOARD_PID=(\d+)/) {
            pid = String(match.1)
        }
    }

    /// The command ended: stopped, at the time limit, or because screenrecord failed.
    private func exited(_ status: Int32) async {
        process = nil
        switch state {
        case .starting:
            // It never got going.
            let reason = output.replacingOccurrences(of: #"SIDEBOARD_PID=\d+\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed(reason.isEmpty ? String(localized: "The device couldn't record its screen.") : reason)
            if let adb { _ = await adb.shellOutput(serial, "rm -f \(Self.remotePath)") }
        case .recording:
            // The 3-minute limit.
            state = .saving
            await finish()
        default:
            break
        }
    }

    private var fileName = "Android.mp4"

    /// Brings the video to the Mac and deletes it on the device.
    private func finish() async {
        guard let adb, !finishing else { return }
        finishing = true
        defer { finishing = false }
        let folder = Self.folder
        var target = folder.appending(path: fileName)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appending(path: fileName.replacingOccurrences(of: ".mp4", with: " \(number).mp4"))
            number += 1
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let failure = await adb.pull(serial, Self.remotePath, to: target)
        _ = await adb.shellOutput(serial, "rm -f \(Self.remotePath)")
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        if failure == nil, size > 0 {
            state = .saved(target)
        } else {
            try? FileManager.default.removeItem(at: target)
            state = .failed(failure ?? String(localized: "The recording came out empty."))
        }
    }

    /// Movies → Sideboard; SIDEBOARD_MOVIES_DIR replaces it (for tests).
    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["SIDEBOARD_MOVIES_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "Sideboard")
    }

    static func fileName(_ name: String?, date: Date = Date()) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "\(name ?? "Android") \(stamp).mp4".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

/// The finished recording: a preview, where it was saved, and what to expect from it.
struct RecordingView: View {
    let url: URL
    let done: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black
                }
            }
            .frame(width: 640, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(spacing: 2) {
                Text(verbatim: url.lastPathComponent).font(.callout)
                Text("Saved on this Mac in Movies → Sideboard. Nothing is kept on the device.")
                Text("HDMI inputs and protected video come out black, and there's no sound.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
    }
}

/// The header's record button: starts, shows the time while recording, stops.
struct RecordButton: View {
    let recorder: ScreenRecorder
    let name: String?

    var body: some View {
        if case let .recording(since) = recorder.state {
            Button {
                Task { await recorder.stop() }
            } label: {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Label {
                        Text(verbatim: Self.clock(context.date.timeIntervalSince(since)))
                    } icon: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
                }
            }
            .help(Text("Stop recording"))
        } else if recorder.state == .starting || recorder.state == .saving {
            Button {} label: {
                ProgressView().controlSize(.small).frame(width: 18)
            }
            .disabled(true)
        } else {
            Button {
                Task { await recorder.start(name: name) }
            } label: {
                Label("Record Screen", systemImage: "record.circle")
            }
            .help(Text("Records the device's screen, up to 3 minutes, without sound. HDMI inputs and protected video come out black."))
        }
    }

    /// "0:42 / 3:00"
    static func clock(_ seconds: TimeInterval) -> String {
        let elapsed = min(Int(seconds), Int(ScreenRecorder.limit))
        return String(format: "%d:%02d / 3:00", elapsed / 60, elapsed % 60)
    }
}
