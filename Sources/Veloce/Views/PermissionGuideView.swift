import SwiftUI

struct PermissionGuideState {
    var microphonePermission: MicrophonePermission = .notDetermined
    var accessibilityGranted = false
    var hotkeyReady = false
    var requestingMicrophone = false
    var accessibilityRequested = false
    var permissionSettingsOpened: VelocePermission?
    var permissionError: String?
    var applicationPath = Bundle.main.bundleURL.path
    var microphoneGranted: Bool { microphonePermission == .granted }
    var inputReady: Bool { accessibilityGranted && hotkeyReady }
    var allPermissionsReady: Bool { microphoneGranted && inputReady }
}

enum PermissionGuideAction {
    case requestMicrophone, requestAccessibility, refresh, revealApplication, done
    case openSettings(VelocePermission)
}

struct PermissionGuideView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let initialPermission: VelocePermission

    var body: some View {
        PermissionGuideContent(
            state: PermissionGuideState(
                microphonePermission: model.microphonePermission,
                accessibilityGranted: model.accessibilityGranted,
                hotkeyReady: model.hotkeyReady,
                requestingMicrophone: model.requestingMicrophone,
                accessibilityRequested: model.accessibilityRequested,
                permissionSettingsOpened: model.permissionSettingsOpened,
                permissionError: model.permissionError
            ),
            initialPermission: initialPermission
        ) { action in
            switch action {
            case .requestMicrophone: model.authorizeMicrophone()
            case .requestAccessibility: model.authorizeAccessibility()
            case .refresh: model.refreshPermissions()
            case .revealApplication: model.revealApplicationForPermissions()
            case .openSettings(let permission): model.openPermissionSettings(permission)
            case .done: dismiss()
            }
        }
    }
}

/// The presentation has no permission or event-tap side effects, including in previews.
struct PermissionGuideContent: View {
    let state: PermissionGuideState
    let onAction: (PermissionGuideAction) -> Void
    @State private var selected: VelocePermission
    @State private var showRecovery = false

    init(state: PermissionGuideState, initialPermission: VelocePermission, onAction: @escaping (PermissionGuideAction) -> Void) {
        self.state = state
        self.onAction = onAction
        _selected = State(initialValue: initialPermission)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .top) {
                VeloceMark(size: 39)
                Spacer()
                Button { onAction(.done) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(VeloceTheme.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer le guide des permissions")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(state.allPermissionsReady ? "Tout est prêt." : "Un instant, et c’est à vous.")
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .tracking(-0.7)
                Text(state.allPermissionsReady ? "Véloce peut vous entendre et écrire dans vos apps." : "Deux permissions pour parler avec Fn et retrouver vos mots là où vous écrivez.")
                    .font(.system(size: 12))
                    .foregroundStyle(VeloceTheme.secondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 10) {
                permissionCard(.microphone, title: "Microphone", symbol: "mic", ready: state.microphoneGranted)
                permissionCard(.accessibility, title: "Fn et insertion", symbol: "keyboard", ready: state.inputReady)
            }

            if !state.allPermissionsReady {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 7) {
                        Image(systemName: detailSymbol)
                            .foregroundStyle(VeloceTheme.amber)
                        Text(detailTitle)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(VeloceTheme.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    if shouldShowSettingsPreview {
                        settingsPreview
                    }
                    if let error = state.permissionError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(VeloceTheme.error)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VeloceTheme.card, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(VeloceTheme.line, lineWidth: 1))
            }

            HStack {
                if state.requestingMicrophone {
                    ProgressView().controlSize(.small)
                    Text("Répondez à la demande de macOS…")
                        .font(.system(size: 11))
                        .foregroundStyle(VeloceTheme.secondary)
                } else {
                    Label("Vérification automatique", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(VeloceTheme.secondary)
                }
                Spacer(minLength: 12)
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(VeloceButtonStyle())
                    .disabled(state.requestingMicrophone || (selected == .microphone && state.microphonePermission == .restricted))
            }

            if !state.allPermissionsReady {
                DisclosureGroup("Besoin d’un coup de main ?", isExpanded: $showRecovery) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(recoveryText)
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .foregroundStyle(VeloceTheme.secondary)
                        if selected == .accessibility {
                            HStack(spacing: 16) {
                                Button("Retrouver cette app", action: { onAction(.revealApplication) })
                                Button("Ouvrir Accessibilité") { onAction(.openSettings(.accessibility)) }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(VeloceTheme.accent)
                            Text(state.applicationPath)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(VeloceTheme.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 11))
                .foregroundStyle(VeloceTheme.secondary)
            }

            Text("Votre audio reste sur ce Mac. Le microphone s’active uniquement pendant une dictée.")
                .font(.system(size: 10))
                .foregroundStyle(VeloceTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(27)
        .frame(width: 560)
        .foregroundStyle(VeloceTheme.ink)
        .background(VeloceTheme.paper)
        .onAppear { onAction(.refresh) }
        .onChange(of: state.microphoneGranted) { _, granted in
            if granted && selected == .microphone && !state.inputReady { selected = .accessibility }
        }
        .onChange(of: state.inputReady) { _, ready in
            if ready && selected == .accessibility && !state.microphoneGranted { selected = .microphone }
        }
    }

    private func permissionCard(_ permission: VelocePermission, title: String, symbol: String, ready: Bool) -> some View {
        Button { selected = permission; showRecovery = false } label: {
            HStack(spacing: 10) {
                Image(systemName: ready ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(ready ? VeloceTheme.green : VeloceTheme.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(ready ? "Prêt" : permission == .accessibility && state.accessibilityGranted ? "À vérifier" : "À autoriser")
                        .font(.system(size: 10))
                        .foregroundStyle(VeloceTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(selected == permission ? VeloceTheme.amber.opacity(0.08) : VeloceTheme.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected == permission ? VeloceTheme.amber.opacity(0.4) : VeloceTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(ready ? "prêt" : "à configurer")")
        .accessibilityAddTraits(selected == permission ? .isSelected : [])
    }

    private var selectedReady: Bool { selected == .microphone ? state.microphoneGranted : state.inputReady }
    private var shouldShowSettingsPreview: Bool {
        if selected == .accessibility { return !state.accessibilityGranted }
        return state.microphonePermission == .denied
    }
    private var detailSymbol: String {
        if selectedReady { return "checkmark.circle" }
        if selected == .accessibility && state.accessibilityGranted { return "exclamationmark.circle" }
        return selected == .microphone ? "mic" : "cursorarrow.rays"
    }
    private var detailTitle: String {
        if selectedReady { return "Cette permission est prête." }
        if selected == .accessibility {
            return state.accessibilityGranted ? "Fn attend encore le feu vert." : "Autorisez Véloce dans Accessibilité."
        }
        switch state.microphonePermission {
        case .notDetermined: return "Laissez Véloce vous entendre."
        case .denied: return "Activez le microphone pour Véloce."
        case .restricted: return "Le microphone est restreint sur ce Mac."
        case .granted: return "Le microphone est prêt."
        }
    }
    private var detailText: String {
        if selectedReady { return "Passez à l’autre permission pour terminer la configuration." }
        if selected == .accessibility {
            if state.accessibilityGranted {
                return "L’accès est autorisé, mais le raccourci n’a pas encore démarré. Réessayez ; si nécessaire, utilisez l’aide ci-dessous."
            }
            if state.accessibilityRequested || state.permissionSettingsOpened == .accessibility {
                return "Dans Confidentialité et sécurité → Accessibilité, activez l’interrupteur à côté de Véloce. Nous vérifions dès que l’accès est disponible."
            }
            return "macOS vous demandera d’ouvrir ses réglages. Activez ensuite Véloce pour détecter Fn et insérer vos dictées dans vos apps."
        }
        switch state.microphonePermission {
        case .notDetermined: return "Cliquez sur Autoriser, puis acceptez la demande de macOS. Vous gardez le contrôle : Véloce écoute seulement pendant la dictée."
        case .denied: return "Dans Confidentialité et sécurité → Microphone, activez Véloce. L’état se mettra à jour automatiquement."
        case .restricted: return "Un réglage système ou une règle d’administration empêche l’accès. Une personne qui administre ce Mac doit lever cette restriction."
        case .granted: return "Le microphone est autorisé."
        }
    }
    private var primaryTitle: String {
        if state.allPermissionsReady { return "C’est prêt" }
        if selectedReady { return "Continuer" }
        if selected == .microphone {
            switch state.microphonePermission {
            case .notDetermined: return "Autoriser le microphone"
            case .denied: return "Ouvrir les réglages"
            case .restricted: return "Accès restreint"
            case .granted: return "Continuer"
            }
        }
        if state.accessibilityGranted { return "Réessayer la détection" }
        return state.accessibilityRequested ? "Ouvrir les réglages" : "Autoriser Fn et l’insertion"
    }
    private func primaryAction() {
        if state.allPermissionsReady { onAction(.done) }
        else if selectedReady { selected = selected == .microphone ? .accessibility : .microphone }
        else if selected == .microphone { onAction(.requestMicrophone) }
        else if state.accessibilityGranted { onAction(.refresh); showRecovery = true }
        else { onAction(.requestAccessibility) }
    }
    private var recoveryText: String {
        if selected == .microphone {
            return "Si macOS vous demande de quitter puis de rouvrir Véloce, faites-le une fois le réglage activé. Si aucune entrée Véloce n’apparaît, fermez ce guide puis réessayez la demande de microphone."
        }
        return "Véloce est absent ? Ouvrez son emplacement puis glissez cette app dans la liste Accessibilité. Après une mise à jour de développement, une ancienne entrée peut rester cochée : retirez cette entrée avec −, ajoutez l’app indiquée ci-dessous puis activez-la. Si macOS le demande, quittez et rouvrez Véloce."
    }

    private var settingsPreview: some View {
        HStack(spacing: 10) {
            VeloceMark(size: 23)
            Text("Véloce").font(.system(size: 12, weight: .medium))
            Spacer()
            Text("À activer").font(.system(size: 10)).foregroundStyle(VeloceTheme.secondary)
            ZStack(alignment: .trailing) {
                Capsule().fill(VeloceTheme.green).frame(width: 30, height: 18)
                Circle().fill(.white).frame(width: 14, height: 14).padding(.trailing, 2)
            }
        }
        .padding(11)
        .background(VeloceTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dans Réglages Système, activez l’interrupteur Véloce.")
    }
}
