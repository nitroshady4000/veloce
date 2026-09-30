import Foundation
import VeloceCore

/// Exercises the real import, queue, persistence and sidecar path with synthetic
/// audio and a tiny fake transport, without permissions, an ASR model or playback.
@MainActor
enum MeetingWorkflowDiagnostics {
    static func verify(directory: URL) async throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw VeloceError.message("Utilisez un dossier de vérification neuf.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originals = try (1...3).map { try fixture(number: $0, directory: directory) }
        var calls = 0
        let engine = EngineClient { method, params in
            if method == "transcribe_meeting" {
                calls += 1
                guard let path = params["audio_path"] as? String,
                      path.hasSuffix("imported.wav"), FileManager.default.fileExists(atPath: path),
                      params["microphone_path"] == nil else { throw VeloceError.message("L’import ne pointe pas sur son propre WAV.") }
                return try reply(["duration": 1, "diarization": "tracks-only", "segments": [
                    ["id": "fake-\(calls)", "start": 0, "end": 1, "speaker": "Audio importé", "source": "imported", "text": "Transcription locale \(calls)."]
                ]])
            }
            return try reply(["diarization_ready": false])
        }
        let store = MeetingStore(root: directory.appendingPathComponent("history", isDirectory: true))
        let model = MeetingModel(engine: engine, store: store, previewRecords: [])
        var allowed = false
        model.canBegin = { allowed }
        model.onSidecarReady = { record, url, format in _ = try MeetingSidecar.write(record: record, beside: url, format: format) }
        model.enqueueImports(Array(originals.prefix(2)), model: .balanced, language: "French", vocabulary: "", sidecarFormat: "txt")
        guard model.queuedImportCount == 2, model.records.isEmpty, calls == 0 else { throw VeloceError.message("Une importation a ignoré le moteur occupé.") }
        allowed = true
        try await wait(until: { model.queuedImportCount == 0 && !model.isBusy })
        guard calls == 2, model.records.count == 2, model.records.allSatisfy({ $0.status == .transcribed && $0.isImported }),
              store.load().count == 2 else { throw VeloceError.message("La file d’imports ou son historique n’a pas été conservé.") }
        for original in originals.prefix(2) {
            let sidecar = original.deletingPathExtension().appendingPathExtension("txt")
            guard try String(contentsOf: sidecar, encoding: .utf8).contains("Transcription locale") else { throw VeloceError.message("Le fichier voisin manque.") }
        }
        let occupied = originals[2].deletingPathExtension().appendingPathExtension("txt")
        let keep = Data("document déjà présent".utf8)
        try keep.write(to: occupied)
        model.enqueueImports([originals[2]], model: .balanced, language: "French", vocabulary: "", sidecarFormat: "txt")
        try await wait(until: { model.queuedImportCount == 0 && !model.isBusy })
        guard calls == 3, model.records.count == 3, store.load().count == 3,
              try Data(contentsOf: occupied) == keep, model.error != nil else {
            throw VeloceError.message("Un conflit de nom a supprimé la transcription ou remplacé le document.")
        }
        await model.finishForTermination()

        // Cancellation after the first import is stored must discard waiting
        // jobs, retain recoverable audio and stop without starting the second.
        var started = false
        let slowEngine = EngineClient { method, _ in
            if method == "transcribe_meeting" {
                started = true
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return try reply([:])
        }
        let cancelledStore = MeetingStore(root: directory.appendingPathComponent("cancelled-history"))
        let cancelled = MeetingModel(engine: slowEngine, store: cancelledStore, previewRecords: [])
        cancelled.canBegin = { true }
        cancelled.enqueueImports(Array(originals.prefix(2)), model: .balanced, language: "French", vocabulary: "")
        try await wait(until: { started })
        cancelled.cancelProcessing()
        try await wait(until: { cancelled.queuedImportCount == 0 && !cancelled.isBusy })
        guard cancelled.records.count == 1, cancelledStore.load().count == 1,
              FileManager.default.fileExists(atPath: cancelledStore.directory(for: cancelled.records[0].id).appendingPathComponent("imported.wav").path) else {
            throw VeloceError.message("L’annulation a perdu le fichier importé ou démarré un autre traitement.")
        }
        await cancelled.finishForTermination()
        for original in originals {
            guard try Data(contentsOf: original) == wav() else { throw VeloceError.message("Un média original a été modifié.") }
        }
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw VeloceError.message("Le flux d’import ne s’est pas terminé.") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func reply(_ result: [String: Any]) throws -> EngineReply.Result {
        try JSONDecoder().decode(EngineReply.Result.self, from: JSONSerialization.data(withJSONObject: result))
    }
    private static func fixture(number: Int, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("Média \(number).wav")
        try wav().write(to: url, options: .withoutOverwriting)
        return url
    }
    private static func wav() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(32_036); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(32_000)
        for frame in 0..<16_000 { u16(UInt16(bitPattern: Int16(2_000 * sin(Double(frame) * 0.3)))) }
        return data
    }
}
