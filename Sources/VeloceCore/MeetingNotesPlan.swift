import Foundation

/// Lossless, bounded pieces for local models with a small context window.
public enum MeetingNotesPlan {
    public static func chunks(_ text: String, maximumUTF8Bytes: Int) -> [String] {
        precondition(maximumUTF8Bytes >= 64)
        let bytes = Array(text.utf8)
        var pieces: [String] = []
        var start = 0
        while start < bytes.count {
            var end = min(start + maximumUTF8Bytes, bytes.count)
            if end < bytes.count {
                // A UTF-8 continuation byte cannot start the next piece.
                while bytes[end] & 0xC0 == 0x80 { end -= 1 }
                // Keep complete paragraphs/turns when the split is nearby.
                let halfway = start + (end - start) / 2
                if let newline = bytes[halfway..<end].lastIndex(of: 10) {
                    end = newline + 1
                } else if let space = bytes[halfway..<end].lastIndex(of: 32) {
                    end = space + 1
                }
            }
            pieces.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end
        }
        return pieces
    }
}
