import AppKit
import SwiftUI

// Famulus' motion for the pill (app/poc/Magic.swift, Skin.swift,
// SkinLisere.swift, Pill.swift), Liseré look, without the character: the swell
// in and the fade out, the capsule widening by steps as words arrive, words
// written in light then settling, the heard sentence dimmed while it is
// transcribed, the result written in with its seal.

enum Motion {
    /// Quick, soft swell when the pill appears (about 180 ms to settle visually).
    static let appear = Animation.spring(response: 0.26, dampingFraction: 0.86)
    /// Quick fade and shrink when it leaves (150 ms).
    static let disappear = Animation.easeIn(duration: 0.15)
    /// One line becoming another inside the pill.
    static let morph = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// Words arriving (and the capsule growing a step).
    static let words = Animation.spring(response: 0.3, dampingFraction: 0.92)

    static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Stage

/// The pill's presence (driven by the panel) and, as animated, what the light
/// reads at its own frames (Famulus' SkinStage). The probes write the drawn
/// values during animation frames; nothing drawn is published.
@MainActor
final class PillStage: ObservableObject {
    /// 0 hidden ... 1 shown: the swell in and the fade out (native animations).
    @Published var presence: Double = 1
    /// The pill is fading out: its thread flows back into the source.
    @Published var leaving = false
    private(set) var drawnPresence = 1.0
    private(set) var drawnWidth = PillLayout.width
    weak var light: PillLightView?

    func setDrawn(presence value: Double) {
        guard value != drawnPresence else { return }
        drawnPresence = value
        light?.follow()
    }

    func setDrawn(width value: CGFloat) {
        guard value != drawnWidth else { return }
        drawnWidth = value
        light?.follow()
    }
}

/// Liseré's swell (Famulus SkinSwell): a bloom from the bottom, quick, no
/// bounce on the words; it tells the light the swell as it is animated.
struct PillSwell: ViewModifier, Animatable {
    var presence: Double
    let stage: PillStage?

    var animatableData: Double {
        get { presence }
        set { presence = newValue }
    }

    func body(content: Content) -> some View {
        let _ = stage?.setDrawn(presence: presence)
        let p = presence
        content
            .scaleEffect(x: 0.86 + 0.14 * p, y: 0.9 + 0.1 * p, anchor: .bottom)
            .opacity(min(1, 2 * p))
    }
}

/// Reports the capsule's width to the light at each frame of its animation.
struct PillWidthProbe: ViewModifier, Animatable {
    var width: CGFloat
    let stage: PillStage?

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        let _ = stage?.setDrawn(width: width)
        content
    }
}

// MARK: - Words

/// Text metrics for the pill's words (17 pt rounded medium).
enum TextMetrics {
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 17, weight: .medium)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: 17) ?? base
    }()

    static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

struct PillWord: Equatable {
    let text: String
    let volatile: Bool

    static func split(stable: String, volatile: String) -> [PillWord] {
        let fixed = stable.split(whereSeparator: \.isWhitespace).map { PillWord(text: String($0), volatile: false) }
        let moving = volatile.split(whereSeparator: \.isWhitespace).map { PillWord(text: String($0), volatile: true) }
        return fixed + moving
    }

    /// The words' width rounded up to a step: the capsule widens a few times
    /// per sentence, not at every word.
    static func areaWidth(_ words: [PillWord], minimum: CGFloat, limit: CGFloat) -> CGFloat {
        let natural = TextMetrics.width(words.map(\.text).joined(separator: " ")) + CGFloat(max(0, words.count - 1)) * 0.8 + 4
        let step = PillLayout.wordsStep
        return min(limit, max(minimum, (natural / step).rounded(.up) * step))
    }
}

/// Liseré's ink and light for words.
enum LisereText {
    static let gold = Color(.sRGB, red: 1, green: 0xD2 / 255, blue: 0x7A / 255)
    static let pale = Color(.sRGB, red: 1, green: 0xF1 / 255, blue: 0xD6 / 255)
    /// Words still being recognised: warm light, not yet settled.
    static let volatile = Color(.sRGB, red: 1, green: 0xE7 / 255, blue: 0xC2 / 255, opacity: 0.8)
    static let settled = Color.white.opacity(0.96)

    /// A new word: written by a warm light from the left. Reduce Motion: a fade.
    static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity.animation(.easeOut(duration: 0.15))
            : AnyTransition.modifier(active: WordWrite(progress: 0), identity: WordWrite(progress: 1))
                .animation(.spring(response: 0.44, dampingFraction: 0.86))
    }
}

/// A word arriving: a warm light sweeps it on from the left, then it settles
/// into crisp text. No shadow, no blur: a gradient masked by the word.
struct WordWrite: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        if progress >= 0.999 {
            content
        } else {
            let p = min(1, max(0, progress))
            let glow = 1 - p
            let edge = -0.12 + 1.45 * p
            content
                .overlay {
                    LinearGradient(colors: [LisereText.gold, LisereText.pale], startPoint: .leading, endPoint: .trailing)
                        .mask(content)
                        .opacity(glow * 0.9)
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: min(1, max(0, edge - 0.3))),
                        .init(color: .clear, location: min(1, max(0.0001, edge))),
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .offset(y: 3 * glow * glow)
        }
    }
}

/// Keeps the tail of a line wider than `maxWidth` (the newest words).
struct TailClamp: Layout {
    let maxWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let line = subviews.first else { return .zero }
        let ideal = line.sizeThatFits(.unspecified)
        return CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let line = subviews.first else { return }
        let ideal = line.sizeThatFits(.unspecified)
        line.place(at: CGPoint(x: bounds.maxX - ideal.width, y: bounds.minY), proposal: ProposedViewSize(ideal))
    }
}

/// The live transcript (Famulus LiveWords). A word keeps its place (identity by
/// position): when the recognizer revises it, its text changes in place. A new
/// word is written in by itself; the still-moving tail stays warm. Past the
/// width, the oldest words fade out on the left.
struct LiveWords: View {
    let words: [PillWord]
    let width: CGFloat
    var reduceMotion = false
    /// Offline only: each word's arrival (0 ... 1), transitions do not run there.
    var progress: ((Int) -> Double)? = nil

    var body: some View {
        let overflow = TextMetrics.width(words.map(\.text).joined(separator: " ")) > width - 6
        TailClamp(maxWidth: width) {
            HStack(spacing: 5) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    Text(verbatim: word.text)
                        .foregroundStyle(word.volatile ? LisereText.volatile : LisereText.settled)
                        .animation(.easeOut(duration: 0.22), value: word.volatile)
                        .modifier(WordWrite(progress: progress?(index) ?? 1))
                        .transition(LisereText.arrival(reduceMotion: reduceMotion))
                }
            }
            .fixedSize()
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: overflow ? 0.14 : 0),
                .init(color: .black, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .frame(width: width, alignment: .leading)
        .font(.system(size: 17, weight: .medium, design: .rounded))
        .lineLimit(1)
    }
}

/// The heard sentence while it is transcribed (Famulus UtteranceLine,
/// thinking): dimmed, the light's sweep passes behind it.
struct UtteranceLine: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(Color.white.opacity(0.62))
            .shadow(color: .black.opacity(0.28), radius: 2, y: 0.5)
            .frame(width: width, alignment: .leading)
            .contentTransition(.identity)
    }
}

// MARK: - Result

private struct RevealProgressKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    /// 0 ... 1 while a result is revealed; 1 at rest.
    var revealProgress: Double {
        get { self[RevealProgressKey.self] }
        set { self[RevealProgressKey.self] = newValue }
    }
}

struct RevealProgress: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.revealProgress, progress)
    }
}

extension AnyTransition {
    /// A result arriving: its seal draws itself, its words are written in light.
    static func resultArrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: AnyTransition.modifier(active: RevealProgress(progress: 0), identity: RevealProgress(progress: 1))
                .animation(.linear(duration: 0.6)),
            removal: .identity)
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.84))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// "C’est écrit": Liseré's mint seal whose check draws itself, then the words
/// written in light (Famulus ResultLine).
struct ResultLine: View {
    let title: String
    var detail: String? = nil
    var success = true
    @Environment(\.revealProgress) private var reveal

    var body: some View {
        let age = reveal * 0.6
        let mint = success ? VeloceTheme.green : Color.white.opacity(0.66)
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(mint.opacity(0.15))
                Circle().strokeBorder(mint.opacity(0.5), lineWidth: 1)
                CheckShape()
                    .trim(from: 0, to: Motion.smooth((age - 0.1) / 0.34))
                    .stroke(mint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(5.6)
            }
            .frame(width: 20, height: 20)
            HStack(spacing: 0) {
                Text(verbatim: title)
                if let detail {
                    Text(verbatim: " · ")
                    Text(verbatim: detail).fontWeight(.medium).foregroundStyle(Color.white.opacity(0.66))
                }
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.95))
            .lineLimit(1)
            .modifier(WordWrite(progress: reveal))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
        }
    }
}
