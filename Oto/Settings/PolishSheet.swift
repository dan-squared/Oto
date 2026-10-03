//
//  PolishSheet.swift
//  Oto
//
//  Manual Clean up preview: streams the draft over the raw entry text.
//  Keep copies the polished draft to the clipboard (the entry keeps the
//  raw — polish never overwrites history). Use original / dismiss writes
//  nothing. Dismissing cancels the stream (`.task` dies with the sheet).
//

import AppKit
import SwiftUI

/// Clipboard write, injectable board so tests never touch `.general`.
func placePolishedOnClipboard(_ text: String, board: NSPasteboard = .general) {
    board.clearContents()
    board.setString(text, forType: .string)
}

struct PolishSheet: View {
    let entry: HistoryEntry
    let polish: any PolishServing
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var streaming = true
    @State private var failed = false

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
                    // Symmetric clipboard: Keep→polished, Original→raw, so
                    // paste always reflects the last decision (a previous
                    // Keep must not survive a change of mind).
                    placePolishedOnClipboard(entry.finalText)
                    dismiss()
                }
                OtoPill("Keep", filled: true) {
                    placePolishedOnClipboard(draft)
                    dismiss()
                }
                .disabled(draft.isEmpty)
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
}
