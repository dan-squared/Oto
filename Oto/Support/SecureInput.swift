//
//  SecureInput.swift
//  Oto
//

import AppKit
import Carbon.HIToolbox
import Foundation
import IOKit

/// Secure Event Input blocks synthetic keystrokes system-wide — while held,
/// an injected Cmd-V silently vanishes. Check before posting, never after.
/// Pattern follows the Yap reference (`SecureInput`, MIT) as Oto-owned code.
enum SecureInput {
    /// The gate insertion depends on. Needs no entitlement.
    static var isEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Best-effort hint for the recovery message ("held by Safari"), never a
    /// security decision. Nil-tolerant: unknown holder still fails closed.
    /// The pid lives on the registry root, not under IOResources as most
    /// write-ups claim. The reported pid can be wrong for background holders,
    /// so callers must present it as a hint.
    static func holderName() -> String? {
        guard let pid = holderPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    private static func holderPID() -> pid_t? {
        guard isEnabled else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(),
            let sessions = property as? [[String: Any]]
        else { return nil }
        for session in sessions {
            if let pid = session["kCGSSessionSecureInputPID"] as? Int, pid != 0 {
                return pid_t(pid)
            }
        }
        return nil
    }
}
