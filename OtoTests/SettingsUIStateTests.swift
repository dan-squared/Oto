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
        #expect(state.currentInputName == "System default")
    }

    @Test func micToneMapping() {
        // Typed state in, identical display out — typo'd states are now
        // unrepresentable instead of silent.
        let state = makeState()
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
}
