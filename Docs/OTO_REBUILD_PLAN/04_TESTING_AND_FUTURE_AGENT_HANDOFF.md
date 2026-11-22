# Testing, release evidence, and future-agent handoff

The rebuild is not complete when a unit test turns green. It is complete when the packaged app, permissions, shortcut path, audio path, target insertion, and recovery behavior have evidence at the right level.

## Test seams

Inject these boundaries rather than constructing system services in the coordinator:

```swift
protocol Clock {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

protocol PermissionChecking {
    func microphoneStatus() -> PermissionStatus
    func accessibilityStatus() -> Bool
    func speechAssetStatus(locale: Locale) async -> SpeechAssetStatus
}

protocol HotkeySource {
    var events: AsyncStream<ShortcutEvent> { get }
    func start(configuration: ShortcutConfiguration)
    func stop()
}

protocol HistoryStoring {
    func save(_ transcript: FinalTranscript) throws
    func recent(limit: Int) throws -> [FinalTranscript]
    func delete(id: UUID) throws
    func clearAll() throws
}
```

Fakes should be deterministic and free of `sleep`, AppKit windows, real pasteboards, real TCC, microphones, and network calls. Use a fake clock to test clipboard grace periods and cancel races instantly.

## Required automated cases

### Coordinator

- Idle → begin creates one session and captures target before showing UI.
- Duplicate key-down and key repeats do not create a second session.
- Key-up during preparation sets finish intent instead of cancelling.
- Finish and cancel arriving together resolve once; the late path is ignored.
- A late speech final from an old session cannot mutate the current session.
- Empty/filler-only text is not inserted or saved.
- Final text is saved only after a successful finalization, not for cancellation.

### Audio and SpeechAnalyzer

- Startup buffers preserve the first chunk until the engine attaches.
- Relay capacity is bounded and its overflow policy is observable in debug diagnostics.
- Cancel clears relay and engine tasks.
- Device configuration change rebuilds the engine and does not leave a stale tap.
- Unsupported locale and missing assets produce distinct errors.
- The shortcut path never calls asset installation.
- Partial results are never inserted or saved as final history.

### Shortcut and permissions

- Hold-to-talk: down → repeat → up produces begin → ignore → finish.
- Hands-free: down → up → down produces begin → ignore → finish.
- Lost key-up resets state safely.
- HID tap timeout is re-enabled or produces a repair state.
- Accessibility revocation stops claiming that global input is ready.
- Shortcut recorder cancellation leaves the previous configuration intact.
- Packaged app and raw executable are distinguished in diagnostics.

### Insertion and recovery

- App switch after key-down still inserts into the captured target.
- Target exits before finalization: no paste into the new app; recovery remains.
- System Events route, synthetic Command-V fallback, and clipboard-only outcome are each tested.
- Secure input prevents a false “inserted” result.
- A user copy during the grace period prevents clipboard restoration.
- A failed insertion leaves the final transcript available in Copy/Scratchpad.

### Storage

- Dictionary and snippet imports validate before committing.
- Version migration is atomic and recoverable.
- History deletion does not delete dictionary, snippets, or preferences.
- History is final-text-only, bounded, opt-in, and locally deletable.

## Device-only evidence

Keep this list separate from CI claims:

1. Packaged, signed build receives Microphone and Accessibility permission consistently.
2. Built-in keyboard F5/Dictation key works without opening macOS Dictation.
3. External keyboard function row and a modifier shortcut both work.
4. Safari, Messages, Slack, Electron, VS Code, Terminal, and secure fields show expected insertion/recovery.
5. Built-in microphone, Bluetooth microphone, unplug/replug, and sleep/wake recover.
6. Two displays place the Flow Bar on the captured target display.
7. Reduce Motion, VoiceOver, light/dark appearance, and larger text remain usable.
8. Repeated stop/cancel and rapid re-dictation do not crash or leak a panel/task.

## Release gate

Do not call the app release-ready until all of these are true:

- `Oto.app` has a stable bundle identifier and signed release identity.
- The app is launched as a packaged app, never as the raw SwiftPM executable for user testing.
- Microphone, speech assets, Accessibility, and Automation (if actually required) have clear recovery copy.
- No cloud speech or hidden download path exists.
- Every finalization path produces either inserted text or a recoverable local/clipboard result.
- The first release scope excludes unproven AI/model runtimes.
- The remaining manual/device work is written down rather than implied to be complete.

## Future-agent checklist

Before changing code:

1. Read `Docs/OTO_REBUILD_PLAN/README.md`, this file, the engineering playbook, and the relevant YAP audit section.
2. State the owner and invariant for the change.
3. Search for an existing coordinator, boundary, persistence format, or UI pattern before adding another.
4. Decide whether the work is backend, native UI, Flow Bar, storage, or device validation. Keep the change in one boundary.
5. Add a fake and a regression test before changing a lifecycle edge.

Before handoff, report:

- user-visible result;
- changed files;
- automated tests run and their scope;
- manual/device validation still required;
- unresolved risks, OS availability assumptions, and permission assumptions.

## Planned later phases

Only after Apple Speech parity and packaged-app QA:

1. Add a raw-transcript review surface for Apple Intelligence.
2. Add explicit Smart Mode selection and reversible drafts.
3. Add meeting summaries and voice commands with no external side effects.
4. Re-evaluate local model runtimes only if they preserve the same offline, resource, cancellation, and insertion contracts.

Those features must extend the existing protocols, not bypass the coordinator or add a second transcription workflow.

