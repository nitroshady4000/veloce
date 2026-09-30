import SwiftUI

struct RecordingHUDView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VelocePill(phase: hudPhase,
                   level: model.level, title: hudTitle,
                   subtitle: hudSubtitle,
                   stop: stopAction,
                   cancel: cancelAction)
    }

    private var stopAction: (() -> Void)? {
        guard model.isRecording else { return nil }
        return { model.toggleRecording() }
    }

    private var cancelAction: (() -> Void)? {
        guard model.isRecording || model.phase == .transcribing else { return nil }
        return { model.cancel() }
    }

    private var hudPhase: PillPhase {
        switch model.phase {
        case .recording: .listening
        case .transcribing, .preparing: .thinking
        case .ready: .success
        case .error: .failure
        case .idle: .idle
        }
    }

    private var hudSubtitle: String {
        switch model.phase {
        case .recording: "Relâchez fn pour écrire"
        case .ready: model.transcriptInserted ? "À la prochaine idée" : "Retrouvez votre texte dans Véloce"
        default: "Tout reste sur votre Mac"
        }
    }

    private var hudTitle: String {
        switch model.phase {
        case .recording: "À vous la parole"
        case .transcribing: "Vos mots prennent forme…"
        case .preparing: "Préparation du modèle…"
        case .error: "Ouvrez Véloce pour réessayer"
        case .ready: model.transcriptInserted ? "C’est écrit" : "Texte prêt à copier"
        case .idle: "Prêt à vous écouter"
        }
    }
}
