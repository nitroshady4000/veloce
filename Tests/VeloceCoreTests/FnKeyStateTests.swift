import XCTest
@testable import VeloceCore

final class FnKeyStateTests: XCTestCase {
    private let press = FnKeyState.Event.fnChanged(isDown: true, otherModifiers: false)
    private let release = FnKeyState.Event.fnChanged(isDown: false, otherModifiers: false)

    func testHoldEmitsExactlyOnePressAndReleaseDespiteDuplicateEvents() {
        var state = FnKeyState()
        XCTAssertEqual(state.handle(press), .init(action: .press, suppressEvent: true))
        XCTAssertEqual(state.handle(press), .init(suppressEvent: true))
        XCTAssertEqual(state.handle(release), .init(action: .release, suppressEvent: true))
        XCTAssertNil(state.handle(release).action)
        XCTAssertEqual(state.handle(press).action, .press)
        XCTAssertEqual(state.handle(release).action, .release)
    }

    func testFnWithModifierAlreadyHeldPassesThroughWithoutRecording() {
        var state = FnKeyState()
        XCTAssertEqual(state.handle(.fnChanged(isDown: true, otherModifiers: true)), .init())
        XCTAssertEqual(state.handle(.fnChanged(isDown: true, otherModifiers: true)), .init())
        XCTAssertEqual(state.handle(.keyDown(code: 123)), .init())
        XCTAssertEqual(state.handle(release), .init())
    }

    func testKeyCombinationCancelsOnceAndNeverCommitsOnRelease() {
        var state = FnKeyState()
        _ = state.handle(press)
        XCTAssertEqual(state.handle(.keyDown(code: 123)), .init(action: .cancel))
        XCTAssertEqual(state.handle(.keyDown(code: 123)), .init())
        XCTAssertEqual(state.handle(release), .init())
        XCTAssertEqual(state.handle(press).action, .press)
    }

    func testEscapeCancelsAndSuppressesTheKeyAndFnRelease() {
        var state = FnKeyState()
        _ = state.handle(press)
        XCTAssertEqual(state.handle(.keyDown(code: 53)), .init(action: .cancel, suppressEvent: true))
        XCTAssertEqual(state.handle(release), .init(suppressEvent: true))
    }

    func testModifierPressedMidDictationCancelsWithoutRestarting() {
        var state = FnKeyState()
        _ = state.handle(press)
        XCTAssertEqual(state.handle(.modifiersChanged(otherModifiers: true)).action, .cancel)
        XCTAssertNil(state.handle(.modifiersChanged(otherModifiers: false)).action)
        XCTAssertNil(state.handle(release).action)
    }

    func testInterruptedTapCancelsAndDoesNotCommitAnOrphanRelease() {
        var state = FnKeyState()
        _ = state.handle(press)
        XCTAssertEqual(state.handle(.interrupted).action, .cancel)
        XCTAssertNil(state.handle(.interrupted).action)
        XCTAssertNil(state.handle(release).action)
        XCTAssertEqual(state.handle(press).action, .press)
        XCTAssertEqual(state.handle(release).action, .release)
    }

    func testKeysOutsideFnAreUnaffectedAndResetIsIdempotent() {
        var state = FnKeyState()
        XCTAssertEqual(state.handle(.keyDown(code: 53)), .init())
        XCTAssertEqual(state.handle(.modifiersChanged(otherModifiers: true)), .init())
        _ = state.handle(press)
        XCTAssertEqual(state.reset(), .cancel)
        XCTAssertNil(state.reset())
        XCTAssertNil(state.handle(release).action)
    }

    func testDoubleTapLatchesUntilNextFnAndAllowsOrdinaryTyping() {
        var state = FnKeyState(doubleTapEnabled: true)
        XCTAssertEqual(state.handle(press, at: 10).action, .press)
        XCTAssertNil(state.handle(release, at: 10.1).action)
        XCTAssertEqual(state.pendingReleaseAt ?? 0, 10.4, accuracy: 0.001)
        XCTAssertEqual(state.handle(press, at: 10.25).action, .handsFree)
        XCTAssertNil(state.pendingReleaseAt)
        XCTAssertNil(state.handle(release, at: 10.3).action)
        XCTAssertEqual(state.handle(.keyDown(code: 0), at: 11), .init())
        XCTAssertEqual(state.handle(press, at: 12).action, .release)
        XCTAssertNil(state.handle(release, at: 12.1).action)
    }

    func testLongHoldStillFinishesImmediately() {
        var state = FnKeyState(doubleTapEnabled: true)
        XCTAssertEqual(state.handle(press, at: 1).action, .press)
        XCTAssertEqual(state.handle(release, at: 2).action, .release)
        XCTAssertNil(state.pendingReleaseAt)
    }

    func testSingleTapDeadlineFinishesExactlyOnce() {
        var state = FnKeyState(doubleTapEnabled: true)
        _ = state.handle(press, at: 1)
        _ = state.handle(release, at: 1.1)
        XCTAssertEqual(state.handle(.releaseDeadline, at: 1.4).action, .release)
        XCTAssertNil(state.handle(.releaseDeadline, at: 2).action)
        XCTAssertEqual(state.handle(press, at: 3).action, .press)
    }

    func testEscapeCancelsHandsFreeWithoutFnHeld() {
        var state = FnKeyState(doubleTapEnabled: true)
        _ = state.handle(press, at: 1)
        _ = state.handle(release, at: 1.1)
        _ = state.handle(press, at: 1.2)
        _ = state.handle(release, at: 1.3)
        XCTAssertEqual(state.handle(.keyDown(code: 53)), .init(action: .cancel, suppressEvent: true))
        XCTAssertNil(state.handle(.releaseDeadline).action)
        XCTAssertNil(state.reset())
    }

    func testTypingDuringPendingDoubleTapCancelsAndPassesTheKeyThrough() {
        var state = FnKeyState(doubleTapEnabled: true)
        _ = state.handle(press, at: 1)
        _ = state.handle(release, at: 1.1)
        XCTAssertEqual(state.handle(.keyDown(code: 0)), .init(action: .cancel))
        XCTAssertNil(state.pendingReleaseAt)
        XCTAssertNil(state.handle(.releaseDeadline).action)
    }

    func testOwnPasteIsIgnoredDuringCaptureButFnVAndEscapeStillCancel() {
        var state = FnKeyState()
        _ = state.handle(press)
        XCTAssertEqual(
            state.handle(.keyDown(code: 9, sourceUserData: VeloceEventSourceUserData.textInserterPaste)),
            .init()
        )
        XCTAssertEqual(state.handle(.keyDown(code: 9)), .init(action: .cancel))

        _ = state.handle(release)
        _ = state.handle(press)
        XCTAssertEqual(state.handle(.keyDown(code: 53)), .init(action: .cancel, suppressEvent: true))
    }

    func testOwnPasteDoesNotCancelPendingDoubleTap() {
        var state = FnKeyState(doubleTapEnabled: true)
        _ = state.handle(press, at: 1)
        _ = state.handle(release, at: 1.1)

        XCTAssertEqual(
            state.handle(.keyDown(code: 9, sourceUserData: VeloceEventSourceUserData.textInserterPaste), at: 1.2),
            .init()
        )
        XCTAssertEqual(state.pendingReleaseAt ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(state.handle(.releaseDeadline, at: 1.4).action, .release)
    }
}
