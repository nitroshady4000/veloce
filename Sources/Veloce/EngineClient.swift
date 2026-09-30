import Foundation
import VeloceCore

enum VeloceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// A single persistent worker: model weights stay warm between dictations.
@MainActor
final class EngineClient {
    /// Injectable transport for offline workflow verification. Production always
    /// uses the managed process; diagnostics never load a second speech model.
    private let requestOverride: ((String, [String: Any]) async throws -> EngineReply.Result)?
    init(requestOverride: ((String, [String: Any]) async throws -> EngineReply.Result)? = nil) {
        self.requestOverride = requestOverride
    }
    private var process: Process?
    private var installer: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var framing = JSONLineBuffer()
    private var pending: [String: CheckedContinuation<EngineReply.Result, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    var onStatus: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onMeetingProgress: ((Double, String) -> Void)?

    let directory: URL = {
        if let value = ProcessInfo.processInfo.environment["VELOCE_ENGINE_DIR"] {
            return URL(fileURLWithPath: value)
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "VeloceEngineDirectory") as? String, !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent("Engine")
    }()
    var installed: Bool { requestOverride != nil || FileManager.default.isExecutableFile(atPath: python.path) }
    private var python: URL { directory.appendingPathComponent(".venv/bin/python") }

    func install(includeParakeet: Bool, includeMeetings: Bool = false) async throws {
        if requestOverride != nil { try Task.checkCancellation(); return }
        guard installer == nil else { throw VeloceError.message("Une installation du moteur est déjà en cours.") }
        try Task.checkCancellation()
        let script = directory.appendingPathComponent("bootstrap.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw VeloceError.message("Le moteur est introuvable. Reconstruisez Véloce avec scripts/build-app.sh.")
        }
        let task = Process()
        installer = task
        defer { installer = nil }
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path] + (includeParakeet ? ["--parakeet"] : []) + (includeMeetings ? ["--meetings"] : [])
        task.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = environment
        // No transcript or credentials go through the setup process.
        let log = Pipe()
        task.standardOutput = log; task.standardError = log
        log.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.terminationHandler = { finished in
                    log.fileHandleForReading.readabilityHandler = nil
                    if finished.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: VeloceError.message("Installation du moteur interrompue ou impossible. Réessayez, ou lancez Engine/bootstrap.sh dans le Terminal pour le diagnostic.")) }
                }
                do {
                    try task.run()
                    if Task.isCancelled { task.terminate() }
                } catch {
                    task.terminationHandler = nil
                    log.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor in if task.isRunning { task.terminate() } }
        }
        try Task.checkCancellation()
    }

    func request(_ method: String, params: [String: Any] = [:], timeout: Double = 180) async throws -> EngineReply.Result {
        if let requestOverride { return try await requestOverride(method, params) }
        try start()
        let id = UUID().uuidString
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop(reason: "Le moteur ne répond plus. Relancez le modèle.")
            }
            do { try input?.write(contentsOf: data) }
            catch { fail(id, error: error) }
        }
    }

    private func start() throws {
        if process?.isRunning == true { return }
        guard installed else { throw VeloceError.message("Installez d’abord le moteur local.") }
        framing = JSONLineBuffer()
        let worker = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        worker.executableURL = python
        worker.arguments = ["-u", directory.appendingPathComponent("worker.py").path]
        worker.currentDirectoryURL = directory
        worker.standardInput = stdin; worker.standardOutput = stdout; worker.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // Development bundle points at this checkout; reuse its tested model cache.
        if environment["VELOCE_MODEL_CACHE"] == nil, Bundle.main.object(forInfoDictionaryKey: "VeloceEngineDirectory") != nil {
            environment["VELOCE_MODEL_CACHE"] = directory.appendingPathComponent(".models").path
        }
        worker.environment = environment
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak worker] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, let worker, self.process === worker else { return }
                self.receive(data)
            }
        }
        // Always drain stderr so download progress cannot deadlock the worker.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        worker.terminationHandler = { [weak self, weak worker] _ in
            Task { @MainActor in
                guard let self, let worker, self.process === worker else { return }
                self.stop(reason: "Le moteur local s’est arrêté. Vous pouvez le relancer.")
            }
        }
        process = worker
        do { try worker.run() } catch { stop(); throw error }
    }

    private func receive(_ data: Data) {
        do {
            for line in try framing.append(data) {
                let reply = try JSONDecoder().decode(EngineReply.self, from: line)
                if let state = reply.state { onStatus?(state) }
                if reply.event == "meeting_progress", let progress = reply.progress {
                    onMeetingProgress?(min(1, max(0, progress)), reply.detail ?? "Traitement de la réunion…")
                }
                guard let id = reply.id else { continue }
                if let error = reply.error { fail(id, error: VeloceError.message(error.message)) }
                else if let result = reply.result {
                    deadlines.removeValue(forKey: id)?.cancel()
                    pending.removeValue(forKey: id)?.resume(returning: result)
                } else { fail(id, error: VeloceError.message("Réponse du moteur invalide.")) }
            }
        } catch { stop(reason: "Le moteur a renvoyé une réponse illisible : \(error.localizedDescription)") }
    }

    private func fail(_ id: String, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    func stop(reason: String = "Opération annulée.") {
        if installer?.isRunning == true { installer?.terminate() }
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        let worker = process; process = nil
        worker?.terminationHandler = nil
        if worker?.isRunning == true { worker?.terminate() }
        try? input?.close(); input = nil; output = nil; errors = nil
        for id in Array(pending.keys) { fail(id, error: VeloceError.message(reason)) }
        if worker != nil { onExit?() }
    }
}
