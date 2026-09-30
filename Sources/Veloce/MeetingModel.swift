import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloceCore

enum MeetingPhase { case idle, starting, recording, stopping, processing, preparing, summarizing }

@MainActor
final class MeetingModel: ObservableObject {
    @Published private(set) var records: [MeetingRecord]
    @Published var selectedID: UUID?
    @Published private(set) var phase: MeetingPhase = .idle {
        didSet { onBusyChange?(isBusy) }
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
    @Published private(set) var error: String?
    var canBegin: (() -> Bool)?
    var onBusyChange: ((Bool) -> Void)?
    var onModelLoaded: ((SpeechModel) -> Void)?

    var isBusy: Bool { phase != .idle }
    var selected: MeetingRecord? { records.first { $0.id == selectedID } }
    var notesUnavailableReason: String? { MeetingNotesGenerator.unavailableReason }
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

    init(engine: EngineClient, store: MeetingStore = MeetingStore(), previewRecords: [MeetingRecord]? = nil) {
        self.engine = engine; self.store = store
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
            guard let self, self.isBusy else { return }
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
        error = nil; elapsed = 0; progress = 0
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
                phase = .idle; activeID = nil
            }
        }
    }

    private func tick() {
        guard phase == .recording else { return }
        elapsed = Date().timeIntervalSince(recordingDate ?? Date())
        if let activeID, Int(elapsed) % 5 == 0 { update(activeID) { $0.duration = elapsed } }
        if elapsed >= 4 * 3600 { stopRecording(transcribe: transcribeAfterRecording) }
    }

    func stopRecording(transcribe: Bool) {
        guard phase == .recording, let id = activeID else { return }
        timer?.invalidate(); timer = nil
        phase = .stopping; status = "Sauvegarde des pistes…"
        operation = Task {
            do {
                let capture = try await recorder.stop()
                update(id) { $0.duration = capture.duration; $0.status = .recorded }
                elapsed = capture.duration; phase = .idle; activeID = nil
                status = "Les deux pistes sont sauvegardées."
                if transcribe, !shuttingDown, let settings = transcriptionSettings {
                    transcribeMeeting(id, model: settings.0, language: settings.1, vocabulary: settings.2)
                }
            } catch {
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
        guard !isBusy, canBegin?() != false, records.contains(where: { $0.id == id }) else { return }
        error = nil; progress = 0; phase = .processing; selectedID = id
        status = "Chargement du modèle de transcription…"
        let token = UUID(); generation = token
        let useDiarization = diarize && diarizationReady
        operation = Task {
            do {
                if !engine.installed || model == .fast {
                    try await engine.install(includeParakeet: model == .fast, includeMeetings: diarizationReady)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                _ = try await engine.request("load", params: ["model": model.rawValue], timeout: 1800)
                guard generation == token, !Task.isCancelled else { return }
                onModelLoaded?(model)
                let folder = store.directory(for: id)
                var params: [String: Any] = ["microphone_path": folder.appendingPathComponent("microphone.wav").path,
                    "system_path": folder.appendingPathComponent("system.wav").path,
                    "model": model.rawValue, "context": vocabulary, "diarize": useDiarization]
                if language != "Auto" { params["language"] = language }
                let result = try await engine.request("transcribe_meeting", params: params, timeout: 24 * 3600)
                guard generation == token, !Task.isCancelled else { return }
                guard let segments = result.segments else { throw VeloceError.message("Le moteur n’a pas renvoyé les passages de la réunion.") }
                update(id) {
                    $0.segments = segments; $0.model = model; $0.status = .transcribed
                    $0.duration = result.duration ?? $0.duration
                    $0.diarization = result.diarization ?? "sources"
                }
                progress = 1; phase = .idle
                status = segments.isEmpty ? "Aucune parole détectée. Les pistes restent disponibles." : "La transcription est prête."
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
                update(record.id) { $0.notes = notes }
                phase = .idle; progress = 1; status = "Le compte rendu est prêt à relire."
            } catch { finishError(error, token: token) }
        }
    }

    func cancelProcessing() {
        guard phase == .processing || phase == .preparing || phase == .summarizing else { return }
        let token = UUID(); generation = token
        let pending = operation; pending?.cancel()
        if phase != .summarizing { engine.stop() }
        phase = .stopping; status = "Arrêt du traitement…"
        operation = Task {
            await pending?.value
            guard generation == token else { return }
            phase = .idle; status = "Traitement arrêté. L’enregistrement reste disponible."
        }
    }

    func cancelStarting() {
        guard phase == .starting, let id = activeID else { return }
        generation = UUID(); operation?.cancel(); phase = .stopping
        operation = Task {
            await recorder.cancel()
            update(id) { $0.status = .interrupted }
            activeID = nil; phase = .idle; status = "Démarrage annulé."
        }
    }

    func setNotes(_ notes: String) { if let selectedID { update(selectedID) { $0.notes = notes } } }
    func renameSpeaker(_ speaker: String, to name: String) {
        if let selectedID { update(selectedID) { $0.speakerNames[speaker] = name } }
    }
    func renameMeeting(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedID, !title.isEmpty { update(selectedID) { $0.title = title } }
    }
    func revealFiles() { if let selectedID { NSWorkspace.shared.open(store.directory(for: selectedID)) } }
    func playTrack(_ name: String) {
        guard let selectedID, ["microphone.wav", "system.wav"].contains(name) else { return }
        NSWorkspace.shared.open(store.directory(for: selectedID).appendingPathComponent(name))
    }
    func copyTranscript() {
        guard let selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.transcript, forType: .string)
    }
    func deleteSelected() {
        guard !isBusy, let id = selectedID else { return }
        do { try store.remove(id); records.removeAll { $0.id == id }; selectedID = records.first?.id }
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
            case "srt": data = Data(record.srt.utf8)
            case "json": let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(record)
            default: return
            }
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    func exportStereo() {
        guard !isBusy, canBegin?() != false, let record = selected else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Reunion-stereo.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !isBusy, canBegin?() != false else { return }
        error = nil; phase = .processing; status = "Export stéréo : micro à gauche, réunion à droite…"
        let token = UUID(); generation = token
        let folder = store.directory(for: record.id)
        operation = Task {
            do {
                _ = try await engine.request("export_meeting_audio", params: [
                    "microphone_path": folder.appendingPathComponent("microphone.wav").path,
                    "system_path": folder.appendingPathComponent("system.wav").path, "output_path": url.path
                ], timeout: 600)
                guard generation == token, !Task.isCancelled else { return }
                phase = .idle; status = "Les pistes stéréo sont exportées."
            } catch { finishError(error, token: token) }
        }
    }

    func finishForTermination() async {
        shuttingDown = true
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
        generation = UUID(); pending?.cancel(); engine.stop()
        if currentPhase != .starting && currentPhase != .summarizing { await pending?.value }
        await recorder.cancel()
        phase = .idle
    }

    private func update(_ id: UUID, change: (inout MeetingRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        do { try store.save(records[index]) }
        catch { self.error = "L’audio est conservé, mais les informations de réunion n’ont pas pu être enregistrées : \(error.localizedDescription)" }
    }
    private func finishError(_ error: Error, token: UUID) {
        guard generation == token, !Task.isCancelled else { return }
        self.error = error.localizedDescription; phase = .idle
        status = "Traitement interrompu. Les pistes sont conservées."
    }
}
