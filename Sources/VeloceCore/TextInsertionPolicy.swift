import Foundation

public struct TextInputSnapshot: Equatable {
    public let selection: NSRange?
    public let selectedText: String?
    public let value: String?

    public init(selection: NSRange? = nil, selectedText: String? = nil, value: String? = nil) {
        self.selection = selection
        self.selectedText = selectedText
        self.value = value
    }
}

public enum TextInsertionPolicy {
    /// A value change that merely contains old text is not a paste receipt.
    public static func observesPaste(captured: TextInputSnapshot, currentValue: String, text: String) -> Bool {
        guard !text.isEmpty, let before = captured.value, before != currentValue else { return false }
        if let selection = captured.selection {
            return TextInsertionAdvance.replacement(in: before, selection: selection, text: text) == currentValue
        }
        // With no caret metadata, acknowledge only an exact append/prepend.
        // Other successful pastes remain unconfirmed; the clipboard stays available.
        guard captured.selectedText?.isEmpty != false else { return false }
        return currentValue == before + text || currentValue == text + before
    }

    public static func allowsPaste(
        sameApplication: Bool,
        sameElement: Bool?,
        sameWindow: Bool?,
        userInteracted: Bool,
        secureInput: Bool,
        captured: TextInputSnapshot,
        current: TextInputSnapshot,
        requiresSelectedText: Bool = false
    ) -> Bool {
        guard sameApplication,
              sameElement != false,
              sameWindow != false,
              !userInteracted,
              !secureInput else {
            return false
        }

        if let capturedSelection = captured.selection,
           let currentSelection = current.selection,
           capturedSelection != currentSelection {
            return false
        }

        if requiresSelectedText {
            guard let capturedSelectedText = captured.selectedText,
                  !capturedSelectedText.isEmpty,
                  current.selectedText == capturedSelectedText,
                  let capturedRange = captured.selection,
                  let currentRange = current.selection,
                  capturedRange == currentRange else {
                return false
            }

            if let capturedValue = captured.value, current.value != capturedValue {
                return false
            }
            return true
        }

        let capturedHasSelection = (captured.selection?.length ?? 0) > 0
            || !(captured.selectedText?.isEmpty ?? true)
        guard capturedHasSelection else {
            // With a caret, a web editor may update its full value while dictation is running.
            return true
        }

        if let capturedSelectedText = captured.selectedText,
           current.selectedText != capturedSelectedText {
            return false
        }
        if let capturedValue = captured.value, current.value != capturedValue {
            return false
        }
        if let capturedRange = captured.selection, current.selection != capturedRange {
            return false
        }
        return true
    }
}
