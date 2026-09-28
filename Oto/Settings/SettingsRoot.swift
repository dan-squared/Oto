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
    let preparer: SpeechAssetPreparer
    let permissions: PermissionsManager
    let login: any LoginItemManaging
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let history: HistoryStore

    /// Fixed panel size (reference 660×500, grown for Oto's recorder
    /// rows); per-page ScrollViews absorb small-screen overflow.
    nonisolated static let width: CGFloat = 700
    nonisolated static let height: CGFloat = 540
    nonisolated static let rail: CGFloat = 168

    @State private var selection: SettingsPane = .dictation

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(OtoPalette.hairline).frame(width: 1)
            content
        }
        .frame(width: Self.width, height: Self.height)
        .background(OtoPalette.ground)
    }

    // MARK: - the rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OtoPalette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            ForEach(SettingsPane.allCases) { item in
                PageRow(item: item, on: selection == item) { selection = item }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OtoPalette.wash.opacity(0.45))
    }

    private struct PageRow: View {
        let item: SettingsPane
        let on: Bool
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(item.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? OtoPalette.ink : (hovering ? OtoPalette.ink.opacity(0.75) : OtoPalette.muted))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? OtoPalette.ground : (hovering ? OtoPalette.hover : .clear))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(OtoMotion.quick, value: hovering)
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
                VStack(alignment: .leading, spacing: 18) {
                    switch selection {
                    case .general:
                        GeneralPane(login: login)
                    case .dictation:
                        DictationPane(dispatch: dispatch, preparer: preparer, permissions: permissions)
                    case .writing:
                        WritingPane(
                            coordinator: coordinator,
                            dictionary: dictionary,
                            snippets: snippets
                        )
                    case .privacyHistory:
                        PrivacyHistoryPane(
                            history: history,
                            permissions: permissions
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
