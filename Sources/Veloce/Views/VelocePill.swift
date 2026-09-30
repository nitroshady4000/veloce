import SwiftUI

/// Presentation only: no engine or microphone is created by this component.
enum PillPhase: Int, CaseIterable {
    case idle, listening, thinking, success, failure

    init(appPhase: DictationPhase) {
        switch appPhase {
        case .recording: self = .listening
        case .transcribing, .preparing: self = .thinking
        case .ready: self = .success
        case .error: self = .failure
        case .idle: self = .idle
        }
    }
}

/// The microphone meter is intentionally quiet at its lower end. Amplify only
/// its presentation so normal speech lights up the pill without changing audio.
enum PillVoiceResponse {
    static func amplitude(_ level: Double) -> Double {
        let normalized = min(1, max(0, (level - 0.08) / 0.92))
        return min(1, sqrt(normalized) * 1.4)
    }
}

enum PillLayout {
    static let width: CGFloat = 360
    static let height: CGFloat = 56
    static let margin: CGFloat = 28
    static let bulbOverhang: CGFloat = 0
    static let bottom: CGFloat = 44
    static let canvas = CGSize(width: width + margin * 2, height: height + margin * 2)
}

/// A simple capsule: the voice lives in its light, with no logo or mascot.
struct PillOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        return path
    }
}

struct VelocePill: View {
    var phase: PillPhase
    var level: Double = 0
    var title: String
    var subtitle: String
    var stop: (() -> Void)?
    var cancel: (() -> Void)?
    /// A frozen time lets the real shader and view render without starting timers.
    var previewTime: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            glass
                .frame(width: PillLayout.width, height: PillLayout.height)
            PillLight(phase: phase, level: level, reduceMotion: reduceMotion,
                      frozenTime: previewTime)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(phase == .success ? VeloceTheme.green : .white.opacity(0.95))
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if phase == .listening, let stop {
                    Button(action: stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Terminer la dictée")
                }
                if let cancel {
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Annuler la dictée")
                } else {
                    Text(phase == .success ? "✓" : "fn")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.16)))
                }
            }
            .foregroundStyle(.white.opacity(0.66))
            .padding(.leading, 22).padding(.trailing, 20)
            .frame(width: PillLayout.width, height: PillLayout.height)
        }
        .frame(width: PillLayout.canvas.width, height: PillLayout.canvas.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var glass: some View {
        let tint = phase == .failure ? Color(red: 0.32, green: 0.04, blue: 0.07) : Color(red: 0.086, green: 0.059, blue: 0.047)
        if reduceTransparency || previewTime != nil {
            PillOutline().fill(tint)
                .overlay(PillOutline().strokeBorderFallback(.white.opacity(0.10)))
        } else if #available(macOS 26.0, *) {
            PillOutline().fill(Color(red: 0.043, green: 0.027, blue: 0.020).opacity(0.46))
                .glassEffect(.regular.tint(tint.opacity(0.6)), in: PillOutline())
        } else {
            PillOutline().fill(.ultraThinMaterial)
                .overlay(PillOutline().fill(tint.opacity(0.72)))
                .overlay(PillOutline().stroke(.white.opacity(0.14), lineWidth: 0.7))
                .environment(\.colorScheme, .dark)
        }
    }
}

private extension PillOutline {
    func strokeBorderFallback(_ color: Color) -> some View { stroke(color, lineWidth: 0.7) }
}
