import SwiftUI

struct RecordingHUDView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VeloceMark(size: 23, color: Color(red: 0.97, green: 0.65, blue: 0.47))
            if model.isRecording {
                WaveformView(level: model.level, active: true, color: VeloceTheme.paper, barCount: 15, height: 24)
                Button(action: model.toggleRecording) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Terminer la dictée")
                .accessibilityLabel("Terminer la dictée")
                Button(action: model.cancel) {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 25)
                }
                .buttonStyle(.plain)
                .help("Annuler")
                .accessibilityLabel("Annuler la dictée")
            } else {
                if model.phase == .preparing || model.phase == .transcribing {
                    ProgressView().controlSize(.small).tint(VeloceTheme.paper)
                }
                Text(hudTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(VeloceTheme.paper)
        .padding(.horizontal, 17)
        .frame(height: 51)
        .background(VeloceTheme.ink, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 5)
        .padding(17)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hudTitle)
    }

    private var hudTitle: String {
        switch model.phase {
        case .recording: "À vous la parole"
        case .transcribing: "Vos mots prennent forme…"
        case .preparing: "Préparation du modèle…"
        case .error: "Ouvrez Véloce pour réessayer"
        case .ready, .idle: "Prêt à vous écouter"
        }
    }
}
