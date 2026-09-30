import AppKit
import ApplicationServices
import Carbon

/// Pastes only into an accessible text input whose app, element and caret still match.
@MainActor
final class TextInserter {
    private struct Target {
        let id = UUID()
        let processIdentifier: pid_t
        let element: AXUIElement
        let selection: CFTypeRef
        let window: AXUIElement?
    }

    private struct ClipboardItem {
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }

    private struct ClipboardSnapshot {
        let items: [ClipboardItem]
        let changeCount: Int
    }

    private var target: Target?
    private var insertionInProgress = false

    /// Call synchronously when dictation begins, before displaying any focus-taking UI.
    @discardableResult
    func captureTarget(_ app: NSRunningApplication?) -> Bool {
        target = nil
        guard let app,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let element = focusedTextElement(in: app.processIdentifier),
              let selection = attribute(kAXSelectedTextRangeAttribute, of: element)
        else { return false }
        target = Target(
            processIdentifier: app.processIdentifier,
            element: element,
            selection: selection,
            window: elementAttribute(kAXWindowAttribute, of: element)
        )
        return true
    }

    /// A false result leaves the transcript available for an explicit Copy action.
    func insert(_ text: String, into app: NSRunningApplication?) async -> Bool {
        guard !insertionInProgress, !Task.isCancelled, !text.isEmpty, let app, let target,
              target.processIdentifier == app.processIdentifier,
              targetStillMatches(target),
              let savedClipboard = snapshotClipboard(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }

        insertionInProgress = true
        defer {
            insertionInProgress = false
            if self.target?.id == target.id { self.target = nil }
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == savedClipboard.changeCount else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(savedClipboard.items, ifUnchangedSince: pasteboard.changeCount)
            return false
        }
        let temporaryClipboardVersion = pasteboard.changeCount

        // Recheck after clipboard materialization, which can involve another process.
        guard !Task.isCancelled, targetStillMatches(target) else {
            restore(savedClipboard.items, ifUnchangedSince: temporaryClipboardVersion)
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // This delay deliberately survives task cancellation so the receiving app
        // has time to read the clipboard before it is restored.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
        }
        restore(savedClipboard.items, ifUnchangedSince: temporaryClipboardVersion)
        return true
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearTarget() {
        target = nil
    }

    private func targetStillMatches(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let current = focusedTextElement(in: target.processIdentifier),
              CFEqual(current, target.element),
              let selection = attribute(kAXSelectedTextRangeAttribute, of: current),
              CFEqual(selection, target.selection)
        else { return false }
        if let window = target.window {
            guard let currentWindow = elementAttribute(kAXWindowAttribute, of: current),
                  CFEqual(window, currentWindow) else { return false }
        }
        return true
    }

    private func focusedTextElement(in processIdentifier: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, of: application),
              let role = attribute(kAXRoleAttribute, of: element) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(kAXEnabledAttribute, of: element) as? Bool) != false
        else { return nil }

        // Password inputs may report protection on either the input or its container.
        var ancestor: AXUIElement? = element
        for _ in 0..<12 {
            guard let current = ancestor else { break }
            let subrole = attribute(kAXSubroleAttribute, of: current) as? String
            let protected = attribute("AXProtectedContent", of: current) as? Bool
            if subrole == kAXSecureTextFieldSubrole || protected == true { return nil }
            ancestor = elementAttribute(kAXParentAttribute, of: current)
        }
        return element
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        // A hung target app should fall back to Copy, not freeze the dictation UI.
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func snapshotClipboard() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        var items: [ClipboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                // Avoid destroying an existing clipboard format that cannot be materialized.
                guard let data = item.data(forType: type) else { return nil }
                representations.append((type, data))
            }
            items.append(ClipboardItem(representations: representations))
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        return ClipboardSnapshot(items: items, changeCount: changeCount)
    }

    private func restore(_ items: [ClipboardItem], ifUnchangedSince changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return }
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
