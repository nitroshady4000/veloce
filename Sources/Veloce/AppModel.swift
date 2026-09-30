import AppKit
import AVFoundation
import SwiftUI
import VeloceCore

enum DictationPhase { case idle, preparing, ready, recording, transcribing, error }

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var statusMessage = "Une idée ? Dites-la."
    @Published var level: Double = 0
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
    @Published var engineInstalled = false
    var isBusy: Bool { phase == .preparing || phase == .recording || phase == .transcribing }
    var isRecording: Bool { phase == .recording }
    var engineReady: Bool { loadedModel == selectedModel && phase != .preparing }
    private let engine = EngineClient()
    private let recorder = AudioRecorder()
    private let hotkey = FnKeyMonitor()
    private let inserter = TextInserter()
    private var target: NSRunningApplication?
    private var recordingStarted: Date?
    private var recordingLimit: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var heldFn = false
    private var hotkeyRunning = false
    private var permissionTimer: Timer?
    var onHUDVisibility: ((Bool) -> Void)?
    private var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veloce/history.json")
    }

    init() {
        let defaults = UserDefaults.standard
        selectedModel = SpeechModel(rawValue: defaults.string(forKey: "model") ?? "") ?? .precision
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        language = defaults.string(forKey: "language") ?? "French"
        keepHistory = defaults.bool(forKey: "keepHistory")
        if keepHistory, let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Transcript].self, from: data) { history = saved }
        engineInstalled = engine.installed
        recorder.onLevel = { [weak self] value in self?.level = value }
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
    }

    func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted && !hotkeyRunning {
            hotkeyRunning = hotkey.start(onPress: { [weak self] in
                guard let self else { return }; self.heldFn = true
                self.startRecording(fromHotkey: true)
            }, onRelease: { [weak self] in
                self?.heldFn = false
                if self?.isRecording == true { self?.finishRecording() }
            }, onCancel: { [weak self] in self?.heldFn = false; self?.cancel() })
        } else if !accessibilityGranted && hotkeyRunning { hotkey.stop(); hotkeyRunning = false }
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() }
        } else { openSettings("Privacy_Microphone") }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func prepareModel() {
        guard !isBusy else { return }
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
                loadedModel = model; phase = .ready
                statusMessage = "Prêt. Maintenez Fn pour parler."
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                phase = .error; statusMessage = error.localizedDescription
            }
        }
    }

    func toggleRecording() {
        if isRecording { finishRecording() } else { startRecording(fromHotkey: false) }
    }
    private func startRecording(fromHotkey: Bool) {
        guard !isBusy else { return }
        guard engineReady else { statusMessage = "Chargez d’abord un modèle dans l’onglet Modèles."; return }
        guard microphoneGranted else { statusMessage = "Autorisez le microphone avant de dicter."; return }
        if fromHotkey && !heldFn { return }
        target = NSWorkspace.shared.frontmostApplication
        if target?.processIdentifier == ProcessInfo.processInfo.processIdentifier { target = nil }
        do {
            try recorder.start()
            recordingStarted = Date()
            inserter.captureTarget(target)
            generation = UUID()
            phase = .recording; statusMessage = "À vous. On vous écoute."
            onHUDVisibility?(true)
            recordingLimit = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled, isRecording else { return }
                finishRecording()
            }
        } catch { phase = .error; statusMessage = error.localizedDescription }
    }

    private func finishRecording() {
        guard isRecording else { return }
        recordingLimit?.cancel(); recordingLimit = nil
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        let token = generation
        do {
            let url = try recorder.stop()
            level = 0
            guard duration >= 0.25 else {
                try? FileManager.default.removeItem(at: url)
                phase = .ready; statusMessage = "Maintenez Fn un peu plus longtemps."; onHUDVisibility?(false); return
            }
            phase = .transcribing; statusMessage = "Vos mots prennent forme…"
            let model = loadedModel ?? selectedModel
            let vocabularySnapshot = vocabulary
            let languageSnapshot = language
            operation = Task {
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    let start = Date()
                    var params: [String: Any] = ["audio_path": url.path, "model": model.rawValue, "context": vocabularySnapshot]
                    if languageSnapshot != "Auto" { params["language"] = languageSnapshot }
                    let result = try await engine.request("transcribe", params: params)
                    guard token == generation, !Task.isCancelled else { return }
                    let text = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        phase = .ready; statusMessage = "Aucune parole détectée."; onHUDVisibility?(false); return
                    }
                    let transcript = Transcript(text: text, model: model, duration: result.audio_duration_seconds ?? duration, latency: Date().timeIntervalSince(start))
                    history.insert(transcript, at: 0)
                    history = Array(history.prefix(keepHistory ? 100 : 1))
                    if keepHistory { saveHistory() }
                    let inserted = await inserter.insert(text, into: target)
                    guard token == generation, !Task.isCancelled else { return }
                    phase = .ready
                    statusMessage = inserted ? "C’est écrit. À la prochaine idée." : "Votre texte est prêt. Cliquez sur Copier."
                    onHUDVisibility?(false)
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    phase = .error; statusMessage = error.localizedDescription; onHUDVisibility?(false)
                }
            }
        } catch { phase = .error; statusMessage = error.localizedDescription; onHUDVisibility?(false) }
    }

    func cancel() {
        guard phase == .recording || phase == .transcribing else { return }
        generation = UUID(); recordingLimit?.cancel(); operation?.cancel()
        recorder.cancel(); level = 0
        if phase == .transcribing { engine.stop(); loadedModel = nil }
        phase = loadedModel == nil ? .idle : .ready
        statusMessage = "Dictée annulée."; onHUDVisibility?(false)
    }
    func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Texte copié."
    }
    func clearHistory() {
        history = []; try? FileManager.default.removeItem(at: historyURL)
    }
    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch { statusMessage = "Texte prêt ; l’historique n’a pas pu être enregistré." }
    }
    func shutdown() { hotkey.stop(); recorder.cancel(); engine.stop(); permissionTimer?.invalidate(); recordingLimit?.cancel(); operation?.cancel() }
}
