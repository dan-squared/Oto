//
//  SettingsRoot.swift
//  Oto
//
//  Settings as a native split view: destinations down the left column, one
//  page on the right, inside an ordinary window scene (not a Settings
//  scene — ⌘-comma is wired by hand in OtoApp for that reason). Native
//  NavigationSplitView + List do the structure, scrolling and accessibility;
//  only the row fills are ours, because the system selection renderer is
//  what paints accent blue and bolds the label.
//

import SwiftUI

/// First-release Settings destinations: six focused panes (General,
/// Dictation, Dictionary, Snippets, History, Privacy) — no blank tabs,
/// every pane binds a real backend.
enum SettingsPane: Hashable, CaseIterable, Identifiable {
    case general
    case dictation
    case dictionary
    case snippets
    case history
    case privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .history: "History"
        case .privacy: "Privacy"
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
        }
    }
}

struct SettingsRoot: View {
    let dispatch: ShortcutDispatch
    /// Bindable because the split view owns a `Binding` to the column
    /// visibility. `@Observable` class, so the memberwise initializer keeps
    /// the same call site; the panes still take it as a plain `let`.
    @Bindable var uiState: SettingsUIState
    let login: any LoginItemManaging
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let history: HistoryStore

    /// Panel size (+15% over the reference 660×500: room for Oto's recorder
    /// rows with air to spare). FIXED, not a minimum: the window is pinned
    /// to content size, so a constant ideal size is what keeps the window
    /// from re-fitting itself when the column toggles. Per-page ScrollViews
    /// absorb any small-screen overflow.
    nonisolated static let width: CGFloat = 805
    nonisolated static let height: CGFloat = 621

    /// Sidebar column width, locked: min == ideal == max means the column
    /// cannot animate to a different width, which is half the snap fix.
    nonisolated static let sidebarWidth: CGFloat = 210

    /// Sidebar row metrics, hoisted so the numbers that were reported as
    /// broken are pinned by tests instead of hunted in a view body.
    /// `rowPillGap` is the clear space between two neighbouring row pills —
    /// it was 6 and the pills read as touching; 8 is the fix.
    nonisolated static let rowHeight: CGFloat = 36
    nonisolated static let rowFillInsetX: CGFloat = 6
    nonisolated static let rowFillInsetY: CGFloat = 4
    nonisolated static var rowPillGap: CGFloat { rowFillInsetY * 2 }

    @State private var selection: SettingsPane = .dictation

    var body: some View {
        NavigationSplitView(columnVisibility: $uiState.columnVisibility) {
            // No selection binding: the accent selection renderer paints
            // blue + bolds regardless of tint/weight/clear-background
            // (proven by screenshots). Selection is manual state + explicit
            // fills, so only these pixels can ever appear.
            List {
                ForEach(SettingsPane.allCases) { item in
                    SidebarRow(item: item, selected: selection == item) {
                        selection = item
                    }
                }
            }
            .listStyle(.sidebar)
            // No background of our own: the native sidebar vibrancy shows
            // through (that is the "more transparent" ask) and it resolves
            // per scheme on its own. The List still has to be told not to
            // paint a ground over it.
            .scrollContentBackground(.hidden)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(
                min: Self.sidebarWidth,
                ideal: Self.sidebarWidth,
                max: Self.sidebarWidth
            )
        } detail: {
            content
        }
        .frame(width: Self.width, height: Self.height)
        .task {
            uiState.ensureLoaded()
        }
    }

    // Rows are native Buttons (press physics, correct VoiceOver role,
    // keyboard activation) that render fully explicitly: translucent
    // monochrome pill when selected (never solid, never blue), hover fill
    // only when unselected — text, weight and icon never shift on hover.
    // The "bold on hover" was a muted→ink contrast illusion, so removing the
    // text shift removes the effect structurally.
    private struct SidebarRow: View {
        let item: SettingsPane
        let selected: Bool
        let act: () -> Void
        @State private var hovering = false
        @Environment(\.colorScheme) private var scheme

        /// Row content height. 36 keeps the 32pt rows' air at the new
        /// label size; the fill insets below add the breathing so a hovered
        /// row never touches the selected pill.
        private static let contentHeight = SettingsRoot.rowHeight
        private static let fillRadius: CGFloat = 8
        private static let fillInsetX = SettingsRoot.rowFillInsetX
        /// 4 top + 4 bottom on a 36pt row = 44pt pitch, so adjacent pills
        /// stand 8pt apart. 3 left them touching (reported).
        private static let fillInsetY = SettingsRoot.rowFillInsetY

        var body: some View {
            Button(action: act) {
                Label {
                    Text(item.title)
                        .font(.system(size: 14))
                        .fontWeight(.regular)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 16, height: 16)
                }
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .frame(height: Self.contentHeight)
                // Fill the row and claim all of it: without these the hit
                // area hugged the text, so clicking the row beside the label
                // silently did nothing (reported as "rejects clicks").
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Plain, deliberately NOT OtoBounce: a spring scale inside a
            // List row animates the row's own layout mid-press, which both
            // looks wrong and can lose the mouse-up. Selection switching
            // instantly is the feedback here.
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            // The fill lives in listRowBackground so it spans the full row
            // width at any sidebar size (a .background here would hug the
            // label). The insets are what separate neighbouring pills.
            // This replaces the native selection surface.
            .listRowBackground(
                RoundedRectangle(cornerRadius: Self.fillRadius, style: .continuous)
                    .fill(rowFill)
                    .padding(.horizontal, Self.fillInsetX)
                    .padding(.vertical, Self.fillInsetY)
            )
        }

        private var isDark: Bool { scheme == .dark }

        // Explicit literals per scheme, never adaptive tokens: an adaptive
        // token inside a row background resolved to white in light mode,
        // which is how a black pill with invisible text happened.
        private var rowFill: Color {
            if selected {
                return (isDark ? Color.white : Color.black)
                    .opacity(OtoPalette.selectedFillOpacity)
            }
            return hovering ? OtoPalette.hover : .clear
        }

        private var textColor: Color {
            if selected { return isDark ? .black : .white }
            return OtoPalette.muted
        }

        private var iconColor: Color {
            if selected { return isDark ? .black : .white }
            return isDark ? .white : OtoPalette.muted
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(selection.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OtoPalette.ink)

                // Reopen control, parked in the page header: the previous
                // toolbar item drew the system's own oval plate around it
                // (a toolbar item's background is not ours to shape), and
                // the older overlay landed on top of this very title. Here
                // it is a plain square button, only while the sidebar is
                // hidden, and it can never overlap anything.
                if !uiState.sidebarVisible {
                    OtoDoor(
                        systemName: "sidebar.left",
                        showsPlate: true,
                        help: "Show sidebar"
                    ) {
                        uiState.setSidebar(true)
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    switch selection {
                    case .general:
                        GeneralPane(login: login)
                    case .dictation:
                        DictationPane(dispatch: dispatch, uiState: uiState)
                    case .dictionary:
                        DictionaryPane(
                            coordinator: coordinator,
                            dictionary: dictionary
                        )
                    case .snippets:
                        SnippetsPane(snippets: snippets)
                    case .history:
                        HistoryPane(history: history)
                    case .privacy:
                        PrivacyPane(uiState: uiState)
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
