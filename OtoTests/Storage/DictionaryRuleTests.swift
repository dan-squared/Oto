//
//  DictionaryRuleTests.swift
//  OtoTests
//
//  Phase 6A: pure apply() matrix — boundaries, injection, Unicode,
//  longest-match, no-cascade, protection, scope, validation, import.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct DictionaryRuleTests {
    private func target(_ bundleID: String? = nil) -> TargetApplication {
        TargetApplication(bundleIdentifier: bundleID)
    }

    private func rule(
        _ spoken: String,
        _ replacement: String,
        scope: String? = nil,
        enabled: Bool = true
    ) -> DictionaryRule {
        DictionaryRule(spoken: spoken, replacement: replacement, bundleID: scope, isEnabled: enabled)
    }

    // MARK: - Matching and boundaries

    @Test func caseInsensitiveLiteralReplacement() {
        let out = applyDictionaryRules(
            [rule("my company", "Acme Corp")],
            to: "MY COMPANY called", for: target()
        )
        #expect(out == "Acme Corp called")
    }

    @Test func noSubstringFire() {
        #expect(applyDictionaryRules([rule("oto", "Oto")], to: "phototo booth", for: target()) == "phototo booth")
        #expect(applyDictionaryRules([rule("oto", "Oto")], to: "say oto, please", for: target()) == "say Oto, please")
    }

    @Test func punctuationEdges() {
        #expect(applyDictionaryRules([rule("well", "WELL")], to: "well-known", for: target()) == "WELL-known")
        #expect(applyDictionaryRules([rule("oto", "Oto")], to: "(oto)", for: target()) == "(Oto)")
    }

    @Test func regexInjectionIsLiteral() {
        let out = applyDictionaryRules([rule("c++", "C++")], to: "I love c++ lots", for: target())
        #expect(out == "I love C++ lots")
        let paren = applyDictionaryRules([rule("(c)", "see")], to: "mark (c) here", for: target())
        #expect(paren == "mark see here")
    }

    @Test func unicodeWordBoundary() {
        #expect(applyDictionaryRules([rule("café", "CAFE")], to: "un café here", for: target()) == "un CAFE here")
        // Trailing word char blocks: no fire inside "cafés".
        #expect(applyDictionaryRules([rule("café", "CAFE")], to: "cafés visit", for: target()) == "cafés visit")
    }

    @Test func emojiSafeSplicing() {
        let out = applyDictionaryRules([rule("oto", "Oto")], to: "launch 🚀 oto now", for: target())
        #expect(out == "launch 🚀 Oto now")
    }

    @Test func longestMatchWins() {
        let rules = [rule("new york", "NYC"), rule("york", "Y")]
        #expect(applyDictionaryRules(rules, to: "new york", for: target()) == "NYC")
        #expect(applyDictionaryRules(rules, to: "york alone", for: target()) == "Y alone")
    }

    @Test func noCascade() {
        let rules = [rule("a", "b"), rule("b", "a")]
        #expect(applyDictionaryRules(rules, to: "a b", for: target()) == "b a")
    }

    @Test func replacementContainingSpokenIsInert() {
        let rules = [rule("my company", "oto labs"), rule("oto", "OTO")]
        #expect(applyDictionaryRules(rules, to: "my company", for: target()) == "oto labs")
    }

    @Test func disabledRuleInvisible() {
        let rules = [rule("york", "Y", enabled: false), rule("new york", "NYC")]
        #expect(applyDictionaryRules(rules, to: "new york", for: target()) == "NYC")
        #expect(applyDictionaryRules([rule("york", "Y", enabled: false)], to: "york", for: target()) == "york")
    }

    @Test func emptyInputsUnchanged() {
        #expect(applyDictionaryRules([rule("a", "b")], to: "", for: target()) == "")
        #expect(applyDictionaryRules([], to: "hello", for: target()) == "hello")
    }

    // MARK: - Protection

    @Test func urlVeto() {
        let out = applyDictionaryRules(
            [rule("oto", "Oto")],
            to: "see https://example.com/oto/docs now", for: target()
        )
        #expect(out == "see https://example.com/oto/docs now")
    }

    @Test func emailVeto() {
        let out = applyDictionaryRules(
            [rule("mail", "MAIL")],
            to: "write to jane@mailhost.com today", for: target()
        )
        #expect(out == "write to jane@mailhost.com today")
    }

    @Test func pathVeto() {
        let out = applyDictionaryRules(
            [rule("docs", "DOCS")],
            to: "open ~/docs/report and /usr/local/docs/x", for: target()
        )
        #expect(out == "open ~/docs/report and /usr/local/docs/x")
    }

    @Test func protectionIsSurgical() {
        let out = applyDictionaryRules(
            [rule("oto", "Oto")],
            to: "oto at https://x.test/oto is oto", for: target()
        )
        #expect(out == "Oto at https://x.test/oto is Oto")
    }

    // MARK: - Scope

    @Test func globalFiresEverywhere() {
        #expect(applyDictionaryRules([rule("hi", "HI")], to: "hi", for: target("com.apple.Mail")) == "HI")
        #expect(applyDictionaryRules([rule("hi", "HI")], to: "hi", for: target(nil)) == "HI")
    }

    @Test func appScopeExactCaseSensitive() {
        let scoped = rule("hi", "HI", scope: "com.apple.Mail")
        #expect(applyDictionaryRules([scoped], to: "hi", for: target("com.apple.Mail")) == "HI")
        #expect(applyDictionaryRules([scoped], to: "hi", for: target("com.apple.mail")) == "hi")
        #expect(applyDictionaryRules([scoped], to: "hi", for: target("com.other.App")) == "hi")
    }

    @Test func nilTargetFailsClosed() {
        let scoped = rule("hi", "HI", scope: "com.apple.Mail")
        #expect(applyDictionaryRules([scoped], to: "hi", for: target(nil)) == "hi")
    }

    @Test func appScopeBeatsGlobal() {
        let rules = [rule("hi", "GLOBAL"), rule("hi", "SCOPED", scope: "com.a.App")]
        #expect(applyDictionaryRules(rules, to: "hi", for: target("com.a.App")) == "SCOPED")
        #expect(applyDictionaryRules(rules, to: "hi", for: target("com.b.App")) == "GLOBAL")
    }

    // MARK: - Store validation

    private func makeStore() -> (DictionaryStore, LocalPersistence) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistence = LocalPersistence(directory: dir)
        return (DictionaryStore(persistence: persistence), persistence)
    }

    @Test func rejectsEmptyAndOversize() async {
        let (store, _) = makeStore()
        if case .failure(let error) = await store.add(spoken: "  ", replacement: "x", bundleID: nil) {
            #expect(error == .emptySpoken)
        } else { Issue.record("expected emptySpoken") }
        if case .failure(let error) = await store.add(spoken: "x", replacement: "  ", bundleID: nil) {
            #expect(error == .emptyReplacement)
        } else { Issue.record("expected emptyReplacement") }
        if case .failure(let error) = await store.add(spoken: String(repeating: "a", count: 81), replacement: "x", bundleID: nil) {
            #expect(error == .spokenTooLong)
        } else { Issue.record("expected spokenTooLong") }
        if case .failure(let error) = await store.add(spoken: "x", replacement: "y", bundleID: "  ") {
            #expect(error == .emptyBundleID)
        } else { Issue.record("expected emptyBundleID") }
    }

    @Test func rejectsDuplicateSameScope() async {
        let (store, _) = makeStore()
        _ = await store.add(spoken: "hi", replacement: "HI", bundleID: nil)
        let second = await store.add(spoken: "HI", replacement: "Hey", bundleID: nil)
        if case .failure(let error) = second {
            #expect(error == .duplicate(spoken: "HI", scope: "globally"))
        } else { Issue.record("expected duplicate") }
        // Same spoken, different scope: legal.
        let scoped = await store.add(spoken: "hi", replacement: "HI!", bundleID: "com.a.App")
        if case .failure = scoped { Issue.record("cross-scope must be legal") }
    }

    @Test func updateMissingIsNotFound() async {
        let (store, _) = makeStore()
        let ghost = DictionaryRule(spoken: "ghost", replacement: "x")
        let result = await store.update(ghost)
        if case .failure(let error) = result {
            #expect(error == .notFound)
        } else { Issue.record("expected notFound for deleted id") }
    }

    @Test func pipelineAppliesRulesWithScope() {
        let pipeline = TranscriptPipeline(dictionaryRules: [
            rule("teh", "the"),
            rule("hi", "SCOPED", scope: "com.a.App"),
        ])
        #expect(pipeline.process("fix teh now", for: target("com.b.App")) == "fix the now")
        #expect(pipeline.process("  hi  ", for: target("com.a.App")) == "SCOPED")
        #expect(pipeline.process("  hi  ", for: target("com.b.App")) == "hi")
        #expect(pipeline.process("   ", for: target()) == "")
    }

    @Test func importRoundTripWithReport() async {
        let (store, _) = makeStore()
        _ = await store.add(spoken: "one", replacement: "1", bundleID: nil)
        let payload = try! store.exportData(snapshot: store.rules)
        let (store2, _) = makeStore()
        let report = await store2.importData(payload)
        #expect(report.imported == 1)
        #expect(report.skippedDuplicates == 0)
        #expect(report.rejected.isEmpty)
        // Re-import: duplicate skipped, nothing duplicated.
        let report2 = await store2.importData(payload)
        #expect(report2.imported == 0)
        #expect(report2.skippedDuplicates == 1)
        #expect(store2.rules.count == 1)
        // Garbage rejected without touching the store.
        let bad = await store2.importData(Data("nope".utf8))
        #expect(bad.imported == 0)
        #expect(!bad.rejected.isEmpty)
        #expect(store2.rules.count == 1)
    }
}
