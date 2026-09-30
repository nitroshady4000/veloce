import AppKit
import UniformTypeIdentifiers

/// A normal macOS Service: Finder launches Véloce and sends only selected URLs.
@MainActor
final class FinderTranscriptionService: NSObject {
    var onFiles: (([URL], String?) -> Void)?

    @objc func transcribeFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.files(from: pasteboard).filter(Self.supports)
        guard !urls.isEmpty else {
            error.pointee = "Sélectionnez un fichier audio ou vidéo lisible sur ce Mac." as NSString
            return
        }
        onFiles?(urls, ["txt", "md"].contains(userData ?? "") ? userData : nil)
    }

    static func files(from pasteboard: NSPasteboard) -> [URL] {
        if let items = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !items.isEmpty {
            return items
        }
        let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        return (pasteboard.propertyList(forType: legacyType) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func supports(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values?.isRegularFile == true else { return false }
        if let type = values?.contentType, type.conforms(to: .audio) || type.conforms(to: .movie) { return true }
        return ["wav", "m4a", "mp3", "aif", "aiff", "caf", "flac", "mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
}
