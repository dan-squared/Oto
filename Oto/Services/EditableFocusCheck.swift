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

import ApplicationServices
import AppKit
import Foundation
import os

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
    nonisolated static func classify(
        role: String?, subrole: String? = nil, pidMatches: Bool = true
    ) -> EditableFocus {
        guard pidMatches else { return .unknown }
        guard let role else { return .unknown }
        if textCapableRoles.contains(role) {
            return subrole == kAXSecureTextFieldSubrole as String ? .secureField : .editable
        }
        if nonEditableRoles.contains(role) { return .noField }
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

    /// Roles that positively say "this focus is not a text input". Kept
    /// narrow on purpose, and deliberately **interactive controls only**:
    ///
    /// - Containers (group, web area, scroll/layout area, tables, lists,
    ///   rows, cells, windows) are absent because a caret can live inside
    ///   them.
    /// - Content roles (`AXStaticText`, `AXHeading`, `AXImage`, `AXLink`)
    ///   are also absent. They cannot take a caret, but web-rendered editors
    ///   routinely report the caret's host as one of them — the AX tree is
    ///   least reliable exactly where the content is. A false divert is the
    ///   bug being fixed, and these are the roles that produced it.
    ///
    /// What is left is the set of native controls where the AX answer is
    /// trustworthy and where typing is impossible by construction.
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

    /// AX-error mapping (unit-tested). `noValue` means the app did not
    /// answer — NOT that nothing is editable. It diverts only for desktop
    /// shells, where "no field" is the true state. Every other error is
    /// ambiguity and proceeds.
    nonisolated static func verdictForFocusError(
        _ error: AXError, bundleID: String? = nil
    ) -> EditableFocus {
        guard error == .noValue, VoidShells.isVoidShell(bundleID: bundleID) else {
            return .unknown
        }
        return .noField
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
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private nonisolated(unsafe) var claimed = false
        nonisolated func claim() -> Bool {
            lock.withLock {
                guard !claimed else { return false }
                claimed = true
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
        // ResumeGate admits exactly one winner. A late loser still logs
        // (truthful timestamped data) but cannot resume or touch state.
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            let reader = self.reader
            let bundleID = FocusBundle.bundleID(for: pid)
            DispatchQueue.global(qos: .utility).async {
                let read = reader(pid)
                Self.logVerdict(pid: pid, read: read, timedOut: false, bundleID: bundleID)
                if gate.claim() { continuation.resume(returning: read.verdict) }
            }
            Task {
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
        }
    }

    /// Live reader: system-wide focused element first (WindowServer-level
    /// focus, immune to stale per-app trees), ownership-verified by pid,
    /// then the app-level read. v6 reconciles them: if the system-wide read
    /// is not a positive text answer, a positive app-level answer wins — the
    /// weaker read can no longer veto a live field (Shape D).
    nonisolated static func liveRead(pid: pid_t) -> FocusRead {
        let bundle = FocusBundle.bundleID(for: pid)
        let wide = readFocusedElement(
            AXUIElementCreateSystemWide(), source: .systemWide, pid: pid, bundleID: bundle
        )
        if wide.verdict == .editable || wide.verdict == .secureField { return wide }
        let app = readFocusedElement(
            AXUIElementCreateApplication(pid), source: .app, pid: pid, bundleID: bundle
        )
        if app.verdict == .editable || app.verdict == .secureField { return app }
        // Shape D trail: the two reads disagreeing is the one thing that
        // explains a divert when the system-wide read looked innocent. Log
        // the loser so a device run needs no second pass.
        if app.verdict != wide.verdict || app.role != wide.role || app.axError != wide.axError {
            logAlternate(pid: pid, read: app, bundleID: bundle)
        }
        return wide
    }

    /// One element read. Every failure shape — error code, missing element,
    /// missing role — is mapped explicitly, never guessed. Type-ID gate +
    /// downcast per the RealTargetCapture.copyElement precedent.
    nonisolated static func readFocusedElement(
        _ root: AXUIElement, source: FocusSource, pid: pid_t, bundleID: String?
    ) -> FocusRead {
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            root, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard focusError == .success else {
            return FocusRead(
                verdict: EditableFocus.verdictForFocusError(focusError, bundleID: bundleID),
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
        let verdict = EditableFocus.classify(
            role: role,
            subrole: secureSubrole(role: role, element: element),
            pidMatches: true
        )
        return FocusRead(
            verdict: verdict,
            hasSelectedText: selectedTextPresent(element: element),
            role: role,
            source: source
        )
    }

    /// Selected-text presence (diagnostic only in v6): true when the focused
    /// element answers `AXSelectedText` or `AXSelectedTextRange`. The value
    /// is released unread (presence only — content never crosses); any
    /// failure means "no signal", never error.
    nonisolated static func selectedTextPresent(element: AXUIElement) -> Bool {
        for attribute in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            _ = value
            if error == .success { return true }
        }
        return false
    }

    /// Secure-field subrole read, gated on text roles (the only ones it can
    /// reclassify): nil for every other role with no round-trip, nil on any
    /// read failure. A missing subrole means "not a password field", never
    /// ambiguity — plain text fields need not expose one.
    nonisolated static func secureSubrole(role: String?, element: AXUIElement) -> String? {
        guard let role, EditableFocus.textCapableRoles.contains(role) else { return nil }
        var subroleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &subroleRaw
        ) == .success else { return nil }
        return subroleRaw as? String
    }
}
