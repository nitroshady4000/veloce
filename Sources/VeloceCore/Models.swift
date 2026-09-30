import Foundation

public enum SpeechModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case precision = "qwen3-1.7b"
    case balanced = "qwen3-0.6b"
    case fast = "parakeet-v3"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .precision: "Précision"; case .balanced: "Équilibre"; case .fast: "Alternative" }
    }
    public var name: String {
        switch self { case .precision: "Qwen3 · 1.7B"; case .balanced: "Qwen3 · 0.6B"; case .fast: "Parakeet · v3" }
    }
    public var detail: String {
        switch self {
        case .precision: "Pour les nuances, les noms et le français."
        case .balanced: "Un modèle plus léger pour la dictée quotidienne."
        case .fast: "Parakeet, à comparer sur vos dictées. Langue automatique."
        }
    }
    public var symbol: String {
        switch self { case .precision: "sparkle"; case .balanced: "circle.lefthalf.filled"; case .fast: "bolt.fill" }
    }
}

public struct Transcript: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var model: SpeechModel
    public var duration: Double
    public var latency: Double
    /// The exact ASR output, retained when a snippet or optional cleanup changes it.
    public var rawText: String?
    public init(text: String, model: SpeechModel, duration: Double, latency: Double, rawText: String? = nil) {
        self.id = UUID(); self.date = Date(); self.text = text
        self.model = model; self.duration = duration; self.latency = latency
        self.rawText = rawText == text ? nil : rawText
    }
}

public struct VoiceSnippet: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var phrase: String
    public var text: String
    public init(id: UUID = UUID(), phrase: String = "", text: String = "") {
        self.id = id; self.phrase = phrase; self.text = text
    }
}

public enum DictationTextPlan {
    /// A whole utterance must match. Substrings are ordinary dictated prose.
    public static func snippet(for utterance: String, in snippets: [VoiceSnippet]) -> String? {
        let key = normalized(utterance)
        guard !key.isEmpty else { return nil }
        let matches = snippets.filter {
            normalized($0.phrase) == key && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard matches.count == 1 else { return nil }
        return matches[0].text
    }

    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Transport shared with the local engine; no dependency on the macOS UI.
public struct EngineReply: Decodable, Sendable {
    public let id: String?
    public let result: Result?
    public let error: Failure?
    public let event: String?
    public let state: String?
    public let model: String?
    public let progress: Double?
    public let detail: String?
    public struct Result: Decodable, Sendable {
        public let text: String?
        public let model: String?
        public let language: String?
        public let audio_duration_seconds: Double?
        public let inference_seconds: Double?
        public let segments: [MeetingSegment]?
        public let duration: Double?
        public let diarization: String?
        public let diarization_ready: Bool?
        public let path: String?
    }
    public struct Failure: Decodable, Sendable {
        public let code: String
        public let message: String
    }
}

/// Handles arbitrary pipe boundaries, including UTF-8 characters split across reads.
public struct JSONLineBuffer {
    private var pending = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        guard pending.count <= 8_388_608 else { throw BufferError.tooLarge }
        var lines: [Data] = []
        while let index = pending.firstIndex(of: 10) {
            let line = Data(pending[..<index])
            pending.removeSubrange(...index)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
    public enum BufferError: Error { case tooLarge }
}
