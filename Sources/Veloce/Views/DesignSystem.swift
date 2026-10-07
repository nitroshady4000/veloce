import SwiftUI

enum VeloceTheme {
    static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    // Famulus' warm glass, type contrast and spectral light, shared by the
    // window and the dictation pill. The V is Véloce's own brand glyph.
    static let paper = rgb(0x1A1815)
    static let sidebar = rgb(0x151310)
    static let ink = Color.white.opacity(0.95)
    static let secondary = Color.white.opacity(0.66)
    static let tertiary = Color.white.opacity(0.46)
    static let line = Color.white.opacity(0.12)
    static let card = Color.white.opacity(0.045)
    static let surface = rgb(0x211E19)
    static let surfaceRaised = rgb(0x2B261F)
    static let green = rgb(0x8FD6AE)
    static let error = rgb(0xFF6A5C)
    static let amber = rgb(0xFFB547)
    static let gold = rgb(0xFFD66B)
    static let coral = rgb(0xFF6F5E)
    static let magenta = rgb(0xF2479B)
    static let violet = rgb(0x8E5CFF)
    static let cyan = rgb(0x3FD4FF)
    static let ember = rgb(0xFFE3A3)
    static let glass = rgb(0x15100D, opacity: 0.52)
    static let glassCard = rgb(0x15100D, opacity: 0.76)
    static let accent = amber
    static let brandGradient = LinearGradient(
        colors: [gold, amber, coral], startPoint: .topTrailing, endPoint: .bottomLeading
    )
}

struct VeloceMark: View {
    var size: CGFloat = 34
    var color: Color = VeloceTheme.accent

    var body: some View {
        VeloceMarkShape().fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Five rounded waveform bars whose ends trace a V.
struct VeloceMarkShape: Shape {
    /// (x centre, top, bottom) in unit space; scripts/make-icon.swift mirrors it.
    static let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.180, 0.260, 0.470), (0.340, 0.385, 0.690), (0.500, 0.560, 0.840),
        (0.660, 0.300, 0.700), (0.820, 0.150, 0.450)
    ]
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height), w = s * 0.13
        var path = Path()
        for (x, top, bottom) in Self.bars {
            path.addRoundedRect(in: CGRect(x: rect.minX + x * s - w / 2, y: rect.minY + top * s,
                                           width: w, height: (bottom - top) * s),
                                cornerSize: CGSize(width: w / 2, height: w / 2))
        }
        return path
    }
}

struct VeloceButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .foregroundStyle(prominent ? VeloceTheme.paper : VeloceTheme.ink)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(prominent ? VeloceTheme.accent : VeloceTheme.surfaceRaised)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(prominent ? VeloceTheme.gold.opacity(0.55) : VeloceTheme.line, lineWidth: 1))
            .shadow(color: prominent ? VeloceTheme.amber.opacity(0.10) : .clear, radius: 12, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(VeloceTheme.secondary)
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.06), VeloceTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(VeloceTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.09), radius: 16, y: 6)
    }
}

struct WaveformView: View {
    let level: Double
    var active = false
    var color = VeloceTheme.accent
    var barCount = 21
    var height: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let shape = 0.28 + 0.72 * abs(sin(Double(index) * 1.7 + 0.6))
                let amplitude = active ? min(max(level, 0.06), 1) : 0
                Capsule()
                    .fill(color.opacity(active ? 0.9 : 0.36))
                    .frame(width: 3, height: 3 + CGFloat(amplitude * shape) * (height - 3))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: level)
        .accessibilityHidden(true)
    }
}
