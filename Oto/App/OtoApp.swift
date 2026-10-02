//
//  OtoApp.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import SwiftUI

/// Restores the persisted Dock visibility once NSApplication exists.
/// NSApp is nil in App.init (crash-proven 2026-09-21), so this lives in
/// the delegate — silent on failure by design: Regular remains and the
/// stored pref is untouched for next launch (apply writes only on success).
final class DockRestoreDelegate: NSObject, NSApplicationDelegate {
    /// Owned by OtoApp (set in init, before launch finishes). The delegate
    /// carries it because scenes cannot trigger first-launch presentation:
    /// no Oto view instantiates at launch to call `openWindow` from.
    static var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = DockVisibility.apply(shown: DockVisibility.isShown())
        Self.onboarding?.showIfNeeded()
    }
}

@main
struct OtoApp: App {
    /// Phase 5 wiring: REAL audio + REAL Apple Speech behind the unchanged
    /// coordinator seams, the shortcut dispatch layer, and the native
    /// Settings product (General + Dictation) with a production menu.
    /// Default trigger is right-Option hold-to-talk; trigger config
    /// persists via `ShortcutConfiguration` (loaded in dispatch init).
    /// Fakes stay for tests.
    private let coordinator: DictationCoordinator
    private let dispatch: ShortcutDispatch
    private let preparer = SpeechAssetPreparer()
    private let permissions = PermissionsManager()
    private let login: any LoginItemManaging = LiveLoginItemManager()
    // One instance shared by the coordinator pipeline and the menu Retry
    // path — two instances could never diverge in behavior, but one is
    // the honest shape (audit S2).
    private let inserter: RealTextInsertion
    // Slice 6B/6C1: visualizer feed + pill/modal ownership. The spectrum
    // box is forked off the SAME bufferHandler closure as the relay
    // (attaching to the relay would detach speech — single sink).
    private let spectrumBox: SpectrumFeedBox
    private let analyzer: AudioSpectrumAnalyzer
    private let flowController: FlowBarController
    @NSApplicationDelegateAdaptor(DockRestoreDelegate.self) private var dockRestore
    // Phase 6A writing stores. One persistence service; three observable
    // owners passed to Settings. The coordinator receives rule snapshots
    // (values, never store references) and the history sink.
    private let persistence: LocalPersistence
    private let dictionaryStore: DictionaryStore
    private let snippetStore: SnippetStore
    private let historyStore: HistoryStore
    // First-run onboarding window (AppKit-hosted — see
    // OnboardingWindowController for why no SwiftUI scene). Shared with
    // the menu bar re-run entry; single instance, audit S2 rule.
    private let onboarding: OnboardingWindowController
    // Settings UI state (hoisted pane state — mic/speech/permissions load
    // once per app life, never reset by rail navigation; see
    // SettingsUIState). Single instance, audit S2 rule.
    private let settingsUIState: SettingsUIState
    // Intelligence service (Slice A: Manual only). One instance, shared by
    // Settings and History; single instance, audit S2 rule. Init does no
    // model contact (availability is read on demand), so construction is
    // safe in every host including UI tests.
    private let polishService: any PolishServing = LivePolishService()

    init() {
        // Crash backstop first: a kill mid-dictation leaves the duck flag
        // set — put the user's volume back before anything else runs.
        // One-shot migrations precede it (audit F7): Container-scoped
        // state from the sandboxed era would otherwise be invisible.
        LocalPersistence.migrateSandboxedStoreIfNeeded()
        MediaDuck.migrateSandboxedFlagIfNeeded()
        MediaDuck.restoreIfCrashed()
        let relay = AudioBufferRelay()
        let spectrumBox = SpectrumFeedBox()
        let audio = AppleAudioCapture(bufferHandler: { buffer in
            relay.receive(buffer)
            spectrumBox.offer(buffer)
        })
        let speech = AppleSpeechService(relay: relay)
        let inserter = RealTextInsertion()
        let persistence = LocalPersistence()
        let dictionaryStore = DictionaryStore(persistence: persistence)
        let snippetStore = SnippetStore(persistence: persistence)
        let historyStore = HistoryStore(persistence: persistence)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: RealTargetCapture(),
            inserter: inserter,
            history: historyStore,
            mediaDuck: MediaDuck()
        )
        let analyzer = AudioSpectrumAnalyzer()
        let modalController = NoTargetModalController()
        let permissionController = PermissionModalController()
        let flowController = FlowBarController(
            coordinator: coordinator,
            analyzer: analyzer,
            box: spectrumBox,
            modal: modalController,
            permission: permissionController
        )
        self.coordinator = coordinator
        self.inserter = inserter
        self.spectrumBox = spectrumBox
        self.analyzer = analyzer
        self.flowController = flowController
        flowController.start()
        self.persistence = persistence
        self.dictionaryStore = dictionaryStore
        self.snippetStore = snippetStore
        self.historyStore = historyStore
        let dispatch = ShortcutDispatch(coordinator: coordinator)
        self.dispatch = dispatch
        // Shortcut layer: Carbon combos + HID tap (right-Option hold
        // default). No NSEvent monitors in the trigger path — they wedge
        // MenuBarExtra menu tracking (bisect-proven, see HIDEventMonitor).
        dispatch.start()
        // Hoisted UI state first: onboarding shares it (permissions/speech
        // render from one model, never duplicated per surface).
        self.settingsUIState = SettingsUIState(preparer: preparer, permissions: permissions)
        let onboarding = OnboardingWindowController(
            dispatch: dispatch,
            uiState: settingsUIState
        )
        self.onboarding = onboarding
        DockRestoreDelegate.onboarding = onboarding
        // Stores load off the launch path; rules push when ready. Dictation
        // before this lands uses trim-only (today's behavior), never blocks.
        Task {
            await dictionaryStore.load()
            await snippetStore.load()
            await historyStore.load()
            await coordinator.setDictionaryRules(dictionaryStore.rules)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            OtoMenuBarView(coordinator: coordinator, inserter: inserter, dispatch: dispatch, onboarding: onboarding)
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Oto")
        }
        .menuBarExtraStyle(.menu)

        // Native window, not a Settings scene (experiment): identical
        // content, standard window chrome. Cmd-comma is re-wired below
        // since the system only binds it to a Settings scene. The visible
        // title text is removed with the toolbar's title item; the title
        // itself stays, so Exposé, the Window menu and VoiceOver keep a
        // name to show.
        WindowGroup(SettingsWindowLocator.windowTitle, id: SettingsWindowID.id) {
            SettingsRoot(
                dispatch: dispatch,
                uiState: settingsUIState,
                login: login,
                coordinator: coordinator,
                dictionary: dictionaryStore,
                snippets: snippetStore,
                history: historyStore,
                polish: polishService
            )
            // `toolbar(removing:)` is a View modifier, not a Scene one, so
            // the title-text removal belongs on the window's content. This
            // drops the visible "Settings" string while the window keeps its
            // title for Exposé, the Window menu and VoiceOver.
            .toolbar(removing: .title)
        }
        .defaultSize(width: SettingsRoot.width, height: SettingsRoot.height)
        // Content MINIMUM, not content size: a contentSize window re-fits
        // itself whenever the split view's ideal size changes, which is
        // exactly the snap reported when the sidebar was shown/hidden. The
        // window now opens at defaultSize, can grow, and never tracks
        // content. Panes all scroll, so nothing clips at the minimum.
        // Pinned to content size, as before. A fixed content frame means the
        // ideal size never changes, so the window itself cannot re-fit (and
        // so cannot snap) when the column toggles. `.contentMinSize` was
        // tried and rejected: with a min-only frame the content's ideal size
        // is unbounded and the window opened full screen.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommands(uiState: settingsUIState)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Sidebar") {
                    settingsUIState.setSidebar(true)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(settingsUIState.sidebarVisible)

                Button("Hide Sidebar") {
                    settingsUIState.setSidebar(false)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!settingsUIState.sidebarVisible)
            }
        }
    }
}

/// Settings window identity + its Cmd-comma entry. The system binds ⌘,
/// only to a Settings scene, so the native-window experiment re-wires
/// it here (same shortcut, same destination).
enum SettingsWindowID {
    nonisolated static let id = "settings"
}

/// Finds Oto's Settings window among the app's windows. There is no
/// singular `Window` scene in MacOSX27.0.sdk and `openWindow(id:)` has no
/// "focus the existing one" mode, so single-window discipline is
/// hand-rolled — which means the predicate must be pinned, not guessed.
/// Split out as a pure function of an array of windows so it is unit
/// testable without a scene or a run loop.
enum SettingsWindowLocator {
    /// Title carried by the Settings scene's window. One constant, because
    /// it is also the single-open guard's key: if the title-text removal
    /// below turns out to need an empty scene title, this flips and nothing
    /// else moves.
    nonisolated static let windowTitle = "Settings"

    /// The one Settings window Oto owns, or nil.
    ///
    /// Requires a titled, non-utility, non-panel window whose title is the
    /// scene's own. The onboarding window is AppKit-hosted and titled
    /// ("Welcome to Oto") and every Oto panel (catcher, permission modal) is
    /// an `NSPanel`, so nothing else can match.
    nonisolated static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { isSettings($0) }
    }

    nonisolated static func isSettings(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !window.styleMask.contains(.utilityWindow)
            && !(window is NSPanel)
            && window.title == windowTitle
    }
}

private struct SettingsCommands: View {
    let uiState: SettingsUIState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            // Single-open guard: repeated invocations (double-fired key
            // equivalents, rapid menu clicks) focus the live window
            // instead of stacking duplicates.
            if let existing = SettingsWindowLocator.settingsWindow(in: NSApp.windows) {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                // Activate first: as a menu-bar app Oto is often inactive,
                // and a fresh window opened while inactive can land behind.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SettingsWindowID.id)
            }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
