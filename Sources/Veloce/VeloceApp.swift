import SwiftUI
import AppKit

struct VeloceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var updates: UpdateController
    @StateObject private var login = LaunchAtLoginController()

    @MainActor init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _updates = StateObject(wrappedValue: UpdateController(isBusy: { [weak model] in model?.isBusy == true }))
        // Services may arrive before the main window appears. Their queue must
        // have a model before applicationDidFinishLaunching registers it.
        delegate.configure(model)
    }

    var body: some Scene {
        Window("Véloce", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .environmentObject(login)
                .background(AppWindowBridge(model: model, delegate: delegate))
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Rechercher une mise à jour…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates || model.isBusy)
                Divider()
                Button("Charger le modèle") { model.prepareModel() }.disabled(model.isBusy)
            }
        }
        MenuBarExtra {
            MenuContent().environmentObject(model).environmentObject(updates)
        } label: {
            MenuGlyph(phase: model.modelPreparationNotice == .failed ? .failure : PillPhase(appPhase: model.phase),
                      level: model.level,
                      statusLabel: model.phase == .preparing ? "Véloce : préchauffe du modèle" : nil)
            if model.presentationMode == .menuBar, let notice = model.modelPreparationNotice {
                switch notice {
                case .loading: Text("Préchauffe…")
                case .ready: Text("Prêt · Fn pour dicter")
                case .failed: Text("Chargement impossible")
                }
            }
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Véloce · \(model.loadedModel?.name ?? "Modèle non chargé")")
        if model.phase == .preparing { Text("Préchauffe du modèle…") }
        Button("Ouvrir Véloce") {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        if !model.engineReady {
            Button("Charger \(model.selectedModel.title)") { model.prepareModel() }.disabled(model.isBusy)
        }
        if model.isRecording { Button("Annuler la dictée") { model.cancel() } }
        if model.isDictationProcessing {
            Text("\(model.pendingDictationCount) dictée\(model.pendingDictationCount > 1 ? "s" : "") en cours")
            if model.pendingDictationCount > 1 {
                Button("Annuler les dictées en attente") { model.cancelPendingDictations() }
            }
        }
        Button("Réécrire ou traduire une sélection…") { model.showTextProcessing() }.disabled(model.isBusy)
        Divider()
        Text(model.phase == .preparing ? "Patientez avant de parler" :
             model.isDictationProcessing && model.canStartDictation ? "Fn pour dicter la suite" : "Maintenir Fn pour dicter")
        if let latest = model.history.first { Button("Copier le dernier texte") { model.copyTranscript(latest.text) } }
        Divider()
        Button("Rechercher une mise à jour…", action: updates.checkForUpdates)
            .disabled(!updates.canCheckForUpdates || model.isBusy)
        Button("Quitter Véloce") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct AppWindowBridge: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
            delegate.configure(model)
        }
    }
}

extension Notification.Name {
    static let veloceShowMeetings = Notification.Name("VeloceShowMeetings")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private let hudStage: PillStage = {
        let stage = PillStage()
        stage.presence = 0
        return stage
    }()
    /// Bumped at every show and hide: a fade that ends late never hides a newer pill.
    private var hudGeneration = 0
    private var terminating = false
    private let finderService = FinderTranscriptionService()
    private var pendingFiles: [([URL], String?)] = []
    private var pendingWindowRequest = false
    var openMainWindow: (() -> Void)? {
        didSet {
            if pendingWindowRequest, let openMainWindow {
                pendingWindowRequest = false
                openMainWindow()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finderService.onFiles = { [weak self] urls, format in self?.importFromFinder(urls, format: format) }
        NSApp.servicesProvider = finderService
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        importFromFinder(urls, format: nil)
    }

    func configure(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.onHUDVisibility = { [weak self] visible in self?.showHUD(visible) }
        model.onPresentationModeChange = { [weak self, weak model] _ in
            guard let model else { return }
            self?.showHUD(model.presentationMode == .pill &&
                         (model.isRecording || model.phase == .transcribing || model.modelPreparationNotice != nil))
        }
        model.meetings.onShowMeetings = { [weak self] in self?.showMeetings() }
        for (urls, format) in pendingFiles { importFromFinder(urls, format: format) }
        pendingFiles.removeAll()
    }

    private func importFromFinder(_ urls: [URL], format: String?) {
        let urls = urls.filter(FinderTranscriptionService.supports)
        guard !urls.isEmpty else { return }
        guard let model else { pendingFiles.append((urls, format)); return }
        showMeetings()
        model.meetings.enqueueImports(urls, model: model.selectedModel, language: model.language,
                                     vocabulary: model.vocabulary, sidecarFormat: format ?? model.finderExportFormat)
    }

    private func showMeetings() {
        model?.meetings.navigationRequested = true
        if let openMainWindow { openMainWindow() }
        else { pendingWindowRequest = true }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .veloceShowMeetings, object: nil)
    }
    /// Famulus' drop: placed once per appearance at a constant size, it swells
    /// in, and fades out (150 ms) before the panel is ordered out. A pill that
    /// is leaving comes back without a new entrance.
    private func showHUD(_ visible: Bool) {
        guard visible, let model, model.presentationMode == .pill else { hideHUD(); return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if panel == nil {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: PillLayout.canvas), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear
            // As Famulus: the glass draws its own depth; a window shadow would box the halo.
            panel.hasShadow = false; panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            let hosting = NSHostingView(rootView: RecordingHUDView(stage: hudStage).environmentObject(model).preferredColorScheme(.dark))
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.panel = panel
        }
        guard let panel else { return }
        hudGeneration += 1
        if panel.isVisible {
            guard hudStage.leaving else { return }
            hudStage.leaving = false
            if reduceMotion { hudStage.presence = 1 } else { withAnimation(Motion.appear) { hudStage.presence = 1 } }
            return
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel.setFrame(NSRect(x: (screen.visibleFrame.midX - PillLayout.canvas.width / 2).rounded(),
                                  y: screen.visibleFrame.minY + PillLayout.bottom - PillLayout.margin + PillLayout.bulbOverhang,
                                  width: PillLayout.canvas.width, height: PillLayout.canvas.height), display: false)
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            hudStage.leaving = false
            hudStage.presence = reduceMotion ? 1 : 0
        }
        panel.orderFrontRegardless()
        if !reduceMotion { withAnimation(Motion.appear) { hudStage.presence = 1 } }
    }

    private func hideHUD() {
        guard let panel, panel.isVisible, !hudStage.leaving else { return }
        hudGeneration += 1
        let current = hudGeneration
        let finish = { [weak self] in
            guard let self, self.hudGeneration == current else { return }
            panel.orderOut(nil)
            self.hudStage.leaving = false
            self.model?.clearLivePreview()
        }
        hudStage.leaving = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish(); return }
        withAnimation(Motion.disappear, completionCriteria: .logicallyComplete) {
            hudStage.presence = 0
        } completion: { finish() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.meetingBusy else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.meetings.finishForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
