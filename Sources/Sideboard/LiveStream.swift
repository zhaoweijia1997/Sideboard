import CoreMedia
import Foundation

/// Splits an H.264 Annex B byte stream (start codes `00 00 01` and `00 00 00 01`) into NAL units.
/// A unit is complete once the next start code arrives. When the stream goes quiet, `takeOpen()`
/// hands over the unit still open: screenrecord writes a whole frame at once, so it's complete
/// unless the network held part of it back, and then `append` reports the rest as `cut`.
struct AnnexBParser {
    private var buffer: [UInt8] = []
    /// Bytes before this have been searched for start codes.
    private var searched = 0
    /// Whether `buffer` starts with a start code: not before the first one, nor after `takeOpen`.
    private var aligned = false
    private var seenStartCode = false
    /// What came before the first start code: messages from the device's shell and screenrecord.
    private(set) var preamble: [UInt8] = []

    struct Result {
        var units: [Data] = []
        /// The rest of a unit already handed over by `takeOpen()` arrived.
        var cut = false
    }

    mutating func append(_ data: Data) -> Result {
        buffer.append(contentsOf: data)
        var result = Result()
        if !aligned {
            let found = startCode(from: 0)
            // Keep the last bytes while no start code is found: one may be split across reads.
            let end = found ?? max(0, buffer.count - 3)
            let skipped = buffer[..<end]
            if !seenStartCode {
                preamble.append(contentsOf: skipped.prefix(max(0, 4096 - preamble.count)))
            } else if skipped.contains(where: { $0 != 0 }) {
                result.cut = true
            }
            buffer.removeFirst(end)
            searched = 0
            guard found != nil else { return result }
            aligned = true
            seenStartCode = true
        }
        // `buffer` starts with `00 00 01`; each later start code ends the unit before it.
        var open = 0
        var position = max(searched, 3)
        while let next = startCode(from: position) {
            if let unit = unit(from: open + 3, to: next) { result.units.append(unit) }
            open = next
            position = next + 3
        }
        buffer.removeFirst(open)
        searched = max(3, buffer.count - 2)
        return result
    }

    /// The unit after the last start code, taken as complete.
    mutating func takeOpen() -> Data? {
        guard aligned else { return nil }
        var end = buffer.count
        while end > 3, buffer[end - 1] == 0 { end -= 1 }
        let unit = unit(from: 3, to: end)
        // Trailing zeros may begin the next start code.
        buffer.removeFirst(end)
        aligned = false
        searched = 0
        return unit
    }

    /// The first two bytes of the unit still open, once they're here.
    var openHeader: Data? {
        aligned && buffer.count >= 5 ? Data(buffer[3..<5]) : nil
    }

    /// The position of the next `00 00 01`.
    private func startCode(from start: Int) -> Int? {
        guard buffer.count >= 3 else { return nil }
        var index = start
        while index + 2 < buffer.count {
            if buffer[index + 2] > 1 {
                index += 3
            } else if buffer[index + 2] == 1, buffer[index + 1] == 0, buffer[index] == 0 {
                return index
            } else {
                index += 1
            }
        }
        return nil
    }

    /// The bytes between two start codes, without trailing zeros (a four-byte start code's
    /// first byte, or padding); a unit always ends in a non-zero byte.
    private func unit(from start: Int, to end: Int) -> Data? {
        var end = end
        while end > start, buffer[end - 1] == 0 { end -= 1 }
        return end > start ? Data(buffer[start..<end]) : nil
    }
}

/// Turns H.264 NAL units into sample buffers macOS can decode.
enum H264 {
    /// Whether a unit starting with these bytes begins a new picture: parameter sets, delimiters
    /// and SEI come before a picture's slices, and a picture's first slice starts at macroblock 0
    /// (`first_mb_in_slice`, Exp-Golomb coded: a single 1 bit for 0).
    static func beginsPicture(_ unit: Data) -> Bool {
        guard let header = unit.first else { return false }
        switch header & 0x1F {
        case 1, 5: return unit.count > 1 && unit[unit.startIndex + 1] & 0x80 != 0
        case 6, 7, 8, 9, 10, 11: return true
        default: return false
        }
    }

    static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// One picture's slices as a sample, each with a 4-byte length in front (AVCC), to be shown
    /// as soon as it's decoded.
    static func sample(_ units: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var data = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// The device's screen as a live H.264 stream from Android's own screenrecord, straight to the
/// Mac (`adb exec-out`). Nothing is written on the device, and screenrecord ends there as soon as
/// adb disconnects. Android stops each run after 3 minutes, so the stream starts again by itself
/// until `stop()`. Pictures only come when something on the screen changes.
///
/// Everything runs on one serial queue, and the callbacks come from it.
final class LiveStream: @unchecked Sendable {
    enum Event: Sendable {
        /// Pictures are coming, this big.
        case live(width: Int, height: Int)
        case failed(String)
    }

    /// Set both before `start()`.
    var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)?

    /// Ends every stream at once, when Sideboard quits; screenrecord on the devices ends with them.
    static func stopAll() {
        running.terminateAll()
    }

    private static let running = RunningProcesses()

    private let adbPath: String
    private let serial: String
    private let timeLimit: Int
    private let queue = DispatchQueue(label: "Sideboard.LiveStream", qos: .userInteractive)

    private var process: Process?
    private var parser = AnnexBParser()
    private var errors = ""
    private var picture: [Data] = []
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var stopped = false
    private var started = Date.distantPast
    private var picturesThisRun = 0
    private var quickFailures = 0
    /// Set when we end a run ourselves to start a clean one.
    private var restarting = false
    /// Counts reads, to notice the stream going quiet.
    private var reads = 0
    /// How long the stream has to be quiet before the last unit counts as complete. Doubles
    /// whenever that turns out wrong (a slow network), up to a fifth of a second.
    private var quietDelay: TimeInterval = 0.025

    /// `timeLimit`: seconds per run, shorter for tests.
    init(adb: Adb, serial: String, timeLimit: Int = 180) {
        adbPath = adb.path
        self.serial = serial
        self.timeLimit = timeLimit
    }

    func start() {
        queue.async { self.launch() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.process?.terminate()
        }
    }

    /// Starts a new run, which begins with a whole picture: after the Mac couldn't decode one.
    func restart() {
        queue.async { self.restartNow() }
    }

    private func restartNow() {
        guard let process, !restarting else { return }
        restarting = true
        process.terminate()
    }

    // MARK: Running screenrecord

    private func launch() {
        guard !stopped else { return }
        parser = AnnexBParser()
        errors = ""
        picture = []
        format = nil
        picturesThisRun = 0
        restarting = false
        started = Date()
        // The screen's own size; when the encoder can't take it, screenrecord falls back to 720p by itself.
        let arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264", "--bit-rate", "8M",
                         "--time-limit", String(timeLimit), "-"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.queue.async { self?.consume(data) }
            }
        }
        // adb's own messages ("device offline"); the device's go to standard output with exec-out.
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.queue.async { self?.errors += String(decoding: data, as: UTF8.self) }
            }
        }
        process.terminationHandler = { [weak self] process in
            LiveStream.running.remove(process)
            // Let the last reads arrive first.
            self?.queue.asyncAfter(deadline: .now() + 0.2) { self?.ended() }
        }
        do {
            try process.run()
            self.process = process
            LiveStream.running.add(process)
        } catch {
            onEvent?(.failed(error.localizedDescription))
        }
    }

    /// A run ended: at the time limit, because we restarted it, or because it failed.
    private func ended() {
        process = nil
        guard !stopped else { return }
        if !restarting, picturesThisRun == 0, Date().timeIntervalSince(started) < 5 {
            quickFailures += 1
            if quickFailures >= 3 {
                let message = (String(decoding: parser.preamble.filter { $0 != 0 }, as: UTF8.self) + "\n" + errors)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                onEvent?(.failed(message.isEmpty ? String(localized: "The device couldn't stream its screen.") : message))
                return
            }
        } else if picturesThisRun > 0 {
            quickFailures = 0
        }
        queue.asyncAfter(deadline: .now() + 0.2) { self.launch() }
    }

    // MARK: Reading the stream

    private func consume(_ data: Data) {
        guard !stopped, !restarting else { return }
        reads += 1
        let result = parser.append(data)
        if result.cut {
            // A picture was shown before all of it had arrived. Wait longer from now on, and
            // start again for a clean picture.
            quietDelay = min(quietDelay * 2, 0.2)
            restartNow()
            return
        }
        for unit in result.units { handle(unit) }
        // The next picture has begun, so this one is whole.
        if let header = parser.openHeader, H264.beginsPicture(header) { finishPicture() }
        let mark = reads
        queue.asyncAfter(deadline: .now() + quietDelay) { [weak self] in
            guard let self, self.reads == mark, !self.stopped, !self.restarting else { return }
            if let unit = self.parser.takeOpen() { self.handle(unit) }
            self.finishPicture()
        }
    }

    private func handle(_ unit: Data) {
        guard let header = unit.first else { return }
        switch header & 0x1F {
        case 1, 5:
            if H264.beginsPicture(unit) { finishPicture() }
            if format == nil, let sps, let pps, let made = H264.format(sps: sps, pps: pps) {
                format = made
                let dimensions = CMVideoFormatDescriptionGetDimensions(made)
                onEvent?(.live(width: Int(dimensions.width), height: Int(dimensions.height)))
            }
            picture.append(unit)
        case 7:
            finishPicture()
            if unit != sps { sps = unit; format = nil }
        case 8:
            finishPicture()
            if unit != pps { pps = unit; format = nil }
        case 6, 9, 10, 11:
            finishPicture()
        default:
            break
        }
    }

    private func finishPicture() {
        guard !picture.isEmpty else { return }
        defer { picture.removeAll(keepingCapacity: true) }
        guard let format, let sample = H264.sample(picture, format: format) else { return }
        picturesThisRun += 1
        onSample?(sample)
    }
}

private final class RunningProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    func remove(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = nil }
    }

    func terminateAll() {
        lock.withLock {
            processes.values.forEach { $0.terminate() }
            processes.removeAll()
        }
    }
}
