import Foundation

/// One active processor and one microphone capture, with a bounded FIFO.
public struct DictationPipeline<Job> {
    public private(set) var active: Job?
    public private(set) var pending: [Job] = []
    public private(set) var isCapturing = false
    public let capacity: Int
    public var count: Int { pending.count + (active == nil ? 0 : 1) }
    public init(capacity: Int = 4) { precondition(capacity > 0); self.capacity = capacity }

    @discardableResult
    public mutating func beginCapture() -> Bool {
        guard !isCapturing, count < capacity else { return false }
        isCapturing = true
        return true
    }
    public mutating func finishCapture(_ job: Job) {
        precondition(isCapturing)
        isCapturing = false
        pending.append(job)
    }
    public mutating func cancelCapture() { isCapturing = false }
    public mutating func startNext() -> Job? {
        guard active == nil, !pending.isEmpty else { return nil }
        active = pending.removeFirst()
        return active
    }
    public mutating func completeActive() { active = nil }
    /// Cancelling waiting recordings must not terminate the active processor.
    public mutating func removePending() -> [Job] {
        let removed = pending
        pending = []
        return removed
    }
}

public enum TextInsertionAdvance {
    /// Separate a confirmed continuation without changing ordinary replacements
    /// or whitespace deliberately supplied by a snippet.
    public static func continuation(_ text: String, in value: String, at selection: NSRange) -> String {
        guard selection.length == 0, selection.location > 0,
              selection.location <= value.utf16.count,
              let prefixRange = Range(NSRange(location: 0, length: selection.location), in: value),
              let previous = value[prefixRange].last, !previous.isWhitespace,
              let first = text.first, !first.isWhitespace,
              !".,)]}'’-/".contains(first), !"([{/'’".contains(previous) else { return text }
        return " " + text
    }

    /// Accessibility ranges use UTF-16, including both code units of an emoji.
    public static func caret(afterReplacing selection: NSRange, with text: String) -> NSRange? {
        guard selection.location >= 0, selection.location != NSNotFound, selection.length >= 0 else { return nil }
        let (location, overflow) = selection.location.addingReportingOverflow(text.utf16.count)
        guard !overflow else { return nil }
        return NSRange(location: location, length: 0)
    }
    public static func replacement(in original: String, selection: NSRange, text: String) -> String? {
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= original.utf16.count,
              selection.length <= original.utf16.count - selection.location else { return nil }
        return (original as NSString).replacingCharacters(in: selection, with: text)
    }
}
