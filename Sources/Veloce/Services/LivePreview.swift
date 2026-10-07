import AVFoundation
import Foundation
import Speech

// Live words in the pill while dictating, the way Famulus shows them
// (famulus/app/poc/Voice.swift): Apple's on-device recognizer listens to the
// microphone beside the recorder. Preview only: the inserted text stays the
// local model's. Nothing here may delay or break a dictation; every failure
// ends in "no preview".
//
//   1. SpeechAnalyzer + DictationTranscriber (macOS 26+), after preparing its
//      on-device model for the language;
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

enum LivePreviewState: Equatable {
    case idle
    case preparing
    case downloading
    case ready
    case needsAuthorization
    case permissionDenied
    case unavailable(String)
}

@MainActor
final class LivePreviewTranscriber {
    var onText: ((LivePreviewText) -> Void)?
    var onState: ((LivePreviewState) -> Void)?
    /// Bumped at each start and stop: late results of an older session are dropped.
    private var session = 0
    private var preparation = 0
    private var currentState: LivePreviewState = .idle
    private var active: PreviewCapture?
    private var preparedAnalyzers: [String: PreparedAnalyzer] = [:]
    private var analyzerPreparationTasks: [String: Task<AnalyzerPreparation, Never>] = [:]
    /// Engine calls never run on the main thread (the pill's first frames).
    private let queue = DispatchQueue(label: "com.veloce.live-preview", qos: .userInitiated)

    /// Starts listening for the pill. Returns at once; the words follow when
    /// (and if) a recognizer is ready.
    func start(language: String) {
        stop()
        session += 1
        preparation += 1
        let id = session
        let locale = Self.locale(for: language)
        Task { @MainActor [weak self] in
            guard let self, id == self.session else { return }
            self.setState(.preparing)
            let partial: @Sendable (String, String) -> Void = { [weak self] stable, volatile in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    self.onText?(LivePreviewText(stable: stable, volatile: volatile))
                }
            }
            let recognizer: PreviewRecognizer
            if #available(macOS 26, *), let prepared = await self.prepareAnalyzer(locale: locale, session: id) {
                recognizer = AnalyzerPreview(prepared: prepared, onPartial: partial) { [weak self] message in
                    Task { @MainActor in
                        self?.failSession(id, message: message)
                    }
                }
            } else {
                guard id == self.session else { return }
                guard let legacyRecognizer = SFSpeechRecognizer(locale: locale),
                      legacyRecognizer.supportsOnDeviceRecognition, legacyRecognizer.isAvailable else {
                    self.setState(.unavailable("Aperçu vocal indisponible pour cette langue."))
                    return
                }
                let authorization = await Self.legacyAuthorization(request: true)
                guard id == self.session else { return }
                switch authorization {
                case .authorized: break
                case .needsAuthorization:
                    self.setState(.needsAuthorization)
                    return
                case .denied:
                    self.setState(.permissionDenied)
                    return
                case .missingUsageDescription:
                    self.setState(.unavailable("Description d’utilisation de la reconnaissance vocale manquante."))
                    return
                }
                guard id == self.session else { return }
                guard let legacy = LegacyPreview(locale: locale, onPartial: partial, onFailure: { [weak self] message in
                    Task { @MainActor in
                        self?.failSession(id, message: message)
                    }
                }) else {
                    self.setState(.unavailable("Aperçu vocal indisponible pour cette langue."))
                    return
                }
                recognizer = legacy
            }
            guard id == self.session else { recognizer.cancel(); return }
            let capture = PreviewCapture(recognizer: recognizer) { [weak self] message in
                Task { @MainActor in
                    self?.failSession(id, message: message)
                }
            } onStarted: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    self.setState(.ready)
                }
            }
            self.active = capture
            self.queue.async { capture.start() }
        }
    }

    /// The microphone closes for the preview as soon as the recording stops.
    func stop() {
        session += 1
        preparation += 1
        let priorState = currentState
        stopActiveCapture()
        switch priorState {
        case .ready: setState(.ready)
        case .preparing, .downloading, .needsAuthorization: setState(.idle)
        case .idle, .permissionDenied, .unavailable: break
        }
    }

    /// Prepares recognition without opening the microphone. Setting
    /// `requestAuthorization` allows the legacy path to show Apple's Speech prompt.
    /// Modern Speech asset installation is handled independently of that prompt.
    func prepare(language: String, requestAuthorization: Bool = false) {
        preparation += 1
        let id = preparation
        let locale = Self.locale(for: language)
        setState(.preparing)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if #available(macOS 26, *), await self.prepareAnalyzer(locale: locale, preparation: id) != nil {
                guard id == self.preparation else { return }
                self.setState(.ready)
                return
            }
            guard id == self.preparation else { return }
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                self.setState(.unavailable("Aperçu vocal indisponible pour cette langue."))
                return
            }
            guard recognizer.isAvailable else {
                self.setState(.unavailable("Reconnaissance vocale temporairement indisponible."))
                return
            }
            let authorization = await Self.legacyAuthorization(request: requestAuthorization)
            guard id == self.preparation else { return }
            switch authorization {
            case .authorized: self.setState(.ready)
            case .needsAuthorization:
                self.setState(.needsAuthorization)
            case .denied: self.setState(.permissionDenied)
            case .missingUsageDescription: self.setState(.unavailable("Description d’utilisation de la reconnaissance vocale manquante."))
            }
        }
    }

    private func stopActiveCapture() {
        guard let active else { return }
        self.active = nil
        queue.async { active.stop() }
    }

    private func failSession(_ id: Int, message: String) {
        guard session == id else { return }
        session += 1
        stopActiveCapture()
        setState(.unavailable(message))
    }

    private func setState(_ state: LivePreviewState) {
        currentState = state
        onState?(state)
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

    private enum LegacyAuthorization {
        case authorized, needsAuthorization, denied, missingUsageDescription
    }

    private static func legacyAuthorization(request: Bool = false) async -> LegacyAuthorization {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return .missingUsageDescription }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined:
            guard request else { return .needsAuthorization }
            return await withCheckedContinuation { (continuation: CheckedContinuation<LegacyAuthorization, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized ? .authorized : .denied)
                }
            }
        default: return .denied
        }
    }

    @available(macOS 26, *)
    private func prepareAnalyzer(locale requested: Locale, session id: Int? = nil, preparation preparationID: Int? = nil) async -> PreparedAnalyzer? {
        let requestedKey = requested.identifier
        if let prepared = preparedAnalyzers[requestedKey] { return prepared }
        if let existing = analyzerPreparationTasks[requestedKey] {
            let result = await existing.value
            return result.prepared
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return AnalyzerPreparation(prepared: nil, error: "Préparation de l’aperçu interrompue." ) }
            return await self.makePreparedAnalyzer(for: requested, session: id, preparation: preparationID)
        }
        analyzerPreparationTasks[requestedKey] = task
        let result = await task.value
        analyzerPreparationTasks.removeValue(forKey: requestedKey)
        if let prepared = result.prepared { preparedAnalyzers[requestedKey] = prepared }
        if let error = result.error,
           (id != nil && id == session || preparationID != nil && preparationID == preparation) {
            setState(.unavailable(error))
        }
        return result.prepared
    }

    @available(macOS 26, *)
    private func makePreparedAnalyzer(for requested: Locale, session id: Int?, preparation preparationID: Int?) async -> AnalyzerPreparation {
        do {
            let prepared = try await AnalyzerPreview.prepare(locale: requested) { [weak self] state in
                guard let self,
                      (id != nil && id == self.session || preparationID != nil && preparationID == self.preparation) else { return }
                self.setState(state)
            }
            return AnalyzerPreparation(prepared: prepared, error: nil)
        } catch {
            if error is UnsupportedPreviewLocale { return AnalyzerPreparation(prepared: nil, error: nil) }
            return AnalyzerPreparation(prepared: nil, error: error.localizedDescription)
        }
    }
}

struct PreparedAnalyzer: @unchecked Sendable {
    let locale: Locale
    let format: AVAudioFormat
}

private struct AnalyzerPreparation: Sendable {
    let prepared: PreparedAnalyzer?
    let error: String?
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

    static func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    }

    /// Resolves and prepares a locale without opening a microphone. Supported assets
    /// are installed on demand; unsupported locales and failed installs are explicit.
    @MainActor static func prepare(locale requested: Locale,
                                   onState: @escaping @MainActor (LivePreviewState) -> Void = { _ in }) async throws -> PreparedAnalyzer {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw UnsupportedPreviewLocale()
        }
        let transcriber = makeTranscriber(locale)
        var status = await AssetInventory.status(forModules: [transcriber])
        if status == .supported || status == .downloading {
            onState(.downloading)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                status = await AssetInventory.status(forModules: [transcriber])
                guard status == .installed else { throw PreviewSetupError("Impossible d’installer le modèle vocal local.") }
                return try await warm(transcriber: transcriber, locale: locale)
            }
            try await request.downloadAndInstall()
            status = await AssetInventory.status(forModules: [transcriber])
        }
        guard status == .installed else {
            if status == .unsupported { throw UnsupportedPreviewLocale() }
            throw PreviewSetupError("Le modèle vocal local n’est pas installé.")
        }
        return try await warm(transcriber: transcriber, locale: locale)
    }

    @MainActor private static func warm(transcriber: DictationTranscriber, locale: Locale) async throws -> PreparedAnalyzer {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw PreviewSetupError("Aucun format audio compatible avec le modèle vocal.")
        }
        let warmup = SpeechAnalyzer(modules: [transcriber],
                                    options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        do {
            try await warmup.prepareToAnalyze(in: format)
            await warmup.cancelAndFinishNow()
            return PreparedAnalyzer(locale: locale, format: format)
        } catch {
            await warmup.cancelAndFinishNow()
            throw PreviewSetupError("Impossible de préparer l’analyse vocale : \(error.localizedDescription)")
        }
    }

    @MainActor static func make(locale: Locale,
                                onPartial: @escaping @Sendable (String, String) -> Void,
                                onFailure: @escaping @Sendable (String) -> Void) async throws -> AnalyzerPreview {
        let prepared = try await prepare(locale: locale)
        return AnalyzerPreview(prepared: prepared, onPartial: onPartial, onFailure: onFailure)
    }

    init(prepared: PreparedAnalyzer,
         onPartial: @escaping @Sendable (String, String) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.format = prepared.format
        // The model stays loaded for the process: the next dictation starts quicker.
        let transcriber = Self.makeTranscriber(prepared.locale)
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
            } catch is CancellationError {
            } catch {
                onFailure("Échec de la reconnaissance vocale : \(error.localizedDescription)")
            }
        }
        startTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch is CancellationError {}
            catch { onFailure("Impossible de démarrer l’analyse vocale : \(error.localizedDescription)") }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends live input cleanly and waits until final results have been delivered.
    func finish() async throws {
        continuation.finish()
        await startTask?.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    func cancel() {
        continuation.finish()
        startTask?.cancel()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

private struct PreviewSetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct UnsupportedPreviewLocale: LocalizedError {
    var errorDescription: String? { "Aperçu vocal indisponible pour cette langue." }
}

/// Before macOS 26, or without the new model: the older on-device recognizer.
final class LegacyPreview: PreviewRecognizer, @unchecked Sendable {
    let format: AVAudioFormat? = nil
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    init?(locale: Locale, onPartial: @escaping @Sendable (String, String) -> Void,
          onFailure: @escaping @Sendable (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true  // never the network
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                onFailure("Échec de la reconnaissance vocale locale : \(error.localizedDescription)")
                return
            }
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
    private let onFailure: @Sendable (String) -> Void
    private let onStarted: @Sendable () -> Void
    private var tapped = false

    init(recognizer: PreviewRecognizer,
         onFailure: @escaping @Sendable (String) -> Void,
         onStarted: @escaping @Sendable () -> Void) {
        self.recognizer = recognizer
        self.onFailure = onFailure
        self.onStarted = onStarted
    }

    func start() {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        // No input device (or not yet available): an invalid format would abort in installTap.
        guard native.sampleRate > 0, native.channelCount > 0,
              let target = recognizer.format ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.sampleRate,
                                                              channels: 1, interleaved: false) else {
            recognizer.cancel()
            onFailure("Aucun format d’entrée microphone utilisable.")
            return
        }
        let converter = native == target ? nil : PreviewConverter(from: native, to: target)
        if native != target && converter == nil {
            recognizer.cancel()
            onFailure("Impossible de convertir le format du microphone.")
            return
        }
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
        do {
            try engine.start()
            onStarted()
        } catch {
            stop()
            onFailure("Impossible de démarrer l’aperçu microphone : \(error.localizedDescription)")
        }
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
