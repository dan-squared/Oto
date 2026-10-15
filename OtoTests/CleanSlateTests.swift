//
//  CleanSlateTests.swift
//  OtoTests
//
//  Phase 7e: the `-OtoCleanSlate` launch argument parses, and the wipe
//  removes an ephemeral domain + temp support dir without touching
//  production state.
//

import Foundation
import Testing
@testable import Oto

struct CleanSlateTests {
    @Test func parsesLaunchArgument() {
        #expect(CleanSlate.isRequested(arguments: ["Oto", "-OtoCleanSlate"]))
        #expect(!CleanSlate.isRequested(arguments: ["Oto"]))
        #expect(!CleanSlate.isRequested(arguments: ["Oto", "-otoCleanslate"]))
    }

    @Test func wipeIfRequestedNoOpsWithoutFlag() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        defaults.set("keep", forKey: "app.Oto.cleanupLevel")
        #expect(!CleanSlate.wipeIfRequested(arguments: ["Oto"], defaults: defaults))
        #expect(defaults.string(forKey: "app.Oto.cleanupLevel") == "keep")
    }

    @Test func wipeRemovesDomainAndSupportDir() throws {
        let suite = "test.oto.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("x", forKey: "seed")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "data".write(to: dir.appendingPathComponent("history.v1.json"), atomically: true, encoding: .utf8)
        CleanSlate.wipe(defaults: defaults, domain: suite, supportDir: dir)
        #expect(defaults.object(forKey: "seed") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func wipeRemovesSavedStateDir() throws {
        let suite = "test.oto.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // A temp support dir too: supportDir defaults to the production
        // Application Support path, which a test must never touch.
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try "state".write(to: stateDir.appendingPathComponent("window_1.data"), atomically: true, encoding: .utf8)
        CleanSlate.wipe(defaults: defaults, domain: suite, supportDir: supportDir, savedStateDir: stateDir)
        #expect(!FileManager.default.fileExists(atPath: stateDir.path))
    }
}
