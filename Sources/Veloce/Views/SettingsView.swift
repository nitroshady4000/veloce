import SwiftUI
import VeloceCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(text: "Juste l’essentiel")
                Text("Faites comme chez vous.")
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .tracking(-1.3)
                Text("Quelques réglages pour une dictée qui vous ressemble.")
                    .font(.system(size: 13))
                    .foregroundStyle(VeloceTheme.secondary)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 11) {
                SectionEyebrow(text: "Les permissions")
                SurfaceCard {
                    VStack(spacing: 18) {
                        permissionRow(title: "Microphone", detail: "Pour vous entendre pendant la dictée.", symbol: "mic", granted: model.microphoneGranted, action: model.requestMicrophone)
                        Rectangle().fill(VeloceTheme.line.opacity(0.7)).frame(height: 1)
                        permissionRow(title: "Fn et insertion", detail: model.accessibilityGranted && !model.hotkeyReady ? "Accès autorisé ; le raccourci reste à vérifier." : "Pour utiliser Fn et insérer le texte dans vos apps.", symbol: "cursorarrow.rays", granted: model.inputReady, action: model.requestAccessibility)
                    }
                }
                HStack {
                    Text("Les permissions se vérifient automatiquement.")
                        .font(.system(size: 10))
                        .foregroundStyle(VeloceTheme.secondary)
                    Spacer()
                    Button("Ouvrir le guide", action: model.requestMicrophone)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VeloceTheme.accent)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                SectionEyebrow(text: "Votre dictée")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Langue de reconnaissance")
                                    .font(.system(size: 13, weight: .medium))
                                Text(model.selectedModel == .fast ? "Parakeet détecte toujours la langue automatiquement." : "Le français guide Qwen ; Auto laisse le modèle choisir.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(VeloceTheme.secondary)
                            }
                            Spacer()
                            Picker("Langue", selection: $model.language) {
                                Text("Français").tag("French")
                                Text("Automatique").tag("Auto")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 138)
                            .disabled(model.isBusy || model.isRecording || model.selectedModel == .fast)
                        }
                        Rectangle().fill(VeloceTheme.line.opacity(0.7)).frame(height: 1)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Votre vocabulaire")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("Qwen")
                                    .font(.system(size: 10))
                                    .foregroundStyle(VeloceTheme.secondary)
                            }
                            Text("Noms propres, projets, termes techniques… Ajoutez un mot ou une expression par ligne pour aider Qwen à les reconnaître.")
                                .font(.system(size: 11))
                                .lineSpacing(4)
                                .foregroundStyle(VeloceTheme.secondary)
                            ZStack(alignment: .topLeading) {
                                if model.vocabulary.isEmpty {
                                    Text("Véloce\nFamulus\nParakeet")
                                        .foregroundStyle(VeloceTheme.secondary.opacity(0.55))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                                TextEditor(text: $model.vocabulary)
                                    .scrollContentBackground(.hidden)
                                    .padding(3)
                                    .accessibilityLabel("Vocabulaire personnel, un terme par ligne")
                            }
                            .font(.system(size: 12))
                            .frame(height: 91)
                            .background(VeloceTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VeloceTheme.line.opacity(0.7), lineWidth: 1))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                SectionEyebrow(text: "Votre confidentialité")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 19) {
                        Toggle(isOn: $model.keepHistory) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Conserver mes dictées sur ce Mac")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Pour retrouver et recopier vos textes. Aucun compte, aucune synchronisation.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(VeloceTheme.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(VeloceTheme.green)
                        Rectangle().fill(VeloceTheme.line.opacity(0.7)).frame(height: 1)
                        HStack {
                            Text(historyDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(VeloceTheme.secondary)
                            Spacer()
                            Button("Effacer l’historique") { confirmClearHistory = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(VeloceTheme.error)
                                .disabled(model.history.isEmpty)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .light))
                VStack(alignment: .leading, spacing: 7) {
                    Text("La touche Fn, rien de plus.")
                        .font(.system(size: 12, weight: .medium))
                    Text("Si macOS ouvre les emoji ou sa dictée avec Fn, choisissez « Ne rien faire » pour cette touche dans Réglages Système → Clavier.")
                        .font(.system(size: 11))
                        .lineSpacing(4)
                        .foregroundStyle(VeloceTheme.secondary)
                }
            }
            .foregroundStyle(VeloceTheme.secondary)
            .padding(.top, 3)
        }
        .confirmationDialog("Effacer toutes les dictées enregistrées ?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Effacer l’historique", role: .destructive, action: model.clearHistory)
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Cette action supprime les textes conservés dans Véloce sur ce Mac.")
        }
    }

    private var historyDescription: String {
        if !model.keepHistory {
            return model.history.isEmpty ? "Aucune dictée conservée sur disque." : "La dernière dictée reste disponible jusqu’à la fermeture."
        }
        if model.history.isEmpty { return "Aucune dictée enregistrée." }
        return "\(model.history.count) dictée\(model.history.count > 1 ? "s" : "") enregistrée\(model.history.count > 1 ? "s" : "") sur ce Mac."
    }

    private func permissionRow(title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(VeloceTheme.secondary)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                Label("Autorisé", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(VeloceTheme.green)
            } else {
                Button("Configurer", action: action)
                    .buttonStyle(VeloceButtonStyle(prominent: false))
            }
        }
    }
}
