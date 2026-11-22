# Beta release readiness — Sparkle, CI, diagnostics, metadata, crash flake

Status: executed. Debug/Release builds green; full suite green on three consecutive runs; release script validated end-to-end (ad-hoc archive → zip → signed appcast). Feed URL remains a build-setting placeholder until the real site domain is set.

## 1. Goal

Close the non-IA gaps that block handing a beta build to other Mac users, under two constraints the user set:

- **No Apple Developer Program / no notarization.** Release artifacts are ad-hoc signed; users open with right-click → Open.
- **Settings IA drift stays deferred** (custom window / 6 sidebar items) — explicitly out of scope.

Items to close:
1. Sparkle 2 properly integrated (framework + EdDSA keys + appcast + updater UI + release script).
2. CI for build/test plus a tag-triggered ad-hoc release artifact.
3. No-cost crash/issue reporting: local crash log + "Report a Problem" link.
4. Localization declaration (English only).
5. About pane support/source links.
6. `NSSpeechRecognitionUsageDescription` before any auth prompt is added.
7. Diagnose the one observed test-host crash in `FeedbackSoundsTests`.

## 2. Spec sources and verified facts

- `Docs/START_HERE_PRODUCT.md` (canonical): Apple Speech only, recoverable failures, one coordinator, no hidden model runtimes.
- `Docs/OTO_REBUILD_PLAN/04_TESTING_AND_FUTURE_AGENT_HANDOFF.md:98-108` — release gate; `:85-97` device-only evidence (still must be run on hardware by the user).
- `Docs/OTO_REBUILD_PLAN/07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:708-722` — definition of done.
- `Docs/AUDIT_2026-10-30_PRODUCTION_READINESS.md:262-278` — release engineering table (no notarization, privacy manifest, updates, CI, localization, About links).
- Live package research (Context7 + GitHub API, this session):
  - Sparkle package identity: `https://github.com/sparkle-project/Sparkle`; current stable **2.10.1** (published 2026-10-25); release asset `Sparkle-2.10.1.tar.xz` contains `bin/generate_keys` and `bin/generate_appcast`; `Sparkle-for-Swift-Package-Manager.zip` also exists.
  - License (repo `LICENSE`): MIT-style permissive, commercial use allowed. Safe to vendor via SPM. No paid dependency.
  - Sparkle 2.10+ requires macOS 12+; project target is macOS 27 — compatible.
  - Key API: `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`, `updater.canCheckForUpdates`, `updater.checkForUpdates()` (main thread).
  - Info.plist keys: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUAutomaticallyUpdate`.
  - `generate_keys` writes a private key to login Keychain and prints the base64 public key; `generate_appcast <dir>` signs appcast entries with that key.
- Project facts verified this session:
  - No SPM package references in `Oto.xcodeproj/project.pbxproj` today.
  - Build settings: `CODE_SIGN_IDENTITY = Apple Development`, `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = 78458476CJ`, `ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = YES`, `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`, `SWIFT_EMIT_LOC_STRINGS = YES`, mic usage description present in both configs, no `NSSpeechRecognitionUsageDescription`, no localization key, no Sparkle keys.
  - `Oto/Oto.entitlements` already has `com.apple.security.device.audio-input` — keep it for ad-hoc builds.
  - `AboutPane()` is created at `Oto/Settings/SettingsRoot.swift:596` (single call site).
  - Repo `dan-squared/Oto`, default branch `main`, Issues enabled, no `.github/` yet.
  - No `Oto-*.crash` files in `~/Library/Logs/DiagnosticReports`; the earlier full-suite crash left no user-visible diagnostic file.

## 3. Assumptions questioned

- "Sparkle properly setup" cannot be complete without **somewhere to host the appcast**. Decision: commit `appcast.xml` at repo root and use the HTTPS raw URL `https://raw.githubusercontent.com/dan-squared/Oto/main/appcast.xml`. It is free and needs no Pages setup; GitHub Pages can replace the URL later without code changes.
- EdDSA key generation writes to *this* Mac's Keychain. The public key goes in `project.pbxproj`; the private key must be exported with `generate_keys -x` and kept by the user. If lost, future updates need key rotation — documented, not solved here.
- "No crash reporting" with no paid service is best answered by a **local crash log + GitHub issue link**, not an SDK that could capture transcript content. The log will contain version, exception reason and stack symbols only — never transcript text, target app contents, or user files.
- Ad-hoc signing plus right-click Open works for first launch; Sparkle-installed updates may also need right-click Open because each new copy is quarantined. Document this honestly.
- The one flaky test-host crash may be environmental (the suite previously restarted and passed completely). Do not "fix" it by deleting the test. Investigate with repeated runs and captured result bundles; fix only if a reproducible root cause appears. Gate Sparkle out of the test host so the new dependency does not add a new flake.

## 4. Exact changes

### Task A — Sparkle integration

- `Oto.xcodeproj/project.pbxproj`
  - Add `XCRemoteSwiftPackageReference` for `https://github.com/sparkle-project/Sparkle`, requirement `exactVersion: 2.10.1` (release, license and package identity verified above).
  - Add `XCSwiftPackageProductDependency` for product `Sparkle` to the Oto target's `packageProductDependencies`.
  - Add project-level `packageReferences` entry.
  - In both Oto configs add:
    - `INFOPLIST_KEY_SUFeedURL = "https://raw.githubusercontent.com/dan-squared/Oto/main/appcast.xml";`
    - `INFOPLIST_KEY_SUPublicEDKey = "<generated base64 key>";`
    - `INFOPLIST_KEY_SUEnableAutomaticChecks = YES;`
    - `INFOPLIST_KEY_SUScheduledCheckInterval = 86400;`
    - `INFOPLIST_KEY_SUAutomaticallyUpdate = NO;` (download with consent, install on user action)
    - `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Speech recognition is used to transcribe dictation on this Mac.";`
    - `INFOPLIST_KEY_CFBundleLocalizations = ( en );`
  - Bump `CURRENT_PROJECT_VERSION` to 2 (so a future build can be an update); keep `MARKETING_VERSION = 1.0`.
- `Oto/Support/AppUpdater.swift` (new): `@MainActor final class AppUpdater: NSObject`, owns one `SPUStandardUpdaterController`; `canCheckForUpdates` and `checkForUpdates()`; `automaticallyChecksForUpdates = false` when `XCTestConfigurationFilePath` is present or `OTO_SHOT` is set, so probes/tests never reach the network.
- `Oto/App/OtoApp.swift`: single `AppUpdater` instance; pass to `OtoMenuBarView` and `SettingsRoot`.
- `Oto/UI/OtoMenuBarView.swift`: `Button("Check for Updates…")` above Settings, disabled when `!updater.canCheckForUpdates`.
- `Oto/Settings/SettingsRoot.swift`: accept `updater`, pass to `AboutPane` (`:596`).
- `Oto/Settings/AboutPane.swift`: accept `updater`; add "Check for Updates…" button in Details.
- `Scripts/release.sh` (new): archive with `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`, export `.app`, zip with `ditto`, put archive in `updates/`, run `generate_appcast`, write `appcast.xml`. Resolve the tool from the SPM artifacts path or the downloaded `Sparkle-2.10.1.tar.xz`. Refuse to run if `SUPublicEDKey` is a placeholder.
- `Docs/BETA_RELEASE.md` (new): one-time `generate_keys` (and `-x` export), how to build, where to upload (`appcast.xml` + archives), and the right-click Open instruction for testers.

### Task B — CI and release artifact

- `.github/workflows/ci.yml` (new):
  - `push` + `pull_request`: `xcodebuild -resolvePackageDependencies`, then `xcodebuild test -scheme Oto -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (runner must provide Xcode 27 / macOS 27 SDK; fail with a clear message if not).
  - `push` on tags `v*`: ad-hoc build + zip/upload as a workflow artifact (no notarization), so the tag produces something a tester can download.

### Task C — Local crash/issue reporting + About links

- `Oto/Support/IssueReporter.swift` (new): `install()` sets `NSSetUncaughtExceptionHandler`; writes `Crash-<timestamp>.txt` under `~/Library/Application Support/Oto/Crashes/` with app version/build, exception reason and `callStackSymbols`. No transcript or target-app data. `latestReportURL` for support copy.
- `Oto/App/OtoApp.swift`: call `IssueReporter.install()` first in `init()` (before probe hooks).
- `Oto/Settings/AboutPane.swift`: add a "Support" section with `Link("Source & Releases", https://github.com/dan-squared/Oto)` and `Link("Report a Problem", https://github.com/dan-squared/Oto/issues/new?title=...&body=...)`. Body prefilled with version/build and a note to attach the newest local crash report; build URL safely with adding percent encoding (no force unwrap).

### Task D — Flaky test diagnosis

- Run the full suite 3× with `-resultBundlePath` into a temp dir; search each `.xcresult` for crash/abort diagnostics.
- If a reproducible root cause appears, fix it in the same batch (smallest honest patch) and re-run.
- If not reproducible, leave the test intact and record the evidence and the "environmental, not verified" verdict in `plan/beta-release-readiness.md` and the final report.
- No deletion or suppression of `FeedbackSoundsTests.finishingInsideTheStartToneNeverDucks()`.

## 5. Verification

1. `xcodebuild -resolvePackageDependencies` then Debug + Release builds (ad-hoc override for the release build) — both green.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` full suite green; plus Task D repeats.
3. Inspect the built `Info.plist`: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `NSSpeechRecognitionUsageDescription`, `CFBundleLocalizations` all present.
4. Run `Scripts/release.sh` once locally (with generated key) and confirm `generate_appcast` produces a signed `appcast.xml` with an enclosure matching the zip.
5. `curl -I` the raw appcast URL to confirm it is publicly reachable.
6. In a Debug launch with a test feed override, confirm "Check for Updates…" is enabled in menu and About; in a test host launch, confirm Sparkle is not started.
7. About pane: both links open the correct URLs; report body contains version/build.
8. CI workflow YAML syntax check; confirm it does not require secrets for the test job.
9. Confirm Settings IA was not touched.

## 5.1 Flaky-crash / flaky-test verdict (executed)

- Three consecutive full `xcodebuild test` runs ended **TEST SUCCEEDED** (662 tests + UI test). No crash reproduced.
- Two intermittent failures were found and fixed rather than suppressed:
  - `OtoThemeTests.settingsGroundUsesSystemDarkAndUnchangedInLight` assumed one exact gray; AppKit resolves the same token to 0.09–0.12 depending on display profile, so the assertion now checks that range. The suite is serialized because its helper swaps `NSAppearance.current`.
  - `SettingsUITests` could no longer reach "Finish" once the onboarding permission gate was added; the gate is bypassed in UI-test/probe launches (`suppressesNativePrompts`), which cannot grant TCC.
- The original one-off `FeedbackSoundsTests` host restart did not recur; no code deletion or test suppression was done.

## 6. Risks / deferred

- Raw GitHub appcast has no CDN/cache controls and `text/plain` MIME; acceptable for beta. Move to GitHub Pages or a real host before 1.0.
- Without Developer ID + notarization, Gatekeeper may quarantine both the first download and Sparkle-installed updates; right-click Open remains necessary. This cannot be engineered away for free.
- Local crash log only catches `NSException`, not SIGSEGV/SIGABRT — adding signal handlers needs async-signal-safe code and is deliberately deferred.
- macOS runner SDK drift in CI may break the `macOS 27` deployment target; the workflow must report it rather than silently downgrade.
- Privacy manifest, localization beyond English, update analytics, push-based crash reporting, IA changes, and device matrices remain out of this batch.

## 7. Open questions

1. Appcast host: raw GitHub URL chosen (free, zero setup) — okay, or do you want GitHub Pages from `docs/` instead?
2. Should the "Report a Problem" link include the local crash report's *contents* in the prefilled body, or only the file name/path? Plan chooses name/path only to avoid uploading private data without consent.
