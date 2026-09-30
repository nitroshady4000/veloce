import XCTest
@testable import VeloceCore

final class DictationPipelineTests: XCTestCase {
    func testCaptureCanOverlapProcessingAndCancelDoesNotCancelFirstJob() {
        var pipeline = DictationPipeline<String>()
        XCTAssertTrue(pipeline.beginCapture())
        pipeline.finishCapture("première")
        XCTAssertEqual(pipeline.startNext(), "première")
        XCTAssertTrue(pipeline.beginCapture())
        pipeline.cancelCapture()
        XCTAssertEqual(pipeline.active, "première")
        XCTAssertEqual(pipeline.count, 1)
        XCTAssertTrue(pipeline.beginCapture())
        pipeline.finishCapture("troisième")
        XCTAssertNil(pipeline.startNext())
        pipeline.completeActive()
        XCTAssertEqual(pipeline.startNext(), "troisième")
    }

    func testBoundedFIFOAndOnlyOneMicrophoneCapture() {
        var pipeline = DictationPipeline<Int>(capacity: 4)
        for value in 1...4 {
            XCTAssertTrue(pipeline.beginCapture())
            XCTAssertFalse(pipeline.beginCapture())
            pipeline.finishCapture(value)
        }
        XCTAssertFalse(pipeline.beginCapture())
        for value in 1...4 {
            XCTAssertEqual(pipeline.startNext(), value)
            XCTAssertNil(pipeline.startNext())
            pipeline.completeActive()
        }
        XCTAssertEqual(pipeline.count, 0)
        XCTAssertTrue(pipeline.beginCapture())
    }

    func testClearingPendingPreservesActiveAndCurrentCapture() {
        var pipeline = DictationPipeline<String>()
        XCTAssertTrue(pipeline.beginCapture())
        pipeline.finishCapture("active")
        _ = pipeline.startNext()
        XCTAssertTrue(pipeline.beginCapture())
        pipeline.finishCapture("en attente")
        XCTAssertTrue(pipeline.beginCapture())
        XCTAssertEqual(pipeline.removePending(), ["en attente"])
        XCTAssertEqual(pipeline.active, "active")
        XCTAssertTrue(pipeline.isCapturing)
        pipeline.finishCapture("nouvelle")
        pipeline.completeActive()
        XCTAssertEqual(pipeline.startNext(), "nouvelle")
    }

    func testCaretAdvanceUsesUTF16AndReplacementLength() {
        let selection = NSRange(location: 2, length: 4)
        XCTAssertEqual(TextInsertionAdvance.caret(afterReplacing: selection, with: "👋é"), NSRange(location: 5, length: 0))
        XCTAssertEqual(TextInsertionAdvance.replacement(in: "abcdefghi", selection: selection, text: "👋é"), "ab👋éghi")
        XCTAssertEqual(TextInsertionAdvance.caret(afterReplacing: NSRange(location: 0, length: 0), with: "a\nb"), NSRange(location: 3, length: 0))
    }

    func testInvalidOrOverflowingRangesNeverRebase() {
        XCTAssertNil(TextInsertionAdvance.caret(afterReplacing: NSRange(location: NSNotFound, length: 0), with: "texte"))
        XCTAssertNil(TextInsertionAdvance.caret(afterReplacing: NSRange(location: Int.max - 1, length: 0), with: "trois"))
        XCTAssertNil(TextInsertionAdvance.replacement(in: "Court", selection: NSRange(location: 4, length: 4), text: "fin"))
    }

    func testConfirmedContinuationAddsOnlyMissingSpacingAtTheCaret() {
        XCTAssertEqual(TextInsertionAdvance.continuation("Comment ça va ?", in: "Bonjour.Suite", at: NSRange(location: 8, length: 0)), " Comment ça va ?")
        XCTAssertEqual(TextInsertionAdvance.continuation("\nDeuxième ligne", in: "Bonjour.", at: NSRange(location: 8, length: 0)), "\nDeuxième ligne")
        XCTAssertEqual(TextInsertionAdvance.continuation(" suite", in: "Bonjour.", at: NSRange(location: 8, length: 0)), " suite")
        XCTAssertEqual(TextInsertionAdvance.continuation("suite", in: "Bonjour. ", at: NSRange(location: 9, length: 0)), "suite")
        XCTAssertEqual(TextInsertionAdvance.continuation(", ensuite", in: "Bonjour", at: NSRange(location: 7, length: 0)), ", ensuite")
        XCTAssertEqual(TextInsertionAdvance.continuation("fin", in: "Court", at: NSRange(location: 30, length: 0)), "fin")
    }
}
