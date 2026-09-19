# Current repository to rebuild map

The rebuild should be easy to review. Keep the current implementation intact while each replacement boundary is proven, then remove obsolete code only after the corresponding tests and packaged-app checks pass.

## Boundary map

| Current source | Rebuild destination | Action |
| --- | --- | --- |
| `Sources/Oto/Core/DictationSessionController.swift` | `Sources/Oto/Coordinator/DictationCoordinator.swift` | Split lifecycle ownership from UI-facing observations; keep one terminal owner. |
| `Sources/Oto/Core/AudioCaptureService.swift` | `Sources/Oto/Services/AudioCaptureService.swift` | Preserve fresh-engine recovery and move the realtime contract behind a protocol. |
| `Sources/Oto/Core/AudioChunkQueue.swift` | `Sources/Oto/Services/AudioBufferRelay.swift` | Use a small bounded startup relay with explicit overflow and cancellation reset. |
| `Sources/Oto/Core/TranscriptionEngine.swift` | `Sources/Oto/Services/TranscriptionService.swift` | Keep Apple SpeechAnalyzer only; expose prepare/start/feed/finish/cancel. |
| `Sources/Oto/Input/GlobalHotkeyMonitor.swift` | `Sources/Oto/Services/FunctionKeyMonitor.swift` | Retain the HID seam, but converge key-down/up into one transition state machine. |
| `Sources/Oto/Input/ShortcutBackend.swift` | `Sources/Oto/Services/ModifierHotkeyMonitor.swift` | Keep ordinary shortcuts separate from function-row HID events. |
| `Sources/Oto/Input/TextInsertionService.swift` | `Sources/Oto/Services/TextInjector.swift` | Make target capture, layered paste, and recovery outcomes explicit. |
| `Sources/Oto/Text/TranscriptPipeline.swift` | `Sources/Oto/Services/TranscriptPipeline.swift` | Keep deterministic cleanup separate from future AI drafts. |
| `Sources/Oto/UI/FlowBar.swift` | `Sources/Oto/UI/FlowBar/` | Keep the only custom visual surface, driven by coordinator state. |
| `Sources/Oto/UI/SettingsView.swift` | `Sources/Oto/UI/Settings/` | Rebuild from native Settings, NavigationSplitView/List/Form, and system controls. |
| `Sources/Oto/Core/Models.swift` | `Sources/Oto/Models/` | Split session, insertion, shortcut, and storage value types. |
| `Tests/OtoTests/` | `Tests/OtoTests/Coordinator`, `Services`, `UI` | Mirror boundaries and add fakes before device/UI tests. |

## Migration rules

1. Do not move files solely to make the tree look different. Move a boundary when it improves ownership or testability.
2. Do not make the new coordinator call the old controller. It should depend on protocols and small adapters.
3. Run old and new pure tests side by side while parity is being established.
4. Keep user data stores compatible or write an explicit migration. Never silently reset dictionary, snippets, or history.
5. Delete old code only when `rg` proves there are no references and the replacement has equivalent tests.

## Recommended implementation order

### Phase A — contracts and packaging

- Add the new folders and value types.
- Add protocols and fakes.
- Add a packaged `.app` build with a stable bundle identifier.
- Record the Settings scene contract without building a second window; native UI implementation belongs after the backend seams are testable.

### Phase B — backend parity

- Implement the coordinator state machine.
- Implement target capture before UI presentation.
- Implement bounded capture relay and analyzer-compatible conversion.
- Implement Apple Speech prepare/start/feed/finish/cancel.
- Implement function-row HID and ordinary shortcut backends.

### Phase C — safe output

- Implement dictionary cleanup and manual snippets.
- Implement layered insertion and clipboard ownership.
- Add local final-only history and recovery.
- Add interruption, device-change, permission, and target-liveness handling.

### Phase D — native UI and release proof

- Replace the settings shell with real native panes and controls.
- Drive the Flow Bar from the coordinator without autonomous work that can outlive dismissal.
- Test packaged TCC identity, launch-at-login, cross-app insertion, and sleep/wake on hardware.
- Remove obsolete code only after parity and release checks pass.

## Non-goals during the rebuild

- local model catalogs or model downloads;
- cloud transcription;
- Qwen, Nemotron, Cohere, or other unproven runtimes;
- automatic AI rewriting;
- custom title bars or traffic lights;
- a second recording coordinator;
- a new global font installation or runtime font download.
