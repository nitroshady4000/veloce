/// The hold-to-talk lifecycle, separated from the macOS event tap for deterministic tests.
public struct FnKeyState: Sendable {
    public enum Event: Sendable {
        case fnChanged(isDown: Bool, otherModifiers: Bool)
        case keyDown(code: Int64)
        case modifiersChanged(otherModifiers: Bool)
        case interrupted
    }

    public enum Action: Equatable, Sendable { case press, release, cancel }

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

    public init() {}

    public mutating func handle(_ event: Event) -> Outcome {
        switch event {
        case let .fnChanged(isDown, otherModifiers):
            guard isDown != fnIsDown else {
                return Outcome(suppressEvent: !combinationInProgress)
            }
            fnIsDown = isDown
            if isDown {
                combinationInProgress = otherModifiers
                guard !otherModifiers else { return Outcome() }
                recording = true
                return Outcome(action: .press, suppressEvent: true)
            }
            let wasCombination = combinationInProgress
            combinationInProgress = false
            let action: Action? = recording ? .release : nil
            recording = false
            return Outcome(action: action, suppressEvent: !wasCombination)

        case let .keyDown(code) where fnIsDown:
            if code == 53 && recording {
                recording = false
                return Outcome(action: .cancel, suppressEvent: true)
            }
            combinationInProgress = true
            let action: Action? = recording ? .cancel : nil
            recording = false
            return Outcome(action: action)

        case let .modifiersChanged(otherModifiers) where fnIsDown && otherModifiers:
            combinationInProgress = true
            let action: Action? = recording ? .cancel : nil
            recording = false
            return Outcome(action: action)

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
        return action
    }
}
