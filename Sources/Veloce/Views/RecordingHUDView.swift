import SwiftUI

struct RecordingHUDView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var stage: PillStage

    var body: some View {
        VelocePill(phase: hudPhase,
                   level: model.level, title: hudTitle,
                   subtitle: hudSubtitle,
                   words: hudWords,
                   detail: hudDetail,
                   stop: stopAction,
                   cancel: cancelAction,
                   presence: stage.presence,
                   stage: stage)
    }

    /// Famulus: the words while speaking, then the heard sentence while it is
    /// transcribed (only while this dictation is the one being processed).
    private var hudWords: LivePreviewText {
        if model.isRecording { return model.livePreview }
        if model.phase == .transcribing, model.pendingDictationCount == 1 { return model.livePreview }
        return LivePreviewText()
    }

    private var hudDetail: String? {
        if let notice = model.modelPreparationNotice {
            return notice == .ready ? "Maintenez Fn pour parler" : nil
        }
        return model.phase == .ready && !model.transcriptInserted ? "dans Véloce" : nil
    }

    private var stopAction: (() -> Void)? {
        guard model.isRecording else { return nil }
        return { model.toggleRecording() }
    }

    private var cancelAction: (() -> Void)? {
        guard model.isRecording || (model.phase == .transcribing && !model.isDictationProcessing) else { return nil }
        return { model.cancel() }
    }

    private var hudPhase: PillPhase {
        if let notice = model.modelPreparationNotice {
            return switch notice {
            case .loading: .thinking
            case .ready: .success
            case .failed: .failure
            }
        }
        return PillPhase(appPhase: model.phase)
    }

    private var hudSubtitle: String {
        if let notice = model.modelPreparationNotice {
            return switch notice {
            case .loading: "Patientez avant de parler"
            case .ready: "Maintenez Fn pour parler"
            case .failed: "Ouvrez Véloce pour réessayer"
            }
        }
        if model.isRecording, model.pendingDictationCount > 0 {
            let finish = model.isHandsFree ? "Fn pour terminer" : "Relâchez fn"
            return "\(finish) · \(model.pendingDictationCount) en cours"
        }
        if model.isDictationProcessing {
            return model.canStartDictation ? "Fn pour dicter la suite" : "\(model.pendingDictationCount) dictées dans la file"
        }
        switch model.phase {
        case .recording: return model.isHandsFree ? "Appuyez sur Fn pour terminer" : "Relâchez Fn pour insérer"
        case .ready: return model.transcriptInserted ? "Collage envoyé" : "Texte prêt à copier dans Véloce"
        default: return "Traitement sur ce Mac"
        }
    }

    private var hudTitle: String {
        if let notice = model.modelPreparationNotice {
            return switch notice {
            case .loading: "Préchauffe du modèle…"
            case .ready: "Prêt à dicter"
            case .failed: "Chargement impossible"
            }
        }
        return switch model.phase {
        case .recording: "Enregistrement…"
        case .transcribing: "Transcription…"
        case .preparing: "Préparation du modèle…"
        case .error: "Erreur · Ouvrez Véloce"
        case .ready: model.transcriptInserted ? "Collage envoyé" : "Texte prêt à copier"
        case .idle: "Prêt"
        }
    }
}
