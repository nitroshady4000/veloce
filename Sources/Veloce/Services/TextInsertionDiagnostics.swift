import AppKit
import VeloceCore

/// Exercises clipboard backup with an isolated pasteboard. It never reads or
/// changes the user's clipboard and does not post keyboard events.
@MainActor
enum TextInsertionDiagnostics {
    static func verify() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        // An empty clipboard is still a valid snapshot and must restore empty.
        pasteboard.clearContents()
        guard let emptyBackup = ClipboardBackup.capture(from: pasteboard), emptyBackup.items.isEmpty else {
            throw VeloceError.message("La sauvegarde du presse-papiers vide a échoué.")
        }
        pasteboard.setString("temporary", forType: .string)
        let emptyVersion = pasteboard.changeCount
        emptyBackup.restore(to: pasteboard, ifUnchangedSince: emptyVersion)
        guard pasteboard.pasteboardItems?.isEmpty ?? true else {
            throw VeloceError.message("Le presse-papiers vide n’a pas été restauré.")
        }

        // Preserve both multiple items and every readable representation.
        let firstType = NSPasteboard.PasteboardType("com.veloce.diagnostic.first")
        let secondType = NSPasteboard.PasteboardType("com.veloce.diagnostic.second")
        let first = NSPasteboardItem()
        first.setData(Data("alpha".utf8), forType: firstType)
        first.setString("Alpha", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data([0, 1, 2, 255]), forType: secondType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([first, second]),
              let backup = ClipboardBackup.capture(from: pasteboard),
              backup.items.count == 2 else {
            throw VeloceError.message("Les éléments du presse-papiers n’ont pas été sauvegardés.")
        }
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        backup.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
        guard let restored = pasteboard.pasteboardItems, restored.count == 2,
              restored[0].data(forType: firstType) == Data("alpha".utf8),
              restored[0].string(forType: .string) == "Alpha",
              restored[1].data(forType: secondType) == Data([0, 1, 2, 255]) else {
            throw VeloceError.message("Les représentations du presse-papiers n’ont pas été restaurées.")
        }

        // A promised format that cannot materialize must not discard the
        // ordinary readable representation from an otherwise valid backup.
        let promisedItem = NSPasteboardItem()
        let promisedType = NSPasteboard.PasteboardType("com.veloce.diagnostic.promised")
        promisedItem.setString("Readable", forType: .string)
        promisedItem.setDataProvider(UnavailablePasteboardRepresentation(), forTypes: [promisedType])
        pasteboard.clearContents()
        guard pasteboard.writeObjects([promisedItem]),
              let promisedBackup = ClipboardBackup.capture(from: pasteboard),
              promisedBackup.items.count == 1,
              promisedBackup.items[0].contains(where: { $0.0 == .string && $0.1 == Data("Readable".utf8) }) else {
            throw VeloceError.message("Un format promis illisible a bloqué la sauvegarde du texte.")
        }

        // A clipboard edit after capture belongs to the user; stale snapshots
        // must never overwrite it.
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        guard let changedBackup = ClipboardBackup.capture(from: pasteboard) else {
            throw VeloceError.message("La sauvegarde du presse-papiers a échoué.")
        }
        pasteboard.clearContents()
        pasteboard.setString("user edit", forType: .string)
        changedBackup.restore(to: pasteboard, ifUnchangedSince: changedBackup.changeCount)
        guard pasteboard.string(forType: .string) == "user edit" else {
            throw VeloceError.message("La restauration a remplacé une modification du presse-papiers.")
        }
    }
}

private final class UnavailablePasteboardRepresentation: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // Intentionally leave this promised representation unavailable.
    }
}
