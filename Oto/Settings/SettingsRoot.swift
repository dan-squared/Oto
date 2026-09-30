//
//  SettingsRoot.swift
//  Oto
//
//  Settings as a rail: pages down the left, one page on the right — the
//  reference panel's shape (168 rail + hairline + content) inside the
//  native Settings scene, so Cmd-comma and SettingsLink keep targeting
//  the same window. Panes are untouched logic; only this frame changed.
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

    var title: String {
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

struct SettingsRoot: View {
    let dispatch: ShortcutDispatch
    let uiState: SettingsUIState
    let login: any LoginItemManaging
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let history: HistoryStore

    /// Fixed panel size (+15% over the reference 660×500: room for Oto's
    /// recorder rows with air to spare); per-page ScrollViews absorb
    /// small-screen overflow.
    nonisolated static let width: CGFloat = 805
    nonisolated static let height: CGFloat = 621

    @State private var selection: SettingsPane = .dictation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .font(.system(size: 14))
                    .fontWeight(.regular)
            }
            .listStyle(.sidebar)
            // Monochrome selection (not blue): primary reads black in
            // light, white in dark. Matrix screenshot decides; fallback
            // is a custom listRowBackground (plan §3).
            .tint(.primary)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            content
        }
        .frame(width: Self.width, height: Self.height)
        .task {
            uiState.ensureLoaded()
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selection.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OtoPalette.ink)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    switch selection {
                    case .general:
                        GeneralPane(login: login)
                    case .dictation:
                        DictationPane(dispatch: dispatch, uiState: uiState)
                    case .writing:
                        WritingPane(
                            coordinator: coordinator,
                            dictionary: dictionary,
                            snippets: snippets
                        )
                    case .privacyHistory:
                        PrivacyHistoryPane(
                            history: history,
                            uiState: uiState
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
