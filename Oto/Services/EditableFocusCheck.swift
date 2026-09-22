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
//  no new entitlement. Any AX error, nil, or timeout degrades to
//  `.unknown`, which proceeds EXACTLY as before — exotic AX trees can
//  never regress insertion. Hung targets can't stall finalization: the
//  check races a 300 ms timeout.
//

import ApplicationServices
import Foundation

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
}

/// Seam: the insertion path injects this; tests stub verdicts without AX.
protocol FocusChecking: Sendable {
    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus
}

struct LiveFocusCheck: FocusChecking {
    /// A hung target must never stall finalization — past this budget
    /// the verdict is `.unknown` (legacy behavior), not a hang.
    nonisolated static let timeoutNanoseconds: UInt64 = 300_000_000

    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus {
        await withTaskGroup(of: EditableFocus.self) { group in
            group.addTask { Self.syncCheck(pid: pid) }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                return .unknown
            }
            let first = await group.next() ?? .unknown
            group.cancelAll()
            return first
        }
    }

    /// Synchronous AX read (C API, thread-safe). Every failure shape —
    /// error code, missing element, missing role — is `.unknown`, never
    /// a guess. Conditional casts only: an unexpected object graph can
    /// never trap.
    nonisolated static func syncCheck(pid: pid_t) -> EditableFocus {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        // Type-ID gate first: the conditional cast below is trivially
        // true for CoreFoundation types (compiler-enforced), so the ID
        // check is the real protection against a surprising graph.
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
            let raw = focused,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return .unknown }
        // Safe: type ID verified above (RealTargetCapture.copyElement
        // precedent — conditional casts are trivially true for CF types,
        // unconditional `as` is unexpressible, so ID-gate + downcast).
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        var roleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        ) == .success
        else { return .unknown }
        return EditableFocus.classify(role: roleRaw as? String)
    }
}
