import Foundation
import Darwin
import VeloceCore

/// Finder imports publish a neighbor file only after transcription is saved.
/// The same name is used; an existing document is never replaced.
enum MeetingSidecar {
    static func write(record: MeetingRecord, beside source: URL, format: String) throws -> URL {
        guard source.isFileURL, ["txt", "md"].contains(format), record.status == .transcribed else {
            throw VeloceError.message("Cette transcription n’est pas encore prête à être enregistrée à côté du fichier.")
        }
        let destination = source.deletingPathExtension().appendingPathExtension(format)
        let content = format == "md" ? record.markdown : record.transcript + "\n"
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".veloce-transcript-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try Data(content.utf8).write(to: temporary, options: .withoutOverwriting)
            // Foundation's atomic and withoutOverwriting options cannot be
            // combined. Darwin provides an exclusive atomic rename, including
            // on volumes where hard links are unavailable.
            let result = temporary.withUnsafeFileSystemRepresentation { oldPath in
                destination.withUnsafeFileSystemRepresentation { newPath -> Int32 in
                    guard let oldPath, let newPath else { errno = EINVAL; return -1 }
                    return renamex_np(oldPath, newPath, UInt32(RENAME_EXCL))
                }
            }
            if result != 0 {
                let code = errno
                if code == EEXIST { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        } catch {
            if (error as NSError).code == NSFileWriteFileExistsError {
                throw VeloceError.message("\(destination.lastPathComponent) existe déjà. La transcription est conservée dans l’historique de Véloce ; ce fichier n’a pas été remplacé.")
            }
            throw VeloceError.message("La transcription est dans l’historique, mais son fichier voisin n’a pas pu être créé : \(error.localizedDescription)")
        }
        return destination
    }

    static func verify(directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw VeloceError.message("Utilisez un dossier de vérification neuf.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Entretien partagé.mp4")
        let sentinel = Data("synthetic-media-original".utf8)
        try sentinel.write(to: source)
        var record = MeetingRecord(title: "Entretien")
        record.status = .transcribed
        record.segments = [MeetingSegment(id: "test", start: 12, end: 14, speaker: "Camille", source: "imported", text: "La décision finale.")]
        for format in ["txt", "md"] {
            let destination = try write(record: record, beside: source, format: format)
            guard destination.lastPathComponent == "Entretien partagé.\(format)",
                  try String(contentsOf: destination, encoding: .utf8).contains("La décision finale.") else {
                throw VeloceError.message("Le fichier voisin n’a pas le bon nom ou le bon texte.")
            }
            let preserved = try Data(contentsOf: destination)
            var rejected = false
            do {
                _ = try write(record: record, beside: source, format: format)
            } catch {
                rejected = true
                guard try Data(contentsOf: destination) == preserved else { throw error }
            }
            guard rejected else { throw VeloceError.message("Un fichier voisin existant n’a pas été protégé.") }
        }
        guard try Data(contentsOf: source) == sentinel else { throw VeloceError.message("Le média original a été modifié.") }
    }
}
