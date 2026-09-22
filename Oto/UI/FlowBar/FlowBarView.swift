//
//  FlowBarView.swift
//  Oto
//
//  Slice 6B: the pill's SwiftUI content. Width is OWNED by the AppKit panel
//  (arrives as a parameter; no SwiftUI width animation — the frame animator
//  below is the single width-motion owner). Content crossfades on state
//  change; the panel resizes underneath it. No text anywhere except failure
//  copy and transient notices (the pill carries state by shape + motion).
//

import SwiftUI

/// Button-free by design (2026-09-22): every intent stays reachable
/// without pill chrome — hold-to-talk ends on key-up, hands-free toggles
/// on second shortcut press, cancel rides the shortcut monitor's Escape.
/// The pill shows state only; failure recovery lives in the menu + modal.
struct FlowBarView: View {
    let model: FlowBarModel
    /// Current panel width (controller-driven, matches the frame).
    let width: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VisualizerMath.pillHeight / 2)
                .fill(Color(red: 0.055, green: 0.055, blue: 0.065))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
            content
                .padding(.horizontal, 16)
        }
        .frame(width: width, height: VisualizerMath.pillHeight)
    }

    @ViewBuilder
    private var content: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        } else {
            switch model.projection.state {
            case .hidden:
                Color.clear
            case .preparing:
                BarVisualizer(mode: .dots, values: [], tick: model.sample.tick, handsFree: false)
                    .transition(.opacity)
            case .recording:
                BarVisualizer(
                    mode: .bars, values: model.sample.values,
                    tick: model.sample.tick,
                    handsFree: model.projection.handsFreeCaption
                )
                .transition(.opacity)
            case .finalizing, .inserting:
                BarVisualizer(mode: .dotsSpinner, values: [], tick: model.sample.tick, handsFree: false)
                    .transition(.opacity)
            case .successFlash, .cancelledFlash:
                BarVisualizer(mode: .flash, values: [], tick: model.sample.tick, handsFree: false)
                    .transition(.opacity)
            case .failure:
                failureRow
                    .transition(.opacity)
            }
        }
    }

    private var failureRow: some View {
        HStack(spacing: 10) {
            BarVisualizer(mode: .failureDot, values: [], tick: model.sample.tick, handsFree: false)
                .frame(width: 26)
            Text(model.projection.message ?? "Something went wrong.")
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
