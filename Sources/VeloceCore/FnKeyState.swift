import Foundation

/// CGEvent source user data used to identify Veloce's synthetic paste keystrokes.
public enum VeloceEventSourceUserData {
    public static let textInserterPaste: Int64 = 0x56454C4F434550 // "VELOCEP"
}

/// Hold to talk, or double-tap Fn to keep listening. Kept independent from macOS.
public struct FnKeyState: Sendable {
    public enum Event: Sendable {
        case fnChanged(isDown: Bool, otherModifiers: Bool)
        case keyDown(code: Int64, sourceUserData: Int64 = 0)
        case modifiersChanged(otherModifiers: Bool)
        case interrupted
        case releaseDeadline
    }

    public enum Action: Equatable, Sendable { case press, release, cancel, handsFree }

    public struct Outcome: Equatable, Sendable {
        public let action: Action?
        public let suppressEvent: Bool

        public init(action: Action? = nil, suppressEvent: Bool = false) {
            self.action = action
            self.suppressEvent = suppressEvent
        }
    }

    private var fnIsDown = false
    private var recording = false
    private var combinationInProgress = false
    private var handsFree = false
    private var pressedAt: TimeInterval = 0
    public private(set) var pendingReleaseAt: TimeInterval?
    private let doubleTapEnabled: Bool
    public static let doubleTapInterval: TimeInterval = 0.30
    public static let tapDuration: TimeInterval = 0.22

    public init(doubleTapEnabled: Bool = false) { self.doubleTapEnabled = doubleTapEnabled }

    public mutating func handle(_ event: Event, at time: TimeInterval = 0) -> Outcome {
        switch event {
        case let .fnChanged(isDown, otherModifiers):
            guard isDown != fnIsDown else {
                return Outcome(suppressEvent: !combinationInProgress)
            }
            fnIsDown = isDown
            if isDown {
                combinationInProgress = otherModifiers
                guard !otherModifiers else { return Outcome() }
                if handsFree {
                    handsFree = false
                    recording = false
                    return Outcome(action: .release, suppressEvent: true)
                }
                if let deadline = pendingReleaseAt, time <= deadline {
                    pendingReleaseAt = nil
                    handsFree = true
                    return Outcome(action: .handsFree, suppressEvent: true)
                }
                pendingReleaseAt = nil
                pressedAt = time
                recording = true
                return Outcome(action: .press, suppressEvent: true)
            }
            let wasCombination = combinationInProgress
            combinationInProgress = false
            if handsFree { return Outcome(suppressEvent: !wasCombination) }
            if recording && !wasCombination && doubleTapEnabled && time - pressedAt <= Self.tapDuration {
                pendingReleaseAt = time + Self.doubleTapInterval
                return Outcome(suppressEvent: true)
            }
            let action: Action? = recording ? .release : nil
            recording = false
            return Outcome(action: action, suppressEvent: !wasCombination)

        case let .keyDown(code, sourceUserData)
            where code == 9 && sourceUserData == VeloceEventSourceUserData.textInserterPaste:
            return Outcome()

        case let .keyDown(code, _) where fnIsDown:
            if code == 53 && recording {
                recording = false
                pendingReleaseAt = nil
                handsFree = false
                return Outcome(action: .cancel, suppressEvent: true)
            }
            combinationInProgress = true
            let action: Action? = recording ? .cancel : nil
            recording = false
            pendingReleaseAt = nil
            handsFree = false
            return Outcome(action: action)

        case let .modifiersChanged(otherModifiers) where fnIsDown && otherModifiers:
            combinationInProgress = true
            let action: Action? = recording ? .cancel : nil
            recording = false
            pendingReleaseAt = nil
            handsFree = false
            return Outcome(action: action)

        case let .keyDown(code, _) where recording && (code == 53 || pendingReleaseAt != nil):
            recording = false
            handsFree = false
            pendingReleaseAt = nil
            return Outcome(action: .cancel, suppressEvent: code == 53)

        case .releaseDeadline:
            guard pendingReleaseAt != nil, !fnIsDown, recording else { return Outcome() }
            pendingReleaseAt = nil
            recording = false
            return Outcome(action: .release)

        case .interrupted:
            return Outcome(action: reset())

        default:
            return Outcome()
        }
    }

    @discardableResult
    public mutating func reset() -> Action? {
        let action: Action? = recording ? .cancel : nil
        fnIsDown = false
        recording = false
        combinationInProgress = false
        handsFree = false
        pendingReleaseAt = nil
        return action
    }
}
