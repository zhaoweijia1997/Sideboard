import AVFoundation
import AppKit
import Observation
import SwiftUI

/// A device's screen, live, in a window of its own. Clicks become touches and keys become remote
/// buttons (`adb shell input`). Streams only while the window can be seen, and nothing is
/// installed or left on the device. HDMI inputs and protected video show black, as in screenshots.
@MainActor @Observable
final class LiveScreen {
    enum State: Equatable {
        case connecting
        case live
        /// The window is hidden or minimized, so the device isn't asked for pictures.
        case paused
        case failed(String)
    }

    private(set) var state: State = .connecting
    /// The stream's pictures, in pixels.
    private(set) var videoSize: CGSize?
    /// No picture yet, a few seconds after starting.
    private(set) var screenOff = false
    private(set) var stillWaiting = false

    let layer = AVSampleBufferDisplayLayer()
    let serial: String
    private let adb: Adb?
    private var stream: LiveStream?
    private var running = false
    private var visible = true
    /// The screen in the device's own coordinates, which touches use: a TV may draw at 1920 × 1080
    /// on a 4K panel, and the stream may be smaller than the screen.
    private var screenSize: CGSize?
    private var waiting: Task<Void, Never>?
    /// Touches and keys go out one after another, in order.
    private var input: Task<Void, Never>?

    init(adb: Adb?, serial: String) {
        self.adb = adb
        self.serial = serial
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Made-up state for screenshots.
    init(sample size: CGSize) {
        adb = nil
        serial = "sample"
        state = .live
        videoSize = size
        layer.backgroundColor = NSColor.black.cgColor
    }

    func start() {
        running = true
        resume()
    }

    func stop() {
        running = false
        suspend()
    }

    func retry() {
        suspend()
        resume()
    }

    /// Whether the window can be seen; the stream rests while it can't.
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            resume()
        } else if stream != nil {
            suspend()
            state = .paused
        }
    }

    private func resume() {
        guard running, visible, stream == nil, let adb else { return }
        state = .connecting
        screenOff = false
        stillWaiting = false
        let stream = LiveStream(adb: adb, serial: serial)
        // Fed from the stream's queue only, one picture at a time.
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        stream.onSample = { [weak stream] sample in
            if renderer.status == .failed {
                // Couldn't decode: start over from a whole picture.
                renderer.flush()
                stream?.restart()
                return
            }
            renderer.enqueue(sample)
        }
        stream.onEvent = { [weak self] event in
            Task { @MainActor in self?.received(event) }
        }
        self.stream = stream
        stream.start()
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.checkWaiting()
        }
    }

    private func suspend() {
        stream?.stop()
        stream = nil
        waiting?.cancel()
    }

    private func received(_ event: LiveStream.Event) {
        guard stream != nil else { return }
        switch event {
        case let .live(width, height):
            state = .live
            screenOff = false
            stillWaiting = false
            videoSize = CGSize(width: width, height: height)
            // Each run follows the screen's current size and orientation.
            Task { await readScreenSize() }
        case let .failed(reason):
            stream = nil
            waiting?.cancel()
            state = .failed(reason)
        }
    }

    /// Nothing after a few seconds: tell why if we can.
    private func checkWaiting() async {
        guard state == .connecting, let adb else { return }
        let power = await adb.shell(serial, "dumpsys power | grep -m1 mWakefulness=")
        guard state == .connecting else { return }
        if let power, !power.contains("Awake") {
            screenOff = true
        } else {
            stillWaiting = true
        }
    }

    /// `mOverrideDisplayInfo=DisplayInfo{"Built-in Screen", displayId 0, …, real 1920 x 1080, …}`:
    /// the size apps and touches use, turned the way the screen is.
    private func readScreenSize() async {
        guard let adb, let output = await adb.shell(serial, "dumpsys display | grep -m1 mOverrideDisplayInfo"),
              let match = output.firstMatch(of: /real (\d+) x (\d+)/),
              let width = Double(match.1), let height = Double(match.2), width > 0, height > 0 else { return }
        screenSize = CGSize(width: width, height: height)
    }

    // MARK: Touches and keys

    /// `point` is where on the picture, from its top left corner, as fractions of its size.
    func tap(_ point: CGPoint) {
        let (x, y) = devicePoint(point)
        send("input tap \(x) \(y)")
    }

    /// A drag, or a long press when both points are the same.
    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        let (x1, y1) = devicePoint(start)
        let (x2, y2) = devicePoint(end)
        send("input swipe \(x1) \(y1) \(x2) \(y2) \(Int(duration * 1000))")
    }

    func press(_ key: RemoteKey) {
        send("input keyevent \(key.rawValue)")
    }

    func wake() {
        press(.wake)
        retry()
    }

    private func devicePoint(_ point: CGPoint) -> (Int, Int) {
        let size = screenSize ?? videoSize ?? CGSize(width: 1, height: 1)
        let x = min(max(point.x, 0), 1) * (size.width - 1)
        let y = min(max(point.y, 0), 1) * (size.height - 1)
        return (Int(x.rounded()), Int(y.rounded()))
    }

    private func send(_ command: String) {
        guard let adb else { return }
        let previous = input
        input = Task { [serial] in
            await previous?.value
            _ = await adb.shell(serial, command, timeout: 10)
        }
    }
}

// MARK: - Window

/// The window for one device's live screen: `openWindow(id: LiveScreenWindow.id, value: serial)`.
struct LiveScreenWindow: View {
    static let id = "live-screen"

    let serial: String
    @State private var live: LiveScreen?
    @State private var dashboard: DashboardModel?
    @State private var name: String?

    var body: some View {
        Group {
            if let live, let dashboard {
                LiveScreenView(live: live, dashboard: dashboard)
            } else {
                Color.black
            }
        }
        .navigationTitle(name.map { Text(verbatim: $0) } ?? Text("Android device"))
        .frame(minWidth: 380, minHeight: 320)
        .onAppear {
            DockIcon.windowOpened()
            let store = AppModels.shared.store
            let dashboard = store.dashboard(for: serial)
            name = store.entries.first { $0.id == serial }?.name ?? dashboard.status?.model
            let live = dashboard.liveScreen()
            self.dashboard = dashboard
            self.live = live
            live.start()
        }
        .onDisappear {
            live?.stop()
            DockIcon.windowClosed()
        }
    }
}

struct LiveScreenView: View {
    let live: LiveScreen
    let dashboard: DashboardModel
    @State private var showingRemote = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                status
                Spacer(minLength: 8)
                Group {
                    Button { live.press(.back) } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                        .help(Text("Back"))
                    Button { live.press(.home) } label: { Label("Home", systemImage: "house") }
                        .help(Text("Home"))
                    Button { live.press(.recentApps) } label: { Label("Recent apps", systemImage: "square.on.square") }
                        .help(Text("Recent apps"))
                    Button { showingRemote.toggle() } label: { Label("Remote", systemImage: "av.remote") }
                        .help(Text("Remote"))
                        .popover(isPresented: $showingRemote, arrowEdge: .bottom) {
                            RemoteView(model: dashboard)
                        }
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ZStack {
                LiveScreenSurface(live: live, videoSize: live.videoSize)
                overlay
            }
            VStack(spacing: 2) {
                Text("Click to tap, drag to swipe, right-click to go back. Arrow keys, Return and Esc work too.")
                Text("HDMI inputs and protected video show black, and there's no sound.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var status: some View {
        switch live.state {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
            .foregroundStyle(.secondary)
        case .live:
            Label {
                Text("Live")
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.red).font(.system(size: 8))
            }
        case .paused:
            Text("Paused while the window is hidden").foregroundStyle(.secondary)
        case .failed:
            Label("Stopped", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch live.state {
        case .connecting:
            if live.screenOff {
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz").font(.largeTitle)
                    Text("The screen is off.")
                    Button("Wake Up") { live.wake() }
                }
                .foregroundStyle(.white)
            } else if live.stillWaiting {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Still waiting for a picture from the device…")
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.small)
            }
        case let .failed(reason):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("The live screen stopped.")
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(6)
                    .textSelection(.enabled)
                Button("Try Again") { live.retry() }
            }
            .foregroundStyle(.white)
            .padding(20)
        case .live, .paused:
            EmptyView()
        }
    }
}

// MARK: - Picture

private struct LiveScreenSurface: NSViewRepresentable {
    let live: LiveScreen
    let videoSize: CGSize?

    func makeNSView(context: Context) -> LiveScreenNSView {
        LiveScreenNSView(live: live)
    }

    func updateNSView(_ view: LiveScreenNSView, context: Context) {
        view.videoSize = videoSize
    }
}

/// Shows the stream and turns the mouse and keyboard into touches and remote buttons.
final class LiveScreenNSView: NSView {
    private let live: LiveScreen
    var videoSize: CGSize? {
        didSet {
            guard videoSize != oldValue, let videoSize else { return }
            if !fitted {
                fitted = true
                fitWindow(to: videoSize)
            }
        }
    }
    private var fitted = false
    private var down: (point: NSPoint, time: TimeInterval)?
    private var scrolled: CGFloat = 0
    private var scrollStart: CGPoint?
    private var scrollWork: DispatchWorkItem?
    private var occlusion: NSObjectProtocol?

    init(live: LiveScreen) {
        self.live = live
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(live.layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.layer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { return }
        // A live screen shouldn't open again by itself the next time Sideboard starts.
        window.isRestorable = false
        window.makeFirstResponder(self)
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        live.setVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    /// Makes the window the picture's shape the first time it's known (a phone is tall, a TV wide).
    private func fitWindow(to video: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main, video.width > 0, video.height > 0 else { return }
        let chrome = CGSize(width: window.contentLayoutRect.width - bounds.width,
                            height: window.contentLayoutRect.height - bounds.height)
        let room = screen.visibleFrame.size
        let scale = min((room.width * 0.6 - chrome.width) / video.width, (room.height * 0.8 - chrome.height) / video.height, 1)
        let content = NSSize(width: max(video.width * scale + chrome.width, 380), height: video.height * scale + chrome.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        // Keep the top left corner where it is, on the screen.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.width)
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Mouse

    /// Where the picture is drawn: the video's shape, fitted into the view.
    private var picture: CGRect {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    /// A point in the view as fractions of the picture from its top left; nil outside it.
    private func fraction(_ point: NSPoint, clamped: Bool = false) -> CGPoint? {
        let rect = picture
        guard rect.width > 0, rect.height > 0 else { return nil }
        var x = (point.x - rect.minX) / rect.width
        var y = (rect.maxY - point.y) / rect.height
        if clamped {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        down = (convert(event.locationInWindow, from: nil), event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down, let start = fraction(down.point) else { return }
        self.down = nil
        let point = convert(event.locationInWindow, from: nil)
        let held = event.timestamp - down.time
        if hypot(point.x - down.point.x, point.y - down.point.y) < 5 {
            if held < 0.5 {
                live.tap(start)
            } else {
                live.swipe(from: start, to: start, duration: held)
            }
        } else if let end = fraction(point, clamped: true) {
            live.swipe(from: start, to: end, duration: min(max(held, 0.1), 2))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        live.press(.back)
    }

    /// Scrolling becomes one swipe when it pauses: `input` can't stream a gesture.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let start = scrollStart ?? fraction(point) else { return }
        scrollStart = start
        scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishScroll() }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func finishScroll() {
        defer {
            scrolled = 0
            scrollStart = nil
        }
        guard let start = scrollStart, abs(scrolled) >= 2, picture.height > 0 else { return }
        // Content follows the fingers, as on the trackpad.
        let end = CGPoint(x: start.x, y: min(max(start.y + scrolled / picture.height, 0), 1))
        live.swipe(from: start, to: end, duration: 0.25)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let keys: [UInt16: RemoteKey] = [
            126: .up, 125: .down, 123: .left, 124: .right, 36: .ok, 76: .ok, 53: .back, 51: .back, 49: .playPause,
        ]
        if let key = keys[event.keyCode] {
            live.press(key)
        } else {
            super.keyDown(with: event)
        }
    }
}
