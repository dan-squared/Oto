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

    @Test func contentRolesProceed() {
        // Content roles cannot take a caret, but web-rendered editors report
        // the caret's host as one of them — a WebKit markdown editor was
        // measured answering `axerr=nil` with a non-text role. Diverting
        // here is the false positive v6 exists to remove.
        for role in ["AXStaticText", "AXHeading", "AXImage", "AXLink"] {
            #expect(EditableFocus.classify(role: role) == .unknown)
        }
    }

    @Test func containersAndStrangersProceed() {
        // The measured shapes: Muse answered with a container, and a web
        // area is what a Chromium composer reports once its tree is awake.
        // None of these is positive evidence that a caret cannot exist.
        for role in [
            "AXGroup", "AXWebArea", "AXScrollArea", "AXLayoutArea", "AXLayoutItem",
            "AXSplitGroup", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell",
            "AXWindow", "AXSheet", "AXUnknown", "AXWhateverAppleAddsNext",
        ] {
            #expect(EditableFocus.classify(role: role) == .unknown)
        }
        #expect(EditableFocus.classify(role: nil) == .unknown)
        // Focus owned by another app is the race guard's failure mode, not
        // this layer's.
        #expect(EditableFocus.classify(role: "AXTextField", pidMatches: false) == .unknown)
        #expect(EditableFocus.classify(role: "AXButton", pidMatches: false) == .unknown)
    }

    @Test func caretlessContainerDivertsOnlyWithoutACaret() {
        // v7: a window-family container that publishes no caret means nothing
        // inside the app has focus (measured: Windscribe). Both facts are
        // positive evidence, so it diverts before any paste is posted.
        for role in [
            "AXWindow", "AXSheet", "AXDrawer", "AXScrollArea",
            "AXSplitGroup", "AXToolbar", "AXTabGroup",
        ] {
            #expect(EditableFocus.classify(role: role, publishesCaret: false) == .noField)
            // Same role with a caret publisher stays ambiguous — the
            // container may be hosting a real editor.
            #expect(EditableFocus.classify(role: role, publishesCaret: true) == .unknown)
        }
        // Containers measured to host an unpublished caret in web content
        // never divert on this rule, caret or not.
        for role in [
            "AXGroup", "AXLayoutArea", "AXWebArea", "AXBrowser",
            "AXTable", "AXList", "AXRow", "AXCell", "AXStaticText",
        ] {
            #expect(EditableFocus.classify(role: role, publishesCaret: false) == .unknown)
        }
        // A text role wins over caret silence: the role is the stronger fact.
        #expect(EditableFocus.classify(role: "AXTextField", publishesCaret: false) == .editable)
        #expect(EditableFocus.classify(role: "AXTextField", subrole: "AXSecureTextField", publishesCaret: false) == .secureField)
        // No role is still unknown, and another app's focus never diverts.
        #expect(EditableFocus.classify(role: nil, publishesCaret: false) == .unknown)
        #expect(EditableFocus.classify(role: "AXWindow", pidMatches: false, publishesCaret: false) == .unknown)
        // An interactive widget diverts whether or not it has a caret.
        #expect(EditableFocus.classify(role: "AXButton", publishesCaret: false) == .noField)
        #expect(EditableFocus.classify(role: "AXButton", publishesCaret: true) == .noField)
    }

    @Test func noValueDivertsOnlyForDesktopShells() {
        // Measured: Claude answers -25212 while a live composer holds the
        // caret. "Did not answer" is not "nothing is here".
        #expect(EditableFocus.verdictForFocusError(.noValue) == .unknown)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.anthropic.claudefordesktop") == .unknown)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.meta.endo") == .unknown)
        // The desktop: the one place where "no field" is the truth.
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.apple.finder") == .noField)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.apple.dock") == .noField)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "COM.APPLE.FINDER") == .noField)
        #expect(EditableFocus.verdictForFocusError(.noValue, bundleID: "com.apple.systemuiserver") == .noField)
        // Every other error is ambiguity everywhere, shell or not.
        for error in [
            AXError.failure, .invalidUIElement, .apiDisabled, .cannotComplete, .attributeUnsupported,
        ] {
            #expect(EditableFocus.verdictForFocusError(error, bundleID: "com.apple.finder") == .unknown)
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
