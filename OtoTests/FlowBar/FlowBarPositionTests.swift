//
//  FlowBarPositionTests.swift
//  OtoTests
//
//  Phase 8: pill slots are pure geometry + a scalar setting. Slot frames,
//  snap splits, and setting round-trips are headless (no window server);
//  the drag gesture itself is thin AppKit wiring over these.
//

import CoreGraphics
import Foundation
import Testing
@testable import Oto

struct FlowBarPositionTests {
    private func visible() -> NSRect {
        // 1512×944 visible area on a 1512×982 screen (menu strip off top).
        NSRect(x: 0, y: 0, width: 1512, height: 944)
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "oto-flowbar-position-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func bottomSlotIsToday() {
        let frame = FlowBarPosition.frame(width: 112, on: visible(), position: .bottom)
        // Bottom-center, 28pt margin, today's geometry exactly.
        #expect(frame.minY == 28)
        #expect(abs(frame.midX - 756) < 0.001)
        #expect(frame.width == 112)
        #expect(frame.height == VisualizerMath.pillHeight)
    }

    @Test func topSlotSitsBelowTheNotchLine() {
        let frame = FlowBarPosition.frame(width: 112, on: visible(), position: .top)
        // Top-center, 12pt under the visible top (= below menu bar + notch).
        #expect(frame.maxY == 932)
        #expect(abs(frame.midX - 756) < 0.001)
        #expect(frame.width == 112)
    }

    @Test func widePillsClampInsideTheScreen() {
        let frame = FlowBarPosition.frame(width: 4000, on: visible(), position: .top)
        #expect(frame.width == 1496)
        #expect(frame.minX == 8)
    }

    @Test func snapSplitFollowsTheMiddle() {
        let screen = visible()
        #expect(FlowBarPosition.nearest(dropCenterY: 100, on: screen) == .bottom)
        #expect(FlowBarPosition.nearest(dropCenterY: 900, on: screen) == .top)
        // The exact midpoint belongs to Top (straddling reads as "up there").
        #expect(FlowBarPosition.nearest(dropCenterY: screen.midY, on: screen) == .top)
    }

    @Test func settingRoundTripsAndDefaultsToBottom() {
        let (defaults, suite) = scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // Absent key → Bottom (current behavior, forever).
        #expect(FlowBarPosition.current(defaults: defaults) == .bottom)
        FlowBarPosition.save(.top, defaults: defaults)
        #expect(FlowBarPosition.current(defaults: defaults) == .top)
        FlowBarPosition.save(.bottom, defaults: defaults)
        #expect(FlowBarPosition.current(defaults: defaults) == .bottom)
        // Unknown strings (hand-edited defaults) fall back, never crash.
        defaults.set("penthouse", forKey: FlowBarPosition.defaultsKey)
        #expect(FlowBarPosition.current(defaults: defaults) == .bottom)
    }

    @Test func tickGateFiresOncePerEntry() {
        // v8b: the threshold tick is edge-triggered — entering a slot
        // ticks, staying silent, and silence never ticks.
        // (Mutating calls hoisted: #expect captures immutably.)
        var gate = SnapTickGate()
        let t0 = ContinuousClock().now
        let first = SnapTickGate.shouldTick(&gate, now: t0, slotChanged: true)
        #expect(first)
        let repeatInsideWindow = SnapTickGate.shouldTick(&gate, now: t0, slotChanged: true)
        #expect(!repeatInsideWindow)
        var fresh = SnapTickGate()
        let silent = SnapTickGate.shouldTick(&fresh, now: t0, slotChanged: false)
        #expect(!silent)
    }

    @Test func tickGateRearmsAfterTheWindow() async throws {
        // Past the 100ms refractory window, the next entry ticks again.
        var gate = SnapTickGate()
        let first = SnapTickGate.shouldTick(&gate, now: ContinuousClock().now, slotChanged: true)
        #expect(first)
        try await Task.sleep(for: .milliseconds(120))
        let rearmed = SnapTickGate.shouldTick(&gate, now: ContinuousClock().now, slotChanged: true)
        #expect(rearmed)
    }

    @Test func tickGateResetRearmsImmediately() {
        // A new grab re-arms instantly (no stale suppression leaks across
        // drags).
        var gate = SnapTickGate()
        let t0 = ContinuousClock().now
        let first = SnapTickGate.shouldTick(&gate, now: t0, slotChanged: true)
        #expect(first)
        SnapTickGate.reset(&gate)
        let rearmed = SnapTickGate.shouldTick(&gate, now: t0, slotChanged: true)
        #expect(rearmed)
    }

    @Test func rawValuesAreStable() {
        // The strings ARE the persisted format — renaming breaks upgrades.
        #expect(FlowBarPosition.top.rawValue == "top")
        #expect(FlowBarPosition.bottom.rawValue == "bottom")
        #expect(FlowBarPosition.defaultsKey == "app.Oto.flowBarPosition")
    }
}
