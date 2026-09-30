import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VeloceCore

struct MeetingCaptureResult {
    let microphoneURL: URL
    let systemURL: URL
    let duration: Double
}

/// One ScreenCaptureKit clock, two audio-only outputs, and bounded streaming writes.
/// No screen output is registered and no video buffers or images are retained.
@MainActor
final class MeetingRecorder {
    var onLevels: ((Double, Double) -> Void)?
    var onFailure: ((String) -> Void)?

    private var generation: UUID?
    private var session: MeetingCaptureSession?

    enum CaptureError: LocalizedError {
        case requiresMacOS15, microphoneDenied, noMicrophone, noDisplay, alreadyRecording
        case notRecording, invalidAudio, writeFailed(String), systemPermission, captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .requiresMacOS15: "L’enregistrement multipiste des réunions nécessite macOS 15 ou une version plus récente."
            case .microphoneDenied: "Autorise le microphone pour Véloce dans Réglages Système → Confidentialité et sécurité → Microphone."
            case .noMicrophone: "Aucun microphone n’est disponible. Branche ou sélectionne un microphone dans Réglages Système → Son."
            case .noDisplay: "macOS ne fournit aucune source audio système. Vérifie l’autorisation Enregistrement de l’écran et audio système, puis relance Véloce."
            case .alreadyRecording: "Un enregistrement est déjà en cours."
            case .notRecording: "Aucune réunion n’est en cours d’enregistrement."
            case .invalidAudio: "macOS a fourni un paquet audio illisible. L’enregistrement a été arrêté et les pistes déjà reçues sont conservées."
            case let .writeFailed(detail): "L’écriture des pistes a échoué. Vérifie l’espace disque disponible. Les fichiers déjà enregistrés sont conservés. \(detail)"
            case .systemPermission: "Autorise Véloce dans Réglages Système → Confidentialité et sécurité → Enregistrement de l’écran et audio système. Relance ensuite Véloce si macOS le demande. Aucune image n’est enregistrée."
            case let .captureFailed(detail): "La capture audio de la réunion a été interrompue. Les pistes déjà enregistrées sont conservées. \(detail)"
            }
        }
    }

    /// Called only after the user's Record action, never during app initialization.
    func start(directory: URL) async throws {
        guard #available(macOS 15.0, *) else { throw CaptureError.requiresMacOS15 }
        guard generation == nil, session == nil else { throw CaptureError.alreadyRecording }
        let token = UUID()
        generation = token
        do {
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed: Bool
            if permission == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                allowed = permission == .authorized
            }
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            guard allowed else { throw CaptureError.microphoneDenied }
            guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.noMicrophone }

            // This explicit capture action lets macOS present its system-audio permission.
            // Do not combine this with a second CGRequestScreenCaptureAccess prompt.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            guard let display = content.displays.first else { throw CaptureError.noDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = microphone.uniqueID
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // Audio has independent cadence. Keep unused visual work minimal.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
            configuration.queueDepth = 3

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let output = try MeetingAudioOutput(directory: directory, origin: origin, onLevels: { [weak self] microphone, system in
                Task { @MainActor in
                    guard self?.generation == token else { return }
                    self?.onLevels?(microphone, system)
                }
            }, onFailure: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == token, let session = self.session else { return }
                    // Start stopping immediately; callers can still stop() to recover the tracks.
                    session.beginStopping()
                    self.onFailure?(Self.friendly(error).localizedDescription)
                }
            })
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            let created = MeetingCaptureSession(stream: stream, output: output, origin: origin)
            session = created
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            // Deliberately no .screen or SCRecordingOutput (which could write video).
            created.startTask = Task { try await stream.startCapture() }
            try await created.startTask?.value
            try await output.checkFailure()
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
        } catch {
            if generation == token {
                generation = nil
                if let session {
                    session.beginStopping()
                    await session.stopTask?.value
                    _ = try? await session.output.finish(duration: session.duration)
                    self.session = nil
                }
                onLevels?(0, 0)
            }
            throw Self.friendly(error)
        }
    }

    func stop() async throws -> MeetingCaptureResult {
        guard let session else { throw CaptureError.notRecording }
        generation = nil
        session.beginStopping()
        await session.stopTask?.value
        defer {
            if self.session === session { self.session = nil }
            onLevels?(0, 0)
        }
        return try await session.output.finish(duration: session.duration)
    }

    /// Ends a pending or active capture, preserving every audio file already written.
    /// It never removes a completed meeting or an interrupted recording.
    func cancel() async {
        generation = nil
        guard let session else { return }
        session.beginStopping()
        await session.stopTask?.value
        _ = try? await session.output.finish(duration: session.duration)
        if self.session === session { self.session = nil }
        onLevels?(0, 0)
    }

    private static func friendly(_ error: Error) -> Error {
        if error is CaptureError || error is CancellationError { return error }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 { return CaptureError.systemPermission }
        return CaptureError.captureFailed(error.localizedDescription)
    }

    /// Offline diagnostic: exercises the production CMSampleBuffer → converter → WAV path.
    /// It creates synthetic stereo tones only; no SCStream, permission, microphone, or UI.
    static func verifyAudioPipeline(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let microphone = try MeetingAudioTrack(url: directory.appendingPathComponent("verify-microphone.wav"))
        let system = try MeetingAudioTrack(url: directory.appendingPathComponent("verify-system.wav"))
        let packet = try syntheticStereoPacket()
        for offset in [0.1, 0.2, 0.5] { _ = try microphone.append(packet, at: offset) }
        for offset in [0.3, 0.4] { _ = try system.append(packet, at: offset) }
        try microphone.finish(duration: 1)
        try system.finish(duration: 1)
        for track in [microphone, system] {
            let bytes = try Data(contentsOf: track.url)
            guard bytes.count == 44 + 32_000,
                  String(data: bytes[0..<4], encoding: .ascii) == "RIFF",
                  String(data: bytes[8..<12], encoding: .ascii) == "WAVE",
                  bytes[20] == 1, bytes[22] == 1, bytes[34] == 16 else {
                throw CaptureError.captureFailed("Auto-test : en-tête WAV PCM16 mono invalide.")
            }
            let decoded = try AVAudioFile(forReading: track.url)
            guard decoded.length == 16_000, decoded.fileFormat.sampleRate == 16_000,
                  decoded.fileFormat.channelCount == 1,
                  let pcm = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_000) else {
                throw CaptureError.captureFailed("Auto-test : le fichier rééchantillonné n’a pas le format attendu.")
            }
            try decoded.read(into: pcm)
            guard let samples = pcm.floatChannelData?[0] else { throw CaptureError.invalidAudio }
            func peak(_ range: Range<Int>) -> Float { range.reduce(0) { max($0, abs(samples[$1])) } }
            let leadingSilence = track === microphone ? 0..<1_500 : 0..<4_700
            let sound = track === microphone ? 1_800..<4_500 : 5_000..<7_700
            guard peak(leadingSilence) == 0, peak(sound) > 0.1, peak(10_000..<16_000) == 0 else {
                throw CaptureError.captureFailed("Auto-test : audio ou alignement des silences incorrect.")
            }
            if track === microphone, peak(5_000..<7_900) != 0 {
                throw CaptureError.captureFailed("Auto-test : une interruption de paquets a décalé la piste.")
            }
        }
    }

    private static func syntheticStereoPacket() throws -> CMSampleBuffer {
        let count = 4_800
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        var stereo = [Float]()
        stereo.reserveCapacity(count * 2)
        for frame in 0..<count {
            let tone = Float(sin(2 * Double.pi * 800 * Double(frame) / 48_000))
            stereo.append(tone * 0.4)
            stereo.append(tone * 0.2)
        }
        var block: CMBlockBuffer?
        let byteCount = stereo.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                  blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                  offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw CaptureError.invalidAudio }
        let copied = stereo.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { throw CaptureError.invalidAudio }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 2 * MemoryLayout<Float>.size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                  formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1,
                  sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                  sampleBufferOut: &sample) == noErr, let sample else { throw CaptureError.invalidAudio }
        return sample
    }
}

@MainActor
private final class MeetingCaptureSession {
    let stream: SCStream
    let output: MeetingAudioOutput
    let origin: Double
    var startTask: Task<Void, Error>?
    var stopTask: Task<Void, Never>?
    private var stoppedAt: Double?
    var duration: Double { max(0, (stoppedAt ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds) - origin) }

    init(stream: SCStream, output: MeetingAudioOutput, origin: Double) {
        self.stream = stream
        self.output = output
        self.origin = origin
    }

    func beginStopping() {
        guard stopTask == nil else { return }
        stoppedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        stopTask = Task { [stream, startTask, output] in
            // Cancellation during the permission/start transition cannot leave a late stream running.
            _ = try? await startTask?.value
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(output, type: .audio)
            if #available(macOS 15.0, *) { try? stream.removeStreamOutput(output, type: .microphone) }
        }
    }
}

/// All mutable state, conversion, and disk I/O are confined to `queue` after init.
/// Both SCStream outputs use that queue; delegate failures explicitly dispatch to it.
/// Callbacks are immutable before capture starts and marshal UI work to MainActor.
private final class MeetingAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.veloce.meeting-audio", qos: .userInitiated)
    private let onLevels: (Double, Double) -> Void
    private let onFailure: (Error) -> Void
    private let origin: Double
    private let microphone: MeetingAudioTrack
    private let system: MeetingAudioTrack
    private var microphoneLevel = 0.0
    private var systemLevel = 0.0
    private var lastLevelUpdate = 0.0
    private var lastMicrophonePacket = 0.0
    private var lastSystemPacket = 0.0
    private var failure: Error?
    private var finished = false
    private var result: MeetingCaptureResult?
    private var finishError: Error?

    init(directory: URL, origin: Double, onLevels: @escaping (Double, Double) -> Void,
         onFailure: @escaping (Error) -> Void) throws {
        self.origin = origin
        self.onLevels = onLevels
        self.onFailure = onFailure
        microphone = try MeetingAudioTrack(url: directory.appendingPathComponent("microphone.wav"))
        system = try MeetingAudioTrack(url: directory.appendingPathComponent("system.wav"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard #available(macOS 15.0, *), !finished, failure == nil,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard type == .audio || type == .microphone else { return }
        do {
            let hostClock = CMClockGetHostTimeClock()
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTime = CMSyncConvertTime(presentation, from: stream.synchronizationClock ?? hostClock, to: hostClock)
            let offset = hostTime.seconds - origin
            let now = CMClockGetTime(hostClock).seconds
            guard offset.isFinite, offset >= -2, offset <= now - origin + 2 else {
                throw MeetingRecorder.CaptureError.invalidAudio
            }
            let track = type == .microphone ? microphone : system
            let level = try track.append(sampleBuffer, at: offset)
            if type == .microphone {
                microphoneLevel = level
                lastMicrophonePacket = now
            } else {
                systemLevel = level
                lastSystemPacket = now
            }
            if now - lastLevelUpdate >= 0.08 {
                lastLevelUpdate = now
                onLevels(now - lastMicrophonePacket < 0.3 ? microphoneLevel : 0,
                         now - lastSystemPacket < 0.3 ? systemLevel : 0)
            }
        } catch { fail(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail(error) }
    }

    private func fail(_ error: Error) {
        guard !finished, failure == nil else { return }
        failure = error
        onFailure(error)
    }

    func checkFailure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            }
        }
    }

    func finish(duration: Double) async throws -> MeetingCaptureResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result { continuation.resume(returning: result); return }
                if let finishError { continuation.resume(throwing: finishError); return }
                finished = true
                let alignedDuration = max(duration, max(microphone.duration, system.duration))
                var writeError: Error?
                // Always finalize both headers, including when the first track fails.
                do { try microphone.finish(duration: alignedDuration) } catch { writeError = error }
                do { try system.finish(duration: alignedDuration) } catch { if writeError == nil { writeError = error } }
                if let writeError {
                    let error = MeetingRecorder.CaptureError.writeFailed(writeError.localizedDescription)
                    finishError = error
                    continuation.resume(throwing: error)
                } else {
                    let captured = MeetingCaptureResult(microphoneURL: microphone.url, systemURL: system.url, duration: alignedDuration)
                    result = captured
                    continuation.resume(returning: captured)
                }
            }
        }
    }
}

private final class MeetingAudioTrack {
    let url: URL
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var inputFormat: AVAudioFormat?
    private var timeline = MeetingAudioTimeline()
    private var file: FileHandle?
    private var actualFrames = 0
    private var checkpointFrames = 0
    private var writeFailure: Error?
    private let zeros = Data(count: 32_000)
    var duration: Double { Double(actualFrames) / 16_000 }

    init(url: URL) throws {
        self.url = url
        // Never overwrite an existing meeting track, even if a caller reuses its directory.
        try Data(Self.header(frames: 0)).write(to: url, options: .withoutOverwriting)
        file = try FileHandle(forUpdating: url)
        try file?.seekToEnd()
    }

    deinit {
        // Last-resort repair; normal shutdown awaits finish() on the writer queue.
        try? checkpoint()
        try? file?.close()
    }

    func append(_ sample: CMSampleBuffer, at startTime: Double) throws -> Double {
        guard let description = sample.formatDescription else { throw MeetingRecorder.CaptureError.invalidAudio }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count <= 1_000_000,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw MeetingRecorder.CaptureError.invalidAudio
        }
        input.frameLength = AVAudioFrameCount(count)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw MeetingRecorder.CaptureError.invalidAudio }
        if inputFormat != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.primeMethod = .none
            inputFormat = format
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(count) * 16_000 / format.sampleRate)) + 256) else {
            throw MeetingRecorder.CaptureError.invalidAudio
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error, let samples = output.floatChannelData?[0] else {
            throw MeetingRecorder.CaptureError.invalidAudio
        }
        let placement = try timeline.place(startTime: startTime, frameCount: Int(output.frameLength))
        do {
            try writeSilence(frames: placement.silenceFrames)
            var peak: Float = 0
            var pcm = [Int16]()
            pcm.reserveCapacity(placement.framesToWrite)
            for index in placement.trimLeadingFrames..<(placement.trimLeadingFrames + placement.framesToWrite) {
                let value = samples[index].isFinite ? min(1, max(-1, samples[index])) : 0
                peak = max(peak, abs(value))
                pcm.append(Int16((value * 32_767).rounded()).littleEndian)
            }
            if !pcm.isEmpty {
                try pcm.withUnsafeBytes { try file?.write(contentsOf: Data($0)) }
                actualFrames += pcm.count
            }
            if actualFrames - checkpointFrames >= 16_000 { try checkpoint() }
            return min(1, max(0, (20 * log10(max(Double(peak), 0.000_001)) + 55) / 55))
        } catch {
            writeFailure = error
            throw MeetingRecorder.CaptureError.writeFailed(error.localizedDescription)
        }
    }

    func finish(duration: Double) throws {
        guard file != nil else { return }
        var firstError = writeFailure
        if firstError == nil {
            do { try writeSilence(frames: timeline.pad(toDuration: duration)) } catch { firstError = error }
        }
        do { try checkpoint() } catch { if firstError == nil { firstError = error } }
        do { try file?.synchronize(); try file?.close() } catch { if firstError == nil { firstError = error } }
        file = nil
        if let firstError { throw firstError }
    }

    private func writeSilence(frames: Int) throws {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, zeros.count / 2)
            try file?.write(contentsOf: zeros.prefix(count * 2))
            actualFrames += count
            remaining -= count
        }
    }

    private func checkpoint() throws {
        guard let file else { return }
        // Use successful disk writes, not a planned timestamp, for the recoverable WAV length.
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Self.header(frames: actualFrames))
        try file.seekToEnd()
        checkpointFrames = actualFrames
    }

    private static func header(frames: Int) -> Data {
        let length = UInt32(frames * 2)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + length); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(length)
        return data
    }
}
