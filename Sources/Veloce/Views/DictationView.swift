import SwiftUI
import VeloceCore

struct DictationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 18) {
                    SectionEyebrow(text: "Moins de clavier. Plus d’élan.")
                    Text("L’esprit libre.\nLes mots suivent.")
                        .font(.system(size: 43, weight: .regular, design: .serif))
                        .tracking(-1.8)
                        .lineSpacing(0)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Maintenez **Fn**, parlez, relâchez.\nVotre texte apparaît là où vous écrivez.")
                        .font(.system(size: 13))
                        .foregroundStyle(VeloceTheme.secondary)
                        .lineSpacing(5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FnKeyVisual()
                    .frame(width: 218, height: 230)
            }
            .padding(.top, 7)

            HStack(spacing: 15) {
                Button(action: primaryAction) {
                    HStack(spacing: 8) {
                        Image(systemName: primarySymbol)
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(VeloceButtonStyle())
                .disabled(model.isBusy && !model.isRecording)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.phase == .error ? VeloceTheme.accent : model.engineReady ? VeloceTheme.green : VeloceTheme.secondary)
                            .frame(width: 5, height: 5)
                        Text(model.statusMessage)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                    }
                    Text(model.selectedModel.name)
                        .font(.system(size: 10))
                        .foregroundStyle(VeloceTheme.secondary)
                }
                Spacer(minLength: 0)
                if model.isRecording {
                    Button("Annuler", action: model.cancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(VeloceTheme.secondary)
                }
            }

            HStack(spacing: 9) {
                ReadinessChip(title: "Microphone", ready: model.microphoneGranted, symbol: "mic", action: model.requestMicrophone)
                ReadinessChip(title: "Accessibilité", ready: model.accessibilityGranted, symbol: "cursorarrow.rays", action: model.requestAccessibility)
                ReadinessChip(title: "Modèle local", ready: model.engineReady, symbol: "cpu", action: model.prepareModel)
                    .disabled(model.isBusy)
            }

            Rectangle().fill(VeloceTheme.line.opacity(0.7)).frame(height: 1)
                .padding(.vertical, 3)

            HStack {
                SectionEyebrow(text: "Derniers mots")
                Spacer()
                if !model.keepHistory {
                    Text("Historique désactivé")
                        .font(.system(size: 10))
                        .foregroundStyle(VeloceTheme.secondary)
                }
            }
            if model.history.isEmpty {
                SurfaceCard {
                    HStack(alignment: .top, spacing: 15) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(VeloceTheme.secondary.opacity(0.65))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Une pensée ? Dites-la.")
                                .font(.system(size: 18, weight: .regular, design: .serif))
                            Text(model.keepHistory ? "Votre dernière dictée apparaîtra ici, prête à être retrouvée ou copiée." : "Vos dictées seront insérées directement, sans être conservées dans l’historique.")
                                .font(.system(size: 12))
                                .lineSpacing(4)
                                .foregroundStyle(VeloceTheme.secondary)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(model.history.prefix(3)) { transcript in
                        transcriptCard(transcript)
                    }
                }
            }
        }
    }

    private var primaryTitle: String {
        if model.isRecording { return "Terminer la dictée" }
        if model.phase == .preparing { return "Préparation…" }
        if model.phase == .transcribing { return "Transcription…" }
        if !model.microphoneGranted { return "Autoriser le micro" }
        if !model.accessibilityGranted { return "Autoriser l’insertion" }
        if !model.engineReady { return "Préparer mon modèle" }
        return "Commencer à dicter"
    }

    private var primarySymbol: String {
        if model.isRecording { return "stop.fill" }
        if model.phase == .preparing { return "arrow.down" }
        if model.phase == .transcribing { return "ellipsis" }
        return model.engineReady ? "mic.fill" : "arrow.right"
    }

    private func primaryAction() {
        if model.isRecording { model.toggleRecording() }
        else if !model.microphoneGranted { model.requestMicrophone() }
        else if !model.accessibilityGranted { model.requestAccessibility() }
        else if !model.engineReady { model.prepareModel() }
        else { model.toggleRecording() }
    }

    private func transcriptCard(_ transcript: Transcript) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 15) {
                Text(transcript.text)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .lineLimit(5)
                HStack(spacing: 7) {
                    Text(transcript.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    Text("·")
                    Text(transcript.model.name)
                    Spacer()
                    Text(String(format: "%.1f s", transcript.latency))
                        .help("Durée de transcription")
                    Button {
                        model.copyTranscript(transcript.text)
                        copiedID = transcript.id
                    } label: {
                        Image(systemName: copiedID == transcript.id ? "checkmark" : "doc.on.doc")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(copiedID == transcript.id ? "Texte copié" : "Copier la dictée")
                    .accessibilityLabel("Copier la dictée")
                }
                .font(.system(size: 10))
                .foregroundStyle(VeloceTheme.secondary)
            }
        }
    }
}

private struct ReadinessChip: View {
    let title: String
    let ready: Bool
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: ready ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(ready ? VeloceTheme.green : VeloceTheme.secondary)
                Text(title)
                Spacer(minLength: 0)
                if !ready { Image(systemName: "arrow.up.right").font(.system(size: 8)) }
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(VeloceTheme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VeloceTheme.line.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) : \(ready ? "prêt" : "à configurer")")
    }
}

private struct FnKeyVisual: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(VeloceTheme.line.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1, 7]))
                .frame(width: 214, height: 214)
            Circle()
                .stroke(VeloceTheme.line.opacity(0.45), lineWidth: 1)
                .frame(width: 164, height: 164)
            Circle()
                .fill(VeloceTheme.accent.opacity(model.isRecording ? 0.10 : 0.035))
                .frame(width: 132, height: 132)
            VStack(spacing: 19) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 19)
                        .fill(VeloceTheme.line.opacity(0.65))
                        .offset(y: 5)
                    RoundedRectangle(cornerRadius: 19)
                        .fill(model.isRecording ? VeloceTheme.accent : VeloceTheme.paper)
                        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Color.white.opacity(0.95), lineWidth: 2))
                        .shadow(color: VeloceTheme.ink.opacity(0.08), radius: 12, x: 0, y: 8)
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "globe")
                            .font(.system(size: 17, weight: .light))
                        Text("fn")
                            .font(.system(size: 30, weight: .regular, design: .rounded))
                    }
                    .foregroundStyle(model.isRecording ? Color.white : VeloceTheme.ink)
                    .padding(17)
                }
                .frame(width: 94, height: 103)
                .offset(y: model.isRecording ? 3 : 0)
                WaveformView(level: model.level, active: model.isRecording, barCount: 23, height: 24)
            }
            .padding(.top, 21)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.isRecording)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.isRecording ? "Dictée en cours, relâchez Fn pour terminer" : "Maintenez la touche Fn pour parler")
    }
}
