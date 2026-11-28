//
//  SettingsUIStateTests.swift
//  OtoTests
//
//  Hoisted Settings state: initial values are the honest pendings, and
//  the tone mappings are pure over typed stored state (no hardware reads,
//  no string literals outside the single derivation site).
//  Refresh timing (once per window open) belongs to the matrix.
//

import Foundation
import SwiftUI
import Testing
@testable import Oto

@MainActor
struct SettingsUIStateTests {
    private func makeState() -> SettingsUIState {
        SettingsUIState(preparer: SpeechAssetPreparer(), permissions: PermissionsManager())
    }

    @Test func initialValuesAreHonestPendings() {
        let state = makeState()
        #expect(state.micPermission == nil)
        #expect(state.speechReadiness == nil)
        #expect(state.micText == "Checking…")
        #expect(state.micActionText == "Checking…")
        #expect(state.readinessText == "Checking…")
        #expect(state.axTrusted == false)
        #expect(state.inputDevices.isEmpty)
        #expect(state.speechReady == false)
        #expect(state.prepareProgress == nil)
        #expect(state.currentInputName == "System default")
    }

    @Test func micToneMapping() {
        // Typed state in, identical display out — typo'd states are now
        // unrepresentable instead of silent.
        let state = makeState()
        // Unread (nil) is honest pending: grey tone, no denied guidance.
        #expect(state.micPermission == nil)
        #expect(state.micTone == .idle)
        #expect(state.micDeniedGuidance == nil)
        state.micPermission = .granted
        #expect(state.micText == "Allowed")
        #expect(state.micAllowed == true)
        #expect(state.micTone == .ok)
        #expect(state.micDeniedGuidance == nil)
        state.micPermission = .notDetermined
        #expect(state.micText == "Not asked yet")
        #expect(state.micTone == .idle)
        #expect(state.micDeniedGuidance == nil)
        state.micPermission = .denied
        #expect(state.micText == "Denied")
        #expect(state.micTone == .warn)
        #expect(state.micDeniedGuidance != nil)
    }

    /// The pill never ends at a dead state: where a remedy exists the label
    /// is the invitation ("Allow"), and the state stays on the dot and in the
    /// readout-only branch.
    @Test func actionablePillsInviteThePress() {
        let state = makeState()
        state.micPermission = .notDetermined
        #expect(state.micAction == .allow)
        #expect(state.micActionText == "Allow")
        state.micPermission = .denied
        #expect(state.micAction == .openSettings)
        #expect(state.micActionText == "Allow")
        // Nothing to do: the honest state stays, and there is no button.
        state.micPermission = .granted
        #expect(state.micAction == .none)
        #expect(state.micActionText == "Allowed")
        state.micPermission = nil
        #expect(state.micActionText == "Checking…")
        #expect(state.axActionText == "Allow")
    }

    @Test func readinessMappingIsTypedEndToEnd() {
        // No dependency on Apple wording: readiness (not its description
        // string) decides, and copy falls back to "Ready" only for .ready.
        let state = makeState()
        #expect(state.readinessText == "Checking…")
        #expect(state.speechReady == false)
        state.speechReadiness = .assetsPreparing
        #expect(state.readinessText == "Speech assets are still preparing.")
        #expect(state.speechReady == false)
        state.speechReadiness = .microphoneDenied
        #expect(state.readinessText == "Microphone access is needed.")
        #expect(state.speechReady == false)
        state.speechReadiness = .ready
        #expect(state.readinessText == "Ready")
        #expect(state.speechReady == true)
    }

    @Test func currentInputNameFollowsDefault() {
        let state = makeState()
        state.inputDevices = [AudioInputDevice(id: 7, uid: "uid-7", name: "USB Mic")]
        state.defaultInputUID = "uid-7"
        #expect(state.currentInputName == "USB Mic")
        state.defaultInputUID = "gone"
        #expect(state.currentInputName == "System default")
    }

    @Test func sidebarUsesCompactResizableWidth() {
        #expect(SettingsRoot.minimumSidebarWidth == 170)
        #expect(SettingsRoot.sidebarWidth == 180)
    }

    @Test func cancelPrepareResetsStateCleanly() {
        let state = makeState()
        #expect(state.prepareProgress == nil)
        #expect(state.prepareFeedback == nil)
        #expect(state.isPreparing == false)

        state.prepareProgress = 0.42
        state.prepareFeedback = "Preparing…"
        state.cancelPrepare()

        #expect(state.prepareProgress == nil)
        #expect(state.prepareFeedback == nil)
        #expect(state.isPreparing == false)
    }

    @Test func cancelPrepareExitsImmediatelyEvenWhenDownloadHangs() async {
        // Mirrors real macOS 27.2 AssetInstallationRequest.downloadAndInstall(),
        // which can remain suspended after progress.cancel() when mobileassetd stalls.
        let gate = AsyncGate()
        let state = SettingsUIState(
            preparer: SpeechAssetPreparer(),
            permissions: PermissionsManager(),
            prepareHandler: { _ in
                await gate.wait()
                return .failed("Stale late failure after cancel")
            },
            networkConditionProvider: { .online },
            stallHintDelayNanoseconds: 0
        )

        let runTask = Task { await state.runPrepare() }
        // Yield until runPrepare enters preparing state and launches prepareTask.
        for _ in 0..<20 where !state.isPreparing {
            await Task.yield()
        }
        #expect(state.isPreparing == true)

        state.cancelPrepare()
        // UI state resets synchronously without waiting for the hung handler.
        #expect(state.isPreparing == false)
        #expect(state.prepareProgress == nil)
        #expect(state.prepareFeedback == nil)

        // Caller awaiting runPrepare() also unblocks promptly.
        await runTask.value

        // Even when the cancelled handler eventually finishes later, stale
        // results must never overwrite current UI state.
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        #expect(state.isPreparing == false)
        #expect(state.prepareFeedback == nil)
    }

    @Test func constrainedNetworkShowsLowDataModeNoteAndClearsOnProgress() async {
        let progressGate = AsyncGate()
        let finishGate = AsyncGate()
        let state = SettingsUIState(
            preparer: SpeechAssetPreparer(),
            permissions: PermissionsManager(),
            prepareHandler: { onProgress in
                await progressGate.wait()
                onProgress(0.35)
                await finishGate.wait()
                return .prepared("en-US")
            },
            networkConditionProvider: { .constrained },
            stallHintDelayNanoseconds: 0
        )

        let runTask = Task { await state.runPrepare() }
        for _ in 0..<40 where state.prepareFeedback == nil {
            await Task.yield()
        }
        #expect(state.isPreparing == true)
        #expect(state.prepareFeedback?.contains("Low Data Mode") == true)

        // Once real progress arrives, the Low Data Mode warning clears.
        await progressGate.open()
        for _ in 0..<40 where state.prepareProgress == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.prepareProgress == 0.35)
        #expect(state.prepareFeedback == nil)

        await finishGate.open()
        await runTask.value
        #expect(state.isPreparing == false)
        #expect(state.prepareProgress == nil)
        #expect(state.prepareFeedback == "Prepared (en-US).")
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
