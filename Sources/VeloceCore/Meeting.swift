import Foundation

public struct MeetingSegment: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var source: String
    public var text: String
    public init(id: String, start: Double, end: Double, speaker: String, source: String, text: String) {
        self.id = id; self.start = start; self.end = end
        self.speaker = speaker; self.source = source; self.text = text
    }
}

public struct MeetingRecord: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case recording, recorded, transcribed, interrupted }
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: Double
    public var status: Status
    public var segments: [MeetingSegment]
    public var speakerNames: [String: String]
    public var notes: String
    public var diarization: String
    public var model: SpeechModel?

    public init(title: String, date: Date = Date()) {
        id = UUID(); self.title = title; self.date = date
        duration = 0; status = .recording; segments = []; speakerNames = [:]
        notes = ""; diarization = "sources"; model = nil
    }

    public func speakerName(_ segment: MeetingSegment) -> String {
        let name = speakerNames[segment.speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? segment.speaker : name
    }
    public var transcript: String {
        segments.map { "[\(Self.timestamp($0.start))] \(speakerName($0)) : \($0.text)" }.joined(separator: "\n\n")
    }
    public var markdown: String {
        var output = "# \(title)\n\n\(date.formatted(date: .abbreviated, time: .shortened)) · \(Self.timestamp(duration))\n"
        if !notes.isEmpty { output += "\n## Compte rendu · à relire\n\n\(notes)\n" }
        return output + "\n## Transcription\n\n" + transcript + "\n"
    }
    public var srt: String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Self.subtitleTimestamp(segment.start)) --> \(Self.subtitleTimestamp(max(segment.end, segment.start + 0.01)))\n\(speakerName(segment)): \(segment.text.replacingOccurrences(of: "\n", with: " "))\n"
        }.joined(separator: "\n")
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
    private static func subtitleTimestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int((max(0, seconds) * 1000).rounded()) : 0
        return String(format: "%02d:%02d:%02d,%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }
}
