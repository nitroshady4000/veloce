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

/// Shape the microphone meter for the pill and menu glyph only. The recorder's
/// audio and its level remain untouched; a soft curve gives quieter speech
/// room to register while keeping louder speech in range.
enum PillVoiceResponse {
    static func amplitude(_ level: Double) -> Double {
        min(0.96, meter(level) * 1.12)
    }

    /// The recorder reports a 0...1 level. Lift its quiet end gently, with a
    /// small floor to keep room noise from keeping the light alive.
    static func meter(_ level: Double) -> Double {
        let normalized = min(1, max(0, (level - 0.025) / 0.975))
        return pow(normalized, 0.68)
    }
}

enum PillLayout {
    /// The capsule at rest; it widens by steps with the live words, up to `maxWidth`.
    static let width: CGFloat = 360
    static let maxWidth: CGFloat = 560
    static let height: CGFloat = 56
    static let margin: CGFloat = 28
    static let bulbOverhang: CGFloat = 0
    static let bottom: CGFloat = 44
    /// The words' area widens by steps of this width (Famulus PillMetrics.wordsStep).
    static let wordsStep: CGFloat = 72
    /// The panel, constant: room for the widest capsule and its halo. Never
    /// resized while shown; every motion is a SwiftUI animation inside it.
    static let canvas = CGSize(width: maxWidth + margin * 2, height: height + margin * 2)
    static let leading: CGFloat = 22
    static let trailing: CGFloat = 20
    static let spacing: CGFloat = 11
}

/// A simple capsule: the voice lives in its light, with no logo or mascot.
struct PillOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        return path
    }
}

/// The pill, Famulus' drop without its character: it swells in, widens with
/// the words written in light while you speak, keeps the heard sentence dimmed
/// while it is transcribed, then writes the result in with its seal.
struct VelocePill: View {
    var phase: PillPhase
    var level: Double = 0
    var title: String
    var subtitle: String
    /// Listening: the live words (Apple's on-device preview). Thinking: the
    /// heard sentence. Empty: the title and subtitle.
    var words = LivePreviewText()
    /// Success: a short note after the title (" · ...").
    var detail: String? = nil
    var stop: (() -> Void)?
    var cancel: (() -> Void)?
    /// 0 hidden ... 1 shown (the panel animates it); the stage carries the
    /// animated values to the light.
    var presence: Double = 1
    var stage: PillStage? = nil
    /// A frozen time lets the real shader and view render without starting timers.
    var previewTime: Double?
    /// Offline only: the raw level at a past time, to show the voice's pour.
    var previewLevelAt: ((Double) -> Double)? = nil
    /// Offline only: each word's arrival, the capsule's width as animated,
    /// seconds since the pill appeared, and its exit (0 ... 1).
    var previewWordProgress: ((Int) -> Double)? = nil
    var previewWidth: CGFloat? = nil
    var previewSinceAppear: Double = 10
    var previewDisappear: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private enum Line: String { case lines, words, utterance, result }

    private var line: Line { Self.line(phase, words) }

    private static func line(_ phase: PillPhase, _ words: LivePreviewText) -> Line {
        switch phase {
        case .listening: return .words
        case .thinking: return words.isEmpty ? .lines : .utterance
        case .success: return .result
        default: return .lines
        }
    }

    private var pillWords: [PillWord] { PillWord.split(stable: words.stable, volatile: words.volatile) }

    private var showsKeycap: Bool { cancel == nil && phase != .success }

    private var chrome: CGFloat { Self.chrome(phase, stop: stop != nil, cancel: cancel != nil) }

    /// Leading and trailing paddings, and the controls after the line.
    private static func chrome(_ phase: PillPhase, stop: Bool, cancel: Bool) -> CGFloat {
        var width = PillLayout.leading + PillLayout.trailing
        if phase == .listening, stop { width += PillLayout.spacing + 26 }
        if cancel { width += PillLayout.spacing + 24 }
        if !cancel && phase != .success { width += PillLayout.spacing + 28 }
        return width
    }

    /// The capsule's width: 360 at rest, else the words by steps (up to the maximum).
    static func width(phase: PillPhase, words: LivePreviewText, stop: Bool, cancel: Bool) -> CGFloat {
        let chrome = chrome(phase, stop: stop, cancel: cancel)
        let minimum = PillLayout.width - chrome
        let limit = PillLayout.maxWidth - chrome
        switch line(phase, words) {
        case .words where !words.isEmpty:
            return chrome + PillWord.areaWidth(PillWord.split(stable: words.stable, volatile: words.volatile),
                                               minimum: minimum, limit: limit)
        case .utterance:
            return chrome + PillWord.areaWidth(PillWord.split(stable: words.text, volatile: ""), minimum: minimum, limit: limit)
        default:
            return PillLayout.width
        }
    }

    private var pillWidth: CGFloat {
        previewWidth ?? Self.width(phase: phase, words: words, stop: stop != nil, cancel: cancel != nil)
    }

    var body: some View {
        let width = pillWidth
        ZStack {
            glass
                .frame(width: width, height: PillLayout.height)
            PillLight(phase: phase, level: level, reduceMotion: reduceMotion, width: width, stage: stage,
                      frozenTime: previewTime, levelAt: previewLevelAt,
                      frozenSinceAppear: previewSinceAppear, frozenDisappear: previewDisappear)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            row
                .frame(width: width, height: PillLayout.height)
                // A new line never overhangs the glass while the capsule morphs.
                .clipShape(Capsule(style: .continuous))
        }
        .modifier(PillWidthProbe(width: width, stage: stage))
        .animation(reduceMotion ? nil : Motion.words, value: width)
        .frame(width: PillLayout.canvas.width, height: PillLayout.canvas.height)
        .modifier(PillSwell(presence: presence, stage: stage))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line == .words && !words.isEmpty ? words.text : title)
    }

    private var row: some View {
        HStack(spacing: PillLayout.spacing) {
            // Another kind of line replaces this one in place, at once (the
            // glass morphs); a result is written in.
            center
                .frame(width: max(1, pillWidth - chrome), alignment: .leading)
                .id(line.rawValue)
                .transition(line == .result ? .resultArrival(reduceMotion: reduceMotion || previewTime != nil) : .identity)
            trailingControls
        }
        .foregroundStyle(.white.opacity(0.66))
        .padding(.leading, PillLayout.leading).padding(.trailing, PillLayout.trailing)
    }

    @ViewBuilder private var center: some View {
        switch line {
        case .words:
            // The words' row is always there while listening: the first word is
            // written in like the others.
            ZStack(alignment: .leading) {
                if words.isEmpty { lines }
                LiveWords(words: pillWords, width: max(1, pillWidth - chrome), reduceMotion: reduceMotion,
                          progress: previewWordProgress)
            }
        case .utterance:
            UtteranceLine(text: words.text, width: max(1, pillWidth - chrome))
        case .result:
            if let previewTime {
                ResultLine(title: title, detail: detail).environment(\.revealProgress, min(1, previewTime / 0.6))
            } else {
                ResultLine(title: title, detail: detail)
            }
        case .lines:
            lines
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(phase == .success ? VeloceTheme.green : .white.opacity(0.95))
            Text(subtitle)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.66))
        }
        .lineLimit(1)
    }

    @ViewBuilder private var trailingControls: some View {
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
        } else if showsKeycap {
            Text("fn")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 28, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.16)))
        }
    }

    /// Famulus' Liseré glass (SkinLook.glassTint, GlassShape): a bare Liquid
    /// Glass capsule, tinted; the smoke under the words is drawn by the light.
    /// No fill or stroke of its own reaches the glass edge.
    @ViewBuilder private var glass: some View {
        // Famulus: 0x140F0C at 0.56; alert 0x7A1418 at 0.6, here coral at the same value.
        let base = phase == .failure ? Color(red: 0x7A / 255, green: 0x35 / 255, blue: 0x2D / 255)
            : Color(red: 0x14 / 255, green: 0x0F / 255, blue: 0x0C / 255)
        let tint = base.opacity(phase == .failure ? 0.6 : 0.56)
        let capsule = Capsule(style: .continuous)
        if reduceTransparency || previewTime != nil {
            // Offline renders cannot draw Liquid Glass: the tint over a dark ground.
            capsule.fill(Color(red: 0x0B / 255, green: 0x07 / 255, blue: 0x05 / 255)).overlay(capsule.fill(tint))
                .overlay(capsule.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(tint), in: capsule)
        } else {
            capsule.fill(.ultraThinMaterial).overlay(capsule.fill(tint))
                .overlay(capsule.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .environment(\.colorScheme, .dark)
        }
    }
}
