import AVFoundation
import Foundation

/// Feeds synthetic speech at recording speed through the actual preview backend.
/// No microphone, event tap, authorization prompt, or dictation engine is used.
@MainActor
enum LivePreviewDiagnostics {
    static func verify(fileURL: URL) async throws {
        guard #available(macOS 26, *) else {
            throw VeloceError.message("Ce diagnostic nécessite macOS 26.")
        }
        let observations = PreviewObservations()
        let preview = try await AnalyzerPreview.make(locale: Locale(identifier: "fr-FR"), onPartial: { stable, volatile in
            observations.record(stable: stable, volatile: volatile)
        }, onFailure: { observations.fail($0) })
        defer { preview.cancel() }
        let audio = try AVAudioFile(forReading: fileURL)
        guard let target = preview.format,
              let converter = PreviewConverter(from: audio.processingFormat, to: target),
              audio.length > AVAudioFramePosition(audio.processingFormat.sampleRate * 3) else {
            throw VeloceError.message("Le diagnostic attend au moins trois secondes de parole française.")
        }
        observations.begin()
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
                throw VeloceError.message("Impossible de préparer les buffers de test.")
            }
            try audio.read(into: buffer)
            guard let converted = converter.convert(buffer) else {
                throw VeloceError.message("Conversion audio de l’aperçu impossible.")
            }
            preview.append(converted)
            let duration = Double(buffer.frameLength) / audio.processingFormat.sampleRate
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
        observations.endInput()
        try await preview.finish()
        let result = observations.snapshot()
        if let failure = result.failure { throw VeloceError.message(failure) }
        guard result.partialCount > 1, result.hadVolatile, !result.text.isEmpty else {
            throw VeloceError.message("L’aperçu n’a pas fourni de mots progressifs avant la fin de l’audio.")
        }
        print("Live preview: \(result.partialCount) progressive results, first text after \(String(format: "%.2f", result.firstTextDelay ?? 0)) s")
        print("Synthetic transcript: \(result.text)")
    }
}

private final class PreviewObservations: @unchecked Sendable {
    struct Result {
        var partialCount = 0
        var hadVolatile = false
        var text = ""
        var firstTextDelay: TimeInterval?
        var failure: String?
    }
    private let lock = NSLock()
    private var began: Date?
    private var feeding = false
    private var result = Result()

    func begin() { lock.withLock { began = Date(); feeding = true } }
    func endInput() { lock.withLock { feeding = false } }
    func fail(_ message: String) { lock.withLock { result.failure = message } }
    func snapshot() -> Result { lock.withLock { result } }

    func record(stable: String, volatile: String) {
        lock.withLock {
            let text = LivePreviewText.join(stable, volatile)
            guard !text.isEmpty else { return }
            if feeding {
                result.partialCount += 1
                result.hadVolatile = result.hadVolatile || !volatile.isEmpty
            }
            if result.firstTextDelay == nil, let began { result.firstTextDelay = Date().timeIntervalSince(began) }
            result.text = text
        }
    }
}
