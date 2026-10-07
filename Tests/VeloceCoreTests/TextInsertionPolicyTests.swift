import Foundation
import XCTest
@testable import VeloceCore

final class TextInsertionPolicyTests: XCTestCase {
    func testUnrelatedValueUpdateCannotAcknowledgePasteOfExistingText() {
        let captured = TextInputSnapshot(value: "hello")
        XCTAssertFalse(TextInsertionPolicy.observesPaste(captured: captured, currentValue: "hello world", text: "hello"))
        XCTAssertTrue(TextInsertionPolicy.observesPaste(captured: captured, currentValue: "hello again", text: " again"))
    }

    func testExactReplacementCanBeAcknowledgedWithoutCurrentCaretMetadata() {
        let captured = TextInputSnapshot(selection: NSRange(location: 4, length: 3), selectedText: "old", value: "The old text")
        XCTAssertTrue(TextInsertionPolicy.observesPaste(captured: captured, currentValue: "The new text", text: "new"))
        XCTAssertFalse(TextInsertionPolicy.observesPaste(captured: captured, currentValue: "The old text, new", text: "new"))
    }

    private func allows(
        captured: TextInputSnapshot = TextInputSnapshot(),
        current: TextInputSnapshot = TextInputSnapshot(),
        sameApplication: Bool = true,
        sameElement: Bool? = true,
        sameWindow: Bool? = true,
        userInteracted: Bool = false,
        secureInput: Bool = false,
        requiresSelectedText: Bool = false
    ) -> Bool {
        TextInsertionPolicy.allowsPaste(
            sameApplication: sameApplication,
            sameElement: sameElement,
            sameWindow: sameWindow,
            userInteracted: userInteracted,
            secureInput: secureInput,
            captured: captured,
            current: current,
            requiresSelectedText: requiresSelectedText
        )
    }

    func testAllowsAccessibilitySnapshotsWithoutSelectionRanges() {
        XCTAssertTrue(allows(
            captured: TextInputSnapshot(selectedText: "hello", value: "hello world"),
            current: TextInputSnapshot(selectedText: "hello", value: "hello world")
        ))
    }

    func testAllowsMissingAccessibilityMetadataWhenTargetRemainsActive() {
        XCTAssertTrue(allows(
            captured: TextInputSnapshot(selection: NSRange(location: 2, length: 0), value: "before"),
            current: TextInputSnapshot(selection: NSRange(location: 2, length: 0), value: "before after"),
            sameElement: nil,
            sameWindow: nil
        ))
    }

    func testRejectsSelectionChanges() {
        XCTAssertFalse(allows(
            captured: TextInputSnapshot(selection: NSRange(location: 1, length: 3), selectedText: "old", value: "old text"),
            current: TextInputSnapshot(selection: NSRange(location: 1, length: 3), selectedText: "new", value: "new text")
        ))
        XCTAssertFalse(allows(
            captured: TextInputSnapshot(selection: NSRange(location: 1, length: 3)),
            current: TextInputSnapshot(selection: NSRange(location: 2, length: 3))
        ))
    }

    func testRejectsKeyboardInteractionAndSecureInput() {
        XCTAssertFalse(allows(userInteracted: true))
        XCTAssertFalse(allows(secureInput: true))
        XCTAssertFalse(allows(sameApplication: false))
        XCTAssertFalse(allows(sameElement: false))
        XCTAssertFalse(allows(sameWindow: false))
    }

    func testDistinguishesCaretInsertionFromReplacingSelectedText() {
        let caret = NSRange(location: 4, length: 0)
        XCTAssertTrue(allows(
            captured: TextInputSnapshot(selection: caret, value: "before"),
            current: TextInputSnapshot(selection: caret, value: "before with script change")
        ))

        let selected = TextInputSnapshot(
            selection: NSRange(location: 4, length: 3),
            selectedText: "old",
            value: "some old text"
        )
        XCTAssertTrue(allows(captured: selected, current: selected))
        XCTAssertFalse(allows(
            captured: selected,
            current: TextInputSnapshot(selection: selected.selection, selectedText: "new", value: "some new text")
        ))
    }

    func testAllowsAjaxValueChangesWhenCaretIsStable() {
        let caret = NSRange(location: 5, length: 0)
        XCTAssertTrue(allows(
            captured: TextInputSnapshot(selection: caret, selectedText: "", value: "initial"),
            current: TextInputSnapshot(selection: caret, selectedText: "", value: "server-updated value")
        ))
    }

    func testRewriteRequiresVisibleUnchangedSelectionAndRange() {
        let selected = TextInputSnapshot(
            selection: NSRange(location: 2, length: 4),
            selectedText: "word",
            value: "a word here"
        )
        XCTAssertTrue(allows(captured: selected, current: selected, requiresSelectedText: true))
        XCTAssertFalse(allows(
            captured: TextInputSnapshot(selectedText: "word", value: "a word here"),
            current: TextInputSnapshot(selectedText: "word", value: "a word here"),
            requiresSelectedText: true
        ))
        XCTAssertFalse(allows(
            captured: selected,
            current: TextInputSnapshot(selection: nil, selectedText: "word", value: "a word here"),
            requiresSelectedText: true
        ))
        XCTAssertFalse(allows(
            captured: selected,
            current: TextInputSnapshot(selection: selected.selection, selectedText: "word", value: "changed"),
            requiresSelectedText: true
        ))
    }
}
