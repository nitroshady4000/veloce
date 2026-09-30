import AppKit
import AVFoundation
import ApplicationServices

enum VelocePermission: String, Identifiable, CaseIterable {
    case microphone, accessibility
    var id: String { rawValue }
}

enum MicrophonePermission: Equatable {
    case notDetermined, denied, restricted, granted
}

/// Native permission requests live here. Merely opening the guide never prompts.
@MainActor
final class PermissionCoordinator {
    struct Snapshot {
        let microphone: MicrophonePermission
        let accessibility: Bool
    }

    func snapshot() -> Snapshot {
        let microphone: MicrophonePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: microphone = .notDetermined
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        case .authorized: microphone = .granted
        @unknown default: microphone = .restricted
        }
        return Snapshot(microphone: microphone, accessibility: AXIsProcessTrusted())
    }

    func requestMicrophone() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // The native alert offers its own Settings button. Do not also open
        // Settings here: that obscures the alert and leaves two competing flows.
    }

    @discardableResult
    func openSettings(for permission: VelocePermission) -> Bool {
        let pane = permission == .microphone ? "Privacy_Microphone" : "Privacy_Accessibility"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
