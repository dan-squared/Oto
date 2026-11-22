# Beta release (right-click → Open, no notarization)

This is the hand-off for shipping a beta without an Apple Developer Program subscription. The app is ad-hoc signed; macOS Gatekeeper will still quarantine it, so testers must **right-click the app → Open** the first time (and again after a Sparkle update, because each new copy is quarantined).

## One-time setup (done on this Mac)

1. Sparkle's `generate_keys` created an Ed25519 signing key in the login Keychain.
   Public key (already in `project.pbxproj` as `INFOPLIST_KEY_SUPublicEDKey`):

   ```
   2VhZbBhuDkrI34qLKTAPK+LSWDIdKbR04KyCKC/6bJg=
   ```

2. A backup of the private seed was exported (chmod 600, **never commit**):

   ```
   ~/.config/oto/sparkle-keychain-key.txt
   ```

   To re-export later: `generate_keys -x <file>`. To import on another Mac: `generate_keys -f <file>`.
   If the private key is lost, updates cannot be signed for this public key — rotate the key and rebuild.

3. Set the real feed URL before shipping. It is currently a placeholder:

   ```
   export OTO_FEED_URL='https://YOUR-SITE/appcast.xml'
   ```

   Then rebuild. `OTO_FEED_URL` is a build setting, so it can also be overridden on a single `xcodebuild` invocation without editing the project. The site skeleton in `site/` serves the appcast at `public/appcast.xml`.

## Making a release

```bash
export OTO_FEED_URL='https://YOUR-SITE/appcast.xml'
./Scripts/release.sh
```

The script:
- archives with ad-hoc signing (`CODE_SIGN_IDENTITY=-`, hardened runtime on),
- zips `Oto.app` into `updates/Oto-<version>-<build>.zip`,
- runs Sparkle's `generate_appcast` with the EdDSA key (Keychain by default, or `SPARKLE_KEY_FILE=/path/to/key` for headless CI),
- writes the signed `site/public/appcast.xml`.

`generate_appcast` needs a base URL for the download enclosures; set `OTO_DOWNLOAD_PREFIX` if you host the zip somewhere other than the default GitHub Releases tag URL.

Then:
1. Upload the zip to the matching GitHub Release.
2. Commit `site/public/appcast.xml` (and the new file in `updates/`).
3. Deploy `site/` (Next.js + Tailwind; `npm install && npm run build` on Vercel).
4. Verify the feed is reachable: `curl -I https://YOUR-SITE/appcast.xml`.

## Tester instructions

1. Download the zip, unzip, drag Oto to Applications.
2. Right-click Oto → Open → Open (Gatekeeper).
3. Grant Microphone and Accessibility when the onboarding asks.

## CI

`.github/workflows/ci.yml` runs build + tests on pushes and PRs. A tag matching `v*` builds an ad-hoc release and uploads the app, zip, and appcast as an artifact. The release job needs repository variable `OTO_FEED_URL` and secret `SPARKLE_KEY_FILE` (the base64 seed, not the Keychain).

## What is still manual

- Device matrices: TCC prompts, shortcut/keyboard coverage, cross-app insertion, Bluetooth mic, sleep/wake, two displays, Reduce Motion/VoiceOver/larger text.
- The landing page content in `site/` is intentionally empty.
- No notarization, privacy manifest, or Mac App Store path by design for this beta.
