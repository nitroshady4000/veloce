import AppKit
import AVFoundation
import SwiftUI
import VeloceCore

enum DictationPhase { case idle, preparing, ready, recording, transcribing, error }
enum DictationPresentationMode: String, CaseIterable { case pill, menuBar }
enum DictationOutcome { case none, inserted, available, empty, failed }
enum ModelPreparationNotice { case loading, ready, failed }
enum TextInstructionPhase { case idle, recording, transcribing }
struct TextInstructionHandlers {
    let onText: (String) -> Void
    let onUpdate: (TextInstructionPhase, String?) -> Void
    let onLevel: (Double) -> Void
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var statusMessage = "Maintenez Fn pour dicter."
    @Published var level: Double = 0
    @Published private(set) var transcriptInserted = false
    @Published private(set) var isHandsFree = false
    @Published private(set) var modelPreparationNotice: ModelPreparationNotice?
    @Published var presentationMode: DictationPresentationMode {
        didSet {
            UserDefaults.standard.set(presentationMode.rawValue, forKey: "dictationPresentation")
            onPresentationModeChange?(presentationMode)
        }
    }
    @Published var finderExportFormat: String {
        didSet { UserDefaults.standard.set(finderExportFormat, forKey: "finderExportFormat") }
    }
    @Published var doubleFnEnabled: Bool {
        didSet {
            UserDefaults.standard.set(doubleFnEnabled, forKey: "doubleFnEnabled")
            hotkey.setDoubleTapEnabled(doubleFnEnabled)
            refreshPermissions()
        }
    }
    @Published var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    @Published var snippets: [VoiceSnippet] {
        didSet {
            if let data = try? JSONEncoder().encode(snippets) { UserDefaults.standard.set(data, forKey: "voiceSnippets") }
        }
    }
    @Published var selectedModel: SpeechModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "model") }
    }
    @Published var loadedModel: SpeechModel?
    @Published var history: [Transcript] = []
    @Published var vocabulary: String {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var keepHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepHistory, forKey: "keepHistory")
            if !keepHistory { clearHistory() }
            else { saveHistory() }
        }
    }
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    @Published private(set) var microphonePermission: MicrophonePermission = .notDetermined
    @Published private(set) var hotkeyReady = false
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var accessibilityRequested = false
    @Published private(set) var permissionSettingsOpened: VelocePermission?
    @Published private(set) var permissionError: String?
    @Published var permissionGuide: VelocePermission?
    var inputReady: Bool { accessibilityGranted && hotkeyReady }
    var allPermissionsReady: Bool { microphoneGranted && inputReady }
    @Published var engineInstalled = false
    @Published private(set) var meetingBusy = false
    @Published private(set) var textProcessingBusy = false
    @Published private(set) var pendingDictationCount = 0
    @Published private(set) var isDictationProcessing = false
    @Published private(set) var lastDictationOutcome: DictationOutcome = .none
    /// Apple's on-device words for the pill while dictating (preview only).
    @Published private(set) var livePreview = LivePreviewText()
    var isBusy: Bool { meetingBusy || textProcessingBusy || pendingDictationCount > 0 || phase == .preparing || phase == .recording || phase == .transcribing }
    var canStartDictation: Bool {
        !meetingBusy && !textProcessingBusy && phase != .preparing && capture == nil
            && !instructionProcessing && textInstruction == nil && pipeline.count < pipeline.capacity
            && engineReady && microphoneGranted
    }
    var textProcessingUnavailableReason: String? { LocalTextProcessor.unavailableReason }
    var isRecording: Bool { phase == .recording }
    var engineReady: Bool { loadedModel == selectedModel && phase != .preparing }
    private let permissions = PermissionCoordinator()
    private let engine = EngineClient()
    lazy var meetings: MeetingModel = {
        let meetings = MeetingModel(engine: engine)
        meetings.canBegin = { [weak self] in self?.isBusy == false }
        meetings.onBusyChange = { [weak self] in self?.meetingBusy = $0 }
        meetings.onModelLoaded = { [weak self] model in
            self?.markModelLoaded(model)
        }
        meetings.onSidecarReady = { record, source, format in
            _ = try MeetingSidecar.write(record: record, beside: source, format: format)
        }
        return meetings
    }()
    private let recorder = AudioRecorder()
    private let preview = LivePreviewTranscriber()
    private let hotkey = FnKeyMonitor()
    private lazy var textProcessingController: TextProcessingController = {
        let controller = TextProcessingController()
        controller.canBegin = { [weak self] in self?.isBusy == false }
        controller.onBusyChange = { [weak self] in self?.textProcessingBusy = $0 }
        controller.onVoiceStart = { [weak self] handlers in self?.startTextInstruction(handlers) ?? false }
        controller.onVoiceFinish = { [weak self] in
            guard self?.textInstruction != nil else { return }
            self?.finishRecording()
        }
        controller.onVoiceCancel = { [weak self] in
            guard self?.textInstruction != nil else { return }
            self?.cancel()
        }
        return controller
    }()
    private struct CaptureContext {
        let id = UUID()
        let started = Date()
        let model: SpeechModel
        let language: String
        let vocabulary: String
        let snippets: [VoiceSnippet]
        let cleanup: Bool
        let target: NSRunningApplication?
        let inserter: TextInserter
        let instruction: TextInstructionHandlers?
    }
    private struct DictationJob {
        let capture: CaptureContext
        let audioURL: URL
        let duration: Double
    }
    private var capture: CaptureContext?
    private var pipeline = DictationPipeline<DictationJob>(capacity: 4)
    private var processingTask: Task<Void, Never>?
    private var pipelineGeneration = UUID()
    private var processingMessage = "Transcription…"
    private var instructionProcessing = false
    private var recordingLimit: Task<Void, Never>?
    private var hudDismissal: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var heldFn = false
    private var textInstruction: TextInstructionHandlers?
    private var permissionTimer: Timer?
    var onHUDVisibility: ((Bool) -> Void)?
    var onPresentationModeChange: ((DictationPresentationMode) -> Void)?
    private var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veloce/history.json")
    }
    private let preparedModelKey = "preparedModel"

    init() {
        let defaults = UserDefaults.standard
        selectedModel = SpeechModel(rawValue: defaults.string(forKey: "model") ?? "") ?? .balanced
        presentationMode = DictationPresentationMode(rawValue: defaults.string(forKey: "dictationPresentation") ?? "") ?? .pill
        finderExportFormat = defaults.string(forKey: "finderExportFormat") == "md" ? "md" : "txt"
        doubleFnEnabled = defaults.object(forKey: "doubleFnEnabled") as? Bool ?? true
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        if let data = defaults.data(forKey: "voiceSnippets"), let saved = try? JSONDecoder().decode([VoiceSnippet].self, from: data) {
            snippets = saved
        } else { snippets = [] }
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        language = defaults.string(forKey: "language") ?? "French"
        keepHistory = defaults.bool(forKey: "keepHistory")
        if keepHistory, let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Transcript].self, from: data) { history = saved }
        engineInstalled = engine.installed
        hotkey.setDoubleTapEnabled(doubleFnEnabled)
        preview.onText = { [weak self] text in
            guard let self, self.capture != nil else { return }
            self.livePreview = text
        }
        recorder.onLevel = { [weak self] value in
            self?.level = value
            self?.textInstruction?.onLevel(value)
        }
        engine.onStatus = { [weak self] state in
            guard let self, self.phase == .preparing else { return }
            if state == "loading" { self.statusMessage = "Téléchargement et chargement du modèle…" }
        }
        engine.onExit = { [weak self] in
            self?.loadedModel = nil
            if self?.phase == .ready { self?.phase = .idle; self?.statusMessage = "Le moteur s’est arrêté. Relancez le modèle." }
        }
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        restorePreparedModel()
    }

    /// Restore a model the user already prepared, using the local cache only.
    /// A missing cache leaves the app idle and never starts a download.
    private func restorePreparedModel() {
        guard engine.hasExistingEnvironment, !isBusy else { return }
        let defaults = UserDefaults.standard
        let model = SpeechModel(rawValue: defaults.string(forKey: preparedModelKey) ?? "") ?? selectedModel
        // Resume the last working model, including after browsing another card.
        selectedModel = model
        generation = UUID()
        let token = generation
        phase = .preparing
        statusMessage = "Chargement du modèle local…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if !engine.installed {
                    statusMessage = "Mise à jour du moteur local…"
                    try await engine.install(includeParakeet: model == .fast)
                    engineInstalled = engine.installed
                }
                _ = try await engine.request("load_cached", params: ["model": model.rawValue], timeout: 1800)
                guard token == generation, !Task.isCancelled else { return }
                markModelLoaded(model)
                statusMessage = "Prêt. Maintenez Fn pour parler."
                finishModelPreparationNotice(succeeded: true)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                loadedModel = nil
                phase = .idle
                statusMessage = "Chargement automatique impossible. \(error.localizedDescription)"
                finishModelPreparationNotice(succeeded: false)
            }
        }
    }

    private func markModelLoaded(_ model: SpeechModel) {
        loadedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: preparedModelKey)
        switch phase {
        case .preparing, .idle, .ready: phase = .ready
        case .recording, .transcribing, .error: break
        }
    }

    func refreshPermissions() {
        let snapshot = permissions.snapshot()
        microphonePermission = snapshot.microphone
        microphoneGranted = snapshot.microphone == .granted
        accessibilityGranted = snapshot.accessibility

        let microphoneInterrupted = isRecording && !microphoneGranted
        let shortcutInterrupted = isRecording && heldFn && (!accessibilityGranted || !hotkey.isRunning)
        if microphoneInterrupted || shortcutInterrupted {
            // Do not keep listening when Fn's release can no longer arrive.
            // A manually started recording can continue without Accessibility.
            heldFn = false
            cancel()
        }

        if !accessibilityGranted {
            hotkey.stop()
        } else if !hotkey.isRunning {
            hotkey.start(onPress: { [weak self] in
                guard let self else { return }; self.heldFn = true
                self.startRecording(fromHotkey: true)
            }, onRelease: { [weak self] in
                self?.heldFn = false
                if self?.isRecording == true { self?.finishRecording() }
            }, onCancel: { [weak self] in self?.heldFn = false; self?.cancel() }, onHandsFree: { [weak self] in
                guard let self, self.isRecording else { return }
                self.isHandsFree = true
                self.statusMessage = "Mains libres. Appuyez sur Fn pour terminer, Échap pour annuler."
            })
        }
        hotkeyReady = accessibilityGranted && hotkey.isRunning
        if microphoneInterrupted {
            statusMessage = "Dictée annulée : l’accès au microphone a été retiré."
        } else if shortcutInterrupted {
            statusMessage = "Dictée annulée : Fn a perdu son accès. Vérifiez les permissions."
        }
    }

    func requestMicrophone() { showPermissionGuide(.microphone) }
    func requestAccessibility() { showPermissionGuide(.accessibility) }

    private func showPermissionGuide(_ permission: VelocePermission) {
        refreshPermissions()
        permissionError = nil
        permissionGuide = permission
    }

    func authorizeMicrophone() {
        guard !requestingMicrophone else { return }
        permissionError = nil
        guard microphonePermission == .notDetermined else {
            if microphonePermission == .denied { openPermissionSettings(.microphone) }
            return
        }
        requestingMicrophone = true
        Task {
            await permissions.requestMicrophone()
            requestingMicrophone = false
            refreshPermissions()
        }
    }

    func authorizeAccessibility() {
        permissionError = nil
        if accessibilityRequested {
            openPermissionSettings(.accessibility)
        } else {
            accessibilityRequested = true
            permissions.requestAccessibility()
            refreshPermissions()
        }
    }

    func openPermissionSettings(_ permission: VelocePermission) {
        permissionError = nil
        if permissions.openSettings(for: permission) {
            permissionSettingsOpened = permission
        } else {
            permissionError = "Ouvrez Réglages Système → Confidentialité et sécurité, puis la permission indiquée."
        }
    }

    func revealApplicationForPermissions() { permissions.revealApplication() }

    func prepareModel() {
        guard !isBusy else { return }
        hudDismissal?.cancel(); onHUDVisibility?(false)
        modelPreparationNotice = nil
        let model = selectedModel
        generation = UUID()
        let token = generation
        phase = .preparing; statusMessage = "Préparation du moteur local…"
        loadedModel = nil
        operation = Task {
            do {
                if !engine.installed || model == .fast {
                    statusMessage = "Installation des dépendances locales…"
                    try await engine.install(includeParakeet: model == .fast)
                }
                guard token == generation, !Task.isCancelled else { return }
                engineInstalled = engine.installed
                _ = try await engine.request("load", params: ["model": model.rawValue], timeout: 1800)
                guard token == generation, !Task.isCancelled else { return }
                markModelLoaded(model)
                statusMessage = "Prêt. Maintenez Fn pour parler."
                finishModelPreparationNotice(succeeded: true)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                phase = .error; statusMessage = error.localizedDescription
                finishModelPreparationNotice(succeeded: false)
            }
        }
    }

    func toggleRecording() {
        if isRecording { finishRecording() } else { startRecording(fromHotkey: false) }
    }
    private func startRecording(fromHotkey: Bool) {
        if phase == .preparing {
            // A rejected Fn press must still explain why no capture started.
            // Keep the notice until loading finishes, even after key release.
            hudDismissal?.cancel()
            modelPreparationNotice = .loading
            onHUDVisibility?(true)
            rejectHotkeyCapture(fromHotkey)
            return
        }
        // A new microphone capture can overlap our FIFO processor, but never
        // meetings, installation, selection rewriting or a spoken instruction.
        guard !meetingBusy, !textProcessingBusy, phase != .preparing, capture == nil,
              !instructionProcessing, textInstruction == nil || pipeline.count == 0 else {
            rejectHotkeyCapture(fromHotkey); return
        }
        guard engineReady else {
            statusMessage = "Chargez d’abord un modèle dans l’onglet Modèles."
            rejectHotkeyCapture(fromHotkey); return
        }
        guard microphoneGranted else {
            statusMessage = "Autorisez le microphone avant de dicter."
            rejectHotkeyCapture(fromHotkey); return
        }
        if fromHotkey && !heldFn { return }
        let instruction = textInstruction
        if instruction == nil, !pipeline.beginCapture() {
            statusMessage = "Quatre dictées sont déjà en cours. Attendez un instant."
            rejectHotkeyCapture(fromHotkey); return
        }
        hudDismissal?.cancel()
        modelPreparationNotice = nil
        let snippetPhrases = snippets.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.phrase).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let combinedVocabulary = ([vocabulary] + snippetPhrases).joined(separator: "\n")
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let inserter = TextInserter()
        if instruction == nil { inserter.captureTarget(target) }
        let context = CaptureContext(model: loadedModel ?? selectedModel, language: language,
                                     vocabulary: combinedVocabulary.unicodeScalars.count <= 4_000 ? combinedVocabulary : vocabulary,
                                     snippets: snippets, cleanup: cleanupEnabled, target: target,
                                     inserter: inserter, instruction: instruction)
        do {
            try recorder.start()
            capture = context
            livePreview = LivePreviewText()
            if instruction == nil && presentationMode == .pill { preview.start(language: context.language) }
            isHandsFree = false
            transcriptInserted = false
            instruction?.onUpdate(.recording, nil)
            updateDictationPresentation()
            recordingLimit = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled, self.capture?.id == context.id else { return }
                finishRecording()
            }
        } catch {
            if instruction == nil { pipeline.cancelCapture() }
            rejectHotkeyCapture(fromHotkey)
            completeTextInstruction(error: error.localizedDescription)
            updateDictationPresentation()
            if !isDictationProcessing { phase = .error }
            statusMessage = error.localizedDescription
        }
    }

    private func rejectHotkeyCapture(_ fromHotkey: Bool) {
        if fromHotkey { heldFn = false; isHandsFree = false; hotkey.resetRecordingState() }
    }

    private func finishRecording() {
        guard let context = capture else { return }
        capture = nil
        preview.stop()
        heldFn = false; isHandsFree = false; hotkey.resetRecordingState()
        recordingLimit?.cancel(); recordingLimit = nil
        let duration = Date().timeIntervalSince(context.started)
        do {
            let url = try recorder.stop()
            level = 0
            guard duration >= 0.25 else {
                livePreview = LivePreviewText()
                try? FileManager.default.removeItem(at: url)
                if context.instruction == nil { pipeline.cancelCapture() }
                completeTextInstruction(error: "Parlez un peu plus longtemps pour donner votre consigne.")
                updateDictationPresentation(hideWhenIdle: true)
                if !isDictationProcessing { statusMessage = "Maintenez Fn un peu plus longtemps." }
                return
            }
            if context.instruction != nil {
                processInstruction(context: context, audioURL: url)
            } else {
                pipeline.finishCapture(DictationJob(capture: context, audioURL: url, duration: duration))
                drainDictations()
            }
            updateDictationPresentation()
        } catch {
            if context.instruction == nil { pipeline.cancelCapture() }
            completeTextInstruction(error: error.localizedDescription)
            updateDictationPresentation(hideWhenIdle: true)
            if !isDictationProcessing { phase = .error; statusMessage = error.localizedDescription }
        }
    }

    private func drainDictations() {
        guard processingTask == nil else { return }
        let token = pipelineGeneration
        processingTask = Task {
            while !Task.isCancelled, token == pipelineGeneration, let job = pipeline.startNext() {
                updateDictationPresentation()
                await processDictation(job, token: token)
                guard !Task.isCancelled, token == pipelineGeneration else { break }
                pipeline.completeActive()
                updateDictationPresentation()
            }
            guard token == pipelineGeneration else { return }
            processingTask = nil
            updateDictationPresentation()
            if capture == nil { dismissHUDLater() }
        }
    }

    private func processDictation(_ job: DictationJob, token: UUID) async {
        defer { try? FileManager.default.removeItem(at: job.audioURL) }
        let context = job.capture
        lastDictationOutcome = .none
        do {
            let start = Date()
            // A crashed worker may need reloading; only the FIFO processor loads.
            if loadedModel != context.model {
                processingMessage = "Préparation du modèle pour la dictée en attente…"
                updateDictationPresentation()
                _ = try await engine.request("load", params: ["model": context.model.rawValue], timeout: 1800)
                guard token == pipelineGeneration, !Task.isCancelled else { return }
                markModelLoaded(context.model)
            }
            processingMessage = "Transcription…"
            updateDictationPresentation()
            var params: [String: Any] = ["audio_path": job.audioURL.path, "model": context.model.rawValue, "context": context.vocabulary]
            if context.language != "Auto" { params["language"] = context.language }
            let result = try await engine.request("transcribe", params: params)
            guard token == pipelineGeneration, !Task.isCancelled else { return }
            let rawText = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else {
                lastDictationOutcome = .empty
                transcriptInserted = false
                processingMessage = "Aucune parole détectée."
                return
            }
            let snippet = DictationTextPlan.snippet(for: rawText, in: context.snippets)
            var text = snippet ?? rawText
            var transcript = Transcript(text: text, model: context.model,
                                        duration: result.audio_duration_seconds ?? job.duration,
                                        latency: Date().timeIntervalSince(start), rawText: rawText)
            history.insert(transcript, at: 0)
            history = Array(history.prefix(keepHistory ? 100 : 4))
            if keepHistory { saveHistory() }
            var cleanupFailed = false
            if context.cleanup && snippet == nil {
                processingMessage = "Correction du texte…"
                updateDictationPresentation()
                do {
                    text = try await LocalTextProcessor.clean(rawText)
                    guard token == pipelineGeneration, !Task.isCancelled else { return }
                    transcript.text = text
                    transcript.rawText = text == rawText ? nil : rawText
                    transcript.latency = Date().timeIntervalSince(start)
                    if let index = history.firstIndex(where: { $0.id == transcript.id }) { history[index] = transcript }
                    if keepHistory { saveHistory() }
                } catch {
                    guard token == pipelineGeneration, !Task.isCancelled else { return }
                    cleanupFailed = true; text = rawText
                }
            }
            let insertion = await context.inserter.insertWithReceipt(text, into: context.target)
            guard token == pipelineGeneration, !Task.isCancelled else { return }
            if let receipt = insertion.receipt {
                // Captures begun before our own paste still refer to its old caret.
                // Rebase only those exact targets, never a user-moved selection.
                capture?.inserter.advanceAfterOwnInsertion(receipt)
                for pending in pipeline.pending { pending.capture.inserter.advanceAfterOwnInsertion(receipt) }
            }
            transcriptInserted = insertion.inserted
            lastDictationOutcome = insertion.inserted ? .inserted : .available
            processingMessage = insertion.message
                ?? (insertion.inserted ? "Collage envoyé." : "Texte disponible avec Copier.")
            if cleanupFailed { processingMessage += " Correction indisponible ; texte brut conservé." }
        } catch {
            guard token == pipelineGeneration, !Task.isCancelled else { return }
            lastDictationOutcome = .failed
            transcriptInserted = false
            processingMessage = error.localizedDescription
        }
    }

    private func processInstruction(context: CaptureContext, audioURL: URL) {
        guard let instruction = context.instruction else { return }
        generation = UUID()
        let token = generation
        lastDictationOutcome = .none
        instructionProcessing = true
        instruction.onUpdate(.transcribing, nil)
        operation = Task {
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                var params: [String: Any] = ["audio_path": audioURL.path, "model": context.model.rawValue, "context": context.vocabulary]
                if context.language != "Auto" { params["language"] = context.language }
                let result = try await engine.request("transcribe", params: params)
                guard token == generation, !Task.isCancelled else { return }
                let text = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { instruction.onText(text) }
                completeTextInstruction(error: text.isEmpty ? "Aucune consigne détectée. Réessayez ou écrivez-la." : nil)
                instructionProcessing = false
                updateDictationPresentation(hideWhenIdle: true)
                statusMessage = "Consigne prête. Vérifiez-la puis lancez la réécriture."
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                completeTextInstruction(error: error.localizedDescription)
                instructionProcessing = false
                updateDictationPresentation(hideWhenIdle: true)
                phase = .error; statusMessage = error.localizedDescription
            }
        }
    }

    private func updateDictationPresentation(hideWhenIdle: Bool = false) {
        pendingDictationCount = pipeline.count
        isDictationProcessing = pipeline.count > 0
        if capture != nil {
            phase = .recording
            statusMessage = isHandsFree ? "Mains libres. Fn termine, Échap annule." : "Enregistrement…"
            if pipeline.count > 0 { statusMessage += " \(pipeline.count) dictée\(pipeline.count > 1 ? "s" : "") en traitement." }
        } else if pipeline.count > 0 {
            phase = .transcribing; statusMessage = processingMessage
        } else if instructionProcessing {
            phase = .transcribing; statusMessage = "Transcription de la consigne…"
        } else {
            switch lastDictationOutcome {
            case .failed: phase = .error
            case .empty: phase = .idle
            default: phase = loadedModel == nil ? .idle : .ready
            }
            statusMessage = processingMessage
        }
        if capture != nil || pipeline.count > 0 || instructionProcessing {
            hudDismissal?.cancel(); onHUDVisibility?(true)
        } else if hideWhenIdle {
            hudDismissal?.cancel(); onHUDVisibility?(false)
        }
    }

    private func finishModelPreparationNotice(succeeded: Bool) {
        guard modelPreparationNotice == .loading else { return }
        modelPreparationNotice = succeeded ? .ready : .failed
        dismissHUDLater(delay: succeeded ? 3_000_000_000 : 5_000_000_000)
    }

    private func dismissHUDLater(delay: UInt64 = 1_400_000_000) {
        hudDismissal?.cancel()
        hudDismissal = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, capture == nil, pipeline.count == 0, !instructionProcessing else { return }
            onHUDVisibility?(false)
            // Let the pill fade before clearing its title. Also clears the
            // menu-bar notice when no pill panel was ever created.
            if modelPreparationNotice != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                modelPreparationNotice = nil
            }
        }
    }

    func cancel() {
        guard capture != nil || instructionProcessing || pipeline.count > 0 else { return }
        heldFn = false; isHandsFree = false; hotkey.resetRecordingState()
        if let context = capture {
            capture = nil
            recordingLimit?.cancel(); recordingLimit = nil
            recorder.cancel(); level = 0
            preview.stop(); livePreview = LivePreviewText()
            if context.instruction == nil { pipeline.cancelCapture() }
            else { completeTextInstruction(error: nil) }
            updateDictationPresentation(hideWhenIdle: true)
            if !isDictationProcessing { statusMessage = "Dictée annulée." }
        } else if instructionProcessing {
            generation = UUID(); operation?.cancel(); engine.stop(); loadedModel = nil
            instructionProcessing = false
            completeTextInstruction(error: nil)
            updateDictationPresentation(hideWhenIdle: true)
            statusMessage = "Consigne annulée."
        } else {
            cancelPendingDictations()
        }
    }

    func cancelPendingDictations() {
        guard pipeline.count > 0 else { return }
        for job in pipeline.removePending() { try? FileManager.default.removeItem(at: job.audioURL) }
        updateDictationPresentation(hideWhenIdle: true)
        statusMessage = pipeline.active == nil ? "Dictées en attente annulées." : "La dictée en cours continue ; les suivantes sont annulées."
    }
    func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Texte copié."
    }
    func clearHistory() {
        history = []; try? FileManager.default.removeItem(at: historyURL)
    }
    func showTextProcessing() {
        guard !isBusy else { return }
        textProcessingController.show()
    }
    private func startTextInstruction(_ handlers: TextInstructionHandlers) -> Bool {
        guard !isBusy else {
            handlers.onUpdate(.idle, "Terminez l’opération en cours avant de dicter une consigne.")
            return false
        }
        textInstruction = handlers
        startRecording(fromHotkey: false)
        guard isRecording else {
            completeTextInstruction(error: statusMessage)
            return false
        }
        return true
    }
    private func completeTextInstruction(error: String?) {
        let handlers = textInstruction
        textInstruction = nil
        handlers?.onLevel(0)
        handlers?.onUpdate(.idle, error)
    }
    /// The pill has faded out: its words go with it.
    func clearLivePreview() {
        guard capture == nil else { return }
        livePreview = LivePreviewText()
    }
    func addSnippet() { snippets.append(VoiceSnippet()) }
    func removeSnippet(_ id: UUID) { snippets.removeAll { $0.id == id } }
    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch { statusMessage = "Texte prêt ; l’historique n’a pas pu être enregistré." }
    }
    func shutdown() {
        textProcessingController.close(); hotkey.stop(); recorder.cancel(); preview.stop(); capture = nil
        pipelineGeneration = UUID(); processingTask?.cancel()
        for job in pipeline.removePending() { try? FileManager.default.removeItem(at: job.audioURL) }
        engine.stop(); permissionTimer?.invalidate(); recordingLimit?.cancel(); hudDismissal?.cancel(); operation?.cancel()
    }
}
