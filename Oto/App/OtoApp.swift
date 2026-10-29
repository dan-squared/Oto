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
    static var settings: OtoSettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = DockVisibility.apply(shown: DockVisibility.isShown())
        OtoProbe.forceAppearance()
        Self.onboarding?.showIfNeeded()
        OtoProbe.captureIfRequested(onboarding: Self.onboarding)
        OtoProbe.captureSettingsIfRequested(settings: Self.settings)
        // Product rule: onboarding owns first-run. A restored Settings window
        // (stale Saved Application State, or quit-mid-onboarding) must not
        // stand while onboarding is unfinished — restoration runs before this
        // delegate callback, so any such window already exists to be closed.
        if OnboardingStore.shouldShow(),
           let settings = SettingsWindowLocator.settingsWindow(in: NSApp.windows)
        {
            settings.close()
        }
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
    private let settingsWindowController: OtoSettingsWindowController
    // Intelligence service (Slice A: Manual only). One instance, shared by
    // Settings and History; single instance, audit S2 rule. Init does no
    // model contact (availability is read on demand), so construction is
    // safe in every host including UI tests.
    private let polishService: any PolishServing = LivePolishService()
    // E2 transforms: selection grabber + serial runner + three-combo
    // dispatch. One instance each (audit S2 rule); runner never touches
    // dictation state, dispatch never interleaves with recording.
    private let transformRunner: TransformRunner
    private let transformDispatch: TransformDispatch

    init() {
        // Dev-only AX tree dump (`--ax-dump[=<bundle>|pid]`): prints and
        // exits before any scene exists. See AXDump.
        AXDump.runIfRequested()
        OtoProbe.runShaderProbeIfRequested()
        // Crash backstop first: a kill mid-dictation leaves the duck flag
        // set — put the user's volume back before anything else runs.
        // One-shot migrations precede it (audit F7): Container-scoped
        // state from the sandboxed era would otherwise be invisible.
        // Dev clean slate first of all (`-OtoCleanSlate`): wipes the domain
        // + support dir and skips the sandbox migration (which would copy
        // cleared data straight back).
        let wipedClean = CleanSlate.wipeIfRequested()
        if !wipedClean {
            LocalPersistence.migrateSandboxedStoreIfNeeded()
        }
        MediaDuck.migrateSandboxedFlagIfNeeded()
        MediaDuck.restoreIfCrashed()
        let relay = AudioBufferRelay()
        let spectrumBox = SpectrumFeedBox()
        let audio = AppleAudioCapture(bufferHandler: { buffer in
            relay.receive(buffer)
            spectrumBox.offer(buffer)
        })
        let speech = AppleSpeechService(relay: relay)
        // Insertion experiment (8b Slice 3): hidden A/B seam, read once
        // here. Defaults reproduce today's behavior exactly — the matrix
        // flips values via `defaults write` + relaunch, zero rebuilds.
        let experiment = InsertionExperiment.current()
        let xpSource: SyntheticEventSource =
            experiment.useDefaultEventSource ? .systemDefault : .privateState
        var insertionEvents = InsertionEvents.live
        insertionEvents.postPaste = {
            await InsertionEvents.postFullCommandV(
                key: PasteKeycodeResolver.keyCode(for: "v"), source: xpSource
            )
        }
        insertionEvents.postCopy = {
            await InsertionEvents.postFullCommandV(
                key: PasteKeycodeResolver.keyCode(for: "c"), source: xpSource
            )
        }
        insertionEvents.postUndo = {
            await InsertionEvents.postFullCommandV(
                key: PasteKeycodeResolver.keyCode(for: "z"), source: xpSource
            )
        }
        var insertionTimings = InsertionTimings()
        insertionTimings.keyStep = experiment.keyStepNs
        insertionTimings.restoreDelay = experiment.restoreDelayNs
        let inserter = RealTextInsertion(
            events: insertionEvents, timings: insertionTimings
        )
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
            mediaDuck: MediaDuck(),
            polish: polishService,
            behaviorProvider: { CleanupBehavior.current() }
        )
        let analyzer = AudioSpectrumAnalyzer()
        let modalController = NoTargetModalController()
        let permissionController = PermissionModalController()
        let transformRunner = TransformRunner(
            grabber: LiveSelectionGrabber(),
            inserter: inserter,
            targetService: RealTargetCapture(),
            polish: polishService
        )
        let flowController = FlowBarController(
            coordinator: coordinator,
            analyzer: analyzer,
            box: spectrumBox,
            modal: modalController,
            permission: permissionController,
            runner: transformRunner
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
        // Shortcut layer: Carbon combos + HID tap (Right Command hold
        // default). No NSEvent monitors in the trigger path — they wedge
        // MenuBarExtra menu tracking (bisect-proven, see HIDEventMonitor).
        dispatch.start()
        let transformDispatch = TransformDispatch(
            runner: transformRunner,
            dictationLive: { await !coordinator.state.isTerminal },
            dictationKinds: {
                (dispatch.configuration.hold.kind, dispatch.configuration.handsFree.kind)
            },
            cancelHoldForCombination: { await coordinator.cancelHoldForCombination() },
            setDictationSuspended: { dispatch.setSuspended($0) }
        )
        self.transformRunner = transformRunner
        self.transformDispatch = transformDispatch
        transformDispatch.start()
        // Intelligence one-shot migration + launch prewarm (E1): legacy
        // Slice-B prefs land on the new cleanup keys once; the model warms
        // while cold. Both gated on sync reads — never a download, never a
        // prompt. (The Slice-B tap→coordinator input clock died with the
        // swap race; the HID tap fires nothing now.)
        CleanupMigrator.migrateIfNeeded()
        let launchCleanup = CleanupBehavior.current()
        if launchCleanup.enabled, launchCleanup.level != .none,
           polishService.availability() == .available
        {
            polishService.prewarm(job: .cleanup(launchCleanup.level))
        }
        // Hoisted UI state first: onboarding shares it (permissions/speech
        // render from one model, never duplicated per surface).
        self.settingsUIState = SettingsUIState(preparer: preparer, permissions: permissions)
        let settingsRoot = SettingsRoot(
            dispatch: dispatch,
            uiState: settingsUIState,
            login: login,
            coordinator: coordinator,
            dictionary: dictionaryStore,
            snippets: snippetStore,
            history: historyStore,
            polish: polishService,
            transforms: transformDispatch
        )
        let settingsController = OtoSettingsWindowController(rootView: settingsRoot)
        self.settingsWindowController = settingsController
        DockRestoreDelegate.settings = settingsController
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
            OtoMenuBarView(
                onboarding: onboarding,
                settings: settingsWindowController
            )
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Oto")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    settingsWindowController.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // This window always keeps its navigation column visible.
            // Remove macOS's Show/Hide Sidebar menu command as well as the
            // toolbar toggle removed by SettingsRoot.
            CommandGroup(replacing: .sidebar) {}
        }
    }
}

/// Finds Oto's Settings window among the app's windows. There is no
/// explicit Settings scene ID, so this predicate remains the onboarding
/// guard for a restored settings window. Split out as a pure function of an
/// array of windows so it can be inspected without a scene or run loop.
enum SettingsWindowLocator {
    /// Native Settings scenes use this title in the app's window list.
    nonisolated static let windowTitle = "Settings"

    /// The one Settings window Oto owns, or nil.
    ///
    /// Requires a titled, non-utility, non-panel window whose title is the
    /// scene's own. The onboarding window is AppKit-hosted and titled
    /// ("Welcome to Oto") and every Oto panel (catcher, permission modal) is
    /// an `NSPanel`, so nothing else can match.
    @MainActor static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { isSettings($0) }
    }

    @MainActor static func isSettings(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !window.styleMask.contains(.utilityWindow)
            && !(window is NSPanel)
            && window.title == windowTitle
    }
}
