//
//  DemoDriverTests.swift
//  OtoTests
//
//  The video probe's scripted transcripts are pure and pinned here. No screen
//  recording, TCC, or app launch in the test suite.
//

import Testing
@testable import Oto

@MainActor
struct DemoDriverTests {
    @Test func everyModeHasAnHonestScript() {
        #expect(DemoDriver.script(for: .hold) == "Send this to Daniel tomorrow.")
        #expect(DemoDriver.script(for: .handsFree) == "This is hands-free.")
        #expect(DemoDriver.script(for: .catcher) == "Remember to buy oat milk tomorrow.")
        #expect(DemoDriver.script(for: .dictionary) == "oh my god that was fast")
        #expect(DemoDriver.script(for: .cleanup).contains("Um, like"))
    }
}
