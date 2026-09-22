//
//  SettingsRoot.swift
//  Oto
//

import SwiftUI

/// First-release Settings destinations. Writing and Privacy & History
/// arrived with their Phase 6A stores — no blank tabs, every tab binds a
/// real backend.
enum SettingsPane: Hashable, CaseIterable, Identifiable {
    case general
    case dictation
    case writing
    case privacyHistory

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .writing: "Writing"
        case .privacyHistory: "Privacy & History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .writing: "text.book.closed"
        case .privacyHistory: "clock"
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
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let history: HistoryStore

    @State private var selection: SettingsPane = .dictation

    var body: some View {
        TabView(selection: $selection) {
            GeneralPane(login: login)
                .tag(SettingsPane.general)
                .tabItem { Label(SettingsPane.general.title, systemImage: SettingsPane.general.symbol) }
            DictationPane(dispatch: dispatch, preparer: preparer, permissions: permissions)
                .tag(SettingsPane.dictation)
                .tabItem { Label(SettingsPane.dictation.title, systemImage: SettingsPane.dictation.symbol) }
            WritingPane(
                coordinator: coordinator,
                dictionary: dictionary,
                snippets: snippets
            )
            .tag(SettingsPane.writing)
            .tabItem { Label(SettingsPane.writing.title, systemImage: SettingsPane.writing.symbol) }
            PrivacyHistoryPane(
                history: history,
                permissions: permissions
            )
            .tag(SettingsPane.privacyHistory)
            .tabItem { Label(SettingsPane.privacyHistory.title, systemImage: SettingsPane.privacyHistory.symbol) }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
