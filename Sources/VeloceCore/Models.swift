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
    public init(text: String, model: SpeechModel, duration: Double, latency: Double) {
        self.id = UUID(); self.date = Date(); self.text = text
        self.model = model; self.duration = duration; self.latency = latency
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
    public struct Result: Decodable, Sendable {
        public let text: String?
        public let model: String?
        public let language: String?
        public let audio_duration_seconds: Double?
        public let inference_seconds: Double?
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
