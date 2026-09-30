import SwiftUI
import UniformTypeIdentifiers
import VeloceCore

struct MeetingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var meetings: MeetingModel
    @State private var dropTargeted = false

    var body: some View {
        MeetingPageContent(meetings: meetings,
            otherWorkActive: app.isBusy && !meetings.isBusy,
            modelName: app.selectedModel.name,
            start: { meetings.startRecording(model: app.selectedModel, language: app.language, vocabulary: app.vocabulary) },
            transcribe: { id in meetings.transcribeMeeting(id, model: app.selectedModel, language: app.language, vocabulary: app.vocabulary) },
            prepare: { meetings.prepareDiarization(model: app.selectedModel) },
            importAudio: { meetings.chooseAudioFile(model: app.selectedModel, language: app.language, vocabulary: app.vocabulary) })
            .onAppear { meetings.refreshAvailability() }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16).stroke(VeloceTheme.amber, lineWidth: 2)
                        .overlay(alignment: .top) {
                            Text("Déposez vos audios ou vidéos pour les transcrire")
                                .font(.system(size: 12, weight: .medium)).padding(12)
                                .background(VeloceTheme.paper, in: Capsule()).padding(.top, 8)
                        }.allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                MeetingDroppedFiles.read(providers) { urls in
                    meetings.enqueueImports(urls, model: app.selectedModel, language: app.language, vocabulary: app.vocabulary)
                }
                return !providers.isEmpty
            }
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
    @State private var editedSegment: MeetingSegment?
    @State private var segmentText = ""
    @State private var segmentSpeaker = ""
    @State private var mergeSource = ""
    @State private var mergeTarget = ""
    @State private var showMerge = false
    @State private var question = ""
    @State private var questionAllMeetings = false

    private var blocked: Bool { meetings.isBusy || otherWorkActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction
            captureCard
            diarizationCard
            MeetingCalendarCard(calendar: meetings.calendar, blocked: blocked)
            processingStatus
            history
            Text("Les deux pistes restent sur ce Mac. macOS peut nommer l’autorisation « Enregistrement de l’écran et audio système » ; Véloce ne conserve aucune image.")
                .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
        }
        .confirmationDialog("Supprimer cette réunion et son audio dans Véloce ?", isPresented: $confirmDelete, titleVisibility: .visible) {
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
        .sheet(item: $editedSegment) { segment in segmentEditor(segment) }
        .sheet(isPresented: $showMerge) { speakerMerger }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(text: "Les réunions, à votre rythme")
            Text("Écoutez. On garde le fil.")
                .font(.system(size: 34, weight: .medium, design: .rounded)).tracking(-1)
            Text("Enregistrez une réunion, ou déposez vos audios et vidéos. Transcription, recherche et notes restent sur ce Mac.")
                .font(.system(size: 13)).foregroundStyle(VeloceTheme.secondary).lineSpacing(4)
        }
    }

    private var captureCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
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
                        .background(VeloceTheme.paper, in: RoundedRectangle(cornerRadius: 9)).disabled(blocked)
                }
                HStack(spacing: 14) {
                    track("Votre microphone", side: "GAUCHE", symbol: "mic", level: meetings.microphoneLevel, color: VeloceTheme.amber)
                    track("Audio de la réunion", side: "DROITE", symbol: "speaker.wave.2", level: meetings.systemLevel, color: VeloceTheme.cyan)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Transcrire après l’arrêt", isOn: $meetings.transcribeAfterRecording)
                        Toggle("Afficher le texte pendant la réunion", isOn: $meetings.liveTranscription)
                    }.toggleStyle(.checkbox).font(.system(size: 11)).disabled(blocked)
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
                if !meetings.liveStatus.isEmpty {
                    Text(meetings.liveStatus).font(.system(size: 11)).foregroundStyle(VeloceTheme.cyan)
                }
                Text(meetings.liveTranscription
                    ? "Le direct utilise le modèle léger Qwen3 0.6B et s’actualise environ toutes les 15 s. La transcription finale utilise le modèle choisi."
                    : "Jusqu’à 4 h · environ 230 Mo par heure. Un casque évite que le micro reprenne les voix distantes.")
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
                    Button(action: importAudio) { Label("Importer des fichiers…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(VeloceButtonStyle(prominent: false)).disabled(blocked)
                }
                Text("Audios et vidéos MP4/MOV · jusqu’à 4 h par fichier. Glissez plusieurs fichiers ici : ils seront traités l’un après l’autre. L’original reste intact.")
                    .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
            }
        }
    }

    private var diarizationCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "person.2.wave.2").foregroundStyle(VeloceTheme.amber)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Qui a dit quoi ?").font(.system(size: 13, weight: .semibold))
                        Text("Le modèle local distingue les voix. Vous pouvez ensuite nommer les interlocuteurs, les fusionner ou réattribuer un passage.")
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
    }

    private var processingStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if meetings.isBusy && meetings.phase != .recording { ProgressView().controlSize(.small) }
                Text(meetings.status).font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary)
                Spacer()
                if [.processing, .preparing, .summarizing, .importing, .asking].contains(meetings.phase) {
                    Button("Arrêter le traitement", action: meetings.cancelProcessing).font(.system(size: 11))
                }
            }
            if meetings.queuedImportCount > 0 {
                HStack {
                    Text("\(meetings.queuedImportCount) fichier\(meetings.queuedImportCount > 1 ? "s" : "") à traiter, import en cours compris")
                        .font(.system(size: 10)).foregroundStyle(VeloceTheme.cyan)
                    Spacer()
                    if !meetings.isBusy { Button("Annuler l’attente", action: meetings.cancelQueuedImports).font(.system(size: 10)) }
                }
            }
            if !meetings.importFailures.isEmpty {
                Text(meetings.importFailures.joined(separator: "\n")).font(.system(size: 10)).foregroundStyle(VeloceTheme.error).textSelection(.enabled)
            }
            if [.processing, .summarizing, .importing, .asking].contains(meetings.phase) {
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
    }

    @ViewBuilder private var history: some View {
        if !meetings.records.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(text: "Vos réunions sur ce Mac")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(VeloceTheme.secondary)
                    TextField("Rechercher un sujet, un interlocuteur ou une décision…", text: $meetings.searchQuery)
                        .textFieldStyle(.plain)
                    if !meetings.searchQuery.isEmpty { Button { meetings.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(11).background(VeloceTheme.paper, in: RoundedRectangle(cornerRadius: 9))
                if meetings.filteredRecords.isEmpty {
                    Text("Aucune réunion ne correspond à cette recherche.").font(.system(size: 12)).foregroundStyle(VeloceTheme.secondary)
                } else {
                    Picker("Réunion", selection: $meetings.selectedID) {
                        ForEach(meetings.filteredRecords) { record in
                            Text("\(record.title) · \(MeetingRecord.timestamp(record.duration))").tag(Optional(record.id))
                        }
                    }.labelsHidden().disabled(meetings.isBusy)
                    if let record = meetings.selected, record.matches(meetings.searchQuery) { detail(record) }
                }
            }.onChange(of: meetings.searchQuery) { _, _ in
                if meetings.selected?.matches(meetings.searchQuery) != true { meetings.selectedID = meetings.filteredRecords.first?.id }
            }
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
                exportMenu(record)
            }
            if record.status == .interrupted {
                Text("Enregistrement interrompu : les fichiers récupérables restent disponibles dans le dossier de cette réunion.")
                    .font(.system(size: 11)).foregroundStyle(VeloceTheme.amber)
            }
            MeetingPlaybackControls(player: meetings.player, isImported: record.isImported,
                recordDuration: record.duration, blocked: blocked, toggle: meetings.togglePlayback)
            HStack {
                Button(record.segments.isEmpty ? "Transcrire avec \(modelName)" : "Retranscrire") { transcribe(record.id) }
                    .buttonStyle(VeloceButtonStyle(prominent: false)).disabled(blocked)
                if !record.segments.isEmpty {
                    Button("Copier", action: meetings.copyTranscript).disabled(blocked)
                    Spacer()
                    Button(record.notes.isEmpty ? "Créer le compte rendu" : "Régénérer le compte rendu") {
                        if record.notes.isEmpty { meetings.generateNotes() } else { confirmReplaceNotes = true }
                    }.disabled(blocked || meetings.notesUnavailableReason != nil)
                }
            }
            if !record.segments.isEmpty {
                notes(record)
                questionCard
                HStack {
                    Text(record.diarization == "live-tracks" ? "Direct provisoire · Vous / Participants"
                        : record.diarization.hasPrefix("sherpa-") ? "Voix détectées · cliquez sur un nom pour le corriger"
                        : record.isImported ? "Audio importé · interlocuteurs non séparés" : "Repères par source · Vous / Participants")
                        .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                    Spacer()
                    if record.speakers.count > 1 {
                        Button("Fusionner des voix…") {
                            mergeSource = record.speakers.first ?? ""; mergeTarget = record.speakers.dropFirst().first ?? ""; showMerge = true
                        }.font(.system(size: 10)).disabled(blocked)
                    }
                }
                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(record.segments) { segment in
                        MeetingSegmentRow(segment: segment, record: record, player: meetings.player, blocked: blocked,
                            play: { meetings.playSegment(segment) },
                            rename: { editedSpeaker = segment.speaker; speakerName = record.speakerName(segment) },
                            edit: { segmentText = segment.text; segmentSpeaker = segment.speaker; editedSegment = segment })
                    }
                }
            }
        }
    }

    private func exportMenu(_ record: MeetingRecord) -> some View {
        Menu {
            Button("Renommer") { newTitle = record.title; renameTitle = true }
            Button("Afficher les fichiers", action: meetings.revealFiles)
            Divider()
            Button(record.isImported ? "Exporter l’audio WAV…" : "Exporter en stéréo WAV…", action: meetings.exportStereo)
            Button("Exporter texte…") { meetings.export("txt") }
            Button("Exporter Markdown…") { meetings.export("md") }
            Button("Exporter les sous-titres SRT…") { meetings.export("srt") }
            Button("Exporter les sous-titres VTT…") { meetings.export("vtt") }
            Button("Exporter JSON…") { meetings.export("json") }
            Divider()
            Button("Supprimer…", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)) }
            .menuStyle(.borderlessButton).fixedSize().disabled(blocked)
    }

    private func notes(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meetings.notesUnavailableReason ?? "Le compte rendu est généré sur ce Mac avec Apple Intelligence. Relisez les décisions et les actions avant de le partager.")
                .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
            if !record.notes.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionEyebrow(text: "Compte rendu · modifiable")
                        Text("Vos notes sont conservées lors d’une retranscription.")
                            .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                        TextEditor(text: Binding(get: { meetings.selected?.notes ?? "" }, set: meetings.setNotes))
                            .font(.system(size: 12)).scrollContentBackground(.hidden).frame(minHeight: 180).disabled(blocked)
                    }
                }
            }
        }
    }

    private var questionCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionEyebrow(text: "Demandez à vos réunions")
                HStack {
                    TextField("Qu’a-t-on décidé concernant… ?", text: $question).textFieldStyle(.roundedBorder).disabled(blocked)
                    Button("Demander") { meetings.askQuestion(question, allMeetings: questionAllMeetings) }
                        .disabled(blocked || meetings.questionsUnavailableReason != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Toggle("Rechercher dans toutes mes réunions", isOn: $questionAllMeetings)
                    .toggleStyle(.checkbox).font(.system(size: 11)).disabled(blocked)
                if let reason = meetings.questionsUnavailableReason {
                    Text(reason).font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                } else {
                    Text("Réponse locale accompagnée de ses passages sources. Les extraits retrouvés peuvent ne pas couvrir toute la réunion.")
                        .font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                }
                if !meetings.questionAnswer.isEmpty {
                    Text(meetings.questionAnswer).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                }
            }
        }
    }

    private func segmentEditor(_ segment: MeetingSegment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Corriger le passage · \(MeetingRecord.timestamp(segment.start))").font(.headline)
            Picker("Interlocuteur", selection: $segmentSpeaker) {
                ForEach(meetings.selected?.speakers ?? [segment.speaker], id: \.self) { speaker in
                    Text(meetings.selected?.speakerNames[speaker] ?? speaker).tag(speaker)
                }
            }
            TextEditor(text: $segmentText).font(.system(size: 13)).frame(minHeight: 180)
            HStack {
                Button("Annuler") { editedSegment = nil }
                Spacer()
                Button("Enregistrer") {
                    meetings.editSegment(segment.id, text: segmentText, speaker: segmentSpeaker); editedSegment = nil
                }.keyboardShortcut(.defaultAction).disabled(segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 550)
    }

    private var speakerMerger: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Fusionner deux interlocuteurs").font(.headline)
            Text("Tous les passages de la première voix seront attribués à la seconde. Les pistes audio et les horodatages restent conservés.")
                .font(.system(size: 12)).foregroundStyle(VeloceTheme.secondary)
            Picker("Voix à réattribuer", selection: $mergeSource) {
                ForEach(meetings.selected?.speakers ?? [], id: \.self) { Text(meetings.selected?.speakerNames[$0] ?? $0).tag($0) }
            }
            Picker("Attribuer à", selection: $mergeTarget) {
                ForEach(meetings.selected?.speakers ?? [], id: \.self) { Text(meetings.selected?.speakerNames[$0] ?? $0).tag($0) }
            }
            HStack {
                Button("Annuler") { showMerge = false }
                Spacer()
                Button("Fusionner") { meetings.mergeSpeaker(mergeSource, into: mergeTarget); showMerge = false }
                    .disabled(mergeSource == mergeTarget || mergeSource.isEmpty || mergeTarget.isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
}

private struct MeetingSegmentRow: View {
    let segment: MeetingSegment
    let record: MeetingRecord
    @ObservedObject var player: MeetingPlayer
    let blocked: Bool
    let play: () -> Void
    let rename: () -> Void
    let edit: () -> Void
    private var active: Bool { player.isPlaying && player.position >= segment.start && player.position < segment.end }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Button(action: play) {
                VStack(spacing: 5) {
                    Text(MeetingRecord.timestamp(segment.start)).font(.system(size: 10, design: .monospaced))
                    Image(systemName: active ? "speaker.wave.2.fill" : "play.circle").font(.system(size: 12))
                }.frame(width: 55, alignment: .leading)
            }.buttonStyle(.plain).foregroundStyle(active ? VeloceTheme.amber : VeloceTheme.secondary).disabled(blocked)
            VStack(alignment: .leading, spacing: 5) {
                Button(action: rename) { Text(record.speakerName(segment)).font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(segment.source == "microphone" ? VeloceTheme.amber : VeloceTheme.cyan).disabled(blocked)
                Text(segment.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: edit) { Image(systemName: "pencil").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(VeloceTheme.secondary).disabled(blocked).help("Corriger le texte ou l’interlocuteur")
        }.padding(8).background(active ? VeloceTheme.amber.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingPlaybackControls: View {
    @ObservedObject var player: MeetingPlayer
    let isImported: Bool
    let recordDuration: Double
    let blocked: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Button(action: toggle) { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 25)) }
                    .buttonStyle(.plain).foregroundStyle(VeloceTheme.amber).disabled(blocked)
                Slider(value: Binding(get: { player.position }, set: player.seek), in: 0...max(0.01, player.duration > 0 ? player.duration : recordDuration))
                    .tint(VeloceTheme.amber).disabled(blocked || player.duration == 0)
                Text("\(MeetingRecord.timestamp(player.position)) / \(MeetingRecord.timestamp(recordDuration))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(VeloceTheme.secondary)
            }
            if !isImported {
                HStack(spacing: 16) {
                    Toggle("Microphone", isOn: $player.microphoneEnabled)
                    Toggle("Audio système", isOn: $player.systemEnabled)
                }.toggleStyle(.checkbox).font(.system(size: 10)).disabled(blocked)
            }
        }.padding(12).background(VeloceTheme.paper, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MeetingCalendarCard: View {
    @ObservedObject var calendar: MeetingCalendarService
    let blocked: Bool

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Les prochaines réunions", systemImage: "calendar").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if calendar.connected {
                        Button("Actualiser") { Task { await calendar.refresh() } }.font(.system(size: 10))
                        Button("Déconnecter", action: calendar.disconnect).font(.system(size: 10))
                    } else {
                        Button(calendar.isConnecting ? "Connexion…" : "Connecter le calendrier", action: calendar.connect)
                            .buttonStyle(VeloceButtonStyle(prominent: false)).disabled(calendar.isConnecting)
                    }
                }
                if calendar.connected {
                    Toggle("Me rappeler les réunions 2 minutes avant", isOn: Binding(get: { calendar.remindersEnabled }, set: calendar.setReminders))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    if calendar.entries.isEmpty {
                        Text("Aucune réunion prévue dans les 7 prochains jours.").font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary)
                    }
                    ForEach(calendar.entries.prefix(8)) { entry in
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
                            Text(entry.title).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Button("Préparer") { calendar.prepare(entry) }.font(.system(size: 10)).disabled(blocked)
                        }
                    }
                } else {
                    Text("Optionnel : affichez votre calendrier et recevez des rappels locaux. L’enregistrement démarre quand vous le choisissez.")
                        .font(.system(size: 11)).foregroundStyle(VeloceTheme.secondary).lineSpacing(3)
                }
                if let error = calendar.error { Text(error).font(.system(size: 11)).foregroundStyle(VeloceTheme.error) }
            }
        }
    }
}

private enum MeetingDroppedFiles {
    static func read(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let result = DroppedURLCollector()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                if let url, url.isFileURL { result.append(url, at: index) }
            }
        }
        group.notify(queue: .main) { completion(result.urls) }
    }
}

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, URL)] = []
    func append(_ url: URL, at index: Int) { lock.lock(); values.append((index, url)); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.0 < $1.0 }.map(\.1) }
}
