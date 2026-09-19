# Oto rebuild decision log

This is the short, explicit record of decisions that previously appeared in several competing forms. A future change must update this file and the affected plan section in the same review. A note here is not evidence that code is complete; evidence belongs in tests, packaged-build checks, or device reports.

## Locked for the first rebuild

| Decision | Choice | Reason and consequence |
| --- | --- | --- |
| Product boundary | Apple Speech-only dictation, local writing tools, target-aware insertion, native Settings, Flow Bar, and opt-in local history | Keeps the first release small, offline after Apple-managed asset preparation, and recoverable. Third-party STT, cloud speech, and model catalogs are not release dependencies. |
| Platform | macOS 26 or later, Apple silicon | The SpeechAnalyzer release path and current product promise are aligned to this baseline. Earlier macOS and Intel support require a new compatibility decision and device evidence. |
| Rebuild shape | Controlled from-scratch rebuild using the old source as reference | Prevents old custom Settings/window assumptions from leaking into the new lifecycle. Reuse is allowed only through named boundaries and tests. |
| Canonical source layout | `App`, `Coordinator`, `Services`, `Models`, `Storage`, `Support`, and `UI/{Settings,FlowBar,Scratchpad}` | Matches `05_CURRENT_TO_REBUILD_MAP.md`, keeps one owner per side effect, and avoids competing `Core`/feature-folder layouts. |
| Session ownership | One coordinator and one session ID; finish and cancel are idempotent and mutually exclusive | Prevents duplicate insertion, late results, and stop-time races. |
| Speech module | Start with `SpeechTranscriber`; validate on a supported device before release. `DictationTranscriber` is a gated alternative, not a fallback or Settings choice. | Avoids shipping two unmeasured paths while keeping a clear escape hatch if device evidence rejects the initial module. |
| Asset preparation | Explicit Settings action only; dictation checks readiness and never starts a download | Preserves the offline-after-setup promise and makes missing assets actionable. |
| Settings navigation | Native `Settings` scene with `NavigationSplitView`, `List(selection:)`, and `Form`; optional native `TabView` inside selected detail panes | Typa's root `TabView` informs spacing and scene ownership but is not a second Oto root architecture. Detail tabs may group tightly related views such as Dictionary/Snippets or Privacy/History. |
| Typography | Native system metrics for macOS-owned chrome and controls; pinned bundled font only for Oto-authored text where it does not alter native behavior | Avoids custom titlebar/control regressions, global font installation, and runtime font downloads. |
| Status vocabulary | “Reference” describes old code; “verified” requires rebuild evidence | Prevents historical implementation notes from being mistaken for shipped behavior. |
| Intelligence | Post-v1 only, on-device `SystemLanguageModel` behind an availability gate | Raw dictation must never depend on Apple Intelligence, network access, or a second lifecycle. |

## Evidence required to change a locked decision

- A concrete product reason and affected user flow.
- The API/OS availability and privacy impact.
- A migration or rollback path for existing preferences and local data.
- Automated tests plus the packaged-app or real-device evidence that the old decision could not provide.
- Updates to `README.md`, this decision log, the relevant phase gate, and the handoff note.

## Open decisions before implementation is called complete

1. Record the final `SpeechTranscriber` configuration and supported locales after device validation.
2. Record the exact packaged-app bundle/signing identity used for TCC and Accessibility tests.
3. Record the shortcut backend's physical-key coverage for the supported keyboard layouts.
4. Record the Flow Bar's final screen-placement and reduced-motion test evidence.
