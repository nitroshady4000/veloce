import AVFoundation
import CoreMedia
import Foundation

/// Native offline decoding and downmixing. The caller owns security-scoped URL access.
enum MeetingAudioImporter {
    static let maximumDuration = 4.0 * 60 * 60
    private static let sampleRate = 16_000.0
    private static let bufferFrames: AVAudioFrameCount = 8_192

    enum ImportError: LocalizedError {
        case empty, tooLong, unreadable(String), destinationExists, invalidDestination, conversion(String)

        var errorDescription: String? {
            switch self {
            case .empty: "Ce fichier ne contient aucun son exploitable."
            case .tooLong: "L’import accepte des fichiers de 4 heures maximum. Découpe cet enregistrement avant de l’importer."
            case let .unreadable(detail): "Impossible de lire ce média. Utilise un audio WAV, M4A, MP3, AIFF ou CAF, ou une vidéo MP4/MOV contenant du son. \(detail)"
            case .destinationExists: "Une piste existe déjà à cet emplacement. Elle n’a pas été remplacée."
            case .invalidDestination: "Le fichier importé doit être enregistré dans un nouvel emplacement WAV local."
            case let .conversion(detail): "L’import audio a échoué. Le fichier d’origine est intact. \(detail)"
            }
        }
    }

    static func importFile(from source: URL, to destination: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let worker = Task.detached(priority: .userInitiated) {
            if ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) {
                return try await convertVideo(source: source, destination: destination, progress: progress)
            }
            return try convert(source: source, destination: destination, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            // Detached work does not inherit cancellation automatically.
            worker.cancel()
        }
    }

    /// Reads only the first audio track; no video frame is decoded or retained.
    private static func convertVideo(source: URL, destination: URL,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL, destination.pathExtension.lowercased() == "wav" else {
            throw ImportError.invalidDestination
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.empty }
        let estimated = try await asset.load(.duration).seconds
        if estimated.isFinite, estimated > maximumDuration { throw ImportError.tooLong }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportError.unreadable("La piste audio vidéo n’est pas décodable par macOS.") }
        reader.add(output)
        do { try Data().write(to: destination, options: .withoutOverwriting) }
        catch {
            if (error as NSError).code == NSFileWriteFileExistsError { throw ImportError.destinationExists }
            throw error
        }
        var file: FileHandle?
        defer { reader.cancelReading(); try? file?.close() }
        do {
            file = try FileHandle(forWritingTo: destination)
            try file?.write(contentsOf: wavHeader(frames: 0))
            guard reader.startReading() else { throw ImportError.unreadable(reader.error?.localizedDescription ?? "Le décodeur vidéo n’a pas démarré.") }
            var bytes = 0
            var lastProgress = 0.0
            progress(0)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let description = sample.formatDescription,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      format.pointee.mFormatID == kAudioFormatLinearPCM,
                      format.pointee.mChannelsPerFrame == 1,
                      format.pointee.mBitsPerChannel == 16,
                      format.pointee.mSampleRate == sampleRate,
                      let block = sample.dataBuffer else { throw ImportError.conversion("Le décodeur vidéo a fourni un format audio inattendu.") }
                let count = CMBlockBufferGetDataLength(block)
                guard count > 0, count <= 4_194_304, count % 2 == 0 else { throw ImportError.conversion("Un paquet audio vidéo est invalide.") }
                var data = Data(count: count)
                let status = data.withUnsafeMutableBytes { pointer in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: pointer.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw ImportError.conversion("Impossible de lire la piste audio vidéo.") }
                bytes += count
                let duration = Double(bytes) / (sampleRate * 2)
                guard duration <= maximumDuration else { throw ImportError.tooLong }
                try file?.write(contentsOf: data)
                let fraction = estimated.isFinite && estimated > 0 ? min(0.99, duration / estimated) : 0
                if fraction - lastProgress >= 0.01 { progress(fraction); lastProgress = fraction }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw ImportError.unreadable(reader.error?.localizedDescription ?? "La lecture vidéo a été interrompue.") }
            guard bytes > 0 else { throw ImportError.empty }
            try file?.seek(toOffset: 0)
            try file?.write(contentsOf: wavHeader(frames: bytes / 2))
            try file?.synchronize(); try file?.close(); file = nil
            progress(1)
            return Double(bytes) / (sampleRate * 2)
        } catch {
            try? file?.close(); file = nil
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func wavHeader(frames: Int) -> Data {
        let bytes = UInt32(frames * 2)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(bytes + 36); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(bytes)
        return data
    }

    private static func convert(source: URL, destination: URL,
                                progress: @escaping @Sendable (Double) -> Void) throws -> Double {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL, destination.pathExtension.lowercased() == "wav" else {
            throw ImportError.invalidDestination
        }
        if FileManager.default.fileExists(atPath: destination.path) { throw ImportError.destinationExists }
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw ImportError.unreadable(error.localizedDescription) }
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw ImportError.empty
        }
        let estimatedDuration = Double(input.length) / format.sampleRate
        guard estimatedDuration <= maximumDuration else { throw ImportError.tooLong }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: bufferFrames) else {
            throw ImportError.conversion("Ce format ne peut pas être converti par macOS.")
        }
        // AVAudioConverter otherwise remaps channels (default downmix is false).
        converter.downmix = true

        // Reserve the destination exclusively before AVAudioFile opens the file we own.
        // A pre-existing source, destination or symbolic link is never overwritten.
        do { try Data().write(to: destination, options: .withoutOverwriting) }
        catch {
            if (error as NSError).code == NSFileWriteFileExistsError { throw ImportError.destinationExists }
            throw ImportError.conversion(error.localizedDescription)
        }
        var output: AVAudioFile?
        do {
            try Task.checkCancellation()
            output = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            var inputFrames: AVAudioFramePosition = 0
            var outputFrames: AVAudioFramePosition = 0
            var inputEnded = false
            var readError: Error?
            var lastProgress = 0.0
            progress(0)

            while true {
                try Task.checkCancellation()
                outputBuffer.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, state in
                    guard !inputEnded, readError == nil else { state.pointee = .endOfStream; return nil }
                    do {
                        try Task.checkCancellation()
                        let remaining = max(0, input.length - input.framePosition)
                        guard remaining > 0 else {
                            inputEnded = true; state.pointee = .endOfStream; return nil
                        }
                        try input.read(into: inputBuffer, frameCount: min(requested, bufferFrames, AVAudioFrameCount(min(remaining, AVAudioFramePosition(bufferFrames)))))
                        guard inputBuffer.frameLength > 0 else {
                            inputEnded = true; state.pointee = .endOfStream; return nil
                        }
                        inputFrames += AVAudioFramePosition(inputBuffer.frameLength)
                        guard Double(inputFrames) / format.sampleRate <= maximumDuration else { throw ImportError.tooLong }
                        let fraction = min(0.99, Double(inputFrames) / Double(input.length))
                        if fraction - lastProgress >= 0.01 { progress(fraction); lastProgress = fraction }
                        state.pointee = .haveData
                        return inputBuffer
                    } catch {
                        readError = error; state.pointee = .endOfStream; return nil
                    }
                }
                if let readError { throw readError }
                if let conversionError { throw conversionError }
                guard status != .error else { throw ImportError.conversion("Le décodeur macOS a arrêté la conversion.") }
                try Task.checkCancellation()
                if outputBuffer.frameLength > 0 {
                    outputFrames += AVAudioFramePosition(outputBuffer.frameLength)
                    guard Double(outputFrames) / sampleRate <= maximumDuration else { throw ImportError.tooLong }
                    try output?.write(from: outputBuffer)
                }
                if status == .endOfStream { break }
                if outputBuffer.frameLength == 0, status == .inputRanDry, inputEnded { break }
            }
            guard outputFrames > 0 else { throw ImportError.empty }
            // Deinitialization closes AVAudioFile and finalizes its container header.
            output = nil
            try Task.checkCancellation()
            let duration = Double(outputFrames) / sampleRate
            progress(1)
            return duration
        } catch {
            output = nil
            // This path is reached only after our exclusive reservation succeeded.
            try? FileManager.default.removeItem(at: destination)
            if error is CancellationError || error is ImportError { throw error }
            throw ImportError.conversion(error.localizedDescription)
        }
    }

    /// Synthetic fixtures only. No microphone, capture stream, permissions, or playback.
    static func verifyImport(directory: URL) async throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ImportError.destinationExists }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = ["wav", "m4a", "aiff", "caf"]
        for ext in fixtures {
            let source = directory.appendingPathComponent("fixture.\(ext)")
            try makeFixture(at: source)
            let original = try Data(contentsOf: source)
            let destination = directory.appendingPathComponent("imported-\(ext).wav")
            let duration = try await importFile(from: source, to: destination) { _ in }
            try verifyOutput(destination, duration: duration)
            guard try Data(contentsOf: source) == original else { throw diagnostic("Le fichier d’origine a été modifié.") }
        }

        // Exercise the AVAssetReader movie path with an MP4 container. No image
        // decoding or source mutation is needed to extract its audio track.
        let movie = directory.appendingPathComponent("fixture.mp4")
        let asset = AVURLAsset(url: directory.appendingPathComponent("fixture.m4a"))
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw diagnostic("Création du conteneur MP4 impossible.")
        }
        exporter.outputURL = movie; exporter.outputFileType = .mp4
        await exporter.export()
        guard exporter.status == .completed else { throw diagnostic("Fixture MP4 : \(exporter.error?.localizedDescription ?? "export incomplet")") }
        let movieBytes = try Data(contentsOf: movie)
        let movieOutput = directory.appendingPathComponent("imported-mp4.wav")
        let movieDuration = try await importFile(from: movie, to: movieOutput) { _ in }
        try verifyOutput(movieOutput, duration: movieDuration)
        guard try Data(contentsOf: movie) == movieBytes else { throw diagnostic("Le MP4 d’origine a changé.") }

        let source = directory.appendingPathComponent("fixture.wav")
        let existing = directory.appendingPathComponent("existing.wav")
        let sentinel = Data("keep-existing-audio".utf8)
        try sentinel.write(to: existing, options: .withoutOverwriting)
        do {
            _ = try await importFile(from: source, to: existing) { _ in }
            throw diagnostic("Un fichier existant a été écrasé.")
        } catch ImportError.destinationExists {}
        guard try Data(contentsOf: existing) == sentinel else { throw diagnostic("Le fichier protégé a changé.") }

        let corrupt = directory.appendingPathComponent("corrupt.m4a")
        try Data("not-audio".utf8).write(to: corrupt, options: .withoutOverwriting)
        let corruptOutput = directory.appendingPathComponent("corrupt-output.wav")
        do {
            _ = try await importFile(from: corrupt, to: corruptOutput) { _ in }
            throw diagnostic("Un fichier corrompu a été accepté.")
        } catch ImportError.unreadable(_) {}
        guard !FileManager.default.fileExists(atPath: corruptOutput.path) else { throw diagnostic("Un import corrompu a laissé une piste.") }

        let oversized = directory.appendingPathComponent("over-four-hours.wav")
        try makeSparseWAV(at: oversized, duration: maximumDuration + 1)
        let oversizedOutput = directory.appendingPathComponent("too-long-output.wav")
        do {
            _ = try await importFile(from: oversized, to: oversizedOutput) { _ in }
            throw diagnostic("La limite de quatre heures n’a pas été appliquée.")
        } catch ImportError.tooLong {}
        guard !FileManager.default.fileExists(atPath: oversizedOutput.path) else { throw diagnostic("Un import trop long a laissé une piste.") }

        let cancelledOutput = directory.appendingPathComponent("cancelled-output.wav")
        let cancellation = ImportCancellationProbe()
        let task = Task {
            try await importFile(from: source, to: cancelledOutput) { fraction in
                if fraction > 0, fraction < 1 { cancellation.cancel() }
            }
        }
        cancellation.install(task)
        do { _ = try await task.value; throw diagnostic("L’annulation de l’import a été ignorée.") }
        catch is CancellationError {}
        guard !FileManager.default.fileExists(atPath: cancelledOutput.path) else { throw diagnostic("Un import annulé a laissé une piste.") }
    }

    private static func diagnostic(_ text: String) -> ImportError { .conversion("Auto-test : \(text)") }

    private static func makeFixture(at url: URL) throws {
        let isAAC = url.pathExtension == "m4a"
        var settings: [String: Any] = [AVFormatIDKey: isAAC ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM,
                                      AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
        if isAAC { settings[AVEncoderBitRateKey] = 128_000 }
        else {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = url.pathExtension == "aiff"
        }
        try Data().write(to: url, options: .withoutOverwriting)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000),
              let channels = pcm.floatChannelData else { throw diagnostic("Allocation du signal synthétique impossible.") }
        pcm.frameLength = 48_000
        for frame in 0..<48_000 {
            let tone = Float(sin(2 * Double.pi * 800 * Double(frame) / 48_000))
            // A first-channel-only implementation would incorrectly produce silence.
            channels[0][frame] = 0
            channels[1][frame] = tone * 0.6
        }
        try file.write(from: pcm)
    }

    private static func verifyOutput(_ url: URL, duration: Double) throws {
        let audio = try AVAudioFile(forReading: url)
        guard audio.fileFormat.sampleRate == sampleRate, audio.fileFormat.channelCount == 1,
              audio.fileFormat.commonFormat == .pcmFormatInt16, abs(duration - 1) < 0.1,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw diagnostic("Le WAV n’est pas mono 16 kHz PCM16 ou sa durée est incorrecte.")
        }
        try audio.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw diagnostic("Le WAV produit est illisible.") }
        let peak = (1_600..<min(Int(buffer.frameLength), 14_400)).reduce(Float(0)) { max($0, abs(samples[$1])) }
        guard peak > 0.1, peak < 0.5 else { throw diagnostic("Le signal stéréo n’a pas été correctement fusionné.") }
    }

    private static func makeSparseWAV(at url: URL, duration: Double) throws {
        let rate: UInt32 = 8_000
        let bytes = UInt32(duration * Double(rate)) * 2
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(bytes + 36); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); text("data"); u32(bytes)
        try header.write(to: url, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(bytes) + 44)
    }
}

/// Only used by the offline verification; synchronization also covers cancellation before install.
private final class ImportCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Double, Error>?
    private var requested = false

    func install(_ task: Task<Double, Error>) {
        lock.lock(); self.task = task; let cancelNow = requested; lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock(); requested = true; let task = task; lock.unlock()
        task?.cancel()
    }
}
