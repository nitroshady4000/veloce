import XCTest
@testable import VeloceCore

final class MeetingQuestionPlanTests: XCTestCase {
    func testRetrievalIndexesRenamedSpeakersAndMeetingTitles() {
        var other = MeetingRecord(title: "Point général")
        other.segments = [MeetingSegment(id: "one", start: 1, end: 2, speaker: "Vous", source: "microphone", text: "Le budget est confirmé.")]
        var target = MeetingRecord(title: "Éclairage du musée")
        target.speakerNames["Interlocuteur 1"] = "Camille"
        target.segments = [MeetingSegment(id: "two", start: 12, end: 13, speaker: "Interlocuteur 1", source: "system", text: "Nous validons les éclairages.")]
        let result = MeetingQuestionPlan.retrieve(question: "Qu’a dit Camille au musée ?", records: [other, target])
        XCTAssertEqual(result.first?.meetingID, target.id)
        XCTAssertTrue(result.first?.text.hasPrefix("Camille :") == true)
    }
    func testSearchFindsFinalDecisionAcrossMeetingsWithinContextBudget() {
        var first = MeetingRecord(title: "Premier point")
        first.segments = (0..<100).map { MeetingSegment(id: String($0), start: Double($0), end: Double($0 + 1), speaker: "A", source: "imported", text: "Discussion sur un autre sujet.") }
        var last = MeetingRecord(title: "Dernier point")
        last.segments = [MeetingSegment(id: "final", start: 3590, end: 3600, speaker: "B", source: "system", text: "Décision : le budget éclairage est validé à mille euros.")]
        let result = MeetingQuestionPlan.retrieve(question: "Quel budget éclairage est validé ?", records: [first, last], maximumUTF8Bytes: 400)
        XCTAssertEqual(result.first?.meetingID, last.id)
        XCTAssertTrue(result.first?.text.contains("mille euros") == true)
        XCTAssertEqual(result.first?.reference, "Dernier point · 59:50")
    }

    func testContextIncludesOnlySavedContentAndHonorsByteLimit() {
        var record = MeetingRecord(title: "Été")
        record.notes = String(repeating: "Un résumé français avec des caractères accentués. ", count: 100)
        let result = MeetingQuestionPlan.retrieve(question: "résumé français", records: [record], maximumUTF8Bytes: 700)
        XCTAssertFalse(result.isEmpty)
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.text.utf8.count + $1.reference.utf8.count + 28 }, 700)
        XCTAssertTrue(result.allSatisfy { record.notes.contains($0.text) })
        XCTAssertTrue(MeetingQuestionPlan.retrieve(question: "budget", records: []).isEmpty)
    }
}
