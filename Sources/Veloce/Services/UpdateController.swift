import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var statusMessage: String?

    private var controller: SPUStandardUpdaterController!
    private let isBusy: () -> Bool
    private var deferredInstall: Task<Void, Never>?

    var automaticUpdatesEnabled: Bool { automaticallyChecks && automaticallyDownloads }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard !isBusy(), canCheckForUpdates else { return }
        statusMessage = "Recherche de mises à jour…"
        controller.checkForUpdates(nil)
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        // Sparkle owns these persisted preferences. Info.plist supplies defaults.
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusMessage = "Version \(item.displayVersionString) disponible."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        statusMessage = "Aucune nouvelle version disponible."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle uses a dedicated error when a successful check finds no update.
        if (error as NSError).code == Int(SUError.noUpdateError.rawValue) {
            statusMessage = "Aucune nouvelle version disponible."
        } else { statusMessage = error.localizedDescription }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        statusMessage = "La mise à jour attend la fin du traitement en cours."
        deferredInstall = Task { @MainActor [weak self] in
            while let self, self.isBusy() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            guard self != nil, !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}
