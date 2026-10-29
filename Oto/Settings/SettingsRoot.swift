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

/// AppKit owns the settings rail so selection, hover, keyboard navigation and
/// icon geometry are one native source-list pattern. SwiftUI `List` painted a
/// second selection behind our custom fill, which created the nested highlight
/// seen in the full-screen build.
private struct OtoSettingsList: NSViewRepresentable {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        init(_ parent: OtoSettingsList) { self.parent = parent }

        var parent: OtoSettingsList
        var updating = false

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            OtoSettingsRow()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let pane = parent.items[row]
            let cell = OtoSettingsCell()
            let well = OtoSettingsIconWell()
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            image.contentTintColor = .labelColor
            image.setAccessibilityElement(false)

            let label = cell.titleField
            label.stringValue = pane.title
            cell.setSelected(parent.selection == pane)
            label.lineBreakMode = .byTruncatingTail
            for view in [well, image, label] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                well.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                well.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                well.widthAnchor.constraint(equalToConstant: 20),
                well.heightAnchor.constraint(equalToConstant: 20),
                image.centerXAnchor.constraint(equalTo: well.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14),
                image.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            updateSelection(in: table)
            guard !updating, parent.items.indices.contains(table.selectedRow) else { return }
            parent.selection = parent.items[table.selectedRow]
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            (rowView.view(atColumn: 0) as? OtoSettingsCell)?.setSelected(tableView.isRowSelected(row))
        }

        func updateSelection(in table: NSTableView) {
            for row in 0 ..< table.numberOfRows {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OtoSettingsCell)?
                    .setSelected(table.isRowSelected(row))
            }
        }
    }

    let items: [SettingsPane]
    @Binding var selection: SettingsPane

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("setting")))
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .default
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel("Settings sections")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let table = scroll.documentView as? NSTableView else { return }
        let old = coordinator.parent.items
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.parent = self
        if old != items || table.numberOfRows != items.count { table.reloadData() }
        if let row = items.firstIndex(of: selection), table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        coordinator.updateSelection(in: table)
    }
}

private final class OtoSettingsCell: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")

    func setSelected(_ selected: Bool) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: selected ? .semibold : .regular)
        titleField.font = font.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
    }
}

private final class OtoSettingsIconWell: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 0.25
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 4.75, yRadius: 4.75)
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        path.fill()
        let outer = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        let border = NSBezierPath()
        border.append(outer)
        border.append(inner)
        border.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        border.addClip()
        NSGradient(
            starting: NSColor.labelColor.withAlphaComponent(0.12),
            ending: NSColor.labelColor.withAlphaComponent(0.025)
        )?.draw(from: NSPoint(x: bounds.midX, y: bounds.maxY), to: NSPoint(x: bounds.midX, y: bounds.minY), options: [])
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class OtoSettingsRow: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            for column in 0 ..< numberOfColumns {
                (view(atColumn: column) as? OtoSettingsCell)?.setSelected(isSelected)
            }
            needsDisplay = true
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointed = true }
    override func mouseExited(with event: NSEvent) { pointed = false }

    override func drawBackground(in dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 8, yRadius: 8)
        if isSelected {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            shape.fill()
        } else if pointed {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            shape.fill()
        }
    }

    private var tracking: NSTrackingArea?
    private var pointed = false { didSet { if pointed != oldValue { needsDisplay = true } } }
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

    nonisolated static let width: CGFloat = 760
    nonisolated static let height: CGFloat = 500
    nonisolated static let minimumWidth: CGFloat = 760
    nonisolated static let minimumHeight: CGFloat = 440
    nonisolated static let maximumWidth: CGFloat = 760
    nonisolated static let minimumSidebarWidth: CGFloat = 170
    nonisolated static let sidebarWidth: CGFloat = 180

    @State private var selection: SettingsPane = .dictation
    @State private var searchText = ""
    @State private var visitedPanes: [SettingsPane] = [.dictation]
    @State private var historyIndex = 0

    private var filteredPanes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(search: searchText) }
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
            maxWidth: Self.maximumWidth,
            minHeight: Self.minimumHeight,
            idealHeight: Self.height,
            maxHeight: .infinity
        )
        .task {
            uiState.ensureLoaded()
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
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
            .frame(height: 22)
            .background(.quaternary, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.7))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Group {
                if filteredPanes.isEmpty {
                    Text("No results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 18)
                        .transition(.opacity)
                } else {
                    OtoSettingsList(items: filteredPanes, selection: $selection)
                        .accessibilityLabel("Settings sections")
                }
            }
            .onChange(of: filteredPanes) { _, panes in
                guard let first = panes.first, !panes.contains(selection) else { return }
                navigate(to: first)
            }
            .animation(.easeOut(duration: 0.2).delay(filteredPanes.isEmpty ? 0.18 : 0), value: filteredPanes.isEmpty)
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
            guard let window = view.window else { return }
            window.contentMinSize = NSSize(width: SettingsRoot.minimumWidth, height: SettingsRoot.minimumHeight)
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
