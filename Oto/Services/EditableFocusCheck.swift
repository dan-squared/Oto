//
//  EditableFocusCheck.swift
//  Oto
//
//  Pre-paste focus gate, v6 — CAPABILITY-FIRST.
//
//  History worth keeping: v5 ("catcher void fix") taught this gate that
//  `kAXErrorNoValue` on the focus read IS the void case, so a live app
//  with nowhere to paste (Finder, desktop) diverts to recovery instead of
//  reporting a phantom insert. That rule is right for desktop shells and
//  wrong everywhere else: Chromium/Electron publish nothing until an
//  assistive client asks (measured: `-25212` on a live Claude composer),
//  and web-rendered editors publish a *container* rather than the caret
//  (measured: Muse answers with no error and a non-text role).
//
//  v6 inverts the question. Divert only on POSITIVE evidence that focus is
//  non-editable — a known widget role, or a bare desktop shell that does
//  not answer at all. Silence, errors, timeouts, containers and unknown
//  roles proceed: a missed catcher is recoverable (the transcript is always
//  kept, the clipboard is restored, Retry paste exists); a false catcher
//  breaks the feature in the apps people actually use.
//
//  This removes the gate's need to know which apps are weird: there is no
//  terminal allowlist and no canvas allowlist left. The only bundle list is
//  the desktop itself. Everything else is decided from the AX answer alone.
//
//  Read-only AX (focused element + role + selection presence, never a
//  write); runs behind the existing trust gate. The blocking C call cannot
//  honour cooperative cancellation, so the worker runs off-pool and a
//  one-shot gate admits exactly one winner against a hard timeout. Every
//  verdict is logged with the role and the read that answered, so device
//  trails are decisive instead of inferred.
//
//  v7 narrows ambiguity with a second positive fact. A caret-less *window
//  family* container (`caretlessContainerRoles`) with no caret publisher
//  means nothing inside the app has focus — measured on Windscribe, whose
//  focused element is its own AXWindow and whose only caret publisher is a
//  scroll bar. That shape used to read `.unknown`, paste, verify nothing,
//  and claim success. Content/container roles that can host an unpublished
//  caret (`AXGroup`, `AXWebArea`, tables) stay `.unknown` on purpose.
//

import ApplicationServices
import AppKit
import Foundation
import os
import Synchronization

/// Verdict on whether keystrokes have somewhere to land.
enum EditableFocus: Equatable, Sendable {
    /// A text-capable element holds focus — proceed.
    case editable
    /// Positive evidence that focus is NOT editable (a widget role, or a
    /// desktop shell with nothing focused) — divert.
    case noField
    /// Focus is a secure password field — refuse (never auto-fill).
    case secureField
    /// Silence, error, timeout, container or unrecognised role — proceed
    /// exactly as the pre-gate product did.
    case unknown

    // Explicit: compared from nonisolated contexts (Swift 6).
    nonisolated static func == (lhs: EditableFocus, rhs: EditableFocus) -> Bool {
        switch (lhs, rhs) {
        case (.editable, .editable), (.noField, .noField),
            (.secureField, .secureField), (.unknown, .unknown):
            return true
        default:
            return false
        }
    }

    /// Pure role mapping (unit-tested). The contract is deliberately
    /// asymmetric: only a *known non-editable widget* diverts, because that
    /// is the one case where the answer is positive. A container role is
    /// ambiguous — a web area, group or layout area can host a caret — and an
    /// unrecognised role is unknown by definition, so both proceed.
    ///
    /// Text-capable roles include `AXComboBox` (a real editable input for URL
    /// bars and search fields) and the date/time fields, which accept typed
    /// text. The secure subrole is checked first: the role stays `AXTextField`
    /// in a password field, and refusal always wins
    /// (`AXRoleConstants.h:408`).
    ///
    /// `pidMatches` is the system-wide ownership check: a focused element
    /// owned by another app is ambiguity (`.unknown`, proceed) — the
    /// frontmostPID race guard owns that failure mode with the better
    /// message. Single owner per failure mode.
    ///
    /// `publishesCaret` is the second, structural fact v7 adds: whether the
    /// focused element answered `AXSelectedText`/`AXSelectedTextRange`. It
    /// only matters for `caretlessContainerRoles`, where "this is a window
    /// and it has no caret" is positive evidence that nothing inside the
    /// app has focus (measured: Windscribe's focused element is its own
    /// `AXWindow`, and the only caret publisher in the tree is a scroll bar).
    /// Defaulted to `true` — "assume a caret exists" — so a caller that
    /// knows nothing about carets can never cause a divert.
    /// Pure role + capability mapping (unit-tested).
    ///
    /// Positive editable signals (`textCapableRoles` or `hasEditableSignal`:
    /// `AXEditableAncestor`, settable `AXSelectedText`, `AXInsertionPointLineNumber`,
    /// or settable `AXValue` on a non-widget role) ALWAYS win and return `.editable`
    /// (or `.secureField` for password fields).
    ///
    /// Without any positive editable signal:
    /// - Known non-editable interactive controls (`nonEditableRoles`) divert to `.noField`.
    /// - Read-only content roles (`readOnlyContentRoles`: `AXStaticText`, `AXHeading`,
    ///   `AXImage`, `AXLink`) divert to `.noField` — even if static text is highlighted.
    /// - Container roles (`caretlessContainerRoles` + structural/web containers like
    ///   `AXWebArea`, `AXGroup`, `AXOutline`, `AXList`, `AXTable`, `AXRow`, `AXCell`,
    ///   `AXBrowser`, `AXLayoutArea`) divert to `.noField` when `!publishesCaret`
    ///   (no live `CFRange` from `AXSelectedTextRange`).
    /// - Opaque custom/GPU roles (`AXUnknown`, `AXApplication`, unrecognised roles)
    ///   stay `.unknown` so custom canvas/terminal surfaces still paste.
    nonisolated static func classify(
        role: String?,
        subrole: String? = nil,
        pidMatches: Bool = true,
        publishesCaret: Bool = true,
        hasEditableSignal: Bool = false
    ) -> EditableFocus {
        guard pidMatches else { return .unknown }
        guard let role else { return .unknown }
        if textCapableRoles.contains(role) {
            return subrole == kAXSecureTextFieldSubrole as String ? .secureField : .editable
        }
        if hasEditableSignal {
            return .editable
        }
        if nonEditableRoles.contains(role) { return .noField }
        if readOnlyContentRoles.contains(role) { return .noField }
        // A container with no positive editability signal and no live caret
        // means nothing editable is focused here (e.g. empty web page, Finder
        // list, sidebar, app window background).
        if nonEditableContainerRoles.contains(role), !publishesCaret { return .noField }
        return .unknown
    }

    /// Roles that take typed text. `AXTextField`/`AXTextArea` are the
    /// documented pair; the rest are text inputs whose role differs by
    /// widget family.
    nonisolated static let textCapableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        kAXDateFieldRole as String,
        kAXTimeFieldRole as String,
    ]

    /// Roles that positively say "this focus is not a text input" unless the
    /// element itself carries an explicit editable signal (`AXEditableAncestor`,
    /// settable `AXSelectedText`, or `AXInsertionPointLineNumber`).
    nonisolated static let nonEditableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXRadioGroupRole as String,
        kAXColorWellRole as String,
        kAXDisclosureTriangleRole as String,
        kAXDockItemRole as String,
        kAXGrowAreaRole as String,
        kAXHandleRole as String,
        kAXHelpTagRole as String,
        kAXIncrementorRole as String,
        kAXLevelIndicatorRole as String,
        kAXMatteRole as String,
        kAXMenuBarItemRole as String,
        kAXMenuBarRole as String,
        kAXMenuButtonRole as String,
        kAXMenuItemRole as String,
        kAXMenuRole as String,
        kAXPopUpButtonRole as String,
        kAXProgressIndicatorRole as String,
        kAXRelevanceIndicatorRole as String,
        kAXRulerMarkerRole as String,
        kAXRulerRole as String,
        kAXScrollBarRole as String,
        kAXSliderRole as String,
        kAXSplitterRole as String,
        kAXValueIndicatorRole as String,
    ]

    /// Read-only content roles. Inside a `contenteditable` editor WebKit and
    /// Chromium attach `AXEditableAncestor` / settable `AXSelectedText` (caught
    /// above by `hasEditableSignal`); without those signals, these are static
    /// read-only elements and cannot receive pasted text.
    nonisolated static let readOnlyContentRoles: Set<String> = [
        kAXStaticTextRole as String,
        "AXHeading",
        kAXImageRole as String,
        "AXLink",
    ]

    /// Window-furniture container roles (kept for clarity and tests).
    nonisolated static let caretlessContainerRoles: Set<String> = [
        kAXWindowRole as String,
        kAXSheetRole as String,
        kAXDrawerRole as String,
        kAXScrollAreaRole as String,
        kAXSplitGroupRole as String,
        kAXToolbarRole as String,
        kAXTabGroupRole as String,
    ]

    /// Structural and document container roles that divert to `.noField` when
    /// they have neither a positive editability signal nor a live caret range.
    /// Deliberately excludes `AXUnknown` and `AXApplication` so custom GPU
    /// surfaces without semantic AX roles proceed safely.
    nonisolated static let nonEditableContainerRoles: Set<String> = caretlessContainerRoles.union([
        kAXGroupRole as String,
        kAXOutlineRole as String,
        kAXListRole as String,
        kAXTableRole as String,
        kAXRowRole as String,
        kAXCellRole as String,
        kAXBrowserRole as String,
        kAXLayoutAreaRole as String,
        "AXWebArea",
        "AXRootWebArea",
    ])

    /// AX-error mapping (unit-tested). `noValue` diverts for desktop shells
    /// AND when the app's AX tree is live (open native window or zero windows)
    /// while reporting nothing focused (`appHasLiveAXWithoutFocus`). Every
    /// other error (`.apiDisabled`, `.attributeUnsupported`, `.cannotComplete`)
    /// stays `.unknown` so opaque apps proceed safely.
    nonisolated static func verdictForFocusError(
        _ error: AXError,
        bundleID: String? = nil,
        appHasLiveAXWithoutFocus: Bool = false
    ) -> EditableFocus {
        guard error == .noValue else { return .unknown }
        if VoidShells.isVoidShell(bundleID: bundleID) || appHasLiveAXWithoutFocus {
            return .noField
        }
        return .unknown
    }

    /// Roles that mean "an HTML document is rendered here".
    nonisolated static let webContentRoles: Set<String> = ["AXWebArea", "AXBrowser"]

    nonisolated static func isWebContentRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return webContentRoles.contains(role)
    }

    /// Hard AX IPC timeout applied to every AXUIElement touched by focus checks.
    nonisolated static let axTimeoutSeconds: Float = 0.25

    /// True when the element itself has an explicit `AXEditableAncestor`
    /// (published by WebKit and Chromium on nodes inside `contenteditable`
    /// editors). Unlike earlier versions, merely living under an `AXWebArea`
    /// does NOT suppress `.noField` — clicking an empty webpage or a web
    /// button must trigger the catcher.
    /// True when:
    /// 1. `element` has an explicit `AXEditableAncestor` or `AXHighestEditableAncestor`,
    /// 2. `element` reports `AXIsEditable == true`, or
    /// 3. `element` is a child node (not the root `AXWebArea` itself and not static
    ///    read-only text/image) nested inside an `AXWebArea` / `AXBrowser` ancestor
    ///    (within 8 parent hops — covering WebKit/Electron composers like Muse that
    ///    collapse a `contenteditable` composer into a leaf `AXButton` under `AXWebArea`).
    ///
    /// Because the parent walk only runs when `element` itself is NOT `AXWebArea` /
    /// `AXRootWebArea`, clicking an empty webpage or background in Spotify, Chrome,
    /// or Electron (where the root `AXWebArea` itself is focused) still returns
    /// `false` and diverts to the catcher.
    nonisolated static func webContentHidesEditable(element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
        for attr in [kAXEditableAncestorAttribute as String, "AXHighestEditableAncestor"] {
            var ancestor: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, attr as CFString, &ancestor
            ) == .success,
                let raw = ancestor, CFGetTypeID(raw) == AXUIElementGetTypeID()
            {
                return true
            }
        }
        var isEditableRaw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, "AXIsEditable" as CFString, &isEditableRaw
        ) == .success,
            let number = isEditableRaw as? NSNumber,
            number.boolValue
        {
            return true
        }
        let selfRole = role(of: element)
        if let selfRole,
           selfRole == "AXWebArea" || selfRole == "AXRootWebArea" || readOnlyContentRoles.contains(selfRole)
        {
            return false
        }
        var current = parent(of: element)
        var hops = 0
        while let node = current, hops < 8 {
            if isWebContentRole(role(of: node)) {
                return true
            }
            current = parent(of: node)
            hops += 1
        }
        return false
    }

    /// Role descriptions used by web/custom text composers that expose a
    /// generic container role (`AXGroup` / `AXWebArea`) rather than `AXTextArea`.
    nonisolated private static let editableRoleDescriptions: Set<String> = [
        "text entry area",
        "text field",
        "text area",
        "search text field",
    ]

    /// Capability-based check: returns true when `element` publishes a positive
    /// text-editing capability (`AXEditableAncestor`, `AXHighestEditableAncestor`,
    /// settable `AXSelectedText`, settable `AXSelectedTextRange`, editable
    /// `AXRoleDescription`, or settable `AXValue` on a non-widget role).
    ///
    /// Note: `kAXInsertionPointLineNumberAttribute` is deliberately excluded —
    /// Finder's Desktop `AXGroup` returns `0` and Chromium's root `AXWebArea`
    /// returns `NSNotFound` (`Int.max`) even when nothing editable is focused.
    nonisolated static func hasPositiveEditableSignal(element: AXUIElement, role: String?) -> Bool {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
        if webContentHidesEditable(element: element) {
            return true
        }
        var selectedTextSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &selectedTextSettable
        ) == .success, selectedTextSettable.boolValue {
            return true
        }
        var selectedRangeSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeSettable
        ) == .success, selectedRangeSettable.boolValue {
            return true
        }
        if let role, !nonEditableRoles.contains(role), !readOnlyContentRoles.contains(role) {
            var valueSettable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &valueSettable
            ) == .success, valueSettable.boolValue {
                return true
            }
            var descRaw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXRoleDescriptionAttribute as CFString, &descRaw
            ) == .success,
               let desc = (descRaw as? String)?.lowercased(),
               editableRoleDescriptions.contains(desc)
            {
                return true
            }
        }
        return false
    }

    /// Capability check when `AXFocusedUIElement` still returns `.noValue`
    /// after waking the window tree:
    /// - If the app's AX server answers `kAXWindowsAttribute`:
    ///   - 0 open windows (`windows.isEmpty`) → true (`.noField`).
    ///   - No focused window (`kAXFocusedWindowAttribute != .success`, e.g.
    ///     only a non-activating panel like `FlowBarPanel` or desktop background)
    ///     → true (`.noField`).
    /// - When a focused window DOES exist and `AXFocusedUIElement` is `.noValue`
    ///   (the exact shape of Electron/WebKit apps like Claude, Conductor, and
    ///   Codex when a composer is auto-focused on launch before the first key
    ///   is typed), returns `false` so verdict stays `.unknown` and dictation
    ///   pastes on the first try without requiring the user to type first.
    nonisolated static func appHasLiveAXWithoutFocus(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeoutSeconds)

        var windowsRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windowsRaw
        ) == .success,
            let windows = windowsRaw as? [AXUIElement]
        else { return false }

        if windows.isEmpty {
            return true
        }

        var focusedWindowRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focusedWindowRaw
        ) == .success,
            let winRaw = focusedWindowRaw,
            CFGetTypeID(winRaw) == AXUIElementGetTypeID()
        else {
            // The app's AX server is alive (`kAXWindowsAttribute` succeeded)
            // and positively reports no focused window at all.
            return true
        }
        return false
    }

    nonisolated fileprivate static func role(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }

    nonisolated fileprivate static func parent(of element: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXParentAttribute as CFString, &value
        ) == .success,
            let raw = value,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }
}

/// The desktop itself: apps whose focused element is genuinely "nothing"
/// and where the catcher was built to appear. Deliberately tiny — every
/// entry is a place where pasting has no possible target whatever the AX
/// answer says.
enum VoidShells: Sendable {
    nonisolated static let bundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
    ]

    nonisolated static func isVoidShell(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID.lowercased())
    }
}

/// Bundle lookup for pid triage. Nil for dead/fake pids — tests and unknown
/// apps fail closed onto the problem-reporting path, never onto a shell.
enum FocusBundle: Sendable {
    nonisolated static func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}

/// Which read answered — the Shape D discriminator in the trail
/// (system-wide and app-level reads can disagree).
enum FocusSource: String, Sendable, Equatable {
    case systemWide = "syswide"
    case app
    case timeout
}

/// One focus read, complete. Carried as a value so the verdict log can show
/// *why* it decided (role, raw AX error, selection presence, which reader).
struct FocusRead: Equatable, Sendable {
    let verdict: EditableFocus
    let axError: AXError?
    let hasSelectedText: Bool
    let role: String?
    let source: FocusSource

    nonisolated init(
        verdict: EditableFocus,
        axError: AXError? = nil,
        hasSelectedText: Bool = false,
        role: String? = nil,
        source: FocusSource
    ) {
        self.verdict = verdict
        self.axError = axError
        self.hasSelectedText = hasSelectedText
        self.role = role
        self.source = source
    }
}

/// Seam: the insertion path injects this; tests stub verdicts without AX.
protocol FocusChecking: Sendable {
    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus
}

struct LiveFocusCheck: FocusChecking {
    /// Hard budget for the whole read. Past this the verdict is `.unknown`
    /// (proceed), never a hang: a blocking AX call cannot be cancelled, so
    /// the timeout is a race rather than a kill.
    nonisolated static let timeoutNanoseconds: UInt64 = 700_000_000

    /// Injectable reader for deterministic tests. Production uses the live
    /// system-wide read; tests script a `FocusRead` without AX.
    var reader: @Sendable (pid_t) -> FocusRead

    init(reader: @Sendable @escaping (pid_t) -> FocusRead = { LiveFocusCheck.liveRead(pid: $0) }) {
        self.reader = reader
    }

    /// One-shot resume gate: the AX worker and the timeout race, and
    /// exactly one resumes the continuation (double-resume traps).
    private final class ResumeGate: Sendable {
        private let claimed = Mutex(false)
        nonisolated func claim() -> Bool {
            claimed.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
        }
    }

    private nonisolated static let focusLog = Logger(subsystem: "app.Oto", category: "focus")

    /// One line, everything that decided it: verdict, raw AX code (not the
    /// opaque `Optional(__C.AXError)` description), the role actually read,
    /// selection presence, which reader answered, and whether the budget
    /// expired. `role=` is the field whose absence made this whole class
    /// undiagnosable for weeks.
    nonisolated static func logVerdict(
        pid: pid_t, read: FocusRead, timedOut: Bool, bundleID: String? = nil
    ) {
        let code = read.axError.map { String($0.rawValue) } ?? "nil"
        let app = bundleID ?? "?"
        let role = read.role ?? "nil"
        focusLog.info("focus pid=\(pid, privacy: .public) app=\(app, privacy: .public) verdict=\(String(describing: read.verdict), privacy: .public) axerr=\(code, privacy: .public) role=\(role, privacy: .public) sel=\(read.hasSelectedText, privacy: .public) src=\(read.source.rawValue, privacy: .public) timeout=\(timedOut, privacy: .public)")
    }

    /// The app-level read's answer, when it is not the one that wins. One
    /// extra line at most, only on disagreement — enough to tell a silent
    /// system-wide read apart from an app that answered with a role.
    nonisolated static func logAlternate(
        pid: pid_t, read: FocusRead, bundleID: String?
    ) {
        let code = read.axError.map { String($0.rawValue) } ?? "nil"
        let app = bundleID ?? "?"
        let role = read.role ?? "nil"
        focusLog.info("focus alt pid=\(pid, privacy: .public) app=\(app, privacy: .public) verdict=\(String(describing: read.verdict), privacy: .public) axerr=\(code, privacy: .public) role=\(role, privacy: .public) sel=\(read.hasSelectedText, privacy: .public) src=app")
    }

    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus {
        // Unstructured by necessity: the blocking AX call cannot honor
        // cooperative cancellation, so a structured group would await a
        // hung worker forever and the "timeout" would be a lie. The worker
        // runs OFF the cooperative pool (blocking C call), the timer on it;
        // ResumeGate admits exactly one winner, and the worker cancels the
        // timeout task immediately upon completion.
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            let reader = self.reader
            let bundleID = FocusBundle.bundleID(for: pid)
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                // Gate first: if the worker already won (and logged its
                // detail), the timer stays silent — otherwise every
                // session emits a spurious timeout line after the truth.
                if gate.claim() {
                    let read = FocusRead(verdict: .unknown, source: .timeout)
                    Self.logVerdict(pid: pid, read: read, timedOut: true, bundleID: bundleID)
                    continuation.resume(returning: .unknown)
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let read = reader(pid)
                timeoutTask.cancel()
                Self.logVerdict(pid: pid, read: read, timedOut: false, bundleID: bundleID)
                if gate.claim() { continuation.resume(returning: read.verdict) }
            }
        }
    }

    /// Live reader: system-wide focused element first (WindowServer-level
    /// focus, immune to stale per-app trees), ownership-verified by pid,
    /// then the app-level read. v6 reconciles them: if the system-wide read
    /// is not a positive text answer, a positive app-level answer wins — the
    /// weaker read can no longer veto a live field (Shape D).
    nonisolated static func liveRead(pid: pid_t) -> FocusRead {
        let bundle = FocusBundle.bundleID(for: pid)
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, EditableFocus.axTimeoutSeconds)
        let wide = readFocusedElement(
            systemWide, source: .systemWide, pid: pid, bundleID: bundle
        )
        if wide.verdict == .editable || wide.verdict == .secureField { return wide }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, EditableFocus.axTimeoutSeconds)
        let app = readFocusedElement(
            appElement, source: .app, pid: pid, bundleID: bundle
        )
        if app.verdict == .editable || app.verdict == .secureField { return app }
        // Shape D trail: the two reads disagreeing is the one thing that
        // explains a divert when the system-wide read looked innocent. Log
        // the loser so a device run needs no second pass.
        if app.verdict != wide.verdict || app.role != wide.role || app.axError != wide.axError {
            logAlternate(pid: pid, read: app, bundleID: bundle)
        }
        // Never discard positive `.noField` evidence from the app element when
        // the system-wide read returned `.unknown` (e.g. `.noValue`).
        if wide.verdict == .unknown && app.verdict == .noField { return app }
        return wide
    }

    /// One element read. Every failure shape — error code, missing element,
    /// missing role — is mapped explicitly, never guessed. Type-ID gate +
    /// downcast per the RealTargetCapture.copyElement precedent.
    nonisolated static func readFocusedElement(
        _ root: AXUIElement, source: FocusSource, pid: pid_t, bundleID: String?
    ) -> FocusRead {
        AXUIElementSetMessagingTimeout(root, EditableFocus.axTimeoutSeconds)
        var focused: CFTypeRef?
        var focusError = AXUIElementCopyAttributeValue(
            root, kAXFocusedUIElementAttribute as CFString, &focused
        )
        if focusError == .noValue, pid > 0, !VoidShells.isVoidShell(bundleID: bundleID) {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, EditableFocus.axTimeoutSeconds)
            _ = AXUIElementSetAttributeValue(
                appEl, AccessibilityPrewarm.manualAccessibility as CFString, kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                appEl, AccessibilityPrewarm.enhancedUserInterface as CFString, kCFBooleanTrue
            )
            focusError = AXUIElementCopyAttributeValue(
                root, kAXFocusedUIElementAttribute as CFString, &focused
            )
        }
        guard focusError == .success else {
            let liveWithoutFocus = (focusError == .noValue && !VoidShells.isVoidShell(bundleID: bundleID))
                ? EditableFocus.appHasLiveAXWithoutFocus(pid: pid)
                : false
            return FocusRead(
                verdict: EditableFocus.verdictForFocusError(
                    focusError,
                    bundleID: bundleID,
                    appHasLiveAXWithoutFocus: liveWithoutFocus
                ),
                axError: focusError,
                source: source
            )
        }
        guard let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return FocusRead(verdict: .unknown, source: source)
        }
        // Safe: type ID verified above (conditional casts are trivially true
        // for CF types; unconditional `as` is unexpressible).
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, EditableFocus.axTimeoutSeconds)
        if source == .systemWide {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else {
                // Focus lives in another app: ambiguity, not a void — the
                // frontmostPID race guard owns that failure mode.
                return FocusRead(verdict: .unknown, source: source)
            }
        }
        var roleRaw: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        )
        guard roleError == .success else {
            return FocusRead(
                verdict: .unknown,
                axError: roleError,
                hasSelectedText: selectedTextPresent(element: element),
                source: source
            )
        }
        let role = roleRaw as? String
        if let role, EditableFocus.textCapableRoles.contains(role) {
            let verdict = EditableFocus.classify(
                role: role,
                subrole: secureSubrole(role: role, element: element),
                pidMatches: true,
                publishesCaret: true,
                hasEditableSignal: true
            )
            return FocusRead(
                verdict: verdict,
                hasSelectedText: true,
                role: role,
                source: source
            )
        }
        let editableSignal = EditableFocus.hasPositiveEditableSignal(element: element, role: role)
        let publishesCaret = editableSignal || selectedTextPresent(element: element)
        var verdict = EditableFocus.classify(
            role: role,
            subrole: nil,
            pidMatches: true,
            publishesCaret: publishesCaret,
            hasEditableSignal: editableSignal
        )
        if verdict == .unknown, VoidShells.isVoidShell(bundleID: bundleID) {
            verdict = .noField
        }
        return FocusRead(
            verdict: verdict,
            hasSelectedText: publishesCaret,
            role: role,
            source: source
        )
    }

    /// True ONLY when `element` publishes a live, editable `CFRange` via
    /// `kAXSelectedTextRangeAttribute` (with settable `AXSelectedTextRange`
    /// or `AXSelectedText`). Non-editable containers like Finder's `AXDesktop`
    /// (`AXGroup`) and Chromium's root `AXWebArea` return a read-only dummy
    /// `CFRange(0, 0)` when nothing is focused; requiring settability prevents
    /// dummy container ranges from suppressing the catcher.
    nonisolated static func selectedTextPresent(element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, EditableFocus.axTimeoutSeconds)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success,
            let raw = rangeValue,
            CFGetTypeID(raw) == AXValueGetTypeID()
        else {
            return false
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range),
              range.location >= 0,
              range.location != kCFNotFound
        else {
            return false
        }
        var rangeSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable
        ) == .success, rangeSettable.boolValue {
            return true
        }
        var textSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &textSettable
        ) == .success, textSettable.boolValue {
            return true
        }
        return false
    }

    /// Secure-field subrole read, gated on text roles (the only ones it can
    /// reclassify): nil for every other role with no round-trip, nil on any
    /// read failure. A missing subrole means "not a password field", never
    /// ambiguity — plain text fields need not expose one.
    nonisolated static func secureSubrole(role: String?, element: AXUIElement) -> String? {
        guard let role, EditableFocus.textCapableRoles.contains(role) else { return nil }
        AXUIElementSetMessagingTimeout(element, EditableFocus.axTimeoutSeconds)
        var subroleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &subroleRaw
        ) == .success else { return nil }
        return subroleRaw as? String
    }
}
