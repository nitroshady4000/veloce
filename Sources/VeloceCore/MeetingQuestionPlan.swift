import Foundation

/// Small local retrieval, no embedding model and no extra model cache.
public enum MeetingQuestionPlan {
    public struct Evidence: Sendable {
        public let meetingID: UUID
        public let title: String
        public let start: Double
        public let text: String
        public let isNotes: Bool
        public var reference: String { "\(title) · \(isNotes ? "compte rendu" : MeetingRecord.timestamp(start))" }
    }

    public static func retrieve(question: String, records: [MeetingRecord], maximumUTF8Bytes: Int = 1_800) -> [Evidence] {
        let terms = tokens(question)
        let stop: Set<String> = ["les", "des", "une", "dans", "pour", "avec", "est", "sont", "quoi", "que", "quel", "quelle", "quelles", "quels", "qui", "sur", "aux", "nous", "vous", "cette", "ces", "reunion", "reunions", "dit", "qu", "le", "la", "de", "du", "et", "il", "elle", "on", "a", "en", "un"]
        let query = terms.subtracting(stop)
        var candidates: [(Evidence, Int, Int)] = []
        var order = 0
        for record in records {
            var items: [(Double, String, Bool, String?)] = record.segments.map { ($0.start, $0.text, false, record.speakerName($0)) }
            if !record.notes.isEmpty { items.append((0, record.notes, true, nil)) }
            for (start, text, isNotes, speaker) in items {
                for part in MeetingNotesPlan.chunks(text, maximumUTF8Bytes: 500) {
                    let contextual = speaker.map { "\($0) : \(part)" } ?? part
                    let words = tokens(record.title + " " + contextual)
                    let score = query.reduce(0) { sum, term in
                        sum + (words.contains(term) ? 4 : term.count >= 5 && words.contains(where: { $0.hasPrefix(String(term.prefix(5))) }) ? 2 : 0)
                    } + (isNotes ? 1 : 0)
                    let evidence = Evidence(meetingID: record.id, title: record.title, start: start, text: contextual, isNotes: isNotes)
                    candidates.append((evidence, score, order)); order += 1
                }
            }
        }
        candidates.sort { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
        var result: [Evidence] = []
        var bytes = 0
        for (item, _, _) in candidates {
            let cost = item.text.utf8.count + item.reference.utf8.count + 28
            guard bytes + cost <= maximumUTF8Bytes else { continue }
            result.append(item); bytes += cost
            if result.count >= 16 { break }
        }
        return result
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}
