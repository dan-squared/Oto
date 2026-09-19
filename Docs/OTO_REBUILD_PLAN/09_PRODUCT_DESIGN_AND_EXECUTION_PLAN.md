# Oto — Product design, native macOS, and execution plan

> **Rebuild edition:** This copy is the active product contract for the from-scratch Apple Speech/YAP-inspired implementation. Read [`README.md`](README.md) before using it; deferred AI/model work is not release scope.

> **Read this first.** This is the execution document for Oto. It turns the technical strategy in [07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md](07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md) into product flows, design decisions, repository boundaries, bug priorities, and phased work.
>
> **Current handoff:** [10_NEXT_STEP.md](10_NEXT_STEP.md) is the ordered rebuild milestone and release gate. Read it before starting implementation work.
>
> **Product thesis:** Oto is the quiet, dependable layer between a person's voice and the text field they are already using. Apple Speech makes the words; Oto makes the experience trustworthy, useful, and personal.
>
> **Non-negotiables:** fully offline after Apple Speech setup; Apple Speech-first; no cloud speech, Private Cloud Compute, or silent downloads; no text inserted into the wrong app; no custom imitation of standard macOS Settings controls; native system typography and controls for macOS-owned chrome, with Oto-authored text following the pinned-font policy in the engineering playbook.

> **Rebuild track:** The project is now planned as a controlled from-scratch backend rebuild inspired by the local Yap audit. Read [`README.md`](README.md) before implementation. The current source is reference material until the replacement reaches parity; do not mix old UI migration work into the backend rebuild.

> **Scope clarification:** Sections that discuss local model runtimes, model catalogs, Apple Intelligence, or advanced smart writing are future phases. They are not part of the first Apple Speech-only rebuild and must not add a second recording path or a network dependency.

> **Resolved platform decision:** v1 targets macOS 26 or later on Apple silicon. The current macOS 14 package setting is historical scaffolding and must be raised before the rebuild is called supported. Intel Macs and earlier macOS versions are outside the v1 offline SpeechAnalyzer release claim unless a separate compatibility decision and device evidence are added.

> **Historical-audit warning:** Section 2 describes the pre-rebuild source. “Reference” and “observed” findings describe that old implementation; they are not proof that the rebuild is complete.

## 0. The decisions every contributor must know

### What Oto is

- A **menu-bar-first macOS dictation utility** for capable Macs.
- Apple Speech is the transcription backbone.
- Apple's on-device `SystemLanguageModel` is a post-v1, optional intelligence layer after a transcript is final.
- The v1 app works without a network after Apple Speech assets are ready. Future intelligence has its own availability gate and must never be required for dictation.
- The primary interaction is one shortcut: hold to talk, release to insert.

### What Oto is not

- Not a model library, local-model downloader, cloud transcription product, team workspace, or general-purpose automation agent.
- Not an app that reads the active document, email, Slack channel, clipboard, contacts, or browser page just because it can identify the foreground app.
- Not a custom design system pretending to be macOS. The Flow Bar is the only intentionally custom UI surface because it has no system equivalent.

### Implementation order is deliberate

Do the phases in this document in order. Do not start Apple Intelligence polish, long-form meeting features, or visual embellishment while a person can still lose a transcript, trigger two sessions, open broken Settings, or paste into the wrong app.

### The one exception to native UI

The floating Flow Bar remains custom because macOS has no standard component for a global dictation recording state. It must stay small, accessible, and functional. Settings, lists, forms, tabs, buttons, pickers, sidebars, window controls, and file dialogs should be system-provided SwiftUI/AppKit components.

## 1. Product design principles

1. **The active app remains the workspace.** Oto never makes a person leave Mail, Slack, Xcode, Notes, or a browser merely to dictate.
2. **Recognition and transformation are separate.** Speech creates a raw, final transcript. Dictionary rules apply deterministically. Any intelligence result is a separate reversible draft.
3. **A fast raw result beats a slow clever result.** Normal dictation inserts final raw text as soon as it is ready. Formatting/rewrite is optional and visibly in progress.
4. **Automation earns trust through reversibility.** Insert Original, Copy, Scratchpad, Cancel, and Undo are product requirements, not edge cases.
5. **Privacy is a behavior, not a label.** Oto passes only the minimum context to on-device intelligence, does not retain audio, and makes history/context opt-in.
6. **Use familiar macOS patterns.** Standard title bar, standard traffic lights, native sidebar selection, native Form alignment, native file dialogs, native menus, native controls, and system-owned typography. Oto-authored text follows the pinned-font policy without changing AppKit-owned chrome. The Flow Bar is the only intentional custom visual surface.
7. **Settings are for durable preferences.** A person should not need to open Settings during everyday dictation. Permissions and readiness get a direct recovery route when a failure occurs.
8. **Use restrained visual feedback.** The Flow Bar answers “is Oto listening, working, done, or blocked?” It does not become a second application.

Apple’s settings guidance says a macOS settings window should remain stable and reveal the active area; its sidebar guidance recommends concise labels, system symbols, native selection behavior, and no critical actions at the bottom. [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings) and [Sidebars HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars)

## 2. Current product audit

### 2.1 Confirmed UI and architecture problems

These findings come from the current source. They are not aesthetic preferences; each creates a product, reliability, or maintainability cost.

| Priority | Finding | Evidence in current project | Product impact | Correct decision |
| --- | --- | --- | --- | --- |
| P0 | Settings is a custom `NSWindow` rather than an app `Settings` scene. | `OtoSettingsWindowController` creates/retains an `NSWindow`. | Earlier “Open Settings” failures are harder to diagnose; Command-Comma and standard settings lifecycle are bypassed. | Replace it with a SwiftUI `Settings` scene and `SettingsLink`. |
| P0 | The traffic lights are visually detached by custom window configuration, not by a custom traffic-light drawing. | `window.titlebarAppearsTransparent = true` plus a manually hosted fixed canvas. | The top of the window reads as a separate floating layer. | Delete this controller and transparent-titlebar customization. Use the normal title bar. |
| P0 | Settings has a fixed visual canvas. | `SettingsView` forces `980 × 680`; the controller separately sets sizes. | Resize behavior is misleading; content can look like a web panel in a native window. | Let a `Settings` scene own the window; use a default size and content minimum, not a fixed root frame. |
| P1 | Settings recreates a bespoke sidebar, cards, rows, separators, hover behavior, and button styles. | `SettingsSidebar`, `SettingsCard`, `SettingsRow`, `OtoFilledButtonStyle`, `OtoQuietButtonStyle`, `OtoTheme`. | Extra code to maintain, inconsistent focus/selection behavior, and the bespoke look the product is rejecting. | Replace with `NavigationSplitView`, `List(selection:)`, `Form`, `Section`, standard `Toggle`, `Picker`, `Button`, `ContentUnavailableView`, and confirmation dialogs. |
| P1 | The app previously bundled a custom font and applied typography indiscriminately. | Historical `OtoTypography.swift`/font resource. | Global font overrides make native layout and accessibility harder to reason about. | Use the system font and native control metrics for the rebuild; revisit branding only after parity. |
| P1 | Headers and symbols are too large for a preference window. | 38-point page title, 30-point icon, 23-point row icons. | Settings looks like a marketing page and consumes attention needed for controls. | No page hero. Use native navigation title, 14-point body/row labels, captions only for explanations, and normal SF Symbol sizing. |
| P1 | App-scoped dictionary and snippet rules cannot reliably apply to the target app. | **Reference implementation:** the old session captured the target bundle identifier before Flow Bar presentation and passed it through final processing. | A person can create an app-specific rule that silently never fires. | Recreate the behavior in the rebuild and add device coverage for app switching. |
| P1 | Clipboard restoration uses a fixed short delay. | **Reference implementation:** the old insertion path wrote a marker, recorded the change count, and restored only if both still matched after a cancellable grace period. | It may restore too early for a slow target or overwrite a clipboard copy the person made immediately afterward. | Recreate ownership-aware restoration and leave text on the clipboard when no route can be dispatched. |
| P1 | Flow Bar placement ignores the original target screen. | It uses `NSScreen.main`. | On multi-display workspaces, feedback may appear on the wrong display. | Position relative to the target app’s screen or current mouse screen, then preserve that screen through the session. |
| P1 | Capture work makes a main-actor task for every input buffer. | **Reference implementation:** the old tap copied into a bounded lock-protected relay and scheduled at most one main-queue drain. | Under a busy UI this can create scheduling pressure and queue lag. | Recreate the bounded relay and profile overflow on real hardware. |
| P2 | Audio-device changes are not observed automatically. | **Reference implementation:** the old code used `AVAudioEngineConfigurationChangeNotification` to trigger a fresh-engine restart while preserving the session. | Disconnecting a mic can leave an unclear failed or stale state. | Recreate the boundary and validate disconnect, Bluetooth format changes, and default-device changes on hardware. |
| P2 | Deployment messaging is inconsistent with product scope. | The historical package declares macOS 14 while the v1 SpeechAnalyzer plan targets macOS 26+. | Users can build/install a shell that cannot dictate. | Set the package, availability checks, docs, and QA baseline to macOS 26+ on Apple silicon before implementation begins. |
| P2 | Settings data and service concerns live together. | One large `SettingsView.swift` contains layout, input forms, dialogs, panels, styles, and feature behavior. | Changes become risky and agents conflict in the same file. | Split by feature and keep each view a native, shallow composition. |
| P2 | Test coverage is concentrated in one XCTest file and mostly pure logic. | `Tests/OtoTests/TranscriptPipelineTests.swift`. | UI/window, session ownership, target identity, and cross-app behavior lack test seams. | Mirror product modules in tests, add fake services, then add packaged-app UI/manual tests. |

### 2.2 Known past failures that must remain visible

- The Flow Bar previously crashed while stopping because an animated `TimelineView` could outlive a disappearing panel. The current implementation avoids that specific renderer. Do not reintroduce timeline-driven animation without a dedicated repeated-dismissal stress test.
- Settings opening has already been unreliable in practice. Treat native Settings-scene migration as a functional reliability fix, not a cosmetic refactor.
- Apple Speech asset setup has produced confusing “assets are not installed” messages. The app must distinguish unsupported language, download in progress, asset not prepared, microphone denial, and Accessibility denial.
- The function-key shortcut has been unreliable across keyboard variants and system Dictation interception. It needs device validation; changing the appearance of Settings does not prove it works.
- Stopping/cancelling dictation has already exposed lifecycle races. Never casually “simplify” teardown code without preserving serialized finish/cancel ownership.

### 2.3 Product mistakes to avoid

- Do not hide incomplete capabilities behind polished controls. An intelligence control must show unavailable state instead of doing nothing.
- Do not use a colored score, confidence percentage, or “AI is thinking” flourish where a direct state label is clearer.
- Do not auto-select email/message/code mode purely from a model guess. App identity and user preference can suggest; the person chooses or can immediately restore raw text.
- Do not make a finished transcript disappear while a rewrite generates. Raw text is the safety net.
- Do not treat a target app’s visible content as “context” without explicit feature-level consent.
- Do not put support-critical actions at the bottom of a sidebar, where macOS users may never see them.
- Do not create custom pickers, switches, text fields, dropdowns, confirmation UI, or traffic lights to approximate native controls.
- Do not add a large empty hero area, oversized serif type, marketing copy, decorative cards, or unrelated icons to Settings.
- Do not build a folder architecture that is more elaborate than the app. Clear ownership beats “enterprise” ceremony.

## 3. The complete product flow map

### 3.1 First launch and readiness

**Goal:** get a person to one successful offline dictation with minimal permission surprise.

```text
Launch menu-bar utility
    ↓
Status says “Set up Oto” only if a requirement is missing
    ↓
Open Settings → Dictation
    ↓
Check: microphone → Accessibility → Apple Speech language assets → shortcut
    ↓
Use a safe in-app test field
    ↓
Successful result → “Ready” state
```

Rules:

- Do not show a mandatory full-window onboarding wizard.
- Ask for microphone access when the person tests dictation or starts it, not on launch.
- Explain Accessibility in plain language: it lets Oto hear the chosen shortcut everywhere and paste final text into the current app.
- The “Prepare offline” action is explicit. It starts Apple-managed asset setup but never runs from a dictation shortcut.
- The test field confirms recognition, finalization, and insertion independently. It is the fastest way to distinguish setup failure from target-app incompatibility.
- When all checks pass, Settings should become quiet: no persistent completion banners or upsell content.

#### Shortcut calibration belongs in onboarding

The shortcut selector is not a decorative preference. It must prove that the exact physical gesture reaches Oto before Oto claims to be ready.

1. Ask the person to choose an interaction: **Hold to talk** (press and hold; release to finish) or **Hands-free** (press once to start; press again to finish). “Release” is the end gesture of hold-to-talk, not a third interaction mode.
2. Record a real key-down and key-up sequence, including modifiers and the hardware key code. Reject modifier-only input, an unmodified printable letter, and a shortcut reserved by Oto or macOS.
3. Register the candidate through Oto’s actual global-hotkey route—not merely the recorder view—and ask the person to press it once in a safe in-app test area.
4. Report an unambiguous result: **Ready**, **Conflicts with another shortcut**, **Not received globally**, or **Requires Accessibility**. Never mark a shortcut ready solely because it was saved.
5. Store distinct `holdToTalkShortcut` and `handsFreeShortcut` preferences. The active interaction registers one at a time. The same key may be configured for both only because the inactive mode is not registered.
6. Treat F5 and the hardware Dictation key as device-dependent aliases. Capture and test their actual key code. Offer a safe suggested fallback such as Option-Command-Space rather than guessing that F5 will work everywhere.
7. Every test must exercise down, held-repeat suppression, up, cancellation, and a second rapid attempt. The test field must show whether capture, finalization, and insertion each succeeded.

### 3.2 Everyday hold-to-talk dictation

**Goal:** one physical gesture produces one final insertion.

```text
Press configured key
  → capture original target app + screen + bundle ID
  → start audio + show Recording Flow Bar
  → display partial text only inside Oto if needed
Release key
  → stop audio, finalize Apple Speech
  → run dictionary and explicit snippet rules
  → insert final text once into captured target
  → brief success feedback, then disappear
```

Success criteria:

- Press feedback appears immediately; it does not wait for a partial transcript.
- Repeated key-down events never start another session.
- Partial text is never inserted externally and never saved in history.
- Release is respected even if the person switches apps while speaking.
- The captured original app, not the current frontmost app, receives the insertion.
- If insertion cannot happen, the text remains recoverable through Copy and Scratchpad.

### 3.3 Hands-free dictation

**Goal:** make longer thoughts convenient without accidental recordings.

```text
Tap shortcut → recording begins
Tap shortcut again → finish
or, only if enabled, sustained silence → finish
```

Rules:

- Hands-free is a deliberate preference, never the default.
- Auto-stop never runs before meaningful speech begins.
- The Flow Bar always exposes Stop/Cancel while recording.
- Silence detection may end capture, but only finalization/insertion occurs after the same checks as hold-to-talk.
- For an unanswered auto-stop, keep the final transcript recoverable; do not assume it was wanted just because it was recognized.

### 3.4 Cancel, error, and recovery

| Situation | Oto must do | Oto must never do |
| --- | --- | --- |
| Escape/Flow Bar cancel | Stop audio, discard partials, show brief Cancelled state, return to ready. | Insert or save anything. |
| Mic permission missing | Explain it is needed; one action opens the exact system setting. | Loop prompts or display generic “unavailable.” |
| Accessibility missing | Recognition may complete; present Copy, Scratchpad, and Open Accessibility Settings. | Claim text was inserted. |
| Speech assets missing | State “Prepare offline in Oto Settings.” | Download in the background when the shortcut is pressed. |
| Original app closed | Preserve final text in a local transient recovery object. | Paste into whichever app is now frontmost. |
| Device disconnects | Stop safely, identify the input problem, refresh devices. | Leave the Flow Bar listening or retain a broken audio tap. |
| Model/rewrite unavailable | Offer raw final text. | Block ordinary dictation. |

### 3.5 Personal dictionary

**Goal:** solve recurring recognition and casing problems once, transparently.

The user flow:

1. Choose Dictionary in Settings.
2. Add spoken form, exact replacement, and optional app scope.
3. Test the rule with a sample sentence before saving.
4. See it in a native list with enabled state and edit/delete actions.
5. Import/export rules with standard file panels.

Critical rules:

- Save only an exact person-authored replacement; no model-generated replacement value.
- Explain whether the rule applies everywhere or only to a selected app.
- Use the actual captured app bundle identifier when processing a transcript.
- Protect URLs, email addresses, and paths from replacement.
- Show duplicate/conflict feedback before a person thinks a rule has been saved.

### 3.6 Snippets

**Goal:** insert repeated text safely.

Release flow:

1. Create a snippet name, trigger, expansion, scope, and activation type.
2. Insert it manually from the Scratchpad or menu.
3. Optionally enable a spoken, explicit command: “Oto insert [name].”
4. Preview the expansion before inserting if it is long or scoped.

Natural spoken triggers must remain opt-in. A phrase such as “my email” is ordinary speech and can expose private text in the wrong place.

### 3.7 Scratchpad

**Goal:** a safe buffer when the target app is unavailable or the person wants to edit before inserting.

- Opens by shortcut without losing the previously captured target identity.
- Holds text locally until the person explicitly inserts, copies, clears, or closes.
- Uses a standard utility window/panel only where it materially helps. It should have normal titlebar controls and no custom glass/card chrome.
- “Insert” uses the same target-liveness and clipboard protections as normal dictation.
- Closing does not silently discard nonempty text; offer a lightweight confirmation or retain it for the current Oto session.

### 3.8 History and privacy

**Goal:** optional recall without accidental collection.

- History is off by default.
- When enabled, save only final text and timestamp locally.
- Per-entry actions: Copy, Reinsert (after target capture), Delete.
- Clear All must name exactly what it deletes.
- Never place raw audio, partial results, clipboard snapshots, target app contents, or Apple Intelligence prompt traces into history.
- “Use history as AI context” is a distinct opt-in. The person selects exact entries; Oto never silently includes recent material.

### 3.9 Offline intelligence flows (post-v1)

Apple’s on-device `SystemLanguageModel` is capable of these features on supported Macs. This section is a post-v1 design, not a first-rebuild deliverable. It must remain a post-transcript draft tool, not a dependency for core dictation, and it must not create a blank Intelligence pane in v1 Settings.

#### Smart Mode

```text
Final raw text
  → deterministic app category + user preference
  → optional suggested mode
  → structured draft preview
  → Insert draft | Insert original | Copy | Scratchpad | Cancel
```

Smart Mode modes: Email, Message, Code, Meeting Notes, Journal. It may suggest one based on the active app’s identity, but it cannot inspect the app’s content or silently rewrite/insert.

#### Structure and tone

- Lists, tables, reminder candidates, translation, and tone changes appear as an editable Oto draft.
- “Create reminder” is a separate explicit confirmation after review; generation itself has no external side effect.
- “Professional,” “Friendly,” “Shorter,” and “Confident” preserve facts and numbers and never invent recipients, promises, dates, or owners.

#### Long-form meeting mode

- Explicitly start it; do not convert hands-free dictation into meeting capture.
- Chunk transcripts to the local model’s context budget, summarize chunks, then aggregate locally.
- Make action items, owners, deadlines, and follow-up email drafts **candidates** with evidence links/ranges. Never present inferred claims as facts.

#### Voice editing

- Enter explicit Voice Editing mode or require an “Oto” prefix.
- Apply “delete last sentence” deterministically to Oto's local draft and make Undo immediate.
- Send transformations such as “make this a list” or “translate the last part” to the on-device model and show a preview.
- Never execute shell commands, edit an external document in place, send mail, create a calendar record, or call a network service.

## 4. Native macOS Settings redesign

### 4.1 Decision: native sidebar, native Form, standard titlebar

Apple’s most conventional preferences window uses a stable toolbar of panes. The requested sidebar is still a valid native macOS pattern when preference areas are content-rich and benefit from a visible hierarchy. The implementation must use the system `NavigationSplitView`/`List`, not a custom HStack pretending to be one. Apple’s `NavigationSplitView` owns selection, sidebar material, focus, resizing, and sidebar visibility behavior; `Form` provides platform-appropriate control alignment on macOS. [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [Form](https://developer.apple.com/documentation/swiftui/form)

**Chosen design:** a real SwiftUI `Settings` scene containing a two-column `NavigationSplitView`, `List(selection:)` sidebar, and `Form` detail panes. A selected detail pane may contain a native `TabView` for tightly related subviews such as Dictionary/Snippets or Privacy/History; the tabs remain inside the detail pane and never replace the sidebar. This respects the requested sidebar while keeping component behavior native.

### 4.2 Delete, do not reskin

Delete these components after their native replacement is working:

- `OtoSettingsWindowController`.
- Custom `SettingsSidebar`, `SettingsSidebarGroup`, `SettingsSidebarItem`.
- `SettingsPage`, `SettingsCard`, `SettingsRow`, `SettingsDivider`.
- `OtoTheme`, `OtoFilledButtonStyle`, `OtoQuietButtonStyle` as settings dependencies.
- The current custom typography implementation and bundled font resource; remove the global styling. Native controls and macOS-owned chrome use system typography; Oto-authored text follows the pinned bundled-font policy without changing native metrics.
- `titlebarAppearsTransparent`, manual `NSWindow` setup for Settings, manual titlebar behavior, and fixed root `.frame(width:height:)`.

Do **not** replace them with new custom controls. The goal is less code and fewer styling decisions.

### 4.3 Window and scene implementation

1. Add a SwiftUI `Settings` scene in `OtoApp` and provide its dependencies from the existing app-owned state.
2. Use `SettingsLink` in the menu bar rather than a button that manually creates a window. On macOS it opens the settings scene or brings it to front. [SettingsLink](https://developer.apple.com/documentation/swiftui/settingslink)
3. Use standard `.titleBar` window presentation and unified/compact native toolbar treatment only if required by the resulting scene. Do not set a transparent title bar.
4. Provide a default size and content minimum at the scene level. Do not force a fixed width/height on the root view.
5. Persist last selected pane in `AppStorage`; a person returning to Dictionary should land in Dictionary.
6. Keep the built-in sidebar toggle. The HIG recommends allowing people to show/hide a macOS sidebar when it is useful. [Sidebars HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars)
7. Ensure Command-Comma and the menu-bar Settings item target the same scene.

### 4.4 Sidebar information architecture

Use four concise peer areas in v1. Reserve Intelligence for a later release; do not put a disabled or empty future pane in the first Settings window. Do not put a footer, version label, account block, or critical permission action at the bottom.

| Sidebar item | Contains | Why it belongs here |
| --- | --- | --- |
| General | Launch at login, Flow Bar visibility, sounds, support diagnostics | Low-frequency app behavior. |
| Dictation | Readiness, microphone, Apple Speech asset setup, shortcut, hold/tap mode | The daily voice workflow. |
| Writing | Dictionary and snippets | Personal text behavior belongs together. |
| Intelligence (post-v1) | Smart Mode, tone presets, selected-history context, availability | Do not include this pane in v1; add it only with a shipped, tested on-device implementation. |
| Privacy & History | History opt-in, retained-data explanation, deletion | Data control and recall are closely related. |

Use concise system-label names, not internal engineering terms. SF Symbols are optional supporting glyphs, not visual decoration; let system accent and sidebar selection styling do their job. The HIG specifically cautions against fixed styling for all sidebar icons. [Sidebars HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars)

### 4.5 Detail pane rules

- Use `Form` and `Section` for durable preferences, with standard macOS controls.
- Use the system font with a 14-point body baseline. Supporting explanation uses native secondary label/caption styles only when necessary.
- No hero title, oversized symbol, serif display face, full-width rounded card, faux border, or marketing subtitle at the top of a pane.
- Keep the option label and control on the same row whenever practical; let `Form` align them.
- Use native `Toggle`, `Picker(.menu)`, `TextField`, `TextEditor`, `LabeledContent`, `ControlGroup`, `Button(.bordered)` and `Button(.borderedProminent)`.
- Use `ContentUnavailableView` for empty Dictionary, Snippets, and History states.
- Use `fileImporter`/`fileExporter` for dictionary transfer rather than manually driving `NSOpenPanel`/`NSSavePanel` from Settings.
- Use `confirmationDialog` only for deletion/clear operations; do not confirm preference toggles.
- Respect appearance, accent color, Reduce Motion, increased contrast, VoiceOver, keyboard navigation, and the user’s sidebar-icon size. Do not hard-code a palette.

The 14-point body requirement is a baseline, not a license to break accessibility: use the system font and test increased text size so labels do not truncate. Apple recommends platform-appropriate controls for forms and sufficient space around controls. [Form](https://developer.apple.com/documentation/swiftui/form) and [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### 4.5.1 Native/system typography policy

Use native system typography for macOS-owned chrome and native control metrics. Oto-authored labels and Flow Bar copy follow the repository’s pinned bundled-font policy only where that improves product typography; it must never alter the title bar, traffic lights, menus, dialogs, or other AppKit-owned surfaces.

- Never globally install a font or fetch one at runtime.
- Use `.body`, `.callout`, `.caption`, and ordinary `Font.system` roles for system-owned UI.
- Keep the 14-point body baseline as a readability target, not a hard-coded global override.
- Test larger text, non-Latin fallback, light/dark appearance, high contrast, VoiceOver, and the narrowest supported window width.
- Any branded font update must be pinned, licensed, hashed, and documented before it enters the package.

### 4.6 Per-pane content

#### General

- Launch Oto at login.
- Show Flow Bar.
- Dictation sounds.
- About/support diagnostics.

Do not duplicate microphone, Accessibility, language, or system appearance controls here.

#### Dictation

Sections: Readiness; Shortcut; Interaction; Microphone; Apple Speech.

- Readiness uses native status labels with direct actions only for missing items.
- Shortcut recorder is a focused custom AppKit bridge only because native SwiftUI has no global shortcut recorder. Keep its surrounding row native.
- Apple Speech setup explains the language asset state in a footer and shows one “Prepare Offline” action when relevant.

#### Writing

Use a `List` or `Table` for saved entries with add/edit controls in a toolbar or a sheet, not a giant inline form above a hand-built card list.

- Dictionary: Spoken form, Replacement, Scope, Enabled.
- Snippets: Name, Trigger, Expansion preview, Scope, Activation.
- Add/edit appear in a native sheet with Cancel/Save, validation, and a test/preview.

#### Intelligence

Only show when `SystemLanguageModel` is available or show one explanatory unavailable row.

- Smart Mode behavior and per-app mappings.
- Rewrite presets.
- Voice Editing enablement.
- Selected-history context control.
- Clear statement: on-device only, no cloud fallback.

#### Privacy & History

- History toggle and retention statement.
- Browse history in a system list with Copy/Reinsert/Delete actions.
- Clear history separate from Clear all personal data.
- Permission status with direct system-settings routes.

### 4.7 Flow Bar visual direction

Keep it a single dark frosted pill, with a limited moving color wash only while recording. Everything else should be system typography and SF Symbols.

- Body/status label: native system body role with a 14-point readability baseline; Oto-authored Flow Bar copy may follow the pinned font policy without changing system-owned metrics.
- Recording: microphone plus waveform/level; stop button uses an icon with an accessibility label.
- Processing: still surface, progress indicator, no fake animation/counter.
- Success/cancel: short, quiet, then hide.
- Permission/error: concise label, icon-only recovery action, detailed explanation in Settings.
- Respect Reduce Motion by stopping the moving gradient; respect Reduce Transparency by increasing the dark fill.
- Bind the panel to the captured target screen, not `NSScreen.main`.

The Flow Bar should not include a text “Settings” pill or giant icons. A small external-link/slider/gear symbol with a VoiceOver label is sufficient.

## 5. Repository restructuring plan

### 5.1 Why a restructure is warranted

The repository is small enough for a controlled from-scratch rebuild, not a blind rewrite and not an incremental reskin. The current split between Core/Input/Text/UI is reference evidence, while `SettingsView.swift` and its window controller are explicitly retired. Rebuild one boundary at a time with a named owner, a protocol seam, and tests before deleting the old path.

Do not create layers just to mimic a large company. The desired outcome is one obvious home for each behavior, shallow imports, tests that mirror source, and no two agents editing the same giant view file.

### 5.2 Target source layout

```text
Sources/Oto/
├── App/
│   ├── OtoApp.swift                 # scenes, shared dependencies, commands
│   ├── AppCommands.swift            # menu commands and keyboard-facing actions
│   └── AppState.swift               # app-owned observable presentation state
├── Coordinator/
│   └── DictationCoordinator.swift   # sole session state owner
├── Services/
│   ├── DictationSession.swift       # capture + analyzer lifetime
│   ├── TranscriptionService.swift    # Apple Speech adapter and readiness
│   ├── AudioCaptureService.swift
│   ├── AudioBufferRelay.swift
│   ├── VoiceActivityDetector.swift
│   ├── FunctionKeyMonitor.swift
│   ├── ModifierHotkeyMonitor.swift
│   ├── ShortcutRecorder.swift
│   ├── TextInjector.swift
│   └── TranscriptPipeline.swift
├── Models/
│   └── DomainModels.swift            # Sendable state and persisted values
├── Storage/
│   ├── DictionaryStore.swift
│   ├── SnippetStore.swift
│   ├── HistoryStore.swift
│   └── LocalPersistence.swift
├── UI/
│   ├── Settings/                     # native Settings scene and panes
│   ├── FlowBar/
│   ├── Scratchpad/
│   └── Shared/                      # only genuinely reusable, native wrappers
└── Support/
    ├── Diagnostics.swift
    ├── LaunchAtLoginService.swift
    └── PermissionsManager.swift

Tests/OtoTests/
├── Coordinator/
├── Services/
├── Storage/
├── UI/
└── Support/
```

The `Intelligence/` module and `IntelligenceSettingsView` are post-v1 additions. Do not create them in the first release target or add a disabled Settings pane for them.

### 5.3 Ownership rules

| Concern | One owner | Prohibited shortcut |
| --- | --- | --- |
| Session state | `Coordinator/DictationCoordinator` | UI views calling audio/engine methods directly. |
| Original insertion target | Session context captured at start | Querying the current frontmost app at insert time as a fallback. |
| Apple assets | `Services/TranscriptionService` | Settings or UI performing engine setup directly. |
| User text persistence | `Storage/` stores | View-local arrays or `UserDefaults` blobs for growing history. |
| Intelligence draft | post-v1 service plus draft store | Overwriting the raw transcript in-place. |
| Native Settings navigation | `UI/Settings` selection | Each pane inventing its own navigation/window. |
| Flow Bar | `UI/FlowBar` presentation controller/view | Audio or speech classes importing SwiftUI. |

### 5.4 Persistence decision

- Keep small booleans, enum selections, and sidebar selection in `AppStorage`/`UserDefaults`.
- Move dictionary, snippets, history, draft artifacts, and prompt presets out of a single `UserDefaults` blob into versioned local files in Application Support through one persistence service.
- Make migrations explicit and testable. Maintain atomic writes, schema version, backup-on-migration, and deletion semantics.
- Do not store audio or unseen app context. Use a privacy-safe aggregate diagnostics store only if necessary.

### 5.5 Migration sequence

1. Freeze the product boundary, OS baseline, decision log, and test matrix.
2. Build pure models and the coordinator/audio/SpeechAnalyzer seams first.
3. Add shortcut calibration, target capture, insertion, and recovery behind protocols.
4. Add persistence, dictionary, snippets, history, and Scratchpad with migration tests.
5. Build the native Settings scene and Flow Bar projection only after the core seams are testable.
6. Delete old custom Settings code only when no references remain; keep native system typography for system-owned UI and apply the pinned font policy only to authored text that needs it.
7. Add intelligence as a post-v1 feature module only after the v1 release gate; it must not modify the dictation module’s session state machine.

## 6. Phased execution plan

Each phase has an output and a gate. A later phase does not start until the gate is met.

### Phase 0 — Product freeze and safety baseline

**Goal:** establish what must not regress.

- Freeze the Apple Speech-only, offline-first product decision in README and Settings copy.
- Convert the current reliability matrix into a tracked execution checklist.
- Add failing tests for app-scoped dictionary target identity, stale insertion target, clipboard ownership, session finish/cancel races, and settings scene opening.
- Add a single product decision log that records transcriber choice, OS baseline, privacy decisions, and feature gates.

**Gate:** a contributor can name the release scope, data boundaries, target insertion rule, and current known risks without reading every source file.

### Phase 1 — Core session and Apple Speech runtime

**Goal:** establish one correct, cancellable, offline transcription path before UI polish.

- Introduce explicit `DictationSession`/session ID and route begin, finish, cancel, interruption, and failure through one coordinator.
- Add the audio capture boundary, bounded delivery relay, selected-device handling, and route-change recovery.
- Add the Apple SpeechAnalyzer adapter, explicit asset readiness states, locale resolution, and one selected transcriber configuration.
- Add the ordinary shortcut and HID/function-key boundaries, but keep their callbacks limited to lightweight event dispatch.
- Add deterministic fakes and race tests for start, key-up during preparation, finish/cancel, and late results.

**Gate:** the core state machine is deterministic, no audio callback touches UI, and a prepared language can be exercised through a fake engine without the Settings or Flow Bar layers.

### Phase 2 — Target capture, insertion, and recovery

**Goal:** a final transcript reaches the original target exactly once or remains safely recoverable.

- Capture app bundle identifier, process identity, screen, and insertion target before any Oto UI appears.
- Pass captured app identity into dictionary/snippet processing and validate target liveness at finalization.
- Add layered System Events/synthetic paste insertion, ownership-aware clipboard restoration, and Copy/Scratchpad recovery.
- Add audio-device/default-device observation, sleep/wake handling, and interruption recovery.

**Gate:** every P0/P1 reliability row in the test matrix passes in a packaged build; no wrong-target insertion is accepted as a known issue.

### Phase 3 — Writing tools and local data foundation

**Goal:** personal features are predictable, editable, and durable.

- Split Dictionary, Snippets, History, and persistence into independent modules.
- Move user text records to versioned Application Support files with migration tests.
- Finish native add/edit sheets, search/list management, import preview, exports, and deletion affordances.
- Finish Scratchpad recovery flow and prevent accidental silent loss on close.

**Gate:** a person can add, scope, test, export, import, disable, delete, and clear personal text data without corrupting it or affecting another app’s rule.

### Phase 4 — Native macOS shell and Flow Bar

**Goal:** expose the proven runtime through native macOS UI without creating a second lifecycle.

- Add the SwiftUI `Settings` scene, `SettingsLink`, native `NavigationSplitView`, native `List`, and native `Form` panes.
- Replace the manual AppKit Settings window and custom card/sidebar/theme/button components.
- Use standard titlebar/traffic lights and scene sizing; keep system typography on native controls and follow the documented authored-text font policy only where appropriate.
- Project coordinator states into the custom Flow Bar, including screen tracking, reduced motion, reduced transparency, dynamic width, and repeated-dismissal safety.
- Test opening Settings from the menu, Command-Comma, and every permission-recovery action.

**Gate:** no Settings behavior depends on `OtoSettingsWindowController`, `titlebarAppearsTransparent`, a fixed root frame, `OtoTheme`, or custom settings button styles; Flow Bar actions cannot bypass the coordinator.

### Phase 5 — Offline Apple Intelligence foundation (post-v1)

**Goal:** add optional writing intelligence only after the Apple Speech release gate is green.

- Add `OfflineIntelligenceService` using only `SystemLanguageModel`.
- Add availability/locale gates, on-device-only enforcement, token budgeting, cancellation, structured drafts, and source preservation.
- Build a native preview sheet with Insert Draft, Insert Original, Copy, Scratchpad, and Cancel.
- Create prompt fixture/evaluation data with synthetic non-personal examples; test every supported OS/model update.

**Gate:** this phase is not required for v1. When enabled later, normal dictation must still succeed with the intelligence model unavailable, and every intelligence action must succeed with networking disabled.

### Phase 6 — Intelligent writing features (post-v1)

**Goal:** ship intelligence one reversible operation at a time.

1. Tone rewrite and simple structure.
2. Smart Mode suggestion and per-app mappings.
3. Explicit snippets with template fields.
4. Voice Editing on local drafts only.
5. Explicit long-form/meeting mode with local chunking and review.

**Gate for every operation:** it preserves source, has a cancel/recovery path, has no external side effect without confirmation, and has prompt/regression fixtures.

### Phase 7 — Release quality

**Goal:** the app behaves like a dependable Mac utility on real devices.

- Run full device/input/app/permission/reduced-motion/multi-display matrix.
- Profile release builds for capture callback work, allocations, task pressure, analyzer startup, insertion latency, Flow Bar redraws, and long-session memory.
- Finish signing, Hardened Runtime, notarization, login item checks, privacy policy, support diagnostics, and fresh-account test.

**Gate:** no open P0/P1 issue; supported failure modes are actionable; packaged app has passed the matrix, not only unit tests. This gate closes v1 before any post-v1 intelligence phase is advertised.

## 7. Future-agent handoff guide

### Mandatory preflight for every agent

1. Read this file, [16_REBUILD_DECISIONS.md](16_REBUILD_DECISIONS.md), [07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md](07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md), and [11_RELIABILITY_TEST_MATRIX.md](11_RELIABILITY_TEST_MATRIX.md).
2. Identify the active phase and its gate. Do not begin a later phase casually.
3. Inspect the current worktree and preserve unrelated changes.
4. Make the smallest complete change in one owned module. Add/adjust tests in the matching test folder.
5. Build and run the relevant tests. State what was not device-tested.
6. Update the decision log/checklist only when the phase acceptance evidence exists.

### Agent assignments that can run in parallel safely

| Workstream | Owns | Must not edit |
| --- | --- | --- |
| Native Settings agent | `UI/Settings/`, scene wiring, UI tests | Dictation state machine, Flow Bar implementation. |
| Dictation reliability agent | `Coordinator/`, `Services/` audio/speech fakes, coordinator tests | Settings styling, persistence schema. |
| Insertion/privacy agent | `Services/TextInjector`, target identity, clipboard tests | Speech engine, intelligence prompts. |
| Writing-data agent | `Storage/`, schema migrations, dictionary/snippet/history tests | Global shortcut event tap. |
| Intelligence agent (post-v1) | future intelligence module, native preview sheet, prompt fixtures | Audio capture, direct external insertion. |
| Release/QA agent | matrix, packaging, signing configuration, diagnostics | Product behavior without an approved issue/change. |

### Agent stop conditions

An agent must stop and report rather than guess when:

- A requested behavior would send data off-device, read external app content, or make an external side effect.
- A macOS API cannot guarantee a secure-field or cross-app behavior.
- A change would remove the raw-text recovery path.
- A new API only exists on a higher OS version than the declared product baseline.
- A result depends on a real device, permission, or external app that cannot be tested in the environment.

### Definition of a good handoff

Every completed agent task includes:

- the user-visible result;
- changed files and why;
- automated evidence;
- manual/device work still required;
- any decision needing product approval.

## 8. Product acceptance checklist

### Daily dictation

- [ ] Press/release creates exactly one final insertion.
- [ ] Hands-free starts/stops predictably and can be cancelled.
- [ ] No network is required after Apple assets are prepared.
- [ ] Original app and original display are respected.
- [ ] A failed insertion preserves text for recovery.

### Native macOS quality

- [ ] Settings opens through the system Settings scene from both menu and Command-Comma.
- [ ] Standard titlebar and traffic lights are visually integrated with the window.
- [ ] Sidebar selection, hover, focus, toggle, picker, dialog, file picker, and keyboard navigation are system behavior.
- [ ] A pinned official Inter bundle is used only for Oto-authored text; standard body content has a 14-point baseline; system-owned chrome remains native.
- [ ] Settings has no custom cards, giant icons, serif hero titles, fake controls, or fixed root canvas.

### Privacy and intelligence

- [ ] Core dictation works when Apple Intelligence is unavailable.
- [ ] All intelligence uses only on-device `SystemLanguageModel`; no Private Cloud Compute path exists.
- [ ] Every transformation keeps raw source and offers preview/cancel/recovery.
- [ ] No external app text/history is supplied as context without explicit selection.
- [ ] History and history-as-context are independently opt-in.

### Engineering quality

- [x] One active session; one finish/cancel owner; bounded audio delivery.
- [x] App-specific rules receive the captured target bundle ID.
- [x] Clipboard restoration does not overwrite a new user clipboard item.
- [ ] Device, permission, sleep/wake, and app-switch interruptions recover cleanly.
- [ ] Unit, UI, and real-device test evidence matches the release claims.

## 9. Source references

- [Apple macOS resources](https://developer.apple.com/macos/resources/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple Design Resources — macOS apps](https://developer.apple.com/design/resources/#macos-apps)
- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [SwiftUI Get Started](https://developer.apple.com/swiftui/get-started/)
- [Swift Get Started](https://developer.apple.com/swift/get-started/)
- [SwiftUI documentation overview](https://developer.apple.com/documentation/SwiftUI#Overview)
- [Apple HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Apple HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple HIG: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [SwiftUI SettingsLink](https://developer.apple.com/documentation/swiftui/settingslink)
- [SwiftUI NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [SwiftUI Form](https://developer.apple.com/documentation/swiftui/form)
- [ElevenLabs UI Bar Visualizer reference](https://ui.elevenlabs.io/docs/components/bar-visualizer)
- [Yap repository](https://github.com/FrigadeHQ/yap)
- [Apple Speech implementation plan](07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md)
- [Oto reliability test matrix](11_RELIABILITY_TEST_MATRIX.md)
