import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import VeloceCore

@main
struct VeloceMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--verify-audio-import"), args.indices.contains(index + 1) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            Task {
                do {
                    try await MeetingAudioImporter.verifyImport(directory: URL(fileURLWithPath: args[index + 1]))
                    print("Audio file import verified"); exit(0)
                } catch { fputs("Audio import check: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            NSApp.run()
        } else if let index = args.firstIndex(of: "--verify-meeting-audio"), args.indices.contains(index + 1) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            Task {
                do {
                    try await MeetingRecorder.verifyAudioPipeline(directory: URL(fileURLWithPath: args[index + 1]))
                    print("Meeting audio pipeline verified"); exit(0)
                } catch { fputs("Meeting audio check: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            NSApp.run()
        } else if let index = args.firstIndex(of: "--render-design"), args.indices.contains(index + 1) {
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
        var meeting = MeetingRecord(title: "Point produit · Véloce")
        meeting.duration = 1240; meeting.status = .transcribed
        meeting.diarization = "sherpa-onnx-pyannote-wespeaker"
        meeting.segments = [
            MeetingSegment(id: "preview-1", start: 12, end: 18, speaker: "Vous", source: "microphone", text: "On conserve les deux pistes pour pouvoir reprendre la transcription plus tard."),
            MeetingSegment(id: "preview-2", start: 19, end: 25, speaker: "Interlocuteur 1", source: "system", text: "Oui, et chacun pourra retrouver les décisions dans le compte rendu.")
        ]
        let meetingModel = MeetingModel(engine: EngineClient(), previewRecords: [meeting])
        let meetingView = MeetingPageContent(meetings: meetingModel, modelName: "Qwen3 · 1.7B", start: {}, transcribe: { _ in }, prepare: {})
            .padding(32).frame(width: 820).foregroundStyle(VeloceTheme.ink)
            .background(VeloceTheme.paper).environment(\.colorScheme, .dark)
        let meetingImage = try nativeSnapshot(meetingView, width: 820)
        try write(meetingImage, to: directory.appendingPathComponent("meetings.png"))
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

    /// ImageRenderer cannot draw AppKit-backed fields, menus and checkboxes.
    /// Give the real view hierarchy a backing window for AppKit's own bitmap
    /// renderer. This window is never ordered on screen and cannot take focus.
    private static func nativeSnapshot<Content: View>(_ content: Content, width: CGFloat) throws -> CGImage {
        let hosting = NSHostingView(rootView: content.fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(VeloceTheme.paper)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        let height = ceil(hosting.fittingSize.height)
        guard height.isFinite, height > 0, height < 20_000 else {
            throw VeloceError.message("Invalid native preview dimensions")
        }
        window.setContentSize(NSSize(width: width, height: height))
        hosting.setFrameSize(NSSize(width: width, height: height))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw VeloceError.message("Unable to create native preview bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let image = bitmap.cgImage else {
            throw VeloceError.message("Unable to render native meeting view")
        }
        return image
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw VeloceError.message("Unable to write image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VeloceError.message("Unable to save image") }
    }
}
