import AppKit
import ApplicationServices
import VeloceCore

/// Watches the physical Fn/Globe key on the main run loop.
/// The event tap suppresses Fn-only events so macOS does not open its emoji picker.
@MainActor
final class FnKeyMonitor {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var state = FnKeyState()
    private var callbackGeneration = UUID()
    private var deliveredPressActive = false

    var isRunning: Bool {
        guard let eventTap, CFMachPortIsValid(eventTap) else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func start(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> Bool {
        stop()
        guard Self.isTrusted else { return false }
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let suppress = MainActor.assumeIsolated {
                    monitor.handle(type, keyCode: keyCode, flags: flags)
                }
                return suppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            clearCallbacks()
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            clearCallbacks()
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard isRunning else { stop(); return false }
        return true
    }

    func stop() {
        let shouldCancel = state.reset() == .cancel || deliveredPressActive
        deliveredPressActive = false
        callbackGeneration = UUID()
        if shouldCancel { onCancel?() }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        clearCallbacks()
    }

    isolated deinit {
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    private func clearCallbacks() {
        onPress = nil
        onRelease = nil
        onCancel = nil
    }

    private func enqueue(_ action: FnKeyState.Action) {
        let generation = callbackGeneration
        // Permission checks and microphone setup can block. Keep them outside the
        // event-tap callback, preserving the order of press, release and cancellation.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callbackGeneration == generation else { return }
            switch action {
            case .press:
                self.deliveredPressActive = true
                self.onPress?()
            case .release:
                self.deliveredPressActive = false
                self.onRelease?()
            case .cancel:
                self.deliveredPressActive = false
                self.onCancel?()
            }
        }
    }

    private func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A release may have been missed while the tap was disabled.
            if let action = state.handle(.interrupted).action { enqueue(action) }
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        let input: FnKeyState.Event
        if type == .flagsChanged && keyCode == 63 {
            input = .fnChanged(isDown: flags.contains(.maskSecondaryFn), otherModifiers: hasOtherModifiers(flags))
        } else if type == .keyDown {
            input = .keyDown(code: keyCode)
        } else if type == .flagsChanged {
            input = .modifiersChanged(otherModifiers: hasOtherModifiers(flags))
        } else {
            return false
        }
        let outcome = state.handle(input)
        if let action = outcome.action { enqueue(action) }
        return outcome.suppressEvent
    }

    private func hasOtherModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
}
