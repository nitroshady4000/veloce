import XCTest
@testable import VeloceCore

final class DictationTextPlanTests: XCTestCase {
    func testSnippetRequiresWholeUtteranceAndPreservesReplacementWhitespace() {
        let snippets = [VoiceSnippet(phrase: "ma signature", text: "Cédric\nVéloce\n")]
        XCTAssertEqual(DictationTextPlan.snippet(for: "Ma signature !", in: snippets), "Cédric\nVéloce\n")
        XCTAssertNil(DictationTextPlan.snippet(for: "Ajoute ma signature au document", in: snippets))
    }

    func testAmbiguousOrEmptySnippetsNeverExpand() {
        let snippets = [VoiceSnippet(phrase: "Résumé", text: "premier"), VoiceSnippet(phrase: "resume", text: "second")]
        XCTAssertNil(DictationTextPlan.snippet(for: "résumé", in: snippets))
        XCTAssertNil(DictationTextPlan.snippet(for: "", in: [VoiceSnippet(phrase: "", text: "danger")]))
        XCTAssertNil(DictationTextPlan.snippet(for: "signature", in: [VoiceSnippet(phrase: "signature", text: " \n")]))
    }

    func testOldHistoryDecodesAndRawTextSurvivesRoundTrip() throws {
        let old = #"{"id":"67AFF05F-4BC5-40E1-9220-99BF12A8B992","date":0,"text":"Bonjour","model":"qwen3-0.6b","duration":1,"latency":0.2}"#
        let saved = try JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        XCTAssertNil(saved.rawText)
        let clean = Transcript(text: "Bonjour.", model: .balanced, duration: 1, latency: 0.3, rawText: "Euh bonjour")
        let restored = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(clean))
        XCTAssertEqual(restored.rawText, "Euh bonjour")
        XCTAssertEqual(restored.text, "Bonjour.")
    }
}
