import Combine
import ServiceManagement

/// Reads and changes the main app's macOS Login Item registration.
/// Registration is only changed in response to an explicit user action.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = enabled
                ? "Impossible d’activer l’ouverture au démarrage. Vérifiez les réglages des éléments d’ouverture, puis réessayez."
                : "Impossible de désactiver l’ouverture au démarrage. Réessayez depuis l’application."
        }

        refresh()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
