//
//  SettingsRoot.swift
//  Oto
//
//  Native macOS settings shell: system sidebar, sidebar search, toolbar
//  navigation history, and feature panes backed by the existing stores.
//

import SwiftUI

enum SettingsPane: Hashable, CaseIterable, Identifiable {
    case general
    case dictation
    case dictionary
    case snippets
    case history
    case privacy
    case intelligence

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .history: "History"
        case .privacy: "Privacy"
        case .intelligence: "Intelligence"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .dictionary: "book.closed"
        case .snippets: "text.quote"
        case .history: "clock"
        case .privacy: "hand.raised"
        case .intelligence: "sparkles"
        }
    }

    /// Search covers the visible destination name plus the settings people
    /// are likely to look for in that destination.
    var searchTerms: String {
        let terms: String
        switch self {
        case .general:
            terms = "launch login dock flow bar position about version"
        case .dictation:
            terms = "speech shortcut microphone permissions catcher media offline"
        case .dictionary:
            terms = "spoken words replacements rules"
        case .snippets:
            terms = "saved text expansion clipboard"
        case .history:
            terms = "transcripts retention remember delete"
        case .privacy:
            terms = "microphone accessibility speech local data"
        case .intelligence:
            terms = "apple intelligence writing cleanup transforms"
        }
        return "\(title) \(terms)"
    }

    func matches(search query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }
        let words = normalizedQuery
            .localizedLowercase
            .split(whereSeparator: \.isWhitespace)
        let searchable = searchTerms.localizedLowercase
        return words.allSatisfy { searchable.contains($0) }
    }
}

struct SettingsRoot: View {
    let dispatch: ShortcutDispatch
    @Bindable var uiState: SettingsUIState
    let login: any LoginItemManaging
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let history: HistoryStore
    let polish: any PolishServing
    let transforms: TransformDispatch

    nonisolated static let width: CGFloat = 740
    nonisolated static let height: CGFloat = 480
    nonisolated static let minimumWidth: CGFloat = 660
    nonisolated static let minimumHeight: CGFloat = 420
    nonisolated static let minimumSidebarWidth: CGFloat = 194
    nonisolated static let sidebarWidth: CGFloat = 218

    @State private var selection: SettingsPane = .dictation
    @State private var searchText = ""
    @State private var visitedPanes: [SettingsPane] = [.dictation]
    @State private var historyIndex = 0

    private var filteredPanes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(search: searchText) }
    }

    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { selection },
            set: { if let destination = $0 { navigate(to: destination) } }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: selectionBinding) {
                if filteredPanes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredPanes) { pane in
                        sidebarItem(pane)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // NavigationSplitView contributes its own hide-sidebar item
            // unless the removal is scoped to the sidebar column itself.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(
                min: Self.minimumSidebarWidth,
                ideal: Self.sidebarWidth,
                max: 270
            )
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: moveBack) {
                    Image(systemName: "chevron.backward")
                }
                .help("Back")
                .disabled(historyIndex == 0)

                Button(action: moveForward) {
                    Image(systemName: "chevron.forward")
                }
                .help("Forward")
                .disabled(historyIndex >= visitedPanes.count - 1)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .toolbar(removing: .title)
        .frame(
            minWidth: Self.minimumWidth,
            idealWidth: Self.width,
            maxWidth: .infinity,
            minHeight: Self.minimumHeight,
            idealHeight: Self.height,
            maxHeight: .infinity
        )
        .navigationSplitViewStyle(.balanced)
        .task {
            uiState.ensureLoaded()
        }
    }

    @ViewBuilder
    private func sidebarItem(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.symbol)
                .foregroundStyle(.secondary)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(pane)
            .accessibilityHint("\(pane.title) settings")
    }

    private var detailContent: some View {
        Form {
            paneContent
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general:
            GeneralPane(login: login)
        case .dictation:
            DictationPane(dispatch: dispatch, uiState: uiState)
        case .dictionary:
            DictionaryPane(coordinator: coordinator, dictionary: dictionary)
        case .snippets:
            SnippetsPane(snippets: snippets)
        case .history:
            HistoryPane(history: history, polish: polish)
        case .privacy:
            PrivacyPane(uiState: uiState)
        case .intelligence:
            IntelligencePane(polish: polish, transforms: transforms)
        }
    }

    private func navigate(to destination: SettingsPane) {
        guard destination != selection else { return }
        selection = destination

        if historyIndex < visitedPanes.count - 1 {
            visitedPanes.removeSubrange((historyIndex + 1)..<visitedPanes.count)
        }
        visitedPanes.append(destination)
        historyIndex = visitedPanes.count - 1
    }

    private func moveBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        selection = visitedPanes[historyIndex]
    }

    private func moveForward() {
        guard historyIndex < visitedPanes.count - 1 else { return }
        historyIndex += 1
        selection = visitedPanes[historyIndex]
    }
}
