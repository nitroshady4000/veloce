import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloceCore

enum MeetingPhase { case idle, starting, recording, stopping, importing, processing, preparing, summarizing, asking }

@MainActor
final class MeetingModel: ObservableObject {
    @Published private(set) var records: [MeetingRecord]
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { player.stop(); questionAnswer = "" } } }
    @Published private(set) var phase: MeetingPhase = .idle {
        didSet {
            onBusyChange?(isBusy)
            if phase == .idle { Task { [weak self] in self?.startNextQueuedImport() } }
        }
    }
    @Published private(set) var status = "Deux pistes, une conversation."
    @Published private(set) var progress = 0.0
    @Published private(set) var elapsed = 0.0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var systemLevel = 0.0
    @Published private(set) var diarizationReady = false
    @Published var diarize = true
    @Published var draftTitle = ""
    @Published var transcribeAfterRecording = true
    @Published var transcribeAfterImport = true
    @Published var liveTranscription = UserDefaults.standard.bool(forKey: "meetingLiveTranscription") {
        didSet { UserDefaults.standard.set(liveTranscription, forKey: "meetingLiveTranscription") }
    }
    @Published private(set) var liveStatus = ""
    @Published var searchQuery = ""
    @Published private(set) var queuedImportCount = 0
    @Published private(set) var importFailures: [String] = []
    @Published private(set) var questionAnswer = ""
    @Published private(set) var error: String? {
        didSet { showsCaptureSettings = false }
    }
    @Published private(set) var showsCaptureSettings = false
    var canBegin: (() -> Bool)?
    var onBusyChange: ((Bool) -> Void)?
    var onModelLoaded: ((SpeechModel) -> Void)?
    var onSidecarReady: ((MeetingRecord, URL, String) throws -> Void)?
    var onShowMeetings: (() -> Void)?
    var navigationRequested = false

    let player = MeetingPlayer()
    lazy var calendar: MeetingCalendarService = {
        let service = MeetingCalendarService(restorePreferences: !isPreview)
        service.onReminder = { [weak self] title in
            self?.draftTitle = title; self?.onShowMeetings?()
        }
        return service
    }()

    var isBusy: Bool { phase != .idle }
    var selected: MeetingRecord? { records.first { $0.id == selectedID } }
    var filteredRecords: [MeetingRecord] { records.filter { $0.matches(searchQuery) } }
    var notesUnavailableReason: String? { MeetingNotesGenerator.unavailableReason }
    var questionsUnavailableReason: String? { MeetingQuestionService.unavailableReason }
    private let engine: EngineClient
    private let recorder = MeetingRecorder()
    private let store: MeetingStore
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var recordingDate: Date?
    private var activeID: UUID?
    private var generation = UUID()
    private var shuttingDown = false
    private var transcriptionSettings: (SpeechModel, String, String)?
    private var liveTask: Task<Void, Never>?
    private var liveCursor = 0.0
    private var liveFailed = false
    private var importQueue: [ImportJob] = []
    private var queueTimer: Timer?
    private var activeImport = false
    private let isPreview: Bool

    private struct ImportJob {
        let url: URL
        let model: SpeechModel
        let language: String
        let vocabulary: String
        let transcribe: Bool
        let sidecarFormat: String?
    }

    init(engine: EngineClient, store: MeetingStore = MeetingStore(), previewRecords: [MeetingRecord]? = nil) {
        self.engine = engine; self.store = store; isPreview = previewRecords != nil
        records = previewRecords ?? store.load(); selectedID = records.first?.id
        recorder.onLevels = { [weak self] mic, system in
            self?.microphoneLevel = mic; self?.systemLevel = system
        }
        recorder.onFailure = { [weak self] reason in
            guard let self, self.phase == .recording else { return }
            self.error = reason
            self.stopRecording(transcribe: false)
        }
        engine.onMeetingProgress = { [weak self] value, detail in
            guard let self, self.phase == .processing else { return }
            self.progress = value; self.status = detail
        }
    }

    func refreshAvailability() {
        guard !isBusy, canBegin?() != false, engine.installed else { return }
        Task {
            guard !isBusy, canBegin?() != false else { return }
            if let result = try? await engine.request("status") {
                diarizationReady = result.diarization_ready == true
            }
        }
    }

    func startRecording(model: SpeechModel, language: String, vocabulary: String) {
        guard !isBusy, canBegin?() != false else { return }
        if #unavailable(macOS 15.0) {
            error = "La capture de réunion nécessite macOS 15 ou plus récent."; return
        }
        error = nil; elapsed = 0; progress = 0; player.stop()
        liveCursor = 0; liveFailed = false; liveStatus = ""
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = MeetingRecord(title: title.isEmpty ? "Réunion du \(Date().formatted(date: .abbreviated, time: .shortened))" : title)
        do { try store.save(record) }
        catch { self.error = error.localizedDescription; return }
        records.insert(record, at: 0); selectedID = record.id; activeID = record.id
        transcriptionSettings = (model, language, vocabulary)
        let token = UUID(); generation = token
        phase = .starting; status = "Autorisation et préparation des deux pistes…"
        operation = Task { [self] in
            do {
                if liveTranscription {
                    status = "Préparation du modèle léger pour le direct…"
                    if !engine.installed { try await engine.install(includeParakeet: false) }
                    _ = try await engine.request("load", params: ["model": SpeechModel.balanced.rawValue], timeout: 1800)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    onModelLoaded?(.balanced)
                }
                try await recorder.start(directory: store.directory(for: record.id))
                // The cancellation owner already stopped this generation. Do not
                // let a delayed permission response cancel a later recording.
                guard generation == token, !Task.isCancelled else { return }
                recordingDate = Date(); phase = .recording; status = "La réunion s’enregistre sur ce Mac."
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                guard generation == token else { return }
                update(record.id) { $0.status = .interrupted }
                self.error = error.localizedDescription; status = "L’enregistrement n’a pas démarré."
                if let captureError = error as? MeetingRecorder.CaptureError {
                    if case .systemPermission = captureError { showsCaptureSettings = true }
                    if case .noDisplay = captureError { showsCaptureSettings = true }
                }
                phase = .idle; activeID = nil
            }
        }
    }

    func chooseAudioFile(model: SpeechModel, language: String, vocabulary: String) {
        guard !isBusy, canBegin?() != false else { return }
        let panel = NSOpenPanel()
        panel.title = "Importer des audios ou vidéos"
        panel.prompt = "Importer"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        // Fn may have started while the panel was open.
        guard !isBusy, canBegin?() != false else { return }
        enqueueImports(panel.urls, model: model, language: language, vocabulary: vocabulary)
    }

    func enqueueImports(_ urls: [URL], model: SpeechModel, language: String, vocabulary: String, sidecarFormat: String? = nil) {
        guard !shuttingDown else { return }
        if queuedImportCount == 0 { importFailures = [] }
        var seen = Set<URL>()
        for url in urls where url.isFileURL && seen.insert(url.standardizedFileURL).inserted {
            importQueue.append(ImportJob(url: url, model: model, language: language, vocabulary: vocabulary,
                transcribe: sidecarFormat != nil || transcribeAfterImport, sidecarFormat: sidecarFormat))
        }
        updateQueueCount()
        if !importQueue.isEmpty, queueTimer == nil {
            queueTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startNextQueuedImport() }
            }
        }
        startNextQueuedImport()
    }

    func cancelQueuedImports() { importQueue = []; updateQueueCount() }

    private func updateQueueCount() {
        queuedImportCount = importQueue.count + (activeImport ? 1 : 0)
        if queuedImportCount == 0 { queueTimer?.invalidate(); queueTimer = nil }
    }

    private func startNextQueuedImport() {
        guard !isBusy, canBegin?() != false, !shuttingDown, !importQueue.isEmpty else { return }
        let job = importQueue.removeFirst()
        activeImport = true; updateQueueCount()
        importAudioFile(job)
    }

    private func importAudioFile(_ job: ImportJob) {
        let url = job.url
        error = nil; progress = 0; phase = .importing
        player.stop()
        status = "Import de \(url.lastPathComponent)…"
        var record = MeetingRecord(title: url.deletingPathExtension().lastPathComponent)
        record.originalFilename = url.lastPathComponent
        let folder = store.directory(for: record.id)
        let token = UUID(); generation = token
        operation = Task { [self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var createdFolder = false
            do {
                try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                createdFolder = true
                record.duration = try await MeetingAudioImporter.importFile(from: url,
                    to: folder.appendingPathComponent("imported.wav")) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.phase == .importing else { return }
                        self.progress = value
                    }
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                record.status = .recorded
                try store.save(record)
                records.insert(record, at: 0); selectedID = record.id
                if job.transcribe, !shuttingDown {
                    phase = .processing
                    try await transcribeRecord(record, model: job.model, language: job.language, vocabulary: job.vocabulary, token: token)
                    if let format = job.sidecarFormat,
                       let completed = records.first(where: { $0.id == record.id }) {
                        guard let writer = onSidecarReady else { throw VeloceError.message("La transcription est conservée dans l’historique, mais l’export à côté du fichier est indisponible.") }
                        try writer(completed, url, format)
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                progress = 1; status = job.sidecarFormat != nil ? "La transcription et son fichier sont prêts." : job.transcribe ? "La transcription est prête." : "Le fichier audio est prêt."
            } catch {
                // Only this operation's new directory is disposable. The source
                // and all existing meetings are untouched, including on cancel.
                if createdFolder, !records.contains(where: { $0.id == record.id }) { try? FileManager.default.removeItem(at: folder) }
                guard generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                importFailures.append("\(url.lastPathComponent) : \(error.localizedDescription)")
                status = records.contains(where: { $0.id == record.id }) ? "La réunion est conservée ; le traitement n’a pas abouti." : "Le fichier n’a pas pu être importé."
            }
            if generation == token {
                activeImport = false; updateQueueCount(); phase = .idle
            }
        }
    }

    private func tick() {
        guard phase == .recording else { return }
        elapsed = Date().timeIntervalSince(recordingDate ?? Date())
        if let activeID, Int(elapsed) % 5 == 0 { update(activeID) { $0.duration = elapsed } }
        if liveTranscription, !liveFailed, liveTask == nil, elapsed - liveCursor >= 15, let activeID {
            transcribeLive(id: activeID, through: min(elapsed, liveCursor + 30))
        }
        if elapsed >= 4 * 3600 { stopRecording(transcribe: transcribeAfterRecording) }
    }

    func stopRecording(transcribe: Bool) {
        guard phase == .recording, let id = activeID else { return }
        timer?.invalidate(); timer = nil
        phase = .stopping; status = "Sauvegarde des pistes…"
        operation = Task {
            do {
                let capture = try await recorder.stop()
                await liveTask?.value; liveTask = nil
                update(id) { $0.duration = capture.duration; $0.status = .recorded }
                elapsed = capture.duration; phase = .idle; activeID = nil
                status = "Les deux pistes sont sauvegardées."
                if transcribe, !shuttingDown, let settings = transcriptionSettings {
                    transcribeMeeting(id, model: settings.0, language: settings.1, vocabulary: settings.2)
                }
            } catch {
                liveTask?.cancel(); engine.stop(); await liveTask?.value; liveTask = nil
                update(id) { $0.status = .interrupted }
                self.error = error.localizedDescription; phase = .idle; activeID = nil
                status = "Enregistrement interrompu. Les fichiers disponibles sont conservés."
            }
        }
    }

    func prepareDiarization(model: SpeechModel) {
        guard !isBusy, canBegin?() != false else { return }
        error = nil; phase = .preparing; progress = 0
        status = "Installation de la détection locale des interlocuteurs…"
        let token = UUID(); generation = token
        operation = Task {
            do {
                engine.stop()
                try await engine.install(includeParakeet: model == .fast, includeMeetings: true)
                try Task.checkCancellation()
                guard generation == token else { return }
                let result = try await engine.request("prepare_diarization", timeout: 1800)
                guard generation == token, !Task.isCancelled else { return }
                diarizationReady = result.diarization_ready == true; diarize = diarizationReady
                phase = .idle; status = "La détection des interlocuteurs est prête."
            } catch { finishError(error, token: token) }
        }
    }

    func transcribeMeeting(_ id: UUID, model: SpeechModel, language: String, vocabulary: String) {
        guard !isBusy, canBegin?() != false, let record = records.first(where: { $0.id == id }) else { return }
        error = nil; progress = 0; phase = .processing; selectedID = id
        status = "Chargement du modèle de transcription…"
        let token = UUID(); generation = token
        player.stop()
        operation = Task {
            do {
                try await transcribeRecord(record, model: model, language: language, vocabulary: vocabulary, token: token)
                guard generation == token, !Task.isCancelled else { return }
                progress = 1; phase = .idle
                status = selected?.segments.isEmpty == true ? "Aucune parole détectée. Les pistes restent disponibles." : "La transcription est prête."
            } catch { finishError(error, token: token) }
        }
    }

    private func transcribeRecord(_ record: MeetingRecord, model: SpeechModel, language: String,
                                   vocabulary: String, token: UUID) async throws {
        if !engine.installed || model == .fast {
            try await engine.install(includeParakeet: model == .fast, includeMeetings: diarizationReady)
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        _ = try await engine.request("load", params: ["model": model.rawValue], timeout: 1800)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        onModelLoaded?(model)
        let folder = store.directory(for: record.id)
        var params: [String: Any] = ["model": model.rawValue, "context": vocabulary, "diarize": diarize && diarizationReady]
        if record.isImported {
            params["audio_path"] = folder.appendingPathComponent("imported.wav").path
        } else {
            params["microphone_path"] = folder.appendingPathComponent("microphone.wav").path
            params["system_path"] = folder.appendingPathComponent("system.wav").path
        }
        if language != "Auto" { params["language"] = language }
        let result = try await engine.request("transcribe_meeting", params: params, timeout: 24 * 3600)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard let segments = result.segments else { throw VeloceError.message("Le moteur n’a pas renvoyé les passages de la réunion.") }
        try commit(record.id) {
            $0.segments = segments; $0.model = model; $0.status = .transcribed
            $0.duration = result.duration ?? $0.duration
            $0.diarization = result.diarization ?? "sources"
        }
    }

    private func transcribeLive(id: UUID, through end: Double) {
        guard let settings = transcriptionSettings else { return }
        let start = liveCursor
        let token = generation
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veloce-live-\(UUID().uuidString)", isDirectory: true)
        liveStatus = "Transcription du direct…"
        liveTask = Task { [self] in
            defer {
                try? FileManager.default.removeItem(at: folder)
                liveTask = nil
            }
            do {
                let snapshot = try await recorder.snapshot(directory: folder, from: start, through: end)
                var params: [String: Any] = ["model": SpeechModel.balanced.rawValue, "context": settings.2, "diarize": false,
                    "microphone_path": snapshot.microphoneURL.path, "system_path": snapshot.systemURL.path]
                if settings.1 != "Auto" { params["language"] = settings.1 }
                let result = try await engine.request("transcribe_meeting", params: params, timeout: 600)
                try Task.checkCancellation()
                guard generation == token else { return }
                let segments = (result.segments ?? []).map { segment -> MeetingSegment in
                    var segment = segment
                    segment.id = "live-\(Int(start * 1000))-\(segment.id)"
                    segment.start += start; segment.end += start
                    return segment
                }
                update(id) {
                    $0.segments.append(contentsOf: segments)
                    $0.segments.sort { $0.start < $1.start }
                    $0.model = .balanced; $0.diarization = "live-tracks"
                }
                liveCursor = end
                liveStatus = "Direct à jour jusqu’à \(MeetingRecord.timestamp(end)) · version provisoire"
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                liveFailed = true
                liveStatus = "Le direct est interrompu. L’audio continue de s’enregistrer ; il pourra être transcrit après l’arrêt."
            }
        }
    }

    func askQuestion(_ question: String, allMeetings: Bool) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = allMeetings ? records.filter { !$0.segments.isEmpty } : selected.map { [$0] } ?? []
        guard !question.isEmpty, !scope.isEmpty, !isBusy, canBegin?() != false else { return }
        error = nil; questionAnswer = ""; phase = .asking; progress = 0
        status = "Recherche dans vos réunions sur ce Mac…"
        let token = UUID(); generation = token
        operation = Task { [self] in
            do {
                let answer = try await MeetingQuestionService.answer(question: question, records: scope) { [weak self] value in
                    guard let self, self.generation == token else { return }
                    self.progress = value
                }
                guard generation == token, !Task.isCancelled else { return }
                questionAnswer = answer; progress = 1; phase = .idle
                status = "La réponse est prête."
            } catch { finishError(error, token: token) }
        }
    }

    func generateNotes() {
        guard let record = selected, !record.segments.isEmpty, !isBusy, canBegin?() != false else { return }
        error = nil; progress = 0; phase = .summarizing; status = "Rédaction locale du compte rendu…"
        let token = UUID(); generation = token
        operation = Task { [self] in
            do {
                let notes = try await MeetingNotesGenerator.generate(transcript: record.transcript) { [weak self] in self?.progress = $0 }
                guard generation == token, !Task.isCancelled else { return }
                try commit(record.id) { $0.notes = notes }
                phase = .idle; progress = 1; status = "Le compte rendu est prêt à relire."
            } catch { finishError(error, token: token) }
        }
    }

    func cancelProcessing() {
        guard [.processing, .preparing, .summarizing, .importing, .asking].contains(phase) else { return }
        let wasImporting = phase == .importing
        let token = UUID(); generation = token
        let pending = operation; pending?.cancel()
        importQueue = []
        if ![.summarizing, .asking].contains(phase) && !wasImporting { engine.stop() }
        phase = .stopping; status = "Arrêt du traitement…"
        operation = Task {
            await pending?.value
            guard generation == token else { return }
            activeImport = false; updateQueueCount()
            phase = .idle
            status = wasImporting ? "Import annulé. Le fichier d’origine est intact." : "Traitement arrêté. L’enregistrement reste disponible."
        }
    }

    func cancelStarting() {
        guard phase == .starting, let id = activeID else { return }
        generation = UUID(); operation?.cancel(); engine.stop(); phase = .stopping
        operation = Task {
            await recorder.cancel()
            update(id) { $0.status = .interrupted }
            activeID = nil; phase = .idle; status = "Démarrage annulé."
        }
    }

    func setNotes(_ notes: String) { if let selectedID { update(selectedID) { $0.notes = notes } } }
    func renameSpeaker(_ speaker: String, to name: String) {
        if !isBusy, let selectedID { update(selectedID) { $0.speakerNames[speaker] = name } }
    }
    func editSegment(_ id: String, text: String, speaker: String) {
        if !isBusy, let selectedID { update(selectedID) { $0.editSegment(id, text: text, speaker: speaker) } }
    }
    func mergeSpeaker(_ source: String, into target: String) {
        if !isBusy, let selectedID { update(selectedID) { $0.mergeSpeaker(source, into: target) } }
    }
    func audioURLs(for record: MeetingRecord) -> [(String, URL)] {
        let folder = store.directory(for: record.id)
        return record.isImported ? [("imported", folder.appendingPathComponent("imported.wav"))]
            : [("microphone", folder.appendingPathComponent("microphone.wav")), ("system", folder.appendingPathComponent("system.wav"))]
    }
    func playSegment(_ segment: MeetingSegment) {
        guard !isBusy, let selected else { return }
        do { try player.load(id: selected.id, tracks: audioURLs(for: selected)); player.play(at: segment.start) }
        catch { self.error = error.localizedDescription }
    }
    func togglePlayback() {
        guard !isBusy, let selected else { return }
        do { try player.load(id: selected.id, tracks: audioURLs(for: selected)); player.toggle() }
        catch { self.error = error.localizedDescription }
    }
    func replaceNotes(_ notes: String, for id: UUID) { update(id) { $0.notes = notes } }
    func renameMeeting(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedID, !title.isEmpty { update(selectedID) { $0.title = title } }
    }
    func revealFiles() { if let selectedID { NSWorkspace.shared.open(store.directory(for: selectedID)) } }
    func playTrack(_ name: String) {
        guard let selectedID, ["microphone.wav", "system.wav", "imported.wav"].contains(name) else { return }
        NSWorkspace.shared.open(store.directory(for: selectedID).appendingPathComponent(name))
    }
    func copyTranscript() {
        guard let selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.transcript, forType: .string)
    }
    func deleteSelected() {
        guard !isBusy, let id = selectedID else { return }
        do { player.stop(); try store.remove(id); records.removeAll { $0.id == id }; selectedID = records.first?.id }
        catch { self.error = error.localizedDescription }
    }

    func export(_ format: String) {
        guard !isBusy, let record = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(record.title.replacingOccurrences(of: "/", with: "-")) .\(format)".replacingOccurrences(of: " .", with: ".")
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch format {
            case "md": data = Data(record.markdown.utf8)
            case "txt": data = Data(record.transcript.utf8)
            case "srt": data = Data(record.srt.utf8)
            case "vtt": data = Data(record.vtt.utf8)
            case "json": let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(record)
            default: return
            }
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    func exportStereo() {
        guard !isBusy, canBegin?() != false, let record = selected else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = record.isImported ? "Audio-importe.wav" : "Reunion-stereo.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !isBusy, canBegin?() != false else { return }
        error = nil; progress = 0; phase = .processing
        status = record.isImported ? "Export de l’audio importé…" : "Export stéréo : micro à gauche, réunion à droite…"
        let token = UUID(); generation = token
        let folder = store.directory(for: record.id)
        operation = Task {
            do {
                var params: [String: Any] = ["output_path": url.path]
                if record.isImported { params["audio_path"] = folder.appendingPathComponent("imported.wav").path }
                else {
                    params["microphone_path"] = folder.appendingPathComponent("microphone.wav").path
                    params["system_path"] = folder.appendingPathComponent("system.wav").path
                }
                _ = try await engine.request("export_meeting_audio", params: params, timeout: 600)
                guard generation == token, !Task.isCancelled else { return }
                phase = .idle; status = "L’audio est exporté."
            } catch { finishError(error, token: token) }
        }
    }

    func finishForTermination() async {
        shuttingDown = true
        importQueue = []; queueTimer?.invalidate(); queueTimer = nil; player.stop()
        if liveTask != nil { liveTask?.cancel(); engine.stop() }
        timer?.invalidate(); timer = nil
        let currentPhase = phase
        if currentPhase == .starting {
            generation = UUID(); operation?.cancel()
            await recorder.cancel()
            if let activeID { update(activeID) { $0.status = .interrupted } }
        } else if currentPhase == .stopping {
            await operation?.value
        }
        if phase == .recording, let id = activeID {
            if let capture = try? await recorder.stop() {
                update(id) { $0.duration = capture.duration; $0.status = .recorded }
            } else { update(id) { $0.status = .interrupted } }
        }
        let pending = operation
        generation = UUID(); pending?.cancel(); liveTask?.cancel(); engine.stop()
        await liveTask?.value; liveTask = nil
        if currentPhase != .starting && currentPhase != .summarizing && currentPhase != .asking { await pending?.value }
        await recorder.cancel()
        phase = .idle
    }

    private func update(_ id: UUID, change: (inout MeetingRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        do { try store.save(records[index]) }
        catch { self.error = "L’audio est conservé, mais les informations de réunion n’ont pas pu être enregistrées : \(error.localizedDescription)" }
    }
    private func commit(_ id: UUID, change: (inout MeetingRecord) -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw VeloceError.message("Cette réunion n’est plus disponible.") }
        var changed = records[index]
        change(&changed)
        try store.save(changed)
        records[index] = changed
    }
    private func finishError(_ error: Error, token: UUID) {
        guard generation == token, !Task.isCancelled else { return }
        self.error = error.localizedDescription; phase = .idle
        status = "Traitement interrompu. Les pistes sont conservées."
    }
}
