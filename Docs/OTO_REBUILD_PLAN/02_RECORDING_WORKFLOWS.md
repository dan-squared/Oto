# Recording workflows and failure-safe state

This is the behavioral contract for the rebuilt backend. UI labels may change later, but these transitions and recovery guarantees must not.

## Session timeline

```text
idle
  └─ keyDown/toggle ─> preparing
       ├─ permission/asset failure ─> failed(recoverable)
       ├─ cancel ─> cancelled
       └─ analyzer ready ─> recording
            ├─ key repeat ─> recording (ignored)
            ├─ keyUp/stop ─> finalizing
            ├─ Escape/cancel ─> cancelled
            ├─ audio/device failure ─> failed(recoverable)
            └─ app shutdown ─> cancelled

finalizing
  ├─ empty text ─> completed(no insertion)
  ├─ final text ─> inserting
  │    ├─ target accepted ─> completed
  │    └─ target/permission failure ─> completed(recovery available)
  └─ cancellation wins ─> cancelled
```

Only the coordinator may move between these states. The Flow Bar, shortcut monitor, audio service, speech engine, and permission service emit events; they never call insertion or history directly.

## Session context

The context is immutable for the lifetime of a recording:

```swift
struct SessionContext: Sendable, Equatable {
    let id: UUID
    let startedAt: ContinuousClock.Instant
    let target: TargetApplication
    let targetScreen: CGDirectDisplayID?
    let interaction: InteractionMode
}

struct TargetApplication: Sendable, Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let windowIdentifier: String?
}
```

Capture this before showing the Flow Bar, opening a scratchpad, or changing activation. At finalization, verify that the process is still alive. If it is gone, keep the transcript in recovery and never substitute the current frontmost app.

## Hold-to-talk

1. First non-repeat key-down creates a session context and begins capture.
2. Repeat key-down events are ignored.
3. Matching key-up requests finish for that session.
4. If key-up arrives while the analyzer is preparing, set `finishRequested`; do not cancel.
5. If the monitor loses the key-up, a monitor timeout or app deactivation resets the local key state. The coordinator still owns whether the session is finished or cancelled.

## Hands-free

1. First non-repeat key-down starts.
2. Key-up and repeats do nothing.
3. Second non-repeat key-down requests finish.
4. Escape and the Flow Bar cancel action always cancel.
5. Voice activity may request finish only after speech has started and a minimum recording window has elapsed.

Hands-free is opt-in. Silence detection must not become an implicit cancellation path, and it must use the same finalization and insertion pipeline as hold-to-talk.

## Finish and cancel rules

Finish and cancel are mutually exclusive and idempotent:

```swift
func finish(sessionID: UUID, reason: FinishReason) async {
    guard let context = sessionContext,
          context.id == sessionID,
          currentSessionID == sessionID else { return }
    guard state.canFinish else { return }

    state = .finalizing(context)
    await audio.stop()
    let finalText = await engine.finish()

    guard currentSessionID == sessionID,
          case .finalizing = state else { return }

    let cleanText = pipeline.process(finalText, target: context.target)
    guard !cleanText.isEmpty else {
        state = .completed(context)
        return
    }
    state = .inserting(context, cleanText)
    let result = await inserter.insert(cleanText, into: context)
    record(result, text: cleanText, context: context)
}

func cancel(sessionID: UUID, reason: CancelReason) async {
    guard let context = sessionContext,
          context.id == sessionID,
          currentSessionID == sessionID else { return }
    currentSessionID = nil       // invalidate before teardown
    state = .cancelled(context)
    await audio.cancel()
    await engine.cancel()
    relay.reset()
}
```

The actual implementation must not hold a lock across `await`, must re-check session identity after every suspension, and must await owned cleanup tasks before starting another engine.

## Apple Speech workflow

The runtime is offline only after explicit preparation:

```text
Settings → Prepare Apple Speech assets → system installs assets
                                      ↓
Shortcut → inspect readiness only
         → missing assets → specific recovery state, no download
         → ready          → capture + SpeechAnalyzer
```

Use `SpeechAnalyzer`/`SpeechTranscriber` and the analyzer-compatible audio format. Do not use a legacy speech API as a hidden fallback. Volatile results may be shown in the Flow Bar or Scratchpad, but only finalized text can be inserted or saved.

## Recovery outcomes

| Failure | Visible result | Recovery |
| --- | --- | --- |
| Microphone denied | “Microphone access is needed.” | Open the exact Privacy setting; refresh on return. |
| Accessibility denied | Text may be recognized but not inserted. | Copy, Scratchpad, and Open Accessibility Settings. |
| Speech assets missing | “Prepare offline speech in Settings.” | Open Settings; never download from a key press. |
| Unsupported locale | “This language is unavailable offline.” | Choose a supported locale; do not fall back to cloud. |
| Input device changes | Recording stops or restarts safely. | Rebuild the audio engine and expose the selected device. |
| Target app exits | Final text is retained for recovery. | Copy/Scratchpad; never paste into the new frontmost app. |
| Secure input | Text remains local/clipboard-only. | Explain that the focused field blocks synthetic insertion. |
| User cancels | No insertion and no history entry. | Return to idle. |

## Flow Bar contract

The Flow Bar is the only custom visual surface. It must expose stable states:

```swift
enum FlowBarState: Equatable {
    case idle
    case preparing
    case recording(level: Double, partial: String?)
    case processing
    case success
    case cancelled
    case failure(message: String, recovery: RecoveryAction?)
}
```

Every state needs a text label, an accessibility label, a keyboard path, and a Reduced Motion rendering. Animation is decorative; recording/processing/cancel must remain understandable when motion is disabled. The panel must stop timers/tasks before dismissal and tolerate repeated stop/cancel presses.
