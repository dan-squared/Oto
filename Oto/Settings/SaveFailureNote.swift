//
//  SaveFailureNote.swift
//  Oto
//
//  One line for a failed local write. The in-memory edit is still visible;
//  this never claims the change is on disk.
//

import SwiftUI

struct SaveFailureNote: View {
    var body: some View {
        Label(
            "Changes couldn't be saved. Your edits are still here — try again or check available storage.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityIdentifier("saveFailure")
    }
}
