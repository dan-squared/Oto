//
//  FocusPolicyTests.swift
//  OtoTests
//
//  v6 focus policy: divert only on positive evidence of a non-editable
//  focus. Containers, web areas, unrecognised roles and silence proceed —
//  measured shapes from Claude (-25212 on a live composer) and Muse (a
//  readable container 100 ms later). Pure tables; no AX, no hardware.
//

import ApplicationServices
import Foundation
import Testing
@testable import Oto

@MainActor
struct FocusPolicyTests {
    @Test func textRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXDateField", "AXTimeField"] {
            #expect(EditableFocus.classify(role: role) == .editable)
        }
    }

    @Test func secureSubroleWinsOverEveryTextRole() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            #expect(EditableFocus.classify(role: role, subrole: "AXSecureTextField") == .secureField)
        }
        // Any other subrole (or none) leaves the text verdict untouched.
        #expect(EditableFocus.classify(role: "AXTextField", subrole: "AXUsernameField") == .editable)
        // A non-text role stays non-text whatever subrole it carries.
        #expect(EditableFocus.classify(role: "AXButton", subrole: "AXSecureTextField") == .noField)
    }

    @Test func knownInteractiveControlsDivert() {
        for role in [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
            "AXSlider", "AXScrollBar", "AXDisclosureTriangle", "AXPopUpButton",
            "AXMenuButton", "AXColorWell", "AXDockItem",
        ] {
            #expect(EditableFocus.classify(role: role) == .noField)
        }
    }

    @Test func contentRolesDivertWithoutEditableSignalAndProceedWithOne() {
        // Read-only static content cannot accept pasted text without a positive
        // editability signal (AXEditableAncestor / settable AXSelectedText /
        // AXInsertionPointLineNumber), even when static text is selected.
        for role in ["AXStaticText", "AXHeading", "AXImage", "AXLink"] {
            #expect(EditableFocus.classify(role: role, publishesCaret: false, hasEditableSignal: false) == .noField)
            #expect(EditableFocus.classify(role: role, publishesCaret: true, hasEditableSignal: false) == .noField)
            #expect(EditableFocus.classify(role: role, publishesCaret: false, hasEditableSignal: true) == .editable)
        }
        // Web composers exposed with a non-text widget role (e.g. AXButton with
        // AXEditableAncestor) still resolve to `.editable` via hasEditableSignal.
        #expect(EditableFocus.classify(role: "AXButton", hasEditableSignal: true) == .editable)
    }

    @Test func containersWithCaretOrOpaqueRolesProceed() {
        // Containers with a live caret (publishesCaret == true) or positive
        // editability signal proceed; opaque custom/GPU roles always proceed.
        for role in [
            "AXGroup", "AXWebArea", "AXScrollArea", "AXLayoutArea",
            "AXSplitGroup", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell",
            "AXWindow", "AXSheet",
        ] {
            #expect(EditableFocus.classify(role: role, publishesCaret: true) == .unknown)
            #expect(EditableFocus.classify(role: role, publishesCaret: false, hasEditableSignal: true) == .editable)
        }
        for opaqueRole in ["AXUnknown", "AXApplication", "AXLayoutItem", "AXWhateverAppleAddsNext"] {
            #expect(EditableFocus.classify(role: opaqueRole, publishesCaret: false) == .unknown)
        }
        #expect(EditableFocus.classify(role: nil) == .unknown)
        // Focus owned by another app is the race guard's failure mode, not
        // this layer's.
        #expect(EditableFocus.classify(role: "AXTextField", pidMatches: false) == .unknown)
        #expect(EditableFocus.classify(role: "AXButton", pidMatches: false) == .unknown)
    }

    @Test func caretlessContainerDivertsOnlyWithoutACaretOrEditableSignal() {
        // Window-furniture AND structural/web containers with neither a live
        // caret nor an editable signal divert to `.noField` so the catcher
        // fires on empty webpages, Finder lists, sidebars, and app backgrounds.
        for role in [
            "AXWindow", "AXSheet", "AXDrawer", "AXScrollArea",
            "AXSplitGroup", "AXToolbar", "AXTabGroup",
            "AXGroup", "AXLayoutArea", "AXWebArea", "AXRootWebArea",
            "AXBrowser", "AXTable", "AXOutline", "AXList", "AXRow", "AXCell",
        ] {
            #expect(EditableFocus.classify(role: role, publishesCaret: false, hasEditableSignal: false) == .noField)
            // Same role with a live caret stays ambiguous so custom editors proceed.
            #expect(EditableFocus.classify(role: role, publishesCaret: true, hasEditableSignal: false) == .unknown)
            // Same role with positive editability signal is editable.
            #expect(EditableFocus.classify(role: role, publishesCaret: false, hasEditableSignal: true) == .editable)
        }
        // A text role wins over caret silence: the role is the stronger fact.
        #expect(EditableFocus.classify(role: "AXTextField", publishesCaret: false) == .editable)
        #expect(EditableFocus.classify(role: "AXTextField", subrole: "AXSecureTextField", publishesCaret: false) == .secureField)
        // No role is still unknown, and another app's focus never diverts.
        #expect(EditableFocus.classify(role: nil, publishesCaret: false) == .unknown)
        #expect(EditableFocus.classify(role: "AXWindow", pidMatches: false, publishesCaret: false) == .unknown)
        // An interactive widget without an editable signal diverts whether or not it has a caret.
        #expect(EditableFocus.classify(role: "AXButton", publishesCaret: false) == .noField)
        #expect(EditableFocus.classify(role: "AXButton", publishesCaret: true) == .noField)
    }

    @Test func noValueDivertsForDesktopShellsAndLiveAXTreesWithoutFocus() {
        // An asleep/opaque app answering .noValue without a live native AX tree stays .unknown.
        #expect(EditableFocus.verdictForFocusError(.noValue) == .unknown)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.anthropic.claudefordesktop") == .unknown)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.meta.endo") == .unknown)
        // Any app whose AX tree IS live (zero windows or native window hierarchy)
        // and reports .noValue diverts to .noField without needing a bundle allowlist.
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.example.AnyApp", appHasLiveAXWithoutFocus: true) == .noField)
        // The desktop shells also divert directly.
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.apple.finder") == .noField)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.apple.dock") == .noField)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "COM.APPLE.FINDER") == .noField)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.apple.systemuiserver") == .noField)
        // Every other error is ambiguity everywhere, shell or not.
        for error in [
            AXError.failure, .invalidUIElement, .apiDisabled, .cannotComplete, .attributeUnsupported,
        ] {
            #expect(EditableFocus.verdictForFocusError(error, bundleID: "com.apple.finder", appHasLiveAXWithoutFocus: true) == .unknown)
        }
    }

    @Test func voidShellListIsOnlyTheDesktop() {
        #expect(VoidShells.isVoidShell(bundleID: "com.apple.finder"))
        #expect(VoidShells.isVoidShell(bundleID: "com.apple.dock"))
        #expect(!VoidShells.isVoidShell(bundleID: "com.anthropic.claudefordesktop"))
        #expect(!VoidShells.isVoidShell(bundleID: "com.meta.endo"))
        #expect(!VoidShells.isVoidShell(bundleID: "com.figma.Desktop"))
        #expect(!VoidShells.isVoidShell(bundleID: nil))
    }

    @Test func prewarmNeverTrapsOnDeadPid() {
        // Fail-closed: no write for a non-pid, whatever the trust state.
        let outcome = AccessibilityPrewarm.arm(pid: -1, bundleID: nil)
        #expect(outcome.trusted == false)
        #expect(outcome.manual == 0)
        #expect(outcome.enhanced == 0)
        #expect(outcome.pull == 0)
    }

    @Test func webContentRolesAreIdentified() {
        #expect(EditableFocus.isWebContentRole("AXWebArea"))
        #expect(EditableFocus.isWebContentRole("AXBrowser"))
        #expect(!EditableFocus.isWebContentRole("AXButton"))
        #expect(!EditableFocus.isWebContentRole("AXGroup"))
        #expect(!EditableFocus.isWebContentRole(nil))
    }

    @Test func webContentCheckNeverTrapsHeadless() {
        // The guard itself: bounded, boolean out, no trap — whatever the
        // answer on this machine. The real discrimination (a composer
        // exposed as AXButton inside an AXWebArea) is proven on device.
        let wide = AXUIElementCreateSystemWide()
        _ = EditableFocus.webContentHidesEditable(element: wide)
    }

    @Test func probeNeverTrapsHeadless() {
        // The AX read itself: boolean out, no trap, no throw — whatever the
        // answer on this machine.
        let wide = AXUIElementCreateSystemWide()
        _ = LiveFocusCheck.selectedTextPresent(element: wide)
    }
}
