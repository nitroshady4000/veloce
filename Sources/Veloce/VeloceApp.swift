import SwiftUI
import AppKit

@main
struct VeloceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Véloce", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.configure(model) }
                .preferredColorScheme(.light)
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
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "waveform")
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
        Divider()
        Text("Maintenir Fn pour dicter")
        if let latest = model.history.first { Button("Copier le dernier texte") { model.copyTranscript(latest.text) } }
        Divider()
        Button("Quitter Véloce") { model.shutdown(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var panel: NSPanel?
    func configure(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.onHUDVisibility = { [weak self] visible in self?.showHUD(visible) }
    }
    private func showHUD(_ visible: Bool) {
        guard visible, let model else { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: RecordingHUDView().environmentObject(model).preferredColorScheme(.light))
            self.panel = panel
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.minY + 28))
        }
        panel?.orderFrontRegardless()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
