//
//  SettingsRoot.swift
//  Oto
//
//  Native macOS settings shell: system sidebar, sidebar search, toolbar
//  navigation history, and feature panes backed by the existing stores.
//

import SwiftUI
import AppKit

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
    nonisolated static let minimumSidebarWidth: CGFloat = 170
    nonisolated static let sidebarWidth: CGFloat = 194

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
        SettingsSplitView(sidebar: sidebarContent, detail: detailContent)
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
        .toolbar(removing: .title)
        .frame(
            minWidth: Self.minimumWidth,
            idealWidth: Self.width,
            maxWidth: .infinity,
            minHeight: Self.minimumHeight,
            idealHeight: Self.height,
            maxHeight: .infinity
        )
        .task {
            uiState.ensureLoaded()
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search settings")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.quaternary, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.7))
            .padding(.horizontal, 10)
            .padding(.top, 10)

            List(selection: selectionBinding) {
                if filteredPanes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredPanes) { pane in
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
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(.primary)
        }
        .frame(minWidth: Self.minimumSidebarWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .font(.system(size: 13))
        .fontDesign(.rounded)
    }

    private struct SettingsSplitView: NSViewControllerRepresentable {
        let sidebar: AnyView
        let detail: AnyView

        init<Sidebar: View, Detail: View>(sidebar: Sidebar, detail: Detail) {
            self.sidebar = AnyView(sidebar)
            self.detail = AnyView(detail)
        }

        func makeNSViewController(context: Context) -> SettingsSplitViewController {
            let sidebarHost = NSHostingController(rootView: sidebar)
            let detailHost = NSHostingController(rootView: detail)
            sidebarHost.sizingOptions = []
            detailHost.sizingOptions = []

            let controller = SettingsSplitViewController()
            controller.view.frame = NSRect(x: 0, y: 0, width: SettingsRoot.width, height: SettingsRoot.height)

            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
            sidebarItem.minimumThickness = 170
            sidebarItem.maximumThickness = 210
            sidebarItem.canCollapse = false
            controller.addSplitViewItem(sidebarItem)

            let detailItem = NSSplitViewItem(viewController: detailHost)
            detailItem.minimumThickness = SettingsRoot.minimumWidth - 170
            controller.addSplitViewItem(detailItem)
            controller.splitView.setPosition(SettingsRoot.sidebarWidth, ofDividerAt: 0)
            return controller
        }

        func updateNSViewController(_ controller: SettingsSplitViewController, context: Context) {
            (controller.splitViewItems.first?.viewController as? NSHostingController<AnyView>)?.rootView = sidebar
            (controller.splitViewItems.dropFirst().first?.viewController as? NSHostingController<AnyView>)?.rootView = detail
        }
    }

    private final class SettingsSplitViewController: NSSplitViewController {
        override func viewDidAppear() {
            super.viewDidAppear()
            view.window?.minSize = NSSize(width: SettingsRoot.minimumWidth, height: SettingsRoot.minimumHeight)
        }
    }

    private var detailContent: some View {
        Form {
            paneContent
        }
        .formStyle(.grouped)
        .font(.system(size: 13))
        .fontDesign(.rounded)
        .controlSize(.regular)
        .textFieldStyle(.roundedBorder)
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
