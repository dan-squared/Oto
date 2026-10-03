//
//  FocusProbeTests.swift
//  OtoTests
//
//  Phase 8b Slices 1+2: the selected-text probe upgrades canvas-caret
//  verdicts (never secure fields), and the canvas-editor table turns
//  persistent voids into legacy-proceed for named apps only. Pure tables
//  throughout (the AX read itself is one boolean, matrix-proven on Figma);
//  no AX, no hardware.
//

import ApplicationServices
import Foundation
import Testing
@testable import Oto

@MainActor
struct FocusProbeTests {
    @Test func probeUpgradesVoidRolesNeverSecure() {
        // No signal: verdict stands (today's behavior, byte-identical).
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: false) == .noField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .editable, hasSelectedText: false) == .editable)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .secureField, hasSelectedText: false) == .secureField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .unknown, hasSelectedText: false) == .unknown)
        // Signal: canvas caret under a generic role proceeds…
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: true) == .unknown)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .editable, hasSelectedText: true) == .editable)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .unknown, hasSelectedText: true) == .unknown)
        // …but secure fields still refuse (they expose selection too).
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .secureField, hasSelectedText: true) == .secureField)
    }

    @Test func canvasTableAndFallback() {
        #expect(CanvasEditors.isCanvas(bundleID: "com.figma.Desktop"))
        #expect(!CanvasEditors.isCanvas(bundleID: "com.apple.Finder"))
        #expect(!CanvasEditors.isCanvas(bundleID: nil))
        #expect(CanvasEditors.proceedsVoid(bundleID: "com.figma.Desktop"))
        #expect(!CanvasEditors.proceedsVoid(bundleID: "com.apple.Finder"))
        // Divert in a canvas editor proceeds; everything else passes through.
        #expect(CanvasEditors.fallback(verdict: .noField, bundleID: "com.figma.Desktop") == .unknown)
        #expect(CanvasEditors.fallback(verdict: .noField, bundleID: "com.apple.Finder") == .noField)
        #expect(CanvasEditors.fallback(verdict: .noField, bundleID: nil) == .noField)
        #expect(CanvasEditors.fallback(verdict: .secureField, bundleID: "com.figma.Desktop") == .secureField)
        #expect(CanvasEditors.fallback(verdict: .editable, bundleID: "com.figma.Desktop") == .editable)
        #expect(CanvasEditors.fallback(verdict: .unknown, bundleID: "com.figma.Desktop") == .unknown)
    }

    @Test func probeNeverTrapsHeadless() {
        // The AX read itself: boolean out, no trap, no throw — whatever the
        // answer on this machine (matrix proves true on Figma).
        let wide = AXUIElementCreateSystemWide()
        _ = LiveFocusCheck.selectedTextPresent(element: wide)
    }
}
