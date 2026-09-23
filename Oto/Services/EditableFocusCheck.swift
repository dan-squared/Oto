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

    /// Pure role mapping (unit-tested): nil role is unknown, text roles
    /// are editable, everything else present-but-not-editable diverts.
    nonisolated static func classify(role: String?) -> EditableFocus {
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
    /// A hung target must never stall finalization — past this budget
    /// the verdict is `.unknown` (legacy behavior), not a hang.
    nonisolated static let timeoutNanoseconds: UInt64 = 300_000_000

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

    nonisolated static func logVerdict(pid: pid_t, verdict: EditableFocus, axError: AXError?, timedOut: Bool) {
        // Raw code, not the opaque struct description (which prints as
        // `Optional(__C.AXError)` and hides the value that decides the
        // sandbox-denial vs per-app-behavior question).
        let code = axError.map { String($0.rawValue) } ?? "nil"
        focusLog.info("focus pid=\(pid, privacy: .public) verdict=\(String(describing: verdict), privacy: .public) axerr=\(code, privacy: .public) timeout=\(timedOut, privacy: .public)")
    }

    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus {
        // Unstructured by necessity: the blocking AX call cannot honor
        // cooperative cancellation, so a structured group would await a
        // hung worker forever and the "timeout" would be a lie. The
        // worker runs OFF the cooperative pool (global queue — blocking
        // C call), the timer on it; ResumeGate admits exactly one winner.
        // A late loser still logs (truthful timestamped data) but cannot
        // resume or touch state.
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            DispatchQueue.global(qos: .utility).async {
                let detail = Self.syncCheckDetail(pid: pid)
                Self.logVerdict(pid: pid, verdict: detail.verdict, axError: detail.axError, timedOut: false)
                if gate.claim() { continuation.resume(returning: detail.verdict) }
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
