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
        let figma: String? = "com.figma.Desktop"
        let dia: String? = "company.thebrowser.dia"
        let chrome: String? = "com.google.Chrome"
        // No signal: verdict stands (today's behavior, byte-identical).
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: false, bundleID: figma) == .noField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .editable, hasSelectedText: false, bundleID: figma) == .editable)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .secureField, hasSelectedText: false, bundleID: figma) == .secureField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .unknown, hasSelectedText: false, bundleID: figma) == .unknown)
        // Signal on a canvas caret under a generic role proceeds…
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: true, bundleID: figma) == .unknown)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .editable, hasSelectedText: true, bundleID: figma) == .editable)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .unknown, hasSelectedText: true, bundleID: figma) == .unknown)
        // …but secure fields still refuse (they expose selection too).
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .secureField, hasSelectedText: true, bundleID: figma) == .secureField)
        // Signal anywhere else never upgrades: a browser void (selected
        // static text — or an empty range answering the probe) stays a
        // void and diverts to recovery instead of laundering a phantom
        // insert. Nil bundle fails closed, house rule.
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: true, bundleID: dia) == .noField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: true, bundleID: chrome) == .noField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: true, bundleID: "com.apple.Finder") == .noField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .noField, hasSelectedText: true, bundleID: nil) == .noField)
        #expect(EditableFocus.resolveWithSelectionProbe(verdict: .secureField, hasSelectedText: true, bundleID: dia) == .secureField)
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
