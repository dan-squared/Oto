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
import Speech
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
        #expect(state.speechPermission == nil)
        #expect(state.speechReadiness == nil)
        #expect(state.micText == "Checking…")
        #expect(state.speechText == "Checking…")
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

    @Test func speechToneMapping() {
        let state = makeState()
        state.speechPermission = .authorized
        #expect(state.speechText == "Allowed")
        #expect(state.speechTone == .ok)
        state.speechPermission = .notDetermined
        #expect(state.speechText == "Not asked yet")
        #expect(state.speechTone == .idle)
        state.speechPermission = .denied
        #expect(state.speechText == "Not allowed")
        #expect(state.speechTone == .warn)
        #expect(state.speechDeniedGuidance != nil)
        state.speechPermission = .notDetermined
        #expect(state.speechDeniedGuidance == nil)
        state.speechPermission = .restricted
        #expect(state.speechText == "Not allowed")
        #expect(state.speechTone == .warn)
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

    // Sidebar column: the type is NavigationSplitViewVisibility (there is
    // no …ColumnVisibility in this SDK) and it is not an OptionSet, so the
    // visible/hidden test is equality — pinned here so neither can drift.

    @Test func sidebarStartsVisible() {
        let state = makeState()
        #expect(state.columnVisibility == .all)
        #expect(state.sidebarVisible)
    }

    @Test func setSidebarRoundTripsAndIsIdempotent() {
        let state = makeState()
        state.setSidebar(false)
        #expect(state.columnVisibility == .detailOnly)
        #expect(state.sidebarVisible == false)
        // Repeat call must not re-animate or change anything.
        state.setSidebar(false)
        #expect(state.columnVisibility == .detailOnly)
        state.setSidebar(true)
        #expect(state.columnVisibility == .all)
        #expect(state.sidebarVisible)
    }

    @Test func sidebarRowMetricsPinTheReportedFixes() {
        // 36pt rows with 14pt labels (asked for), and an 8pt clear gap
        // between neighbouring pills — 6 read as "touching".
        #expect(SettingsRoot.rowHeight == 36)
        #expect(SettingsRoot.rowFillInsetX == 6)
        #expect(SettingsRoot.rowPillGap == 8)
        // Locked column: min == ideal == max is the snap fix.
        #expect(SettingsRoot.sidebarWidth == 210)
    }
}
