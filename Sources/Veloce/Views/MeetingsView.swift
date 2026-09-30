import SwiftUI
import VeloceCore

struct MeetingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var meetings: MeetingModel

    var body: some View {
        MeetingPageContent(meetings: meetings,
                           otherWorkActive: app.isBusy && !meetings.isBusy,
                           modelName: app.selectedModel.name,
                           start: { meetings.startRecording(model: app.selectedModel, language: app.language, vocabulary: app.vocabulary) },
                           transcribe: { id in meetings.transcribeMeeting(id, model: app.selectedModel, language: app.language, vocabulary: app.vocabulary) },
                           prepare: { meetings.prepareDiarization(model: app.selectedModel) },
                           importAudio: { meetings.chooseAudioFile(model: app.selectedModel, language: app.language, vocabulary: app.vocabulary) })
            .onAppear { meetings.refreshAvailability() }
    }
}

struct MeetingPageContent: View {
    @ObservedObject var meetings: MeetingModel
    var otherWorkActive = false
    let modelName: String
    let start: () -> Void
    let transcribe: (UUID) -> Void
    let prepare: () -> Void
    var importAudio: () -> Void = {}
    @State private var confirmDelete = false
    @State private var confirmReplaceNotes = false
    @State private var editedSpeaker: String?
    @State private var speakerName = ""
    @State private var renameTitle = false
    @State private var newTitle = ""

    private var blocked: Bool { meetings.isBusy || otherWorkActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                SectionEyebrow(text: "Les réunions, à votre rythme")
                Text("Écoutez. On garde le fil.")
                    .font(.system(size: 34, weight: .medium, design: .rounded)).tracking(-1)
                Text("Enregistrez votre réunion sur deux pistes, ou importez un fichier audio. La transcription reste sur ce Mac.")
                    .font(.system(size: 13)).foregroundStyle(VeloceTheme.secondary).lineSpacing(4)
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(meetings.phase == .recording ? "Enregistrement en cours" : "Nouvelle réunion", systemImage: "record.circle")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(MeetingRecord.timestamp(meetings.elapsed)).monospacedDigit()
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                    }
                    if meetings.phase != .recording && meetings.phase != .stopping {
                        TextField("Donnez un titre à la réunion…", text: $meetings.draftTitle)
                            .textFieldStyle(.plain).padding(12)
                            .background(VeloceTheme.paper, in: RoundedRectangle(cornerRadius: 9))
                            .disabled(blocked)
                    }
                    HStack(spacing: 14) {
                        track("Votre microphone", side: "GAUCHE", symbol: "mic", level: meetings.microphoneLevel, color: VeloceTheme.amber)
                        track("Audio de la réunion", side: "DROITE", symbol: "speaker.wave.2", level: meetings.systemLevel, color: VeloceTheme.cyan)
                    }
                    HStack {
                        Toggle("Transcrire après l’arrêt", isOn: $meetings.transcribeAfterRecording)
                            .toggleStyle(.checkbox).font(.system(size: 11)).disabled(blocked)
                        Spacer()
                        if meetings.phase == .recording {
                            Button(meetings.transcribeAfterRecording ? "Arrêter et transcrire" : "Arrêter et sauvegarder") {
                                meetings.stopRecording(transcribe: meetings.transcribeAfterRecording)
                            }.buttonStyle(VeloceButtonStyle())
                        } else if meetings.phase == .starting {
                            Button("Annuler", action: meetings.cancelStarting).buttonStyle(VeloceButtonStyle(prominent: false))
                        } else {
                            Button("Enregistrer la réunion", action: start).buttonStyle(VeloceButtonStyle()).disabled(blocked)
                        }
                    }
                    Text("Les deux pistes sont conservées sur ce Mac. Jusqu’à 4 h · environ 230 Mo par heure. Un casque évite que le micro reprenne les voix distantes.")
                        .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
                    if #unavailable(macOS 15.0) {
                        Text("La capture de réunion nécessite macOS 15 ou plus récent.").font(.system(size: 11)).foregroundStyle(VeloceTheme.error)
                    }
                    Divider().overlay(VeloceTheme.secondary.opacity(0.15))
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Vous avez déjà l’enregistrement ?").font(.system(size: 12, weight: .medium))
                            Toggle("Transcrire après l’import", isOn: $meetings.transcribeAfterImport)
                                .toggleStyle(.checkbox).font(.system(size: 11)).disabled(blocked)
                        }
                        Spacer()
                        Button(action: importAudio) { Label("Importer un audio…", systemImage: "square.and.arrow.down") }
                            .buttonStyle(VeloceButtonStyle(prominent: false)).disabled(blocked)
                    }
                    Text("Jusqu’à 4 h. Une copie audio est conservée dans Véloce ; le fichier d’origine reste intact. Les canaux sont réunis pour la transcription.")
                        .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        Image(systemName: "person.2.wave.2").foregroundStyle(VeloceTheme.amber)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Qui a dit quoi ?").font(.system(size: 13, weight: .semibold))
                            Text(meetings.diarizationReady ? "Le modèle local distingue les voix de la réunion ou du fichier importé. Vous pourrez leur donner un nom après la transcription." : "Préparez la détection locale pour distinguer les différentes voix de la réunion ou d’un fichier importé.")
                                .font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
                        }
                    }
                    if meetings.diarizationReady {
                        Toggle("Distinguer les interlocuteurs", isOn: $meetings.diarize)
                            .toggleStyle(.switch).tint(VeloceTheme.green).font(.system(size: 12)).disabled(blocked)
                    } else {
                        Button("Préparer la détection des voix", action: prepare)
                            .buttonStyle(VeloceButtonStyle(prominent: false)).disabled(blocked)
                        Text("Premier téléchargement d’environ 28 Mo de modèles, plus les dépendances. Ensuite, tout reste local.")
                            .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if meetings.isBusy && meetings.phase != .recording { ProgressView().controlSize(.small) }
                    Text(meetings.status).font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary)
                    Spacer()
                    if [.processing, .preparing, .summarizing, .importing].contains(meetings.phase) {
                        Button("Arrêter le traitement", action: meetings.cancelProcessing).font(.system(size: 11))
                    }
                }
                if [.processing, .summarizing, .importing].contains(meetings.phase) {
                    ProgressView(value: meetings.progress).tint(VeloceTheme.amber)
                }
                if let error = meetings.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(VeloceTheme.error).textSelection(.enabled)
                    if meetings.showsCaptureSettings {
                        Button("Ouvrir les autorisations de capture") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(VeloceTheme.accent)
                    }
                }
            }

            if !meetings.records.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionEyebrow(text: "Vos réunions sur ce Mac")
                    Picker("Réunion", selection: $meetings.selectedID) {
                        ForEach(meetings.records) { record in
                            Text("\(record.title) · \(MeetingRecord.timestamp(record.duration))").tag(Optional(record.id))
                        }
                    }.labelsHidden().disabled(meetings.isBusy)
                    if let record = meetings.selected { detail(record) }
                }
            }

            Text("macOS peut nommer l’autorisation « Enregistrement de l’écran et audio système ». Véloce ne conserve aucune image. Les sons des autres apps sont capturés : coupez les notifications pendant la réunion.")
                .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
        }
        .confirmationDialog("Supprimer cette réunion et l’audio conservé dans Véloce ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer la réunion", role: .destructive, action: meetings.deleteSelected)
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Remplacer le compte rendu et ses modifications ?", isPresented: $confirmReplaceNotes, titleVisibility: .visible) {
            Button("Générer un nouveau compte rendu", action: meetings.generateNotes)
            Button("Conserver mes notes", role: .cancel) {}
        }
        .alert("Nom de l’interlocuteur", isPresented: Binding(get: { editedSpeaker != nil }, set: { if !$0 { editedSpeaker = nil } })) {
            TextField("Nom", text: $speakerName)
            Button("Enregistrer") { if let editedSpeaker { meetings.renameSpeaker(editedSpeaker, to: speakerName) }; editedSpeaker = nil }
            Button("Annuler", role: .cancel) { editedSpeaker = nil }
        }
        .alert("Renommer la réunion", isPresented: $renameTitle) {
            TextField("Titre", text: $newTitle)
            Button("Enregistrer") { meetings.renameMeeting(newTitle) }
            Button("Annuler", role: .cancel) {}
        }
    }

    private func track(_ title: String, side: String, symbol: String, level: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(side).font(.system(size: 8, design: .monospaced)).foregroundStyle(VeloceTheme.secondary)
            }
            WaveformView(level: level, active: meetings.phase == .recording, color: color, barCount: 28, height: 30)
                .frame(maxWidth: .infinity)
        }.padding(12).background(VeloceTheme.paper, in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title).font(.system(size: 20, weight: .medium, design: .rounded))
                    Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingRecord.timestamp(record.duration))")
                        .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                    if let filename = record.originalFilename {
                        Label(filename, systemImage: "waveform").font(.system(size: 10))
                            .foregroundStyle(VeloceTheme.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Menu {
                    Button("Renommer") { newTitle = record.title; renameTitle = true }
                    if record.isImported {
                        Button("Écouter l’audio importé") { meetings.playTrack("imported.wav") }
                    } else {
                        Button("Écouter le microphone") { meetings.playTrack("microphone.wav") }
                        Button("Écouter l’audio système") { meetings.playTrack("system.wav") }
                    }
                    Button("Afficher les fichiers", action: meetings.revealFiles)
                    Divider()
                    Button(record.isImported ? "Exporter l’audio WAV…" : "Exporter en stéréo WAV…", action: meetings.exportStereo)
                    Button("Exporter Markdown…") { meetings.export("md") }
                    Button("Exporter les sous-titres SRT…") { meetings.export("srt") }
                    Button("Exporter JSON…") { meetings.export("json") }
                    Divider()
                    Button("Supprimer…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(blocked)
            }
            if record.status == .interrupted {
                Text("Enregistrement interrompu : les fichiers récupérables restent disponibles dans le dossier de cette réunion.")
                    .font(.system(size: 11)).foregroundStyle(VeloceTheme.amber)
            }
            HStack {
                Button(record.segments.isEmpty ? "Transcrire avec \(modelName)" : "Retranscrire") { transcribe(record.id) }
                    .buttonStyle(VeloceButtonStyle(prominent: false)).disabled(blocked)
                if !record.segments.isEmpty {
                    Button("Copier", action: meetings.copyTranscript).disabled(blocked)
                    Spacer()
                    Button(record.notes.isEmpty ? "Créer le compte rendu" : "Régénérer le compte rendu") {
                        if record.notes.isEmpty { meetings.generateNotes() } else { confirmReplaceNotes = true }
                    }
                        .disabled(blocked || meetings.notesUnavailableReason != nil)
                }
            }
            if !record.segments.isEmpty {
                Text(meetings.notesUnavailableReason ?? "Le compte rendu est généré sur ce Mac avec Apple Intelligence. Relisez les décisions et les actions avant de le partager.")
                    .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
                if !record.notes.isEmpty {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionEyebrow(text: "Compte rendu · modifiable")
                            Text("Vos notes sont conservées lors d’une retranscription. Relisez-les si vous changez de modèle ou corrigez les interlocuteurs.")
                                .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                            TextEditor(text: Binding(get: { meetings.selected?.notes ?? "" }, set: meetings.setNotes))
                                .font(.system(size: 12)).scrollContentBackground(.hidden)
                                .frame(minHeight: 180).disabled(blocked)
                        }
                    }
                }
                Text(record.diarization.hasPrefix("sherpa-") ? "Voix détectées automatiquement · cliquez sur un nom pour le corriger" : record.isImported ? "Audio importé · les interlocuteurs ne sont pas séparés" : "Repères par source · Vous / Participants")
                    .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(record.segments) { segment in
                        HStack(alignment: .top, spacing: 13) {
                            Text(MeetingRecord.timestamp(segment.start))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(VeloceTheme.secondary).frame(width: 55, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Button {
                                    editedSpeaker = segment.speaker; speakerName = record.speakerName(segment)
                                } label: { Text(record.speakerName(segment)).font(.system(size: 11, weight: .semibold)) }
                                    .buttonStyle(.plain).foregroundStyle(segment.source == "microphone" ? VeloceTheme.amber : VeloceTheme.cyan).disabled(blocked)
                                Text(segment.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}
