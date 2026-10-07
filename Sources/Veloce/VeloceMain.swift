import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import VeloceCore

@main
struct VeloceMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--verify-text-insertion") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            do {
                try TextInsertionDiagnostics.verify()
                print("Text insertion clipboard backup verified")
            } catch {
                fputs("Text insertion check: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        } else if let index = args.firstIndex(of: "--verify-meeting-workflows"), args.indices.contains(index + 1) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            Task {
                do {
                    try await MeetingWorkflowDiagnostics.verify(directory: URL(fileURLWithPath: args[index + 1]))
                    print("Meeting queue, history, cancellation and Finder exports verified"); exit(0)
                } catch { fputs("Meeting workflow check: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            NSApp.run()
        } else if let index = args.firstIndex(of: "--verify-finder-service"), args.indices.contains(index + 1) {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            do {
                let directory = URL(fileURLWithPath: args[index + 1]).absoluteURL
                try MeetingSidecar.verify(directory: directory)
                let source = directory.appendingPathComponent("Entretien partagé.mp4")
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                pasteboard.writeObjects([source as NSURL])
                let service = FinderTranscriptionService()
                var delivered: [URL] = []
                service.onFiles = { urls, _ in delivered = urls }
                var failure: NSString?
                service.transcribeFiles(pasteboard, userData: nil, error: &failure)
                guard failure == nil, delivered.map(\.absoluteURL) == [source.absoluteURL] else {
                    throw VeloceError.message("Le service Finder n’a pas reçu le fichier sélectionné.")
                }
                print("Finder service and sidecars verified")
            } catch { fputs("Finder service check: \(error.localizedDescription)\n", stderr); exit(1) }
        } else if let index = args.firstIndex(of: "--verify-audio-import"), args.indices.contains(index + 1) {
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
        try writeVoiceAnimation(to: directory.appendingPathComponent("pill-voice.gif"))
        let glyphURL = directory.appendingPathComponent("menu-glyph.gif")
        guard let glyphGIF = CGImageDestinationCreateWithURL(glyphURL as CFURL, UTType.gif.identifier as CFString, 36, nil) else {
            throw VeloceError.message("Unable to export menu glyph")
        }
        CGImageDestinationSetProperties(glyphGIF, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<36 {
            let t = Double(frame) / 9
            let phase: PillPhase = frame < 18 ? .listening : .thinking
            let level = 0.2 + 0.7 * pow(max(0, sin(t * 4.2)), 2)
            let preview = HStack(spacing: 12) {
                Image(nsImage: MenuGlyphDrawing.image(phase: phase, level: level, time: t))
                    .renderingMode(.template).frame(width: 18, height: 18)
                Text(phase == .listening ? "À l’écoute" : "Transcription…")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white).frame(width: 200, height: 48)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            .environment(\.colorScheme, .dark)
            let frameImage = try nativeSnapshot(preview, width: 200)
            CGImageDestinationAddImage(glyphGIF, frameImage,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 9]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(glyphGIF) else { throw VeloceError.message("Unable to save menu glyph animation") }
        print(directory.path)
    }
    /// A spring's step response (SwiftUI's response / damping fraction), offline.
    private static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let decay = damping * omega
        let wd = omega * sqrt(max(1e-6, 1 - damping * damping))
        return 1 - exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
    }

    /// Famulus' pill, offline at 15 fps: it swells in, the words are written in
    /// light as they are spoken and the capsule widens by steps, the heard
    /// sentence dims while it is transcribed, the result is written in, then it leaves.
    private static func writeVoiceAnimation(to url: URL) throws {
        let fps = 15.0
        let sentence = "Bonjour Claire, je te confirme la démo de jeudi à dix heures, on se retrouve directement au deuxième étage."
            .split(separator: " ").map(String.init)
        let firstWord = 0.45, wordGap = 0.24
        let spoken = firstWord + Double(sentence.count) * wordGap + 0.3
        let thinking = 1.3, success = 1.1, leave = 0.25
        let total = spoken + thinking + success + leave
        let frameCount = Int(total * fps)
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw VeloceError.message("Unable to export animation")
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let speech: (Double) -> Double = { t in
            t < firstWord - 0.1 || t > spoken - 0.2 ? 0.08 : 0.2 + 0.6 * pow(max(0, sin(t * 7.3) * sin(t * 2.1 + 0.6)), 1.2)
        }
        func words(at t: Double) -> LivePreviewText {
            let said = sentence.indices.filter { firstWord + Double($0) * wordGap <= t }
            // The newest words stay volatile for half a second.
            let settled = said.filter { t - (firstWord + Double($0) * wordGap) > 0.5 }
            let moving = said.filter { !settled.contains($0) }
            return LivePreviewText(stable: settled.map { sentence[$0] }.joined(separator: " "),
                                   volatile: moving.map { sentence[$0] }.joined(separator: " "))
        }
        let heard = LivePreviewText(stable: sentence.joined(separator: " "))
        var widthFrom = PillLayout.width, widthTo = PillLayout.width, widthSince = 0.0
        for frame in 0..<frameCount {
            let t = Double(frame) / fps
            let view: VelocePill
            var target: CGFloat
            let phase: PillPhase
            let text: LivePreviewText
            if t < spoken {
                phase = .listening; text = words(at: t)
            } else if t < spoken + thinking {
                phase = .thinking; text = heard
            } else {
                phase = .success; text = LivePreviewText()
            }
            target = VelocePill.width(phase: phase, words: text, stop: phase == .listening, cancel: phase != .success)
            let drawn = widthFrom + (widthTo - widthFrom) * spring(t - widthSince, response: 0.3, damping: 0.92)
            if target != widthTo { widthFrom = drawn; widthTo = target; widthSince = t }
            let width = widthFrom + (widthTo - widthFrom) * spring(t - widthSince, response: 0.3, damping: 0.92)
            let leaving = max(0, t - (total - leave))
            let presence = leaving > 0 ? max(0, 1 - pow(min(1, leaving / 0.15), 2)) : spring(t, response: 0.26, damping: 0.86)
            switch phase {
            case .listening:
                view = VelocePill(phase: .listening, level: speech(t), title: "Enregistrement…", subtitle: "Relâchez Fn pour insérer",
                                  words: text, stop: {}, cancel: {}, presence: presence, previewTime: t, previewLevelAt: speech,
                                  previewWordProgress: { index in
                                      spring(t - (firstWord + Double(index) * wordGap), response: 0.44, damping: 0.86)
                                  },
                                  previewWidth: width, previewSinceAppear: t)
            case .thinking:
                view = VelocePill(phase: .thinking, title: "Transcription…", subtitle: "Traitement sur ce Mac",
                                  words: text, cancel: {}, presence: presence, previewTime: t - spoken, previewWidth: width)
            default:
                view = VelocePill(phase: .success, title: "Texte inséré", subtitle: "",
                                  presence: presence, previewTime: t - spoken - thinking, previewWidth: width,
                                  previewDisappear: leaving > 0 ? 1 - presence : 0)
            }
            let frameRenderer = ImageRenderer(content: view.padding(18).background(VeloceTheme.paper).environment(\.colorScheme, .dark))
            frameRenderer.scale = 2
            if let image = frameRenderer.cgImage {
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(gif) else { throw VeloceError.message("Unable to export animation") }
    }

    private static var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VeloceMark(size: 32, color: VeloceTheme.gold)
                Text("Véloce").font(.system(size: 30, weight: .medium, design: .rounded))
                Spacer()
                Text("DICTÉE VOCALE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
            }.padding(.bottom, 12)
            row(.idle, title: "Prêt", subtitle: "", time: 0)
            row(.thinking, title: "Préchauffe du modèle…", subtitle: "Patientez avant de parler", time: 0.7)
            VelocePill(phase: .success, title: "Prêt à dicter", subtitle: "", detail: "Maintenez Fn pour parler", previewTime: 0.8)
                .frame(maxWidth: .infinity)
            row(.listening, title: "Enregistrement…", subtitle: "Relâchez Fn pour insérer", level: 0.78, time: 0.4,
                levelAt: { 0.14 + 0.65 * pow(max(0, sin($0 * 4.2)), 2) })
            VelocePill(phase: .listening, level: 0.7, title: "Enregistrement…", subtitle: "Relâchez Fn pour insérer",
                       words: LivePreviewText(stable: "On se retrouve jeudi à dix heures", volatile: "pour la démo"),
                       stop: {}, cancel: {}, previewTime: 0.5,
                       previewLevelAt: { 0.14 + 0.65 * pow(max(0, sin($0 * 4.2)), 2) },
                       previewWordProgress: { $0 == 8 ? 0.45 : 1 })
                .frame(maxWidth: .infinity)
            row(.thinking, title: "Transcription…", subtitle: "Traitement sur ce Mac", time: 0.7)
            VelocePill(phase: .thinking, title: "Transcription…", subtitle: "Traitement sur ce Mac",
                       words: LivePreviewText(stable: "On se retrouve jeudi à dix heures pour la démo"), cancel: {}, previewTime: 0.4)
                .frame(maxWidth: .infinity)
            row(.success, title: "Texte inséré", subtitle: "", time: 0.8)
            row(.failure, title: "Erreur · Ouvrez Véloce", subtitle: "", time: 0)
            Text("Aperçu · Aucun microphone ni modèle actif")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(VeloceTheme.secondary)
                .padding(.top, 12)
        }
        .padding(32)
        .frame(width: PillLayout.canvas.width + 64)
        .foregroundStyle(VeloceTheme.ink)
        .background(VeloceTheme.paper)
        .environment(\.colorScheme, .dark)
    }
    private static func row(_ phase: PillPhase, title: String, subtitle: String, level: Double = 0, time: Double,
                            levelAt: ((Double) -> Double)? = nil) -> some View {
        VelocePill(phase: phase, level: level, title: title, subtitle: subtitle, previewTime: time, previewLevelAt: levelAt)
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
