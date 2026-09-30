import XCTest
@testable import VeloceCore

final class MeetingTests: XCTestCase {
    func testOlderSavedMeetingsRemainRecordingsAndImportKeepsProvenance() throws {
        let record = MeetingRecord(title: "Ancienne réunion")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "originalFilename")
        let legacy = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.isImported)
        var imported = legacy
        imported.originalFilename = "Entretien.m4a"
        imported.status = .recorded
        let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(imported))
        XCTAssertTrue(restored.isImported)
        XCTAssertEqual(restored.originalFilename, "Entretien.m4a")
        XCTAssertEqual(restored.status, .recorded)
    }

    func testExportsPreserveSpeakersOverlapAndHourBoundary() throws {
        var record = MeetingRecord(title: "Planning")
        record.duration = 3601
        record.segments = [
            MeetingSegment(id: "a", start: 3599.9996, end: 3601.2, speaker: "Interlocuteur 1", source: "system", text: "Livrer\ndemain."),
            MeetingSegment(id: "b", start: 3600.1, end: 3600.8, speaker: "Vous", source: "microphone", text: "D’accord.")
        ]
        record.speakerNames["Interlocuteur 1"] = "Camille"
        XCTAssertTrue(record.srt.contains("01:00:00,000 --> 01:00:01,200"))
        XCTAssertTrue(record.srt.contains("Camille: Livrer demain."))
        XCTAssertTrue(record.srt.contains("01:00:00,100 --> 01:00:00,800"))
        XCTAssertTrue(record.transcript.contains("Camille : Livrer\ndemain."))
        XCTAssertTrue(record.markdown.contains("1:00:01"))
        XCTAssertEqual(try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record)).segments, record.segments)
    }

    func testSearchFindsCorrectedNamesAndNotesWithoutAccents() {
        var record = MeetingRecord(title: "Réunion équipe")
        record.notes = "Décision : livrer vendredi"
        record.segments = [MeetingSegment(id: "1", start: 3, end: 5, speaker: "Voix 1", source: "system", text: "Prévoir la réunion de suivi.")]
        record.speakerNames["Voix 1"] = "Cédric"
        XCTAssertTrue(record.matches("CEDRIC REUNION"))
        XCTAssertTrue(record.matches("decision vendredi"))
        XCTAssertFalse(record.matches("vendredi inconnu"))
        XCTAssertTrue(record.matches("  "))
    }

    func testEditingAndMergingKeepOriginalTimelinesAndTracks() {
        var record = MeetingRecord(title: "Planning")
        record.segments = [
            MeetingSegment(id: "1", start: 3, end: 5, speaker: "Voix 1", source: "system", text: "Ancien texte"),
            MeetingSegment(id: "2", start: 4, end: 6, speaker: "Vous", source: "microphone", text: "Oui"),
            MeetingSegment(id: "3", start: 8, end: 9, speaker: "Voix 2", source: "system", text: "D’accord")
        ]
        record.speakerNames = ["Voix 1": "Erreur", "Voix 2": "Camille"]
        record.editSegment("1", text: " Nouveau texte ", speaker: "Voix 2")
        XCTAssertEqual(record.segments[0].text, "Nouveau texte")
        XCTAssertEqual(record.segments[0].start, 3)
        XCTAssertEqual(record.segments[0].source, "system")
        record.mergeSpeaker("Vous", into: "Voix 2")
        XCTAssertEqual(record.segments[1].speaker, "Voix 2")
        XCTAssertEqual(record.segments[1].source, "microphone")
        XCTAssertEqual(record.segments[1].end, 6)
        XCTAssertEqual(record.speakers, ["Voix 2"])
        XCTAssertTrue(record.transcript.contains("Camille"))
        XCTAssertTrue(record.vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(record.vtt.contains("00:00:03.000 --> 00:00:05.000"))
    }

    func testMeetingEngineReplyKeepsProgressAndStructuredSegments() throws {
        let progress = try JSONDecoder().decode(EngineReply.self, from: Data(#"{"event":"meeting_progress","progress":0.5,"detail":"Piste système"}"#.utf8))
        XCTAssertEqual(progress.progress, 0.5)
        let reply = try JSONDecoder().decode(EngineReply.self, from: Data(#"{"id":"meeting","result":{"duration":60,"diarization":"speakers","segments":[{"id":"s1","start":1,"end":3,"speaker":"Vous","source":"microphone","text":"Bonjour."}]}}"#.utf8))
        XCTAssertEqual(reply.result?.segments?.first?.source, "microphone")
        XCTAssertEqual(reply.result?.duration, 60)
    }
}
