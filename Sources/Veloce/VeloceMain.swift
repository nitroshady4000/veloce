import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct VeloceMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-design"), args.indices.contains(index + 1) {
            do { try DesignExport.write(to: URL(fileURLWithPath: args[index + 1])) }
            catch { fputs("Design export: \(error.localizedDescription)\n", stderr); exit(1) }
        } else { VeloceApp.main() }
    }
}

/// Renders this app's own views and shader offscreen: no event tap, model, TCC
/// request, live window or microphone. Safe while another build is in use.
@MainActor
enum DesignExport {
    static func write(to directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard PillLightRenderer.shared != nil else { throw VeloceError.message("Metal renderer unavailable") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: gallery)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw VeloceError.message("Unable to render gallery") }
        try write(image, to: directory.appendingPathComponent("pill-states.png"))
        let permissionGuide = PermissionGuideContent(
            state: PermissionGuideState(microphonePermission: .granted, accessibilityRequested: true),
            initialPermission: .accessibility, onAction: { _ in }
        ).environment(\.colorScheme, .dark)
        let permissionRenderer = ImageRenderer(content: permissionGuide)
        permissionRenderer.scale = 2
        guard let permissionImage = permissionRenderer.cgImage else { throw VeloceError.message("Unable to render permission guide") }
        try write(permissionImage, to: directory.appendingPathComponent("permission-guide.png"))
        let gifURL = directory.appendingPathComponent("living-v.gif")
        guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 36, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<36 {
            let t = Double(frame) / 9
            let level = 0.14 + 0.65 * pow(max(0, sin(t * 4.2)), 2)
            let view = VelocePill(phase: .listening, level: level, title: "À vous la parole",
                                  subtitle: "Relâchez fn pour écrire", previewTime: t)
                .padding(18).background(VeloceTheme.paper).environment(\.colorScheme, .dark)
            let frameRenderer = ImageRenderer(content: view)
            frameRenderer.scale = 2
            if let image = frameRenderer.cgImage {
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 9]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(gif) else { throw VeloceError.message("Unable to export animation") }
        print(directory.path)
    }
    private static var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VeloceMark(size: 32, color: VeloceTheme.gold)
                Text("Véloce").font(.system(size: 30, weight: .medium, design: .rounded))
                Spacer()
                Text("UN V QUI PREND VIE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
            }.padding(.bottom, 12)
            row(.idle, title: "Une présence discrète", subtitle: "Même verre, mêmes couleurs", time: 0)
            row(.listening, title: "À vous la parole", subtitle: "Le V respire avec votre voix", level: 0.7, time: 0.4)
            row(.thinking, title: "Vos mots prennent forme…", subtitle: "La lumière fait le tour du verre", time: 0.7)
            row(.success, title: "C’est écrit", subtitle: "Un petit élan, puis le calme", time: 0.8)
            Text("Études d’états visuels · Aucun microphone ni modèle actif")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(VeloceTheme.secondary)
                .padding(.top, 12)
        }
        .padding(32)
        .frame(width: 540)
        .foregroundStyle(VeloceTheme.ink)
        .background(VeloceTheme.paper)
        .environment(\.colorScheme, .dark)
    }
    private static func row(_ phase: PillPhase, title: String, subtitle: String, level: Double = 0, time: Double) -> some View {
        VelocePill(phase: phase, level: level, title: title, subtitle: subtitle, previewTime: time)
            .frame(maxWidth: .infinity)
    }
    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw VeloceError.message("Unable to write image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VeloceError.message("Unable to save image") }
    }
}
