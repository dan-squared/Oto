# Oto

> **A quiet, instant, and completely private macOS dictation utility.**  
> Press a shortcut, speak, release — and your words appear directly in whatever app you are using.

---

## Why Oto?

Most dictation tools either send your private voice recordings to cloud servers or force you to install heavy, power-draining models that spin up your Mac's fans.

**Oto is designed from the ground up for the Mac:**
- **100% On-Device & Private:** Powered entirely by Apple Speech and Apple Foundation Models (`SystemLanguageModel`). Your voice, transcripts, and text never leave your machine. No accounts, no subscriptions, no tracking.
- **Instant & Lightweight:** Starts immediately with virtually zero memory footprint. No heavy runtimes, no background servers, no multi-gigabyte model downloads.
- **Built-in AI Writing Cleanup:** Speaks like you, but writes cleanly. Intelligently removes stumbles, filler words, and awkward phrasing in real time without altering your voice or meaning.
- **Fail-Safe Text Insertion:** Focus is captured the millisecond you hit the trigger. If you dictate without an active text box, Oto catches the transcript and gives you a one-click copy card so you never lose a word.
- **Seamless System Integration:** Automatically ducks background media while speaking and provides crisp, native audio and haptic feedback.

---

## Features

### 🎙️ Effortless Hold-to-Talk & Hands-Free
- **Hold-to-Talk:** Press and hold your shortcut (e.g. `Right Option`), speak, and release to insert.
- **Hands-Free:** Tap once to begin dictation, tap again to finish.
- **Dedicated Trigger Slots:** Assign different keys for raw transcription versus AI-polished output.

### 🔮 The Flow Bar
- A beautiful, minimalist liquid glass indicator that floats smoothly on your screen.
- Real-time voice wave reactivity while you speak.
- Snaps cleanly to the **Top** (under the notch) or **Bottom** of your display with smooth drag-and-drop.
- Five aesthetic glass color palettes: **Graphite**, **Crimson**, **Pink**, **Violet**, and **Ocean**.

### ✨ On-Device AI Writing & Cleanup
Powered by Apple's on-device Foundation Models, Oto refines your raw speech into polished writing before it reaches the page:
- **Auto Cleanup:**
  - **Light:** Corrects punctuation, capitalization, and minor slips while preserving your exact phrasing.
  - **Medium:** Removes stuttering, repetition, and filler words ("um", "ah", "like") into clear, cohesive sentences.
- **One-Touch Transforms:**
  - **Polish:** Refines sentence structure and clarity.
  - **Concise:** Trims verbosity and cuts straight to the point.
  - **Professional:** Elevates tone for emails, documentation, and client communication.
  - **Custom Prompt:** Define your own instructions (e.g. bullet points, action items, formatting).

### 📚 Personal Dictionary & Snippets
- **Custom Dictionary:** Teach Oto technical jargon, names, acronyms, or industry terms (e.g., *Kubernetes*, *PostgreSQL*, *Next.js*) so they are always transcribed with exact spelling and casing.
- **Snippets:** Instant text expansions for frequently spoken templates or phrases.
- **Local History:** Private, searchable, on-device history log so you can retrieve past dictations anytime.

### 🛡️ Never Lose a Thought (The Catcher)
If you start speaking while browsing or reading without an active cursor in a text field, Oto automatically morphs into a compact **Catcher card** displaying your full transcript with a quick **Copy** button.

---

## Technical Overview

```
Oto/
├── App/            # App lifecycle and dependency composition
├── Coordinator/    # DictationCoordinator (actor-isolated session management)
├── Services/       # Speech, on-device AI polish, accessibility capture, text insertion
├── UI/
│   ├── FlowBar/    # Floating liquid glass indicator and live audio visualizer
│   ├── Scratchpad/ # Non-activating Catcher card & recovery surface
│   └── Theme/      # Native macOS controls, typography, and palette shaders
├── Settings/       # Native macOS Settings with full keyboard customization
└── Onboarding/     # Seamless permission setup and interactive walkthrough
```

- **Actor-Isolated Coordination:** `DictationCoordinator` governs session state transitions with idempotent finish/cancel handling and reentrancy safety.
- **Zero Cloud Footprint:** Built on native Apple frameworks (`Speech`, `FoundationModels`, `AVFoundation`, `CoreGraphics`).

---

## Requirements

- **macOS 15.0 or later** (Apple Silicon required for on-device Foundation Models)
- **Xcode 16.0+** (to build from source)

---

## Building from Source

```bash
git clone https://github.com/dan-squared/Oto.git
cd Oto

# Build with Xcode
xcodebuild -scheme Oto -destination 'platform=macOS' build

# Run test suite
xcodebuild test -scheme Oto -destination 'platform=macOS'
```

---

## License

Created by [Daniel Girma](https://github.com/dan-squared).
