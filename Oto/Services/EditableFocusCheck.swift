//
//  EditableFocusCheck.swift
//  Oto
//
//  Catcher void-case fix: before posting keystrokes, verify the target
//  actually has an editable field focused. A live app with nowhere to
//  paste (Finder, desktop, viewer) used to report `.inserted` into the
//  void — now it diverts to recovery (`.noEditableField`) with the
//  clipboard untouched and nothing posted.
//
//  Read-only AX (focused element + role, never writes); runs behind the
//  existing trust gate (untrusted fails closed before reaching here), so
//  no new entitlement. `kAXErrorNoValue` on the focus read IS the void
//  case (nothing focused → divert); any other error, nil role, or the
//  300 ms timeout degrades to `.unknown`, which proceeds EXACTLY as
//  before — exotic AX trees can never regress insertion. The timeout is
//  unstructured by necessity (a blocking C call cannot honor cooperative
//  cancellation — a task group would await a hung worker forever); the
//  worker runs off-pool and a one-shot gate admits exactly one winner.
//  Every verdict is logged (focus category) so device trails are decisive.
//

import ApplicationServices
import AppKit
import Foundation
import os

/// Verdict on whether keystrokes have somewhere to land.
enum EditableFocus: Equatable, Sendable {
    /// An AXTextField/AXTextArea holds focus — proceed.
    case editable
    /// Focus exists but is not editable (or nothing is focused) — divert.
    case noField
    /// Focus is a secure password field — refuse (never auto-fill).
    case secureField
    /// AX errored, timed out, or answered ambiguously — legacy path.
    case unknown

    // Explicit: compared in the retry worker from nonisolated contexts (Swift 6).
    nonisolated static func == (lhs: EditableFocus, rhs: EditableFocus) -> Bool {
        switch (lhs, rhs) {
        case (.editable, .editable), (.noField, .noField),
            (.secureField, .secureField), (.unknown, .unknown):
            return true
        default:
            return false
        }
    }

    /// Pure role mapping (unit-tested): nil role is unknown, text roles
    /// are editable, everything else present-but-not-editable diverts.
    /// A text role with the `AXSecureTextField` subrole is a password
    /// field (`AXRoleConstants.h:408` — the role stays `AXTextField`, the
    /// subrole is the distinguishing mark) and refuses via `.secureField`.
    /// `pidMatches` is the system-wide ownership check: a focused element
    /// owned by another app is ambiguity (`.unknown`, legacy proceed) —
    /// the frontmostPID race guard owns that failure mode with the better
    /// message, so this layer never double-jeopards it. Single owner per
    /// failure mode.
    nonisolated static func classify(role: String?, subrole: String? = nil, pidMatches: Bool = true) -> EditableFocus {
        guard pidMatches else { return .unknown }
        guard let role else { return .unknown }
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            if subrole == kAXSecureTextFieldSubrole as String {
                return .secureField
            }
            return .editable
        }
        return .noField
    }

    /// Pure AX-error mapping (unit-tested — the v5 fix): `.noValue`
    /// on the focused-element read means nothing holds keyboard focus,
    /// which IS nowhere to paste → divert. Every other error is genuine
    /// ambiguity → legacy proceed. A missing role on an EXISTING element
    /// stays unknown via `classify(nil)` (ambiguity, not void).
    nonisolated static func verdictForFocusError(_ error: AXError) -> EditableFocus {
        error == .noValue ? .noField : .unknown
    }

    /// Selected-text probe resolution (canvas-editor fix): an element that
    /// exposes selected text (or a selected range) is text-capable even
    /// when its role read as non-text — canvas editors draw their own
    /// caret under generic roles. Pure — unit-tested. Secure fields still
    /// refuse (they expose selection too — refusal wins, pinned by test);
    /// editable/unknown pass through untouched.
    nonisolated static func resolveWithSelectionProbe(
        verdict: EditableFocus, hasSelectedText: Bool
    ) -> EditableFocus {
        guard hasSelectedText else { return verdict }
        switch verdict {
        case .secureField:
            return .secureField
        case .noField:
            return .unknown
        case .editable, .unknown:
            return verdict
        }
    }
}

/// Seam: the insertion path injects this; tests stub verdicts without AX.
protocol FocusChecking: Sendable {
    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus
}

/// Terminal emulators whose screens never expose AX text roles: a
/// focused pane consumes keystrokes by definition (the pty), so a
/// present-but-unmapped role proceeds (`.unknown`, legacy path) instead
/// of diverting — while true void (nothing focused) still diverts.
/// Secure password FIELDS still refuse via `.secureField` (subrole-gated,
/// never the global secure-input flag, which is not a gate); bracketed
/// paste keeps editors safe.
enum TerminalEmulators: Sendable {
    nonisolated static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "dev.warp.Warp",
    ]

    nonisolated static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// Owning app's bundle ID for pid triage. Nil for dead/fake pids —
    /// tests and unknown apps fall through to non-terminal behavior.
    nonisolated static func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// True when a focused-but-unmapped role should proceed: the role
    /// exists (something holds focus) in a keystroke-consuming app.
    /// Nil role (true void) never proceeds — see `proceedsVoid`.
    nonisolated static func proceeds(role: String?, bundleID: String?) -> Bool {
        guard role != nil else { return false }
        return isTerminal(bundleID: bundleID)
    }

    /// Terminal fallback applied to a classified verdict: a divert in a
    /// keystroke-consuming app proceeds (legacy path) — every other
    /// verdict passes through untouched, notably `.secureField` (a
    /// password field refuses even in a terminal).
    nonisolated static func fallback(
        verdict: EditableFocus, role: String?, bundleID: String?
    ) -> EditableFocus {
        guard verdict == .noField, proceeds(role: role, bundleID: bundleID) else {
            return verdict
        }
        return .unknown
    }

    /// True when even a persistent void proceeds: the app is a terminal
    /// emulator (keystrokes land in the pty by definition) but publishes
    /// no focused element (observed: focus present transiently around
    /// activation, absent in steady state). Nil bundle (dead pid)
    /// never proceeds — fail closed preserved.
    nonisolated static func proceedsVoid(bundleID: String?) -> Bool {
        isTerminal(bundleID: bundleID)
    }
}

/// Canvas editors whose steady state publishes no AX focus (the caret is
/// drawn by the app, not the accessibility tree): a persistent void there
/// is uninformative — proceed (legacy path) instead of diverting. Modeled
/// exactly on `TerminalEmulators` (same shape, same fail-closed rules):
/// secure fields still refuse everywhere, non-canvas voids still divert,
/// dead pids (nil bundle) never proceed.
enum CanvasEditors: Sendable {
    nonisolated static let bundleIDs: Set<String> = [
        "com.figma.Desktop",
    ]

    nonisolated static func isCanvas(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// Owning app's bundle ID for pid triage — shared with the terminal
    /// precedent (`TerminalEmulators.bundleID(for:)`), same fail-closed
    /// nil for dead pids.
    nonisolated static func proceedsVoid(bundleID: String?) -> Bool {
        isCanvas(bundleID: bundleID)
    }

    /// Canvas fallback applied to a classified verdict: a divert in a
    /// canvas editor proceeds (legacy path) — every other verdict passes
    /// through untouched, notably `.secureField` (refusal wins even on
    /// canvas).
    nonisolated static func fallback(
        verdict: EditableFocus, bundleID: String?
    ) -> EditableFocus {
        guard verdict == .noField, isCanvas(bundleID: bundleID) else {
            return verdict
        }
        return .unknown
    }
}

struct LiveFocusCheck: FocusChecking {
    /// Overall budget for the bounded patience loop below. Past this the
    /// verdict is `.unknown` (legacy behavior), not a hang.
    nonisolated static let timeoutNanoseconds: UInt64 = 700_000_000
    /// Transient nothing-focused reads (async AX trees, e.g. Chromium) are
    /// re-read, not diverted on first sight. Persistent void still diverts.
    nonisolated static let maxAttempts = 3
    nonisolated static let retryDelayNanoseconds: UInt64 = 100_000_000

    /// Injectable reader for deterministic retry tests. Production uses the
    /// live system-wide read; tests script verdict sequences without AX.
    /// Triple: verdict + raw error + selected-text presence (canvas-editor
    /// probe — content never crosses, only the boolean).
    var reader: @Sendable (pid_t) -> (verdict: EditableFocus, axError: AXError?, hasSelectedText: Bool)

    init(reader: @Sendable @escaping (pid_t) -> (verdict: EditableFocus, axError: AXError?, hasSelectedText: Bool) = { LiveFocusCheck.liveRead(pid: $0) }) {
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

    private nonisolated(unsafe) static let focusLog = Logger(subsystem: "app.Oto", category: "focus")

    nonisolated static func logVerdict(pid: pid_t, verdict: EditableFocus, axError: AXError?, timedOut: Bool, selected: Bool = false, attempt: Int? = nil) {
        // Raw code, not the opaque struct description (which prints as
        // `Optional(__C.AXError)` and hides the value that decides the
        // sandbox-denial vs per-app-behavior question).
        let code = axError.map { String($0.rawValue) } ?? "nil"
        if let attempt {
            focusLog.info("focus pid=\(pid, privacy: .public) attempt=\(attempt, privacy: .public) verdict=\(String(describing: verdict), privacy: .public) axerr=\(code, privacy: .public) sel=\(selected, privacy: .public) timeout=\(timedOut, privacy: .public)")
        } else {
            focusLog.info("focus pid=\(pid, privacy: .public) verdict=\(String(describing: verdict), privacy: .public) axerr=\(code, privacy: .public) sel=\(selected, privacy: .public) timeout=\(timedOut, privacy: .public)")
        }
    }

    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus {
        // Unstructured by necessity: the blocking AX call cannot honor
        // cooperative cancellation, so a structured group would await a
        // hung worker forever and the "timeout" would be a lie. The
        // worker runs OFF the cooperative pool (global queue — blocking
        // C call), the timer on it; ResumeGate admits exactly one winner.
        // A late loser still logs (truthful timestamped data) but cannot
        // resume or touch state.
        //
        // Bounded patience inside the worker: a transient noValue (async
        // AX trees publishing focus late, e.g. Chromium) sleeps a beat
        // and re-reads rather than diverting on first sight. This is NOT
        // the banned retry family: no activation loop, no focus
        // substitution, no policy refusal re-asked — the same attribute
        // read, patient timing, still diverting on a persistent void.
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            let reader = self.reader
            DispatchQueue.global(qos: .utility).async {
                var attempt = 0
                var verdict: EditableFocus = .unknown
                var settled = false
                while !settled {
                    attempt += 1
                    let detail = reader(pid)
                    Self.logVerdict(pid: pid, verdict: detail.verdict, axError: detail.axError, timedOut: false, selected: detail.hasSelectedText, attempt: attempt)
                    let transientVoid = detail.verdict == .noField
                        && detail.axError == .noValue
                        && attempt < Self.maxAttempts
                    if transientVoid {
                        Thread.sleep(forTimeInterval: Double(Self.retryDelayNanoseconds) / 1_000_000_000)
                    } else {
                        verdict = detail.verdict
                        settled = true
                    }
                }
                if gate.claim() { continuation.resume(returning: verdict) }
            }
            Task {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                // Gate first: if the worker already won (and logged its
                // detail), the timer stays silent — otherwise every
                // session emits a spurious timeout line after the truth.
                // If the timer wins, it logs + resumes; a late worker
                // detail line may follow, which reads chronologically.
                if gate.claim() {
                    Self.logVerdict(pid: pid, verdict: .unknown, axError: nil, timedOut: true)
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    /// Synchronous AX read (C API, thread-safe). Every failure shape —
    /// error code, missing element, missing role — is mapped explicitly,
    /// never guessed. Type-ID gate + downcast per the
    /// RealTargetCapture.copyElement precedent.
    nonisolated static func syncCheck(pid: pid_t) -> EditableFocus {
        syncCheckDetail(pid: pid).verdict
    }

    /// Selected-text probe (canvas-editor fix): true when the focused
    /// element answers `AXSelectedText` or `AXSelectedTextRange` — the
    /// Hex-context read, reused here as text-capability evidence. The value
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

    /// Single mapping funnel for both readers: probe upgrade, then canvas
    /// fallback. Every return site in `liveRead`/`syncCheckDetail` funnels
    /// here, so no path can bypass either rule. `element` is whatever
    /// focused element is in hand (nil on void/error paths — no probe
    /// without an element).
    nonisolated static func finalize(
        pid: pid_t,
        verdict: EditableFocus,
        axError: AXError?,
        element: AXUIElement?
    ) -> (verdict: EditableFocus, axError: AXError?, hasSelectedText: Bool) {
        let selected = element.map(selectedTextPresent) ?? false
        let probed = EditableFocus.resolveWithSelectionProbe(verdict: verdict, hasSelectedText: selected)
        let bundleID = TerminalEmulators.bundleID(for: pid)
        let out: EditableFocus
        if axError == .noValue, CanvasEditors.proceedsVoid(bundleID: bundleID) {
            out = .unknown
        } else {
            out = CanvasEditors.fallback(verdict: probed, bundleID: bundleID)
        }
        return (out, axError, selected)
    }

    /// Live reader: system-wide focused element first (WindowServer-level
    /// focus, immune to stale per-app trees), ownership-verified by pid,
    /// with the legacy per-app read as fallback when system-wide errors
    /// non-noValue (preserving today's `.unknown` degrade path exactly).
    /// `noValue` is returned raw so the caller can retry transient voids.
    /// Every exit funnels through `finalize` (probe + canvas rules).
    nonisolated static func liveRead(pid: pid_t) -> (verdict: EditableFocus, axError: AXError?, hasSelectedText: Bool) {
        let wide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            wide, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard focusError == .success else {
            if focusError == .noValue,
               TerminalEmulators.proceedsVoid(bundleID: TerminalEmulators.bundleID(for: pid))
            {
                return finalize(pid: pid, verdict: .unknown, axError: focusError, element: nil)
            }
            if focusError == .noValue {
                return finalize(
                    pid: pid,
                    verdict: EditableFocus.verdictForFocusError(focusError),
                    axError: focusError,
                    element: nil
                )
            }
            return syncCheckDetail(pid: pid)
        }
        guard let raw = focused,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return finalize(pid: pid, verdict: .unknown, axError: nil, element: nil) }
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else {
            return finalize(pid: pid, verdict: .unknown, axError: nil, element: nil)
        }
        guard owner == pid else {
            // Focus lives in another app: ambiguity here, not a void —
            // the frontmostPID race guard owns that failure with the
            // better message.
            return finalize(pid: pid, verdict: .unknown, axError: nil, element: nil)
        }
        var roleRaw: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        )
        guard roleError == .success else {
            return finalize(pid: pid, verdict: .unknown, axError: roleError, element: element)
        }
        let role = roleRaw as? String
        let verdict = TerminalEmulators.fallback(
            verdict: EditableFocus.classify(
                role: role, subrole: secureSubrole(role: role, element: element), pidMatches: true
            ),
            role: role, bundleID: TerminalEmulators.bundleID(for: pid)
        )
        return finalize(pid: pid, verdict: verdict, axError: nil, element: element)
    }

    /// Secure-field subrole read, gated on text roles (the only ones it
    /// can reclassify): nil for every other role with no round-trip, nil
    /// on any read failure. A missing subrole means "not a password
    /// field", never ambiguity — plain text fields need not expose one.
    nonisolated static func secureSubrole(role: String?, element: AXUIElement) -> String? {
        guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String else {
            return nil
        }
        var subroleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &subroleRaw
        ) == .success else { return nil }
        return subroleRaw as? String
    }

    /// Detail variant: identical verdict, plus the raw AXError for the
    /// verdict log (unknown-cause diagnosis) and the selected-text bit.
    /// v5: no-value IS the void case (nothing focused); any other error is
    /// ambiguity (legacy proceed). Decided here, where the AXError is still
    /// in hand. Every exit funnels through `finalize` (probe + canvas).
    nonisolated static func syncCheckDetail(pid: pid_t) -> (verdict: EditableFocus, axError: AXError?, hasSelectedText: Bool) {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard focusError == .success else {
            if focusError == .noValue,
               TerminalEmulators.proceedsVoid(bundleID: TerminalEmulators.bundleID(for: pid))
            {
                return finalize(pid: pid, verdict: .unknown, axError: focusError, element: nil)
            }
            return finalize(
                pid: pid,
                verdict: EditableFocus.verdictForFocusError(focusError),
                axError: focusError,
                element: nil
            )
        }
        guard let raw = focused,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return finalize(pid: pid, verdict: .unknown, axError: nil, element: nil) }
        // Safe: type ID verified above (RealTargetCapture.copyElement
        // precedent — conditional casts are trivially true for CF types,
        // unconditional `as` is unexpressible, so ID-gate + downcast).
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        var roleRaw: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        )
        guard roleError == .success else {
            return finalize(pid: pid, verdict: .unknown, axError: roleError, element: element)
        }
        let role = roleRaw as? String
        let verdict = TerminalEmulators.fallback(
            verdict: EditableFocus.classify(
                role: role, subrole: secureSubrole(role: role, element: element)
            ),
            role: role, bundleID: TerminalEmulators.bundleID(for: pid)
        )
        return finalize(pid: pid, verdict: verdict, axError: nil, element: element)
    }
}
