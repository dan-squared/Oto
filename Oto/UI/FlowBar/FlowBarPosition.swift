//
//  FlowBarPosition.swift
//  Oto
//
//  Phase 8: where the pill lives. Two slots — Top (top-center, just below
//  the menu-bar/notch line) and Bottom (today's bottom-center). The slot is
//  a persisted setting AND a drag-and-snap gesture target; both write the
//  same key, so they can never disagree. Geometry is pure (nonisolated) so
//  slots and snap splits are headless-tested; the panel owns pixels.
//

import CoreGraphics
import Foundation

/// Pill slot. Raw values are the persisted strings — never rename them.
enum FlowBarPosition: String, Sendable {
    case top
    case bottom

    nonisolated static let defaultsKey = "app.Oto.flowBarPosition"
    nonisolated static let topMargin: CGFloat = 12
    nonisolated static let bottomMargin: CGFloat = 28
    /// Drop-glide length (s). The land tick uses the SAME constant — the
    /// animation and the tick can never drift apart (v8b F1).
    nonisolated static let snapDuration: Double = 0.15
    /// Minimum gap between mid-drag threshold ticks. Boundary wiggle
    /// inside this window stays silent — no machine-gun (v8b).
    nonisolated static let tickRefractory: Duration = .milliseconds(100)

    /// Upgrade default: absent key means Bottom (current behavior, forever).
    nonisolated static func current(defaults: UserDefaults = .standard) -> FlowBarPosition {
        guard let raw = defaults.object(forKey: defaultsKey) as? String else { return .bottom }
        return FlowBarPosition(rawValue: raw) ?? .bottom
    }

    nonisolated static func save(_ position: FlowBarPosition, defaults: UserDefaults = .standard) {
        defaults.set(position.rawValue, forKey: defaultsKey)
    }

    /// Slot frame for a pill width on a screen's visible frame. Same
    /// clamp/center math the panel always used; only Y is slot-dependent.
    /// `visibleFrame` already excludes the menu bar (and the notch lives
    /// inside the menu strip), so Top truly sits below the notch on every Mac.
    nonisolated static func frame(
        width: CGFloat, on visible: NSRect, position: FlowBarPosition
    ) -> NSRect {
        let clamped = min(width, visible.width - 16)
        let x = max(visible.minX + 8, visible.midX - clamped / 2)
        let y: CGFloat
        switch position {
        case .top:
            y = visible.maxY - VisualizerMath.pillHeight - Self.topMargin
        case .bottom:
            y = visible.minY + Self.bottomMargin
        }
        return NSRect(
            x: x, y: y,
            width: clamped, height: VisualizerMath.pillHeight
        )
    }



    /// Snap split: the slot whose half holds the pill's center Y.
    /// The exact midpoint belongs to Top (a dropped pill straddling the
    /// line reads as "up there", not "down here").
    nonisolated static func nearest(dropCenterY y: CGFloat, on visible: NSRect) -> FlowBarPosition {
        y < visible.midY ? .bottom : .top
    }
}

/// Debounce for mid-drag threshold ticks (Phase 8b): edge-triggered,
/// with a refractory window so boundary wiggle can't machine-gun. Pure so
/// the cadence is headless-tested; the panel owns pixels. Static +
/// nonisolated throughout (default-MainActor would otherwise isolate the
/// instance and lock tests out — VisualizerMath precedent).
struct SnapTickGate: Sendable {
    var lastFire: ContinuousClock.Instant?

    nonisolated static func shouldTick(
        _ gate: inout SnapTickGate, now: ContinuousClock.Instant, slotChanged: Bool
    ) -> Bool {
        guard slotChanged else { return false }
        if let last = gate.lastFire,
           now - last < FlowBarPosition.tickRefractory { return false }
        gate.lastFire = now
        return true
    }

    nonisolated static func reset(_ gate: inout SnapTickGate) {
        gate.lastFire = nil
    }
}
