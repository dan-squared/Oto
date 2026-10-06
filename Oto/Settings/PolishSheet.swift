//
//  PolishSheet.swift
//  Oto
//
//  Manual Clean up preview: streams the draft over the raw entry text.
//  Keep copies the polished draft to the clipboard, Use original copies
//  the raw entry (the entry itself keeps its text either way — polish
//  never overwrites history). Foreign clipboard content confirms before
//  either write. Dismissing cancels the stream (`.task` dies with the sheet).
//

import AppKit
import SwiftUI

/// Clipboard write, injectable board so tests never touch `.general`.
/// Marks the placement (overwrite guard: a later manual Oto write skips
/// its confirm; a user copy clears the marker and re-arms it).
func placePolishedOnClipboard(_ text: String, board: NSPasteboard = .general) {
    board.clearContents()
    board.setString(text, forType: .string)
    ClipboardOverwriteGuard.markAsOto(board)
}

struct PolishSheet: View {
    let entry: HistoryEntry
    let polish: any PolishServing
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var streaming = true
    @State private var failed = false
    @State private var confirmOverwrite = false
    @State private var pendingWrite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Original")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                Text(entry.finalText)
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.muted)
                    .lineLimit(4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleaned up")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                if failed {
                    Text("Couldn't clean this one up — the original above is untouched.")
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.unsafe)
                } else {
                    Text(streaming && draft.isEmpty ? "Cleaning…" : draft)
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.ink)
                    if !streaming, let stats = polish.lastRunStats() {
                        Text(polishTimingCaption(stats: stats))
                            .font(.system(size: 11.5))
                            .foregroundStyle(OtoPalette.muted)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                OtoPill("Use original", filled: false) {
                    requestClipboardWrite(entry.finalText)
                }
                OtoPill("Keep", filled: true) {
                    requestClipboardWrite(draft)
                }
                .disabled(draft.isEmpty)
            }
            .confirmationDialog(
                "Replace clipboard contents?",
                isPresented: $confirmOverwrite,
                titleVisibility: .visible
            ) {
                // Symmetric clipboard: Keep→polished, Original→raw, so
                // paste always reflects the last decision (a previous
                // Keep must not survive a change of mind).
                Button("Replace") {
                    placePolishedOnClipboard(pendingWrite)
                    pendingWrite = ""
                    dismiss()
                }
                Button("Cancel", role: .cancel) { pendingWrite = "" }
            } message: {
                Text("The clipboard holds text Oto didn't place.")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .task {
            var got = false
            for await snapshot in polish.streamCleanup(entry.finalText, job: .cleanup(.light)) {
                draft = snapshot
                got = true
            }
            failed = !got
            streaming = false
        }
    }

    /// Clipboard write with overwrite guard (clipboard discipline):
    /// foreign content arms the confirm dialog INSTEAD of dismissing (the
    /// dialog lives in this sheet — dismissing first would kill it).
    /// Empty/Oto boards write + dismiss immediately, as before.
    private func requestClipboardWrite(_ text: String) {
        if ClipboardOverwriteGuard.shouldConfirm(board: .general) {
            pendingWrite = text
            confirmOverwrite = true
        } else {
            placePolishedOnClipboard(text)
            dismiss()
        }
    }
}
