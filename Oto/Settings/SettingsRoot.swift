//
//  SettingsRoot.swift
//  Oto
//

import SwiftUI

/// First-release Settings destinations. Two real tabs; Writing and
/// Privacy & History arrive with their Phase 6 stores — no blank tabs.
/// The enum is extensible: Phase 6 adds cases, nothing here changes shape.
enum SettingsPane: Hashable, CaseIterable, Identifiable {
    case general
    case dictation

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        }
    }
}

/// Toolbar-tab Settings root (§phase-5-topbar, user-approved override of
/// the 03 sidebar mandate): `TabView` as the direct root of the Settings
/// scene renders tabs as native toolbar items with the selected tab's name
/// centered in the titlebar. No sidebar, no toggle, nothing to collapse.
/// Panes are untouched; revert receipt lives in the plan.
struct SettingsRoot: View {
    let dispatch: ShortcutDispatch
    let preparer: SpeechAssetPreparer
    let permissions: PermissionsManager
    let login: any LoginItemManaging

    @State private var selection: SettingsPane = .dictation

    var body: some View {
        TabView(selection: $selection) {
            GeneralPane(login: login)
                .tag(SettingsPane.general)
                .tabItem { Label(SettingsPane.general.title, systemImage: SettingsPane.general.symbol) }
            DictationPane(dispatch: dispatch, preparer: preparer, permissions: permissions)
                .tag(SettingsPane.dictation)
                .tabItem { Label(SettingsPane.dictation.title, systemImage: SettingsPane.dictation.symbol) }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
