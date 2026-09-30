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
}
