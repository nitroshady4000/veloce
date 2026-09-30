import SwiftUI
import VeloceCore

private enum VelocePage: String, CaseIterable, Identifiable {
    case dictate = "Dicter"
    case models = "Modèles"
    case settings = "Réglages"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dictate: "waveform"
        case .models: "square.stack.3d.up"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: VelocePage = .dictate

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(VeloceTheme.line.opacity(0.55)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text(page.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Label("Sur votre Mac", systemImage: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(VeloceTheme.secondary)
                    }
                    .padding(.bottom, 2)
                    switch page {
                    case .dictate: DictationView()
                    case .models: ModelsView()
                    case .settings: SettingsView()
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 34)
                .padding(.bottom, 32)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            .background(VeloceTheme.paper)
        }
        .foregroundStyle(VeloceTheme.ink)
        .background(VeloceTheme.paper)
        .frame(minWidth: 900, minHeight: 650)
        .preferredColorScheme(.light)
        .onAppear { model.refreshPermissions() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                VeloceMark(size: 30)
                Text("Véloce")
                    .font(.system(size: 29, weight: .medium, design: .serif))
                    .tracking(-1.3)
            }
            .padding(.top, 38)
            Text("Votre voix, simplement.")
                .font(.system(size: 11))
                .foregroundStyle(VeloceTheme.secondary)
                .padding(.top, 10)
                .padding(.leading, 3)

            VStack(spacing: 6) {
                ForEach(VelocePage.allCases) { item in
                    Button {
                        page = item
                        if item == .settings { model.refreshPermissions() }
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 20)
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            Spacer()
                            if page == item {
                                Circle().fill(VeloceTheme.accent).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .foregroundStyle(page == item ? VeloceTheme.ink : VeloceTheme.secondary)
                        .background(page == item ? Color.white.opacity(0.74) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            .padding(.top, 42)

            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(VeloceTheme.green).frame(width: 6, height: 6)
                    Text("LOCAL PAR NATURE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                }
                Text("Votre voix reste ici.\nVos mots vont partout.")
                    .font(.system(size: 11))
                    .lineSpacing(4)
                    .foregroundStyle(VeloceTheme.secondary)
                Rectangle().fill(VeloceTheme.line).frame(height: 1).padding(.vertical, 7)
                HStack {
                    Text("Véloce · 0.1")
                    Spacer()
                    Text("Open source")
                }
                .font(.system(size: 9))
                .foregroundStyle(VeloceTheme.secondary)
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 25)
        }
        .padding(.horizontal, 20)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(VeloceTheme.sidebar)
    }
}
