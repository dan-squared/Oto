//
//  DeliveryVerification.swift
//  Oto
//
//  Post-paste delivery check (v7): prove the paste landed instead of
//  assuming it. Before v7, `.inserted` meant "four Cmd-V events reached the
//  HID tap" — the same log line appeared for a session that inserted and one
//  that did not, so a failed paste was only visible to the person looking at
//  the screen.
//
//  Native editable text is verifiable because macOS REQUIRES two attributes
//  on every editable text element (`AXAttributeConstants.h:697-709`,
//  `:744-754`):
//    - `AXSelectedTextRange` — AXValueRef of kAXValueCFRange
//    - `AXNumberOfCharacters` — CFNumberRef
//  Both are `(location, length)` and an integer. No document content is read.
//
//  Web-rendered editors are NOT verifiable: their caret host often reports a
//  non-text role (Muse's composer is an AXButton inside an AXWebArea) and
//  neither attribute is required there. Those sessions report
//  `.unverifiable` and behave exactly as before — an honest gap, never a
//  guess. Guessing "not landed" would put a catcher over text that is
//  already in the document.
//

import ApplicationServices
import AppKit
import Foundation
import Synchronization

/// The caret, as numbers only: where the selection starts, how long it is,
/// and how many characters the field holds (when the app publishes a count).
nonisolated struct CaretSample: Equatable, Sendable {
    let location: Int
    let length: Int
    let characters: Int?

    /// True when anything observable about the caret or the field changed.
    func differs(from other: CaretSample) -> Bool {
        location != other.location
            || length != other.length
            || characters != other.characters
    }

    /// True when both samples publish character counts and the count increased,
    /// proving the target field accepted new text.
    func characterCountGrew(from initial: CaretSample) -> Bool {
        guard let before = initial.characters, let after = characters else { return false }
        return after > before
    }
}

nonisolated enum DeliveryOutcome: Equatable, Sendable {
    /// Something observable changed after the post: the text went in.
    case landed
    /// The same element was still focused and nothing moved: the post was
    /// delivered but the app did not take it.
    case notLanded
    /// No signal to judge (web editor, no AX, read error, element gone).
    /// Treated exactly like the pre-v7 product: assume the post worked.
    case unverifiable
}

/// Detailed delivery verification result: pairs the verdict with whether
/// `AXNumberOfCharacters` positively grew (allowing immediate clipboard
/// restore vs keeping a short restore floor when only caret position moved).
nonisolated struct DeliveryResult: Equatable, Sendable {
    let outcome: DeliveryOutcome
    let characterCountGrew: Bool
}

/// One probe, captured BEFORE the paste. `read` and `stillFocused` re-read
/// the element captured at probe time — never "whatever is focused now" — so
/// a difference cannot be another field's caret moving.
nonisolated struct DeliveryProbe: Sendable {
    /// Nil when the app publishes no verifiable signal. Nil short-circuits
    /// the whole check: no poll, no budget, `.unverifiable`.
    var initial: CaretSample?
    var read: @Sendable () -> CaretSample?
    /// Whether the probed element is still the focused element.
    var stillFocused: @Sendable () -> Bool

    nonisolated static let unavailable = DeliveryProbe(
        initial: nil,
        read: { nil },
        stillFocused: { false }
    )
}

protocol DeliveryChecking: Sendable {
    nonisolated func probe(for pid: pid_t) -> DeliveryProbe
    nonisolated func probeAsync(for pid: pid_t) async -> DeliveryProbe
}

extension DeliveryChecking {
    /// Runs `probe(for:)` off `@MainActor` on a utility queue with a hard
    /// 300ms timeout guard so hung AX IPC in another app can never freeze the
    /// UI or HID event tap.
    nonisolated func probeAsync(for pid: pid_t) async -> DeliveryProbe {
        await DeliveryProbeRunner.run(timeoutNanoseconds: LiveDeliveryCheck.probeTimeoutNanoseconds) {
            self.probe(for: pid)
        }
    }
}

/// Off-pool bounded runner for blocking AX probe reads.
private enum DeliveryProbeRunner {
    private final class ClaimGate: Sendable {
        private let claimed = Mutex(false)
        nonisolated func claim() -> Bool {
            claimed.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
        }
    }

    nonisolated static func run(
        timeoutNanoseconds: UInt64,
        work: @escaping @Sendable () -> DeliveryProbe
    ) async -> DeliveryProbe {
        await withCheckedContinuation { continuation in
            let gate = ClaimGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                if gate.claim() {
                    continuation.resume(returning: .unavailable)
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let probe = work()
                timeoutTask.cancel()
                if gate.claim() {
                    continuation.resume(returning: probe)
                }
            }
        }
    }
}

/// Pure decision core (unit-tested). "Different" is the only positive
/// evidence; identity is the only proof the comparison is meaningful.
enum DeliveryVerification {
    nonisolated static func outcome(
        before: CaretSample?, after: CaretSample?, sameElement: Bool
    ) -> DeliveryOutcome {
        guard let before, let after, sameElement else { return .unverifiable }
        return before.differs(from: after) ? .landed : .notLanded
    }

    /// Base budget plus a little per kilobyte: a 6 KB paste renders slower
    /// than a 6 character one. Capped — a big paste must never hold the
    /// insertion path open indefinitely.
    nonisolated static func budget(
        base: UInt64, perKB: UInt64, cap: UInt64, utf8Count: Int
    ) -> UInt64 {
        let kilobytes = UInt64(max(0, utf8Count / 1024))
        return min(cap, base &+ kilobytes &* perKB)
    }

    /// Poll until the caret moves or the budget expires. Waits one poll
    /// interval before the first read (when `poll > 0`), checks `sameElement`
    /// or character-count growth before declaring `.landed`, and uses a
    /// monotonic `ContinuousClock` deadline.
    nonisolated static func verify(
        probe: DeliveryProbe, budget: UInt64, poll: UInt64,
        sleep: @Sendable (UInt64) async -> Void
    ) async -> DeliveryOutcome {
        await verifyDetailed(probe: probe, budget: budget, poll: poll, sleep: sleep).outcome
    }

    nonisolated static func verifyDetailed(
        probe: DeliveryProbe, budget: UInt64, poll: UInt64,
        sleep: @Sendable (UInt64) async -> Void
    ) async -> DeliveryResult {
        guard let initial = probe.initial else {
            return DeliveryResult(outcome: .unverifiable, characterCountGrew: false)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(clamping: budget))
        if poll > 0 {
            await sleep(poll)
        }
        while clock.now < deadline {
            if let now = probe.read(), now.differs(from: initial) {
                let grew = now.characterCountGrew(from: initial)
                if grew || probe.stillFocused() {
                    return DeliveryResult(outcome: .landed, characterCountGrew: grew)
                }
                return DeliveryResult(outcome: .unverifiable, characterCountGrew: false)
            }
            await sleep(poll)
        }
        let after = probe.read()
        let grew = after.map { $0.characterCountGrew(from: initial) } ?? false
        let same = grew || probe.stillFocused()
        let finalOutcome = outcome(before: initial, after: after, sameElement: same)
        return DeliveryResult(
            outcome: finalOutcome,
            characterCountGrew: finalOutcome == .landed && grew
        )
    }
}

/// Holds the AXUIElement for `DeliveryProbe`'s closures. AXUIElement is a CF
/// type the compiler cannot prove Sendable; the value is immutable and
/// attribute reads are thread-safe, so the box is the sharing proof.
nonisolated final class CaretElementBox: @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }
}

/// Live reader: system-wide focused element, pid-verified (the same rule the
/// focus gate uses), then the two required text attributes. Every AXUIElement
/// carries a 0.25s messaging timeout.
struct LiveDeliveryCheck: DeliveryChecking {
    nonisolated static let axTimeoutSeconds: Float = 0.25
    nonisolated static let probeTimeoutNanoseconds: UInt64 = 300_000_000

    nonisolated func probe(for pid: pid_t) -> DeliveryProbe {
        guard AXIsProcessTrusted(),
              let element = Self.focusedElement(pid: pid),
              Self.isVerifiableTextElement(element),
              let initial = Self.sample(element)
        else { return .unavailable }
        let box = CaretElementBox(element)
        return DeliveryProbe(
            initial: initial,
            read: { Self.sample(box.element) },
            stillFocused: { Self.isFocused(box.element, pid: pid) }
        )
    }

    /// Capability-driven verifiability gate: only native AppKit/SwiftUI text
    /// controls whose AX tree genuinely owns live editable text can prove
    /// post-paste delivery.
    ///
    /// - Terminals, multiplexers, and custom-rendered editors (Ghostty, iTerm2,
    ///   Warp, Alacritty, Kitty, JetBrains, Zed, Emacs, and any future grid)
    ///   do not expose settable `AXValue` + `AXSelectedText`.
    /// - Web/Chromium/Electron DOM editors (Chrome, Safari web pages, Slack,
    ///   Claude, Notion, VS Code, Cursor, Discord, Obsidian) publish DOM
    ///   attributes (`AXDOMClassList`, `AXDOMIdentifier`, `AXEditableAncestor`)
    ///   and frequently update their AX caches asynchronously or keep virtualized
    ///   ranges static after a real paste. Skipping delivery proof for them
    ///   eliminates the "pasted AND also fired catcher" double-fire bug across
    ///   every browser and Electron app without hardcoding bundle IDs.
    nonisolated static func isVerifiableTextElement(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        var roleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRaw
        ) == .success,
            let role = roleRaw as? String,
            EditableFocus.textCapableRoles.contains(role)
        else { return false }

        // Reject web/Chromium/Electron DOM editors (async/virtualized AX caches).
        for webAttr in ["AXDOMClassList", "AXDOMIdentifier", kAXEditableAncestorAttribute as String] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, webAttr as CFString, &value) == .success,
               value != nil
            {
                return false
            }
        }

        // Require BOTH AXValue and AXSelectedText settable AND a live character count:
        // native AppKit/SwiftUI text inputs satisfy all three; terminals and custom
        // editors do not.
        var valueSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &valueSettable
        ) == .success, valueSettable.boolValue else {
            return false
        }
        var selectedSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &selectedSettable
        ) == .success, selectedSettable.boolValue else {
            return false
        }
        return characterCount(element) != nil
    }

    /// Focused element, only when this pid owns it. Any error → nil (no
    /// signal), never a guess.
    nonisolated static func focusedElement(pid: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeoutSeconds)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
            let value = raw,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else {
            return nil
        }
        return element
    }

    nonisolated static func isFocused(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard let current = focusedElement(pid: pid) else { return false }
        return CFEqual(element, current)
    }

    /// The caret, or nil when the element publishes no range (web editors,
    /// unsupported roles, errors). Content is never read.
    nonisolated static func sample(_ element: AXUIElement) -> CaretSample? {
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &raw
        ) == .success,
            let value = raw,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
            return nil
        }
        return CaretSample(
            location: range.location,
            length: range.length,
            characters: characterCount(element)
        )
    }

    /// `AXNumberOfCharacters` when published; nil is "no second signal",
    /// which only narrows the comparison, never widens it.
    nonisolated static func characterCount(_ element: AXUIElement) -> Int? {
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &raw
        ) == .success,
            let number = raw as? NSNumber
        else { return nil }
        return number.intValue
    }
}
