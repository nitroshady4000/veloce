import SwiftUI

enum VeloceTheme {
    static let paper = Color(red: 0.981, green: 0.974, blue: 0.956)
    static let sidebar = Color(red: 0.946, green: 0.936, blue: 0.910)
    static let ink = Color(red: 0.19, green: 0.205, blue: 0.19)
    static let secondary = Color(red: 0.45, green: 0.46, blue: 0.43)
    static let accent = Color(red: 0.79, green: 0.27, blue: 0.18)
    static let line = Color(red: 0.85, green: 0.85, blue: 0.81)
    static let green = Color(red: 0.30, green: 0.43, blue: 0.32)
    static let card = Color.white.opacity(0.60)
}

struct VeloceMark: View {
    var size: CGFloat = 34
    var color: Color = VeloceTheme.accent

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: size * 0.16, y: size * 0.31))
                path.addLine(to: CGPoint(x: size * 0.40, y: size * 0.76))
                path.addQuadCurve(to: CGPoint(x: size * 0.48, y: size * 0.76), control: CGPoint(x: size * 0.44, y: size * 0.86))
                path.addLine(to: CGPoint(x: size * 0.87, y: size * 0.16))
            }
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.105, lineCap: .round, lineJoin: .round))
            Path { path in
                path.move(to: CGPoint(x: size * 0.59, y: size * 0.18))
                path.addLine(to: CGPoint(x: size * 0.73, y: size * 0.18))
            }
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct VeloceButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .foregroundStyle(prominent ? Color.white : VeloceTheme.ink)
            .background(prominent ? VeloceTheme.ink : VeloceTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prominent ? Color.clear : VeloceTheme.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 10))
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
            .background(VeloceTheme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(VeloceTheme.line.opacity(0.7), lineWidth: 1))
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
