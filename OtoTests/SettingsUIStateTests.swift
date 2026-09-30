//
//  SettingsUIStateTests.swift
//  OtoTests
//
//  Hoisted Settings state: initial values are the honest pendings, and
//  the tone mappings are pure over stored strings (no hardware reads).
//  Refresh timing (once per window open) belongs to the matrix.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct SettingsUIStateTests {
    private func makeState() -> SettingsUIState {
        SettingsUIState(preparer: SpeechAssetPreparer(), permissions: PermissionsManager())
    }

    @Test func initialValuesAreHonestPendings() {
        let state = makeState()
        #expect(state.micText == "Checking…")
        #expect(state.speechText == "Checking…")
        #expect(state.readinessText == "Checking…")
        #expect(state.axTrusted == false)
        #expect(state.inputDevices.isEmpty)
        #expect(state.speechReady == false)
        #expect(state.currentInputName == "System default")
    }

    @Test func micToneMapping() {
        let state = makeState()
        state.micText = "Allowed"
        #expect(state.micAllowed == true)
        #expect(state.micTone == .ok)
        #expect(state.micDeniedGuidance == nil)
        state.micText = "Not asked yet"
        #expect(state.micTone == .idle)
        #expect(state.micDeniedGuidance == nil)
        state.micText = "Denied"
        #expect(state.micTone == .warn)
        #expect(state.micDeniedGuidance != nil)
    }

    @Test func speechToneMapping() {
        let state = makeState()
        state.speechText = "Allowed"
        #expect(state.speechTone == .ok)
        state.speechText = "Not asked yet"
        #expect(state.speechTone == .idle)
        state.speechText = "Not allowed"
        #expect(state.speechTone == .warn)
    }

    @Test func currentInputNameFollowsDefault() {
        let state = makeState()
        state.inputDevices = [AudioInputDevice(id: 7, uid: "uid-7", name: "USB Mic")]
        state.defaultInputUID = "uid-7"
        #expect(state.currentInputName == "USB Mic")
        state.defaultInputUID = "gone"
        #expect(state.currentInputName == "System default")
    }
}
