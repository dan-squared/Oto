//
//  SnippetTriggerTests.swift
//  OtoTests
//
//  Opt-in exact-utterance voice trigger matching in TranscriptPipeline.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct SnippetTriggerTests {
    private func target(_ bundleID: String? = nil) -> TargetApplication {
        TargetApplication(bundleIdentifier: bundleID)
    }

    private func snippet(
        id: UUID = UUID(),
        name: String,
        expansion: String,
        bundleIDs: [String] = [],
        voiceTriggerEnabled: Bool = true
    ) -> Snippet {
        Snippet(
            id: id,
            name: name,
            expansion: expansion,
            bundleIDs: bundleIDs,
            voiceTriggerEnabled: voiceTriggerEnabled
        )
    }

    @Test func exactMatchExpandsVerbatim() {
        let pipeline = TranscriptPipeline(snippets: [
            snippet(name: "calendar link", expansion: "https://cal.example/alex?slot=30m"),
        ])
        let result = pipeline.processDetailed("calendar link", for: target())
        #expect(result == ProcessedTranscript(
            text: "https://cal.example/alex?slot=30m",
            matchedSnippet: true
        ))
    }

    @Test func caseInsensitiveAndTrailingPunctuationMatch() {
        let pipeline = TranscriptPipeline(snippets: [
            snippet(name: "Calendar Link", expansion: "https://cal.example/alex"),
        ])
        for utterance in ["Calendar Link.", "calendar link!", "  CALENDAR   LINK? ", "calendar link,;:\n"] {
            let result = pipeline.processDetailed(utterance, for: target())
            #expect(result.matchedSnippet == true)
            #expect(result.text == "https://cal.example/alex")
        }
    }

    @Test func embeddedPhraseInsideSentenceDoesNotExpand() {
        let pipeline = TranscriptPipeline(snippets: [
            snippet(name: "calendar link", expansion: "https://cal.example/alex"),
        ])
        let result = pipeline.processDetailed("send my calendar link please", for: target())
        #expect(result == ProcessedTranscript(
            text: "send my calendar link please",
            matchedSnippet: false
        ))
    }

    @Test func disabledVoiceTriggerNeverExpands() {
        let pipeline = TranscriptPipeline(snippets: [
            snippet(name: "calendar link", expansion: "https://cal.example/alex", voiceTriggerEnabled: false),
        ])
        let result = pipeline.processDetailed("calendar link", for: target())
        #expect(result == ProcessedTranscript(
            text: "calendar link",
            matchedSnippet: false
        ))
    }

    @Test func appScopedSnippetExpandsOnlyInScopedApp() {
        let pipeline = TranscriptPipeline(snippets: [
            snippet(
                name: "calendar link",
                expansion: "https://cal.example/mail",
                bundleIDs: ["com.apple.mail"]
            ),
        ])

        let inScopedApp = pipeline.processDetailed("calendar link", for: target("com.apple.mail"))
        #expect(inScopedApp == ProcessedTranscript(
            text: "https://cal.example/mail",
            matchedSnippet: true
        ))

        let inScopedHelper = pipeline.processDetailed("calendar link", for: target("com.apple.mail.compose"))
        #expect(inScopedHelper == ProcessedTranscript(
            text: "https://cal.example/mail",
            matchedSnippet: true
        ))

        let inOtherApp = pipeline.processDetailed("calendar link", for: target("com.tinyspeck.slackmacgap"))
        #expect(inOtherApp == ProcessedTranscript(
            text: "calendar link",
            matchedSnippet: false
        ))

        let inNilTarget = pipeline.processDetailed("calendar link", for: target(nil))
        #expect(inNilTarget == ProcessedTranscript(
            text: "calendar link",
            matchedSnippet: false
        ))
    }

    @Test func appScopedSnippetWinsOverGlobalOnSameNormalizedName() {
        let global = snippet(name: "calendar link", expansion: "GLOBAL_LINK")
        let scoped = snippet(
            name: "  Calendar   Link. ",
            expansion: "SCOPED_LINK",
            bundleIDs: ["com.apple.Notes"]
        )
        let pipeline = TranscriptPipeline(snippets: [global, scoped])

        let notesResult = pipeline.processDetailed("calendar link", for: target("com.apple.Notes"))
        #expect(notesResult == ProcessedTranscript(text: "SCOPED_LINK", matchedSnippet: true))

        let otherResult = pipeline.processDetailed("calendar link", for: target("com.apple.TextEdit"))
        #expect(otherResult == ProcessedTranscript(text: "GLOBAL_LINK", matchedSnippet: true))
    }

    @Test func dictionaryRulesApplyNormallyWhenNoSnippetMatches() {
        let pipeline = TranscriptPipeline(
            dictionaryRules: [DictionaryRule(spoken: "teh", replacement: "the")],
            snippets: [snippet(name: "calendar link", expansion: "https://cal.example/alex")]
        )
        let result = pipeline.processDetailed("  send teh calendar link please  ", for: target())
        #expect(result == ProcessedTranscript(
            text: "send the calendar link please",
            matchedSnippet: false
        ))
    }

    @Test func smartApostrophesAndUnicodeTrailingPunctuationMatch() {
        let pipeline = TranscriptPipeline(snippets: [
            snippet(name: "Dan's email", expansion: "dan@example.com"),
            snippet(name: "メール", expansion: "dan@example.jp"),
        ])

        let curly = pipeline.processDetailed("Dan\u{2019}s email…", for: target())
        #expect(curly == ProcessedTranscript(text: "dan@example.com", matchedSnippet: true))

        let cjk = pipeline.processDetailed("メール。", for: target())
        #expect(cjk == ProcessedTranscript(text: "dan@example.jp", matchedSnippet: true))
    }
}
