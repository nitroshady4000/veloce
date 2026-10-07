import AppKit
import ApplicationServices
import Carbon
import VeloceCore

/// Captures the destination before the HUD appears. Incomplete AX metadata must
/// not prevent Cmd+V, but an observed focus change or user edit must prevent it.
@MainActor
final class TextInserter {
    fileprivate struct Target {
        let id = UUID()
        let processIdentifier: pid_t
        let element: AXUIElement?
        let focusedElement: AXUIElement?
        let window: AXUIElement?
        let snapshot: TextInputSnapshot
        let requiresSelectedText: Bool
        let isOwnContinuation: Bool
    }

    struct InsertionReceipt {
        fileprivate let previous: Target
        fileprivate let selection: NSRange
        fileprivate let value: String
    }
    struct InsertionResult {
        let inserted: Bool
        let receipt: InsertionReceipt?
        let message: String?
        static let failed = InsertionResult(inserted: false, receipt: nil, message: nil)
    }

    private var target: Target?
    private var insertionInProgress = false
    private var inputMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var userInteracted = false
    private var captureFailure: String?

    isolated deinit { stopTracking() }

    @discardableResult
    func captureTarget(_ app: NSRunningApplication?) -> Bool {
        clearTarget()
        guard AXIsProcessTrusted() else {
            captureFailure = "Autorisez Accessibilité pour le collage automatique. Texte disponible avec Copier."
            return false
        }
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            captureFailure = "Maintenez Fn depuis le champ de destination. Texte disponible avec Copier."
            return false
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        // Electron exposes its Chromium accessibility tree on this request.
        // https://www.electronjs.org/docs/latest/tutorial/accessibility/
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let focused = focusedElement(in: app.processIdentifier)
        guard !IsSecureEventInputEnabled(), !isProtected(focused) else {
            captureFailure = "Collage indisponible dans ce champ protégé."
            return false
        }
        let element = editableElement(focused)
        target = Target(processIdentifier: app.processIdentifier, element: element, focusedElement: focused,
                        window: window(in: app.processIdentifier, element: focused),
                        snapshot: snapshot(element), requiresSelectedText: false, isOwnContinuation: false)
        startTracking(app.processIdentifier)
        return true
    }

    /// The rewrite panel takes focus intentionally. Replacement still requires
    /// an exact, visible selection when the user explicitly chooses Replace.
    func captureSelectedText(_ app: NSRunningApplication?) -> String? {
        guard captureTarget(app), let target, let text = target.snapshot.selectedText,
              !text.isEmpty, target.snapshot.selection != nil else {
            clearTarget(); return nil
        }
        stopTracking()
        self.target = Target(processIdentifier: target.processIdentifier, element: target.element,
                             focusedElement: target.focusedElement, window: target.window, snapshot: target.snapshot,
                             requiresSelectedText: true, isOwnContinuation: false)
        return text
    }

    func insert(_ text: String, into app: NSRunningApplication?) async -> Bool {
        await insertWithReceipt(text, into: app).inserted
    }

    func insertWithReceipt(_ text: String, into app: NSRunningApplication?) async -> InsertionResult {
        guard !insertionInProgress, !Task.isCancelled, !text.isEmpty else { return .failed }
        guard let app, let target, target.processIdentifier == app.processIdentifier else {
            return InsertionResult(inserted: false, receipt: nil, message: captureFailure)
        }
        guard targetStillMatches(target) else {
            clearTarget()
            return InsertionResult(inserted: false, receipt: nil,
                                   message: "La destination a changé. Texte disponible avec Copier.")
        }
        guard let savedClipboard = ClipboardBackup.capture(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .failed }

        let pastedText: String
        if target.isOwnContinuation, let value = target.snapshot.value, let selection = target.snapshot.selection {
            pastedText = TextInsertionAdvance.continuation(text, in: value, at: selection)
        } else { pastedText = text }

        insertionInProgress = true
        defer {
            insertionInProgress = false
            if self.target?.id == target.id { clearTarget() }
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == savedClipboard.changeCount else { return .failed }
        pasteboard.clearContents()
        guard pasteboard.setString(pastedText, forType: .string) else {
            savedClipboard.restore(ifUnchangedSince: pasteboard.changeCount)
            return .failed
        }
        let temporaryClipboardVersion = pasteboard.changeCount
        guard !Task.isCancelled, targetStillMatches(target) else {
            savedClipboard.restore(ifUnchangedSince: temporaryClipboardVersion)
            return .failed
        }
        // Tag both events: our paste must not cancel a concurrent Fn recording.
        for event in [keyDown, keyUp] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: VeloceEventSourceUserData.textInserterPaste)
            event.post(tap: .cghidEventTap)
        }

        // Restore only after the destination acknowledges the paste. A fixed
        // delay can restore the old clipboard before a slow renderer reads it.
        let deadline = Date().addingTimeInterval(1.2)
        repeat {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
            if let receipt = verifiedReceipt(for: target, insertedText: pastedText) {
                savedClipboard.restore(ifUnchangedSince: temporaryClipboardVersion)
                return InsertionResult(inserted: true, receipt: receipt, message: "Texte inséré.")
            }
            if pasteWasObserved(target, insertedText: pastedText) {
                savedClipboard.restore(ifUnchangedSince: temporaryClipboardVersion)
                return InsertionResult(inserted: true, receipt: nil, message: "Texte inséré.")
            }
        } while Date() < deadline

        // Keep the transcription available for a delayed paste or manual Cmd+V.
        // Never overwrite a clipboard the user has changed during processing.
        if let before = target.snapshot.value, let element = target.element,
           (attribute(kAXValueAttribute, of: element) as? String) == before {
            return InsertionResult(inserted: false, receipt: nil,
                                   message: "Collage non confirmé. Texte disponible avec Copier.")
        }
        return InsertionResult(inserted: true, receipt: nil, message: "Collage envoyé.")
    }

    /// Only an exact paste acknowledgement can advance a queued dictation.
    func advanceAfterOwnInsertion(_ receipt: InsertionReceipt) {
        guard let target, !userInteracted,
              target.processIdentifier == receipt.previous.processIdentifier,
              let element = target.element, let previous = receipt.previous.element,
              CFEqual(element, previous), sameWindow(target.window, receipt.previous.window) != false,
              currentElementMatches(target) else { return }
        let current = snapshot(element)
        guard current.selection == receipt.selection, current.value == receipt.value else { return }
        let capturedBefore = target.snapshot == receipt.previous.snapshot
        let capturedAfter = target.snapshot.selection == receipt.selection && target.snapshot.value == receipt.value
        guard capturedBefore || capturedAfter else { return }
        self.target = Target(processIdentifier: target.processIdentifier, element: element,
                             focusedElement: target.focusedElement, window: target.window, snapshot: current,
                             requiresSelectedText: target.requiresSelectedText, isOwnContinuation: true)
    }

    private func verifiedReceipt(for target: Target, insertedText: String) -> InsertionReceipt? {
        guard currentElementMatches(target), let element = target.element,
              let before = target.snapshot.value, let originalRange = target.snapshot.selection,
              let afterRange = TextInsertionAdvance.caret(afterReplacing: originalRange, with: insertedText),
              let expectedValue = TextInsertionAdvance.replacement(in: before, selection: originalRange, text: insertedText)
        else { return nil }
        let current = snapshot(element)
        guard current.selection == afterRange, current.value == expectedValue else { return nil }
        return InsertionReceipt(previous: target, selection: afterRange, value: expectedValue)
    }

    private func pasteWasObserved(_ target: Target, insertedText: String) -> Bool {
        guard currentElementMatches(target), let element = target.element,
              let after = attribute(kAXValueAttribute, of: element) as? String else { return false }
        return TextInsertionPolicy.observesPaste(captured: target.snapshot, currentValue: after, text: insertedText)
    }

    private func currentElementMatches(_ target: Target) -> Bool {
        guard !userInteracted, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let element = target.element, let current = editableElement(focusedElement(in: target.processIdentifier)),
              CFEqual(element, current), !isProtected(current) else { return false }
        return sameWindow(target.window, window(in: target.processIdentifier, element: current)) != false
    }

    private func targetStillMatches(_ target: Target) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let focused = focusedElement(in: target.processIdentifier)
        let current = editableElement(focused)
        let sameElement: Bool?
        if let original = target.element ?? target.focusedElement, let observed = current ?? focused {
            sameElement = CFEqual(original, observed)
        }
        else { sameElement = nil }
        return TextInsertionPolicy.allowsPaste(
            sameApplication: NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
            sameElement: sameElement,
            sameWindow: sameWindow(target.window, window(in: target.processIdentifier, element: focused)),
            userInteracted: target.requiresSelectedText ? false : userInteracted,
            secureInput: IsSecureEventInputEnabled() || isProtected(focused),
            captured: target.snapshot, current: snapshot(current), requiresSelectedText: target.requiresSelectedText)
    }

    private func startTracking(_ processIdentifier: pid_t) {
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Fn starts/stops another capture; our own Cmd+V is not a user edit.
            if event.type == .keyDown {
                if event.keyCode == 63 || event.keyCode == 53 { return }
                if event.keyCode == 9,
                   event.cgEvent?.getIntegerValueField(.eventSourceUserData) == VeloceEventSourceUserData.textInserterPaste { return }
            }
            self?.userInteracted = true
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != processIdentifier { self?.userInteracted = true }
            }
        }
    }

    private func stopTracking() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func clearTarget() {
        target = nil; captureFailure = nil; userInteracted = false
        stopTracking()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func snapshot(_ element: AXUIElement?) -> TextInputSnapshot {
        guard let element else { return TextInputSnapshot() }
        return TextInputSnapshot(selection: attribute(kAXSelectedTextRangeAttribute, of: element).flatMap(range),
                                 selectedText: attribute(kAXSelectedTextAttribute, of: element) as? String,
                                 value: attribute(kAXValueAttribute, of: element) as? String)
    }

    private func range(_ value: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func sameWindow(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool? {
        guard let first, let second else { return nil }
        return CFEqual(first, second)
    }

    private func focusedElement(in processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard var element = elementAttribute(kAXFocusedUIElementAttribute, of: application) else { return nil }
        for _ in 0..<4 {
            guard let child = elementAttribute(kAXFocusedUIElementAttribute, of: element), !CFEqual(child, element) else { break }
            element = child
        }
        return element
    }

    private func editableElement(_ element: AXUIElement?) -> AXUIElement? {
        guard let element, (attribute(kAXEnabledAttribute, of: element) as? Bool) != false else { return nil }
        let role = attribute(kAXRoleAttribute, of: element) as? String ?? ""
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return element }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue { return element }
        return nil
    }

    private func isProtected(_ element: AXUIElement?) -> Bool {
        var ancestor = element
        for _ in 0..<12 {
            guard let current = ancestor else { break }
            if attribute(kAXSubroleAttribute, of: current) as? String == kAXSecureTextFieldSubrole
                || attribute("AXProtectedContent", of: current) as? Bool == true { return true }
            ancestor = elementAttribute(kAXParentAttribute, of: current)
        }
        return false
    }

    private func window(in processIdentifier: pid_t, element: AXUIElement?) -> AXUIElement? {
        if let element, let window = elementAttribute(kAXWindowAttribute, of: element) { return window }
        return elementAttribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(processIdentifier))
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

/// Materialize readable formats; private/promise-only formats can return nil.
/// Such a format must not disable dictation while ordinary clipboard data exists.
@MainActor
struct ClipboardBackup {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    let changeCount: Int

    static func capture(from pasteboard: NSPasteboard = .general) -> ClipboardBackup? {
        let version = pasteboard.changeCount
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> [(NSPasteboard.PasteboardType, Data)]? in
            let readable = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
            return readable.isEmpty ? nil : readable
        }
        guard pasteboard.changeCount == version else { return nil }
        return ClipboardBackup(items: items, changeCount: version)
    }

    func restore(to pasteboard: NSPasteboard = .general, ifUnchangedSince version: Int) {
        guard pasteboard.changeCount == version else { return }
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
