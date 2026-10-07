import SwiftUI
import VeloceCore

struct ModelsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 27) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(text: "Reconnaissance vocale")
                Text("Modèles")
                    .font(.system(size: 41, weight: .medium, design: .rounded))
                    .tracking(-1.5)
                Text("Choisissez un modèle selon vos besoins de précision et de rapidité.")
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .foregroundStyle(VeloceTheme.secondary)
            }
            .padding(.top, 8)

            HStack(alignment: .top, spacing: 12) {
                ForEach(SpeechModel.allCases) { option in
                    modelCard(option)
                }
            }

            SurfaceCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: model.engineReady ? "checkmark.seal" : "arrow.down.circle")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(model.engineReady ? VeloceTheme.green : VeloceTheme.accent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.phase == .preparing ? "Chargement du modèle…" : model.engineReady ? "Modèle prêt" : "Modèle non chargé")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                        Text(model.statusMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(VeloceTheme.secondary)
                            .textSelection(.enabled)
                        if !model.engineReady && model.phase != .preparing {
                            Text("La première préparation télécharge le modèle. Une fois installé, la reconnaissance fonctionne hors ligne.")
                                .font(.system(size: 11))
                                .lineSpacing(4)
                                .foregroundStyle(VeloceTheme.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.phase == .preparing {
                        ProgressView().controlSize(.small).padding(.top, 4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionEyebrow(text: "À propos des modèles")
                Text("Vous pourrez choisir un autre moteur lorsque de nouveaux modèles seront disponibles.")
                    .font(.system(size: 12))
                    .lineSpacing(5)
                    .foregroundStyle(VeloceTheme.secondary)
            }
        }
    }

    private func modelCard(_ option: SpeechModel) -> some View {
        let selected = model.selectedModel == option
        let loaded = model.loadedModel == option
        return VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: option.symbol)
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(selected ? VeloceTheme.accent : VeloceTheme.secondary)
                    .frame(width: 39, height: 43, alignment: .leading)
                Spacer()
                Button {
                    model.selectedModel = option
                } label: {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(selected ? VeloceTheme.accent : VeloceTheme.tertiary)
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy || model.isRecording)
                .accessibilityLabel("Choisir \(option.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(option.title)
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .tracking(-0.7)
                Text(option.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(VeloceTheme.secondary)
            }
            Text(option.detail)
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(VeloceTheme.secondary)
                .frame(minHeight: 60, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(VeloceTheme.line.opacity(0.7)).frame(height: 1)
            Button {
                model.selectedModel = option
                model.prepareModel()
            } label: {
                HStack(spacing: 5) {
                    Text(loaded && selected && model.engineReady ? "Prêt à dicter" : loaded ? "Charger" : "Préparer")
                    Spacer(minLength: 0)
                    Image(systemName: loaded ? "checkmark" : "arrow.down")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? VeloceTheme.accent : VeloceTheme.ink)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.isRecording || (loaded && selected && model.engineReady))
            .accessibilityLabel(loaded ? "Charger \(option.name)" : "Préparer \(option.name)")
            if loaded {
                Label("En mémoire", systemImage: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(VeloceTheme.green)
            } else {
                Text(selected ? "Modèle sélectionné" : "Disponible")
                    .font(.system(size: 9))
                    .foregroundStyle(VeloceTheme.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? VeloceTheme.amber.opacity(0.075) : VeloceTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? VeloceTheme.accent.opacity(0.50) : VeloceTheme.line, lineWidth: 1))
    }
}
