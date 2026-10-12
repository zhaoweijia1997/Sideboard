import AVFoundation
import AppKit
import Network
import Observation
import SwiftUI

/// A device's screen, live, in a window of its own. The mouse is a finger on the device and keys
/// are remote buttons, sent as they happen (`TouchLink`); where that can't run, a click or drag is
/// sent when it ends (`adb shell input`). Streams only while the window can be seen, and nothing
/// is installed or left on the device. HDMI inputs and protected video show black, as in screenshots.
@MainActor @Observable
final class LiveScreen {
    enum State: Equatable {
        case connecting
        /// A Link device is asking its owner whether to allow this Mac.
        case asking
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
    /// Touches as they happen; without it (not connected yet, or the device can't) they go by `input`.
    private var link: TouchLink?
    /// The same two for a device reached through Sideboard Link instead of adb.
    private var linkStream: LinkStream?
    private var linkTouch: LinkTouch?
    var isLink: Bool { SideLink.isLink(serial) }
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
        } else if stream != nil || linkStream != nil {
            suspend()
            state = .paused
        }
    }

    private func resume() {
        if isLink { return resumeLink() }
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
        let link = TouchLink(adb: adb, serial: serial)
        self.link = link
        Task { _ = await link.start() }
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.checkWaiting()
        }
    }

    /// The same as `resume()`, for a device that streams and takes touches by itself.
    private func resumeLink() {
        guard running, visible, linkStream == nil else { return }
        guard let device = LinkBrowser.shared.device(serial: serial) else {
            state = .failed(String(localized: "The device isn't on the network right now. Is it on, on the same Wi-Fi, with Sideboard Link installed?"))
            return
        }
        state = .connecting
        screenOff = false
        stillWaiting = false
        let stream = LinkStream(endpoint: device.endpoint)
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        stream.onSample = { [weak stream] sample in
            if renderer.status == .failed {
                renderer.flush()
                stream?.restart()
                return
            }
            renderer.enqueue(sample)
        }
        stream.onEvent = { [weak self] event in
            Task { @MainActor in self?.received(event) }
        }
        linkStream = stream
        stream.start()
        let touch = LinkTouch(endpoint: device.endpoint)
        linkTouch = touch
        touch.start()
        Task { await checkLinkVersion(device.endpoint) }
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            await self?.checkWaiting()
        }
    }

    private func received(_ event: LinkStream.Event) {
        guard linkStream != nil else { return }
        switch event {
        case .asking:
            state = .asking
        case let .live(width, height):
            state = .live
            stillWaiting = false
            videoSize = CGSize(width: width, height: height)
        case let .failed(reason):
            linkStream = nil
            waiting?.cancel()
            state = .failed(reason)
        }
    }

    /// A Link device whose app is older than the one Sideboard carries: it can be sent the newer one.
    private(set) var linkUpdateAvailable = false
    private(set) var linkUpdating = false

    private func checkLinkVersion(_ endpoint: NWEndpoint) async {
        guard let bundled = LinkSetup.bundledVersion, let installed = await LinkSetup.version(of: endpoint) else { return }
        linkUpdateAvailable = LinkSetup.isNewer(bundled, than: installed)
    }

    /// Sends the newer app; the device installs it and is back a moment later.
    func updateLinkApp() {
        guard let device = LinkBrowser.shared.device(serial: serial), !linkUpdating else { return }
        linkUpdating = true
        Task {
            if await LinkSetup.sendUpdate(to: device.endpoint) { linkUpdateAvailable = false }
            linkUpdating = false
        }
    }

    /// True when the device is connected but its accessibility service is off, so the mouse does nothing there.
    var touchIsOff: Bool { linkTouch?.isOff ?? false }

    private func suspend() {
        stream?.stop()
        stream = nil
        link?.stop()
        link = nil
        linkStream?.stop()
        linkStream = nil
        linkTouch?.stop()
        linkTouch = nil
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
        if isLink {
            if state == .connecting { stillWaiting = true }
            return
        }
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
        guard !isLink, let adb, let output = await adb.shell(serial, "dumpsys display | grep -m1 mOverrideDisplayInfo"),
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
        if isLink {
            // The Link app knows the three navigation buttons; the rest need adb.
            let known: [RemoteKey: LinkTouch.Key] = [.back: .back, .home: .home, .recentApps: .recents]
            if let mapped = known[key] { linkTouch?.press(mapped) }
        } else if let link, link.isReady {
            link.press(key.rawValue)
        } else {
            send("input keyevent \(key.rawValue)")
        }
    }

    /// True when touches reach the device as they happen, so a drag can follow the mouse.
    var followsFinger: Bool { isLink ? linkTouch != nil : link?.isReady ?? false }

    /// A finger going down, moving or lifting at `point` (fractions of the picture, as for `tap`).
    func touch(_ action: TouchLink.Touch, at point: CGPoint) {
        if let linkTouch {
            linkTouch.touch(action, x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
            return
        }
        guard let link, let screen = deviceScreen else { return }
        let (x, y) = devicePoint(point)
        link.touch(action, x: x, y: y, screen: screen)
    }

    /// A mouse wheel turned over `point`, in wheel clicks: positive is up, and to the right.
    func scroll(at point: CGPoint, horizontal: Double, vertical: Double) {
        if let linkTouch {
            linkTouch.scroll(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1), horizontal: horizontal, vertical: vertical)
            return
        }
        guard let link, let screen = deviceScreen else { return }
        let (x, y) = devicePoint(point)
        link.scroll(x: x, y: y, screen: screen, horizontal: horizontal, vertical: vertical)
    }

    private var deviceScreen: (width: Int, height: Int)? {
        (screenSize ?? videoSize).map { (Int($0.width), Int($0.height)) }
    }

    func wake() {
        press(.wake)
        retry()
    }

    /// Text typed on the Mac, for the field that has the cursor on a Link device.
    func type(_ text: String) {
        linkTouch?.type(text)
    }

    private func devicePoint(_ point: CGPoint) -> (Int, Int) {
        let size = screenSize ?? videoSize ?? CGSize(width: 1, height: 1)
        let x = min(max(point.x, 0), 1) * (size.width - 1)
        let y = min(max(point.y, 0), 1) * (size.height - 1)
        return (Int(x.rounded()), Int(y.rounded()))
    }

    private func send(_ command: String) {
        guard let adb, !isLink else { return }
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
            LinkBrowser.shared.start()
            name = LinkBrowser.shared.device(serial: serial)?.name ?? store.entries.first { $0.id == serial }?.name ?? dashboard.status?.model
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
                    // The remote's other buttons go by adb, which a Link device doesn't need to have.
                    if !live.isLink {
                        Button { showingRemote.toggle() } label: { Label("Remote", systemImage: "av.remote") }
                            .help(Text("Remote"))
                            .popover(isPresented: $showingRemote, arrowEdge: .bottom) {
                                RemoteView(model: dashboard)
                            }
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
                if live.isLink {
                    if live.touchIsOff {
                        Text("The mouse does nothing yet: turn on Sideboard Link under Accessibility on the device.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Click to tap, drag to swipe, right-click to go back. What you type goes to the field with the cursor.")
                    }
                    Text("Over your local network, without adb. Protected video shows black, and there's no sound.")
                    if live.linkUpdateAvailable {
                        HStack(spacing: 6) {
                            Text("A newer Sideboard Link is ready for this device.")
                            Button("Update") { live.updateLinkApp() }
                                .controlSize(.small)
                                .disabled(live.linkUpdating)
                                .help(Text("Sends the app to the device. If the device asks whether to install or scan it, answer there or with the mouse here."))
                        }
                    }
                } else {
                    Text("Click to tap, drag to swipe, right-click to go back. Arrow keys, Return and Esc work too.")
                    Text("HDMI inputs and protected video show black, and there's no sound.")
                }
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
        case .connecting, .asking:
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
        case .asking:
            VStack(spacing: 10) {
                Image(systemName: "hand.raised").font(.largeTitle)
                Text("Allow this Mac on the device.")
                Text("The device is showing a request from “\(SideLink.macName)”. It asks only this once.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
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
    /// The mouse button is down as a finger on the device.
    private var touching = false
    /// Where the finger of a trackpad scroll is, in the view.
    private var scrollFinger: NSPoint?
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
        let point = convert(event.locationInWindow, from: nil)
        if live.followsFinger, scrollFinger == nil, let start = fraction(point) {
            touching = true
            live.touch(.down, at: start)
        } else {
            down = (point, event.timestamp)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let point = fraction(convert(event.locationInWindow, from: nil), clamped: true) else { return }
        live.touch(.move, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        if touching {
            touching = false
            if let point = fraction(convert(event.locationInWindow, from: nil), clamped: true) { live.touch(.up, at: point) }
            return
        }
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

    /// With touches going out as they happen, two fingers on the trackpad are one finger dragging
    /// on the device (which adds its own fling when they lift), and a mouse wheel is a mouse wheel
    /// there too. Otherwise scrolling becomes one swipe when it pauses: `input` can't stream a gesture.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if live.followsFinger || scrollFinger != nil {
            if !event.phase.isEmpty {
                trackpadScroll(event, at: point)
            } else if let at = fraction(point) {
                // A wheel that scrolls by the point sends many small steps for one click.
                let clicks = event.hasPreciseScrollingDeltas ? 1.0 / 40 : 1
                live.scroll(at: at, horizontal: -event.scrollingDeltaX * clicks, vertical: event.scrollingDeltaY * clicks)
            }
            return
        }
        guard let start = scrollStart ?? fraction(point) else { return }
        scrollStart = start
        scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishScroll() }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func trackpadScroll(_ event: NSEvent, at point: NSPoint) {
        if event.phase.contains(.began), !touching, let start = fraction(point) {
            scrollFinger = point
            live.touch(.down, at: start)
        } else if var finger = scrollFinger {
            // Content follows the fingers, as on the trackpad; the view's y grows upward.
            finger.x += event.scrollingDeltaX
            finger.y -= event.scrollingDeltaY
            let lifted = !event.phase.isDisjoint(with: [.ended, .cancelled])
            scrollFinger = lifted ? nil : finger
            if let at = fraction(finger, clamped: true) { live.touch(lifted ? .up : .move, at: at) }
        }
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
        if live.isLink {
            // No remote buttons there: Esc goes back, and the rest is typing.
            switch event.keyCode {
            case 53: live.press(.back)
            case 36, 76: live.type("\n")
            case 51: live.type("\u{8}")
            default:
                let typed = event.characters ?? ""
                let command = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
                if !command, !typed.isEmpty, typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }) {
                    live.type(typed)
                } else {
                    super.keyDown(with: event)
                }
            }
            return
        }
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
