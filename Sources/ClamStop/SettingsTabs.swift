import SwiftUI
import ClamStopShared

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case pro

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .pro: "Pro"
        }
    }
}

/// Content of the settings window: a tab bar over the General and Pro settings.
struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $model.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            switch model.settingsTab {
            case .general:
                SettingsView(model: model)
            case .pro:
                ProSettingsView(model: model)
            }
        }
        .frame(width: 440)
    }
}
