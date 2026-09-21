//
//  TextInsertionService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Narrow insertion seam. Real implementation (layered Accessibility +
/// clipboard insertion with change-count-guarded restore) lands in Phase 4.
/// Success is determined here — never by merely sending a paste event.
protocol TextInserting: Sendable {
    func insert(_ text: String, into target: TargetApplication) async -> InsertionResult
}

/// Recording fake for Phase 1 coordinator tests. Asserts which target the
/// text went to; scriptable outcome including secure-field-style refusal.
actor FakeTextInsertion: TextInserting {
    /// Outcome returned by `insert`.
    var result: InsertionResult = .inserted

    private(set) var calls: [(text: String, target: TargetApplication)] = []

    init(result: InsertionResult = .inserted) {
        self.result = result
    }

    func insert(_ text: String, into target: TargetApplication) async -> InsertionResult {
        calls.append((text: text, target: target))
        return result
    }

    /// Test-only visibility into what would have been inserted. Never logged.
    func lastText() async -> String? {
        calls.last?.text
    }
}
