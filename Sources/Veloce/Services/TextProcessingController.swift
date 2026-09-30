import AppKit
import SwiftUI

/// A small native editor gives the user a preview before replacing a selection.
@MainActor
final class TextProcessingController: NSObject, NSWindowDelegate {
    var canBegin: () -> Bool = { true }
    var onBusyChange: ((Bool) -> Void)?
    var onVoiceStart: ((TextInstructionHandlers) -> Bool)?
    var onVoiceFinish: (() -> Void)?
    var onVoiceCancel: (() -> Void)?
    private var window: NSWindow?
    private var state: TextProcessingState?
    private let inserter = TextInserter()
    private var target: NSRunningApplication?

    func show() {
        guard canBegin() else { return }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let selectedText = inserter.captureSelectedText(target)
        let state = TextProcessingState(text: selectedText ?? "", canReplace: selectedText != nil)
        state.canBegin = { [weak self] in self?.canBegin() == true }
        state.onBusyChange = { [weak self] busy in self?.onBusyChange?(busy) }
        state.onApply = { [weak self] text in await self?.apply(text) ?? false }
        state.onCopy = { [weak self] text in self?.inserter.copy(text) }
        state.onVoiceStart = { [weak self] handlers in self?.onVoiceStart?(handlers) ?? false }
        state.onVoiceFinish = { [weak self] in self?.onVoiceFinish?() }
        state.onVoiceCancel = { [weak self] in self?.onVoiceCancel?() }
        self.state = state
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 610, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Réécrire avec Véloce"
        window.minSize = NSSize(width: 500, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TextProcessingView(state: state).preferredColorScheme(.dark))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        state?.cancel()
        state = nil
        window = nil
        target = nil
        inserter.clearTarget()
    }

    private func apply(_ text: String) async -> Bool {
        guard let target else { return false }
        window?.orderOut(nil)
        target.activate(options: [])
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return false }
        let inserted = await inserter.insert(text, into: target)
        if inserted { close() }
        else { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        return inserted
    }
}

@MainActor
private final class TextProcessingState: ObservableObject {
    @Published var text: String
    @Published var instruction = "Corrige la formulation en conservant le sens et mon ton."
    @Published var result = ""
    @Published var error: String?
    @Published var busy = false { didSet { onBusyChange?(busy) } }
    @Published var voicePhase: TextInstructionPhase = .idle
    @Published var voiceLevel: Double = 0
    let canReplace: Bool
    var canBegin: () -> Bool = { true }
    var onBusyChange: ((Bool) -> Void)?
    var onApply: ((String) async -> Bool)?
    var onCopy: ((String) -> Void)?
    var onVoiceStart: ((TextInstructionHandlers) -> Bool)?
    var onVoiceFinish: (() -> Void)?
    var onVoiceCancel: (() -> Void)?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    var unavailableReason: String? { LocalTextProcessor.unavailableReason }

    init(text: String, canReplace: Bool) { self.text = text; self.canReplace = canReplace }

    func generate() {
        guard !busy, canBegin() else { error = "Terminez l’opération en cours avant de réécrire ce texte."; return }
        let source = text
        let request = instruction
        let token = UUID(); generation = token
        error = nil; result = ""; busy = true
        operation = Task {
            do {
                let response = try await LocalTextProcessor.transform(source, instruction: request)
                guard !Task.isCancelled, token == generation else { return }
                result = response; busy = false
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription; busy = false
            }
        }
    }

    func apply() {
        guard !busy, !result.isEmpty, canReplace, canBegin() else { return }
        let output = result
        busy = true
        operation = Task {
            let inserted = await onApply?(output) ?? false
            guard !Task.isCancelled else { return }
            busy = false
            if !inserted { error = "La sélection a changé. Le résultat reste disponible avec Copier." }
        }
    }

    func startVoiceInstruction() {
        guard !busy, voicePhase == .idle else { return }
        error = nil
        let handlers = TextInstructionHandlers(onText: { [weak self] text in
            self?.instruction = text
            self?.result = ""
        }, onUpdate: { [weak self] phase, error in
            self?.voicePhase = phase
            self?.error = error
        }, onLevel: { [weak self] level in self?.voiceLevel = level })
        _ = onVoiceStart?(handlers)
    }

    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        if voicePhase != .idle { voicePhase = .idle; onVoiceCancel?() }
    }
}

private struct TextProcessingView: View {
    @ObservedObject var state: TextProcessingState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Votre texte, à votre façon.")
                .font(.system(size: 24, weight: .medium, design: .rounded))
            Text(state.canReplace ? "La sélection sera remplacée seulement après votre validation." : "Collez votre texte ci-dessous, puis copiez le résultat.")
                .font(.system(size: 12)).foregroundStyle(VeloceTheme.secondary)
            editor("Texte d’origine", text: $state.text)
            Text("Consigne").font(.system(size: 12, weight: .medium))
            HStack {
                TextField("Ex. : Traduis en anglais, avec un ton naturel", text: $state.instruction)
                    .textFieldStyle(.roundedBorder).disabled(state.busy || state.voicePhase != .idle)
                switch state.voicePhase {
                case .idle:
                    Button(action: state.startVoiceInstruction) {
                        Label("Dicter", systemImage: "mic.fill")
                    }.disabled(state.busy)
                case .recording:
                    Button { state.onVoiceFinish?() } label: { Label("Terminer", systemImage: "stop.fill") }
                    Button("Annuler", action: state.cancel)
                case .transcribing:
                    ProgressView().controlSize(.small)
                    Button("Annuler", action: state.cancel)
                }
            }
            if state.voicePhase != .idle {
                HStack(spacing: 10) {
                    if state.voicePhase == .recording {
                        WaveformView(level: state.voiceLevel, active: true, barCount: 11, height: 18).frame(width: 66)
                    }
                    Text(state.voicePhase == .recording ? "On écoute votre consigne. Deux minutes maximum." : "Votre consigne prend forme…")
                        .font(.system(size: 11)).foregroundStyle(VeloceTheme.accent)
                }
            }
            HStack(spacing: 10) {
                Button("Corriger") { state.instruction = "Corrige la grammaire et la ponctuation, sans changer le sens ni le ton." }
                Button("Raccourcir") { state.instruction = "Raccourcis ce texte en conservant toutes ses informations essentielles." }
                Button("Traduire en anglais") { state.instruction = "Traduis fidèlement ce texte en anglais naturel." }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(state.busy || state.voicePhase != .idle)
            editor("Résultat", text: $state.result)
            if let message = state.error ?? state.unavailableReason {
                Text(message).font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary)
            }
            HStack {
                Text("Apple Intelligence · sur ce Mac").font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                Spacer()
                if state.busy {
                    ProgressView().controlSize(.small)
                    Button("Annuler", action: state.cancel)
                } else {
                    Button("Réécrire", action: state.generate)
                        .disabled(state.unavailableReason != nil || state.text.isEmpty || state.instruction.isEmpty || state.voicePhase != .idle)
                    Button("Copier") { state.onCopy?(state.result) }.disabled(state.result.isEmpty || state.voicePhase != .idle)
                    if state.canReplace {
                        Button("Remplacer la sélection", action: state.apply).disabled(state.result.isEmpty || state.voicePhase != .idle)
                    }
                }
            }
            .controlSize(.regular)
        }
        .padding(24)
        .background(VeloceTheme.paper)
        .onChange(of: state.text) { _, _ in if !state.busy { state.result = "" } }
        .onChange(of: state.instruction) { _, _ in if !state.busy { state.result = "" } }
    }

    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: text).font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(7).background(VeloceTheme.card, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(VeloceTheme.line, lineWidth: 1))
                .disabled(state.busy || state.voicePhase != .idle)
        }
    }
}
