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

/// The caret, as numbers only: where the selection starts, how long it is,
/// and how many characters the field holds (when the app publishes a count).
struct CaretSample: Equatable, Sendable {
    let location: Int
    let length: Int
    let characters: Int?

    /// True when anything observable about the caret or the field changed.
    nonisolated func differs(from other: CaretSample) -> Bool {
        location != other.location
            || length != other.length
            || characters != other.characters
    }
}

enum DeliveryOutcome: Equatable, Sendable {
    /// Something observable changed after the post: the text went in.
    case landed
    /// The same element was still focused and nothing moved: the post was
    /// delivered but the app did not take it.
    case notLanded
    /// No signal to judge (web editor, no AX, read error, element gone).
    /// Treated exactly like the pre-v7 product: assume the post worked.
    case unverifiable

    nonisolated static func == (lhs: DeliveryOutcome, rhs: DeliveryOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.landed, .landed), (.notLanded, .notLanded),
            (.unverifiable, .unverifiable):
            return true
        default:
            return false
        }
    }
}

/// One probe, captured BEFORE the paste. `read` and `stillFocused` re-read
/// the element captured at probe time — never "whatever is focused now" — so
/// a difference cannot be another field's caret moving.
struct DeliveryProbe: Sendable {
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

    /// Poll until the caret moves or the budget expires. A move is proof and
    /// returns immediately; only the failure path pays the full budget, and
    /// only then is "same element" checked (a moved focus means we cannot
    /// judge, which is not the same as failure).
    nonisolated static func verify(
        probe: DeliveryProbe, budget: UInt64, poll: UInt64,
        sleep: @Sendable (UInt64) async -> Void
    ) async -> DeliveryOutcome {
        guard let initial = probe.initial else { return .unverifiable }
        let start = Date()
        while Date().timeIntervalSince(start) * 1_000_000_000 < Double(budget) {
            if let now = probe.read(), now.differs(from: initial) {
                return .landed
            }
            await sleep(poll)
        }
        return outcome(
            before: initial,
            after: probe.read(),
            sameElement: probe.stillFocused()
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
/// focus gate uses), then the two required text attributes.
struct LiveDeliveryCheck: DeliveryChecking {
    nonisolated func probe(for pid: pid_t) -> DeliveryProbe {
        guard AXIsProcessTrusted(),
              let element = Self.focusedElement(pid: pid),
              let initial = Self.sample(element)
        else { return .unavailable }
        let box = CaretElementBox(element)
        return DeliveryProbe(
            initial: initial,
            read: { Self.sample(box.element) },
            stillFocused: { Self.isFocused(box.element, pid: pid) }
        )
    }

    /// Focused element, only when this pid owns it. Any error → nil (no
    /// signal), never a guess.
    nonisolated static func focusedElement(pid: pid_t) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
            let value = raw,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
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
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &raw
        ) == .success,
            let number = raw as? NSNumber
        else { return nil }
        return number.intValue
    }
}
