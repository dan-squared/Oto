# ElevenLabs bar visualizer → native SwiftUI plan

## What we are referencing

The official ElevenLabs UI component is documented at [ui.elevenlabs.io/docs/components/bar-visualizer](https://ui.elevenlabs.io/docs/components/bar-visualizer), with source in [elevenlabs/ui](https://github.com/elevenlabs/ui). Its install command is:

```sh
pnpm dlx @elevenlabs/cli@latest components add bar-visualizer
```

That command generates a React/shadcn component. Oto is a native macOS SwiftUI app, so this component must not be added as a web view, Node dependency, or runtime asset. If a future agent needs to inspect the generated source, run it in a temporary web workspace and record the exact CLI/component revision. Do not install `@latest` into Oto’s Swift package.

The useful behavior to recreate is:

- real-time frequency-band bars from a microphone/audio stream;
- a configurable bar count (the reference defaults to 15);
- minimum and maximum height bounds;
- bottom or center alignment;
- explicit state animation for `connecting`, `initializing`, `listening`, `speaking`, and `thinking`;
- a demo/synthetic mode for previews and UI tests;
- smoothed updates around 30 FPS rather than one UI update per audio buffer.

## Oto state mapping

Do not copy the ElevenLabs names into product copy. Map them to Oto’s lifecycle:

| Reference state | Oto state | Rendering |
| --- | --- | --- |
| `connecting` | `.preparing` | Short low-amplitude sweep; no fake speech level. |
| `initializing` | `.preparing` | Stable low bars with a restrained progress movement. |
| `listening` | `.recording` | Live input bands, smoothed and bounded. |
| `speaking` | `.recording` or future playback | Higher live activity if a future playback source exists. |
| `thinking` | `.processing` | Deterministic traveling highlight; never imply audio is still being captured. |
| demo mode | Preview/test only | Seeded deterministic bars, never enabled in production recording. |

The Flow Bar must also support Oto-only `success`, `cancelled`, `failure`, and `permissionError` states. The visualizer is a renderer/projection of the coordinator's `FlowBarState`, not a second lifecycle state machine and not the source of truth for those states.

## Native architecture

Keep the realtime path and the visual path separate:

```text
AVAudioEngine tap
    -> bounded audio relay (no UI, no FFT, no await)
    -> AudioSpectrumAnalyzer on a dedicated task/actor
    -> coalesced 30 Hz level/band samples
    -> @MainActor FlowBarModel
    -> Canvas renderer
```

The input tap may copy a bounded audio buffer and signal the analyzer. It must not allocate an FFT object, publish an array to SwiftUI, or start one task per buffer. The analyzer owns format conversion and Accelerate/vDSP work off the realtime thread. A dropped visual sample is acceptable; a dropped final speech buffer is not.

## Suggested Swift contracts

```swift
enum OtoVisualizerState: Equatable, Sendable {
    case preparing
    case recording
    case processing
    case success
    case cancelled
    case failure
}

struct BarSample: Equatable, Sendable {
    let amplitudes: [Float] // normalized 0...1, fixed count
    let timestamp: ContinuousClock.Instant
}

protocol AudioSpectrumSampling: AnyObject {
    func start() async
    func stop()
    var samples: AsyncStream<BarSample> { get }
}
```

The analyzer should emit a fixed number of normalized bands. Keep the public visual model independent from `AVAudioPCMBuffer`, so previews and tests can provide deterministic samples.

## SwiftUI renderer shape

Use `Canvas` for the bars so a 15–24-bar visualizer remains one drawing pass rather than a tree of independently animated views:

```swift
struct BarVisualizer: View {
    let state: OtoVisualizerState
    let sample: BarSample?
    let barCount: Int
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let centerAlign: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let values = normalizedValues()
            let gap = max(2, size.width / CGFloat(barCount * 5))
            let width = max(2, (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount))

            for index in 0..<barCount {
                let value = values[index]
                let height = minHeight + (maxHeight - minHeight) * CGFloat(value)
                let x = CGFloat(index) * (width + gap)
                let y = centerAlign ? (size.height - height) / 2 : size.height - height
                let rect = CGRect(x: x, y: y, width: width, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(.primary)
                )
            }
        }
        .frame(minHeight: maxHeight)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private func normalizedValues() -> [Float] {
        if reduceMotion {
            return Array(repeating: sample?.amplitudes.max() ?? 0.15, count: barCount)
        }
        return Array((sample?.amplitudes ?? []).prefix(barCount))
            .padding(toCount: barCount, with: 0.12)
    }
}
```

The `padding(toCount:with:)` helper should be a small pure function covered by tests. Avoid per-bar `GeometryReader`, nested animations, or random values in the view body.

## Smoothing and motion

The web reference uses Web Audio analyser data and roughly 30 FPS updates. Native Oto should use equivalent behavior without pretending that every audio frame is a UI frame:

```swift
struct ExponentialSmoother: Sendable {
    var value: Float = 0
    let response: Float = 0.24

    mutating func update(_ next: Float) -> Float {
        value += (next - value) * response
        return value
    }
}
```

For each 30 Hz sample:

1. Calculate RMS or frequency bands off the audio callback with Accelerate.
2. Normalize and clamp to `0...1`.
3. Apply the same smoothing coefficient to each band.
4. Publish one immutable `BarSample` to the main actor.
5. Let `Canvas` redraw from the latest sample.

Do not use a perpetual timer owned by the view. The `FlowBarController` owns the sampling task and cancels it before the panel is dismissed. If a future implementation uses `TimelineView`, it must include repeated-dismissal tests proving no timer/task survives the panel.

## State animation rules

- **Preparing:** use a fixed, low-amplitude sweep. The sweep is bounded and stops on success/failure.
- **Recording:** audio controls amplitude; never add a large decorative pulse that hides silence.
- **Processing:** use a quiet traveling highlight. It must not be mistaken for active recording.
- **Success/cancelled:** use a short opacity or color transition, then dismiss.
- **Failure/permission:** hold a stable pattern and expose text/action recovery.
- **Reduced Motion:** freeze or cross-fade to stable bars. Keep state labels and contrast; remove sweeps, elastic movement, and continuous oscillation.

## Performance acceptance

- No audio callback performs UI work, FFT, logging, blocking, or unbounded allocation.
- At most one visual publication per 30 Hz interval.
- Bar count remains bounded and small; do not allocate a new view hierarchy per sample.
- Flow Bar dismissal cancels sampling and animation work before releasing its panel.
- Repeated start/stop/cancel does not leave tasks, observers, or a second renderer alive.
- Instruments checks show no main-thread audio processing and no growing queue.

## Visualizer tests

Use a deterministic `BarSample` stream:

```swift
@Test func reducedMotionUsesStableBars() {
    let sample = BarSample(
        amplitudes: [0, 0.2, 0.8, 0.1],
        timestamp: .now
    )
    let values = VisualizerMath.values(
        sample: sample,
        barCount: 8,
        reduceMotion: true
    )
    #expect(values.count == 8)
    #expect(values.dropFirst().allSatisfy { $0 == values[1] })
}
```

Also test: empty sample, short sample padding, values outside `0...1`, repeated cancellation, state-to-label mapping, accessibility labels, and no analyzer publication after `stop()`.
