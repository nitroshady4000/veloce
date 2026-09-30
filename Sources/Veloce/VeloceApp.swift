import SwiftUI
import AppKit

struct VeloceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    @MainActor init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // Services may arrive before the main window appears. Their queue must
        // have a model before applicationDidFinishLaunching registers it.
        delegate.configure(model)
    }

    var body: some Scene {
        Window("Véloce", id: "main") {
            ContentView()
                .environmentObject(model)
                .background(AppWindowBridge(model: model, delegate: delegate))
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Charger le modèle") { model.prepareModel() }.disabled(model.isBusy)
            }
        }
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuGlyph(phase: PillPhase(appPhase: model.phase), level: model.level)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Véloce · \(model.loadedModel?.name ?? "Modèle non chargé")")
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
        Text(model.isDictationProcessing && model.canStartDictation ? "Fn pour dicter la suite" : "Maintenir Fn pour dicter")
        if let latest = model.history.first { Button("Copier le dernier texte") { model.copyTranscript(latest.text) } }
        Divider()
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
            self?.showHUD(model.presentationMode == .pill && (model.isRecording || model.phase == .transcribing))
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
    private func showHUD(_ visible: Bool) {
        guard visible, let model, model.presentationMode == .pill else { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: PillLayout.canvas), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: RecordingHUDView().environmentObject(model).preferredColorScheme(.dark))
            self.panel = panel
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - PillLayout.canvas.width / 2,
                                         y: screen.visibleFrame.minY + PillLayout.bottom - PillLayout.margin + PillLayout.bulbOverhang))
        }
        panel?.orderFrontRegardless()
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
