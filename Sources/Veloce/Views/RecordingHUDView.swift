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
        guard model.isRecording || (model.phase == .transcribing && !model.isDictationProcessing) else { return nil }
        return { model.cancel() }
    }

    private var hudPhase: PillPhase { PillPhase(appPhase: model.phase) }

    private var hudSubtitle: String {
        if model.isRecording, model.pendingDictationCount > 0 {
            let finish = model.isHandsFree ? "Fn pour terminer" : "Relâchez fn"
            return "\(finish) · \(model.pendingDictationCount) en cours"
        }
        if model.isDictationProcessing {
            return model.canStartDictation ? "Fn pour dicter la suite" : "\(model.pendingDictationCount) dictées dans la file"
        }
        switch model.phase {
        case .recording: return model.isHandsFree ? "Appuyez sur fn pour terminer" : "Relâchez fn pour écrire"
        case .ready: return model.transcriptInserted ? "À la prochaine idée" : "Retrouvez votre texte dans Véloce"
        default: return "Tout reste sur votre Mac"
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
