import AppKit
import SwiftUI

/// A tiny native image keeps MenuBarExtra animated: AppKit does not continuously
/// render a SwiftUI animation embedded in its label, but it does accept new images.
struct MenuGlyph: View {
    var phase: PillPhase
    var level: Double
    @StateObject private var animator = MenuGlyphAnimator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(nsImage: animator.image)
            .renderingMode(.template)
            .accessibilityLabel(label)
            .onAppear { update() }
            .onChange(of: phase) { _, _ in update() }
            .onChange(of: level) { _, _ in update() }
            .onChange(of: reduceMotion) { _, _ in update() }
            .onDisappear { animator.stop() }
    }

    private func update() {
        animator.configure(phase: phase, level: level, reduceMotion: reduceMotion)
    }

    private var label: String {
        switch phase {
        case .listening: "Véloce écoute"
        case .thinking: "Véloce transcrit"
        case .success: "Véloce est prêt"
        case .failure: "Véloce : ouvrir pour réessayer"
        case .idle: "Véloce"
        }
    }
}

@MainActor
final class MenuGlyphAnimator: ObservableObject {
    @Published private(set) var image = MenuGlyphDrawing.image(phase: .idle, level: 0, time: 0)
    private var phase: PillPhase = .idle
    private var targetLevel = 0.0
    private var envelope = 0.0
    private var reduceMotion = false
    private var timer: Timer?
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var animationTime = 0.0

    func configure(phase: PillPhase, level: Double, reduceMotion: Bool) {
        let changed = self.phase != phase || self.reduceMotion != reduceMotion
        self.phase = phase
        self.reduceMotion = reduceMotion
        targetLevel = phase == .listening ? PillVoiceResponse.amplitude(level) : 0
        if changed {
            animationTime = 0
            lastTime = ProcessInfo.processInfo.systemUptime
            if phase != .listening { envelope = 0 }
        }
        let animates = !reduceMotion && (phase == .listening || phase == .thinking)
        if animates, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.drawFrame() }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !animates { stop() }
        if changed || timer == nil { drawFrame() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit { timer?.invalidate() }

    private func drawFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.1, max(0, now - lastTime))
        lastTime = now
        let tau = targetLevel > envelope ? 0.035 : 0.17
        envelope = reduceMotion ? targetLevel : envelope + (targetLevel - envelope) * (1 - exp(-delta / tau))
        if !reduceMotion { animationTime += delta }
        image = MenuGlyphDrawing.image(phase: phase, level: envelope, time: animationTime)
    }
}

@MainActor
enum MenuGlyphDrawing {
    /// An 18 pt template waveform follows the native menu bar appearance.
    /// There is no retained bitmap timer or frame work while the app is idle.
    static func image(phase: PillPhase, level: Double, time: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.white.setFill()
            NSColor.white.setStroke()
            if phase == .failure {
                NSBezierPath(roundedRect: NSRect(x: 8.1, y: 7, width: 1.8, height: 7), xRadius: 0.9, yRadius: 0.9).fill()
                NSBezierPath(ovalIn: NSRect(x: 8.1, y: 3.7, width: 1.8, height: 1.8)).fill()
            } else {
                for index in 0..<5 {
                    let distance = abs(Double(index) - 2) / 2
                    let resting = 12 - distance * 7
                    let height: Double
                    if phase == .listening {
                        let wave = 0.45 + 0.55 * abs(sin(time * 6.1 + Double(index) * 0.83))
                        height = 3 + (3 + level * 9) * wave * (1 - distance * 0.23)
                    } else if phase == .thinking {
                        height = 4 + 8 * pow(0.5 + 0.5 * sin(time * 5.0 - Double(index) * 0.9), 2)
                    } else { height = resting }
                    let bar = NSRect(x: 2.0 + Double(index) * 3.0, y: (18 - height) / 2,
                                     width: 2.0, height: height)
                    NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
