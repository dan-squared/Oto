//
//  KeyNamesTests.swift
//  OtoTests
//
//  Human key names + keycap chips: table spot-checks, glyph order,
//  dictation-set label, unknown-code fallback. Pure, no hardware.
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

@MainActor
struct KeyNamesTests {
    @Test func lettersDigitsAndNamedKeys() {
        #expect(KeyNames.keyName(for: UInt32(kVK_ANSI_D)) == "D")
        #expect(KeyNames.keyName(for: UInt32(kVK_ANSI_0)) == "0")
        #expect(KeyNames.keyName(for: UInt32(kVK_Space)) == "Space")
        #expect(KeyNames.keyName(for: UInt32(kVK_Delete)) == "Delete")
        #expect(KeyNames.keyName(for: UInt32(kVK_Escape)) == "Escape")
        #expect(KeyNames.keyName(for: UInt32(kVK_F5)) == "F5")
        #expect(KeyNames.keyName(for: UInt32(kVK_Function)) == "fn")
        #expect(KeyNames.keyName(for: UInt32(kVK_LeftArrow)) == "←")
    }

    @Test func unknownCodeFallsBackToRawNumber() {
        #expect(KeyNames.keyName(for: 999) == "key 999")
    }

    @Test func modifierGlyphsFollowReferenceOrder() {
        let all = UInt32(CarbonModifiers.control | CarbonModifiers.option | CarbonModifiers.shift | CarbonModifiers.command)
        #expect(KeyNames.modifierGlyphs(all) == ["⌃", "⌥", "⇧", "⌘"])
        #expect(KeyNames.modifierGlyphs(0) == [])
    }

    @Test func chipsForEachKind() {
        #expect(KeyNames.chips(for: .modifierHold(keyCode: UInt16(kVK_RightOption))) == ["⌥"])
        #expect(KeyNames.chips(for: .functionKey(codes: [Int64(kVK_F5), 176])) == ["Dictation key"])
        #expect(KeyNames.chips(for: .combo(
            modifiers: UInt32(CarbonModifiers.command | CarbonModifiers.shift),
            keyCode: UInt32(kVK_ANSI_D)
        )) == ["⇧", "⌘", "D"])
    }

    @Test func shortLabelsForSentences() {
        #expect(KeyNames.shortLabel(for: .modifierHold(keyCode: UInt16(kVK_RightOption))) == "⌥")
        #expect(KeyNames.shortLabel(for: .functionKey(codes: [Int64(kVK_F5), 176])) == "the Dictation key")
        #expect(KeyNames.shortLabel(for: .combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_V)
        )) == "⌘V")
    }

    @Test func factoryDefaultsRenderHuman() {
        #expect(KeyNames.shortLabel(for: DualShortcutConfiguration.default().hold.kind) == "⌥")
    }

    @Test func holdOptionsCoverEveryModifierSided() {
        #expect(KeyNames.holdOptions.count == 9)
        #expect(KeyNames.holdMenuLabel(for: .modifierHold(keyCode: UInt16(kVK_RightOption))) == "Right Option")
        #expect(KeyNames.holdMenuLabel(for: .modifierHold(keyCode: UInt16(kVK_Control))) == "Left Control")
        #expect(KeyNames.holdMenuLabel(for: .modifierHold(keyCode: UInt16(kVK_Function))) == "fn")
        #expect(KeyNames.holdMenuLabel(for: .combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_D)
        )) == "Hold key")
    }
}
