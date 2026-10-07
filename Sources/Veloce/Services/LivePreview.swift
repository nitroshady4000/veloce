import AVFoundation
import Foundation
import Speech

// Live words in the pill while dictating, the way Famulus shows them
// (famulus/app/poc/Voice.swift): Apple's on-device recognizer listens to the
// microphone beside the recorder. Preview only: the inserted text stays the
// local model's. Nothing here may delay or break a dictation; every failure
// ends in "no preview".
//
//   1. SpeechAnalyzer + DictationTranscriber (macOS 26+), when its model is
//      already installed for the language;
//   2. SFSpeechRecognizer with requiresOnDeviceRecognition;
//   3. otherwise nothing.

/// Settled words, and the tail the recognizer may still revise.
struct LivePreviewText: Equatable {
    var stable = ""
    var volatile = ""

    var isEmpty: Bool { text.isEmpty }
    var text: String { Self.join(stable, volatile) }

    static func join(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

@MainActor
final class LivePreviewTranscriber {
    var onText: ((LivePreviewText) -> Void)?
    /// Bumped at each start and stop: late results of an older session are dropped.
    private var session = 0
    private var active: PreviewCapture?
    /// Engine calls never run on the main thread (the pill's first frames).
    private let queue = DispatchQueue(label: "com.veloce.live-preview", qos: .userInitiated)

    /// Starts listening for the pill. Returns at once; the words follow when
    /// (and if) a recognizer is ready.
    func start(language: String) {
        stop()
        session += 1
        let id = session
        let locale = Self.locale(for: language)
        Task { @MainActor [weak self] in
            guard await Self.authorized(), let self, id == self.session else { return }
            let partial: @Sendable (String, String) -> Void = { [weak self] stable, volatile in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    self.onText?(LivePreviewText(stable: stable, volatile: volatile))
                }
            }
            guard let recognizer = await Self.recognizer(locale: locale, onPartial: partial) else { return }
            guard id == self.session else { recognizer.cancel(); return }
            let capture = PreviewCapture(recognizer: recognizer)
            self.active = capture
            self.queue.async { capture.start() }
        }
    }

    /// The microphone closes for the preview as soon as the recording stops.
    func stop() {
        session += 1
        guard let active else { return }
        self.active = nil
        queue.async { active.stop() }
    }

    /// Véloce's language setting as a locale; Auto follows the system.
    static func locale(for language: String) -> Locale {
        switch language {
        case "French": Locale(identifier: "fr-FR")
        case "English": Locale(identifier: "en-US")
        case "Spanish": Locale(identifier: "es-ES")
        case "German": Locale(identifier: "de-DE")
        case "Italian": Locale(identifier: "it-IT")
        default: Locale.current
        }
    }

    /// Asked lazily, at the first dictation. Denied or unanswered: no preview.
    private static func authorized() async -> Bool {
        // Asking without a usage string would abort the app.
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
            }
        default: return false
        }
    }

    private static func recognizer(locale: Locale, onPartial: @escaping @Sendable (String, String) -> Void) async -> PreviewRecognizer? {
        if #available(macOS 26, *), let analyzer = await AnalyzerPreview.make(locale: locale, onPartial: onPartial) {
            return analyzer
        }
        return LegacyPreview(locale: locale, onPartial: onPartial)
    }
}

// MARK: - Recognizers

protocol PreviewRecognizer: AnyObject, Sendable {
    /// The format it wants (nil: mono Float32 at the device rate).
    var format: AVAudioFormat? { get }
    /// Thread-safe, called from the audio tap.
    func append(_ buffer: AVAudioPCMBuffer)
    func cancel()
}

@available(macOS 26, *)
final class AnalyzerPreview: PreviewRecognizer, @unchecked Sendable {
    let format: AVAudioFormat?
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    /// Resolved once per locale: the supported locale and the analyzer's format.
    @MainActor private static var ready: [String: (Locale, AVAudioFormat?)] = [:]

    private static func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    }

    /// Nil when the language is unsupported or its model is not installed
    /// (never downloaded behind the owner's back).
    @MainActor static func make(locale requested: Locale, onPartial: @escaping @Sendable (String, String) -> Void) async -> AnalyzerPreview? {
        let key = requested.identifier
        if ready[key] == nil {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else { return nil }
            let probe = makeTranscriber(locale)
            guard await AssetInventory.status(forModules: [probe]) == .installed else { return nil }
            ready[key] = (locale, await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]))
        }
        guard let (locale, format) = ready[key] else { return nil }
        return AnalyzerPreview(transcriber: makeTranscriber(locale), format: format, onPartial: onPartial)
    }

    private init(transcriber: DictationTranscriber, format: AVAudioFormat?, onPartial: @escaping @Sendable (String, String) -> Void) {
        self.format = format
        // The model stays loaded for the process: the next dictation starts quicker.
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        resultsTask = Task {
            var stable = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        stable = LivePreviewText.join(stable, text)
                        onPartial(stable, "")
                    } else {
                        onPartial(stable, text)
                    }
                }
            } catch {}
        }
        startTask = Task { try? await analyzer.start(inputSequence: stream) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    func cancel() {
        continuation.finish()
        startTask?.cancel()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Before macOS 26, or without the new model: the older on-device recognizer.
final class LegacyPreview: PreviewRecognizer, @unchecked Sendable {
    let format: AVAudioFormat? = nil
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    init?(locale: Locale, onPartial: @escaping @Sendable (String, String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true  // never the network
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        task = recognizer.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            // The last word may still change until the result is final.
            if !result.isFinal, let space = text.lastIndex(of: " ") {
                onPartial(String(text[..<space]), String(text[text.index(after: space)...]))
            } else {
                onPartial(result.isFinal ? text : "", result.isFinal ? "" : text)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

    func cancel() {
        request.endAudio()
        task?.cancel()
        task = nil
    }
}

// MARK: - Microphone (a second, independent listener beside the recorder)

/// Its own AVAudioEngine on the default input, only while a dictation records.
/// The recorder (AVAudioRecorder) is never touched. Runs on the preview queue.
final class PreviewCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let recognizer: PreviewRecognizer
    private var tapped = false

    init(recognizer: PreviewRecognizer) {
        self.recognizer = recognizer
    }

    func start() {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        // No input device (or not yet available): an invalid format would abort in installTap.
        guard native.sampleRate > 0, native.channelCount > 0,
              let target = recognizer.format ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.sampleRate,
                                                              channels: 1, interleaved: false) else {
            recognizer.cancel(); return
        }
        let converter = native == target ? nil : PreviewConverter(from: native, to: target)
        if native != target && converter == nil { recognizer.cancel(); return }
        let recognizer = recognizer
        input.installTap(onBus: 0, bufferSize: 1024, format: native) { buffer, _ in
            if let converter {
                if let converted = converter.convert(buffer) { recognizer.append(converted) }
            } else {
                recognizer.append(buffer)
            }
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { stop() }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        recognizer.cancel()
    }
}

/// Famulus' FormatConverter: first channel only, resampled.
final class PreviewConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        if input.channelCount > 1 && output.channelCount == 1 { converter.channelMap = [0] }
        self.converter = converter
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
