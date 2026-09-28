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
import Foundation
import os

/// Verdict on whether keystrokes have somewhere to land.
enum EditableFocus: Equatable, Sendable {
    /// An AXTextField/AXTextArea holds focus — proceed.
    case editable
    /// Focus exists but is not editable (or nothing is focused) — divert.
    case noField
    /// AX errored, timed out, or answered ambiguously — legacy path.
    case unknown

    // Explicit: compared in the retry worker from nonisolated contexts (Swift 6).
    nonisolated static func == (lhs: EditableFocus, rhs: EditableFocus) -> Bool {
        switch (lhs, rhs) {
        case (.editable, .editable), (.noField, .noField), (.unknown, .unknown):
            return true
        default:
            return false
        }
    }

    /// Pure role mapping (unit-tested): nil role is unknown, text roles
    /// are editable, everything else present-but-not-editable diverts.
    /// `pidMatches` is the system-wide ownership check: a focused element
    /// owned by another app is ambiguity (`.unknown`, legacy proceed) —
    /// the frontmostPID race guard owns that failure mode with the better
    /// message, so this layer never double-jeopards it. Single owner per
    /// failure mode.
    nonisolated static func classify(role: String?, pidMatches: Bool = true) -> EditableFocus {
        guard pidMatches else { return .unknown }
        guard let role else { return .unknown }
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
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
}

/// Seam: the insertion path injects this; tests stub verdicts without AX.
protocol FocusChecking: Sendable {
    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus
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
    var reader: @Sendable (pid_t) -> (verdict: EditableFocus, axError: AXError?)

    init(reader: @Sendable @escaping (pid_t) -> (verdict: EditableFocus, axError: AXError?) = { LiveFocusCheck.liveRead(pid: $0) }) {
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

    nonisolated static func logVerdict(pid: pid_t, verdict: EditableFocus, axError: AXError?, timedOut: Bool, attempt: Int? = nil) {
        // Raw code, not the opaque struct description (which prints as
        // `Optional(__C.AXError)` and hides the value that decides the
        // sandbox-denial vs per-app-behavior question).
        let code = axError.map { String($0.rawValue) } ?? "nil"
        if let attempt {
            focusLog.info("focus pid=\(pid, privacy: .public) attempt=\(attempt, privacy: .public) verdict=\(String(describing: verdict), privacy: .public) axerr=\(code, privacy: .public) timeout=\(timedOut, privacy: .public)")
        } else {
            focusLog.info("focus pid=\(pid, privacy: .public) verdict=\(String(describing: verdict), privacy: .public) axerr=\(code, privacy: .public) timeout=\(timedOut, privacy: .public)")
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
                    Self.logVerdict(pid: pid, verdict: detail.verdict, axError: detail.axError, timedOut: false, attempt: attempt)
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

    /// Live reader: system-wide focused element first (WindowServer-level
    /// focus, immune to stale per-app trees), ownership-verified by pid,
    /// with the legacy per-app read as fallback when system-wide errors
    /// non-noValue (preserving today's `.unknown` degrade path exactly).
    /// `noValue` is returned raw so the caller can retry transient voids.
    nonisolated static func liveRead(pid: pid_t) -> (verdict: EditableFocus, axError: AXError?) {
        let wide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            wide, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard focusError == .success else {
            if focusError == .noValue {
                return (.noField, focusError)
            }
            return syncCheckDetail(pid: pid)
        }
        guard let raw = focused,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return (.unknown, nil) }
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else {
            return (.unknown, nil)
        }
        guard owner == pid else {
            // Focus lives in another app: ambiguity here, not a void —
            // the frontmostPID race guard owns that failure with the
            // better message.
            return (.unknown, nil)
        }
        var roleRaw: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        )
        guard roleError == .success else { return (.unknown, roleError) }
        return (EditableFocus.classify(role: roleRaw as? String, pidMatches: true), nil)
    }

    /// Detail variant: identical verdict, plus the raw AXError for the
    /// verdict log (unknown-cause diagnosis). v5: no-value IS the void
    /// case (nothing focused); any other error is ambiguity (legacy
    /// proceed). Decided here, where the AXError is still in hand.
    nonisolated static func syncCheckDetail(pid: pid_t) -> (verdict: EditableFocus, axError: AXError?) {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard focusError == .success else {
            return (EditableFocus.verdictForFocusError(focusError), focusError)
        }
        guard let raw = focused,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return (.unknown, nil) }
        // Safe: type ID verified above (RealTargetCapture.copyElement
        // precedent — conditional casts are trivially true for CF types,
        // unconditional `as` is unexpressible, so ID-gate + downcast).
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        var roleRaw: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        )
        guard roleError == .success else { return (.unknown, roleError) }
        return (EditableFocus.classify(role: roleRaw as? String), nil)
    }
}
