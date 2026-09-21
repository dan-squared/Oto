//
//  SettingsRoot.swift
//  Oto
//

import SwiftUI

/// First-release Settings destinations. Two real panes; Writing and
/// Privacy & History arrive with their Phase 6 stores — no blank panes.
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

/// Native Settings root: `NavigationSplitView` + `List(selection:)` per the
/// navigation rules. No custom chrome, no second window, no nested sidebars.
struct SettingsRoot: View {
    let dispatch: ShortcutDispatch
    let preparer: SpeechAssetPreparer
    let permissions: PermissionsManager
    let login: any LoginItemManaging

    @State private var selection: SettingsPane? = .dictation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationTitle("Oto")
        } detail: {
            switch selection ?? .dictation {
            case .general:
                GeneralPane(login: login)
            case .dictation:
                DictationPane(dispatch: dispatch, preparer: preparer, permissions: permissions)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
