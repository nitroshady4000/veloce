import XCTest
@testable import VeloceCore

final class MeetingNotesPlanTests: XCTestCase {
    func testLongMeetingKeepsEveryByteIncludingFinalDecision() {
        let text = String(repeating: "[00:12] Locuteur 2 : discutons du sujet.\n", count: 800)
            + "[59:58] Décision finale : déployer vendredi."
        let parts = MeetingNotesPlan.chunks(text, maximumUTF8Bytes: 600)
        XCTAssertGreaterThan(parts.count, 10)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertTrue(parts.last!.contains("déployer vendredi"))
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 600 })
    }

    func testMultibyteTextAndUnbrokenLinesRemainValidUTF8() {
        let text = String(repeating: "é漢字🧑🏽‍💻", count: 400)
        let parts = MeetingNotesPlan.chunks(text, maximumUTF8Bytes: 127)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertFalse(parts.joined().contains("\u{FFFD}"))
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 127 })
    }

    func testNearbyTurnBoundaryPreferredAndWhitespacePreserved() {
        let turn = "Une phrase assez longue et quelques mots.\n"
        let text = turn + turn + "Dernière phrase.  \n"
        let parts = MeetingNotesPlan.chunks(text, maximumUTF8Bytes: 90)
        XCTAssertEqual(parts.first, turn + turn)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertEqual(MeetingNotesPlan.chunks("", maximumUTF8Bytes: 64), [])
    }
}
