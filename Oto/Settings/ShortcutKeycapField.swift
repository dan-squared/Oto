//
//  ShortcutKeycapField.swift
//  Oto
//
//  Shared shortcut keycap field for onboarding and settings.
//

import SwiftUI

/// One slot's keycap-chip field: live-or-staged binding as chips, pencil to
/// re-record, trash to stage a clear. The combo recorder rides the field;
/// only one card records at a time (the other disables).
struct KeycapField: View {
    let chips: [String]
    let isRecording: Bool
    let disabled: Bool
    /// Shown when no binding is staged or saved (opt-in slot).
    let emptyPlaceholder: String
    /// Trash tooltip; differs when there is nothing to clear.
    let trashHelp: String
    let onArm: () -> Void
    let onTrash: () -> Void
    var recorder: ShortcutRecorderModifier

    var body: some View {
        OtoShortcutField(
            chips: chips,
            isRecording: isRecording,
            placeholder: emptyPlaceholder,
            clearHelp: trashHelp,
            canClear: !chips.isEmpty || isRecording,
            onRecord: onArm,
            onClear: onTrash
        )
        .disabled(disabled)
        .modifier(recorder)
    }
}
