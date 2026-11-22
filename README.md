# Oto

> Speak freely. Oto listens, cleans up your thoughts, and inserts polished prose directly where your cursor lives.

Oto is a native macOS dictation tool designed to bridge the gap between how we talk and how we write. Instead of transcribing every verbal stumble, filler word, or false start literally, Oto refines your spoken words into clear, natural prose before inserting them directly into your active app — all entirely on-device with zero cloud latency.

---

## Why Oto

Traditional dictation tools force a frustrating compromise: either your voice is streamed to third-party cloud servers with noticeable latency and privacy trade-offs, or you run massive local models that drain your battery and heat up your machine.

Oto takes a different path:

- **Invisible Editing in Real Time:** Speaks like you, but writes like an editor. Verbal filler ("um", "like", "you know"), accidental repeats, and awkward pauses are stripped away seamlessly without altering your voice or meaning.
- **Strictly Local and Private:** Powered entirely by Apple Speech and on-device Foundation Models. Your voice and text never touch a server, an API, or external storage. It operates seamlessly even completely offline.
- **Instantaneous Response:** Native Swift architecture with near-zero memory footprint and no heavy runtimes. Dictation starts the instant you press your shortcut and finishes the moment you let go.
- **Never Loses a Thought:** If you dictate without an active text field focused, Oto does not drop your words. It catches the transcript in a compact floating card with a single-click copy button.
- **Native macOS Craft:** Mutes and ducks background media during recording, provides subtle native audio cues, and stays completely out of your way when you are done.

---

## Capabilities

### Hold-to-Talk and Hands-Free Modes
- **Hold-to-Talk:** Press and hold your trigger key (such as `Right Option`), speak naturally, and release to insert text.
- **Hands-Free:** Tap once to start dictation, tap again to finish.
- **Independent Triggers:** Map separate shortcuts for raw verbatim dictation versus AI-polished output.

### On-Device Writing Polish
Oto refines raw transcripts before insertion using Apple's local language models:
- **Auto Cleanup:**
  - **Light:** Corrects punctuation, capitalization, and minor slips while preserving your exact sentence phrasing.
  - **Medium:** Eliminates filler words, stammers, and stuttering into clear, flowing sentences.
- **One-Touch Transforms:**
  - **Polish:** Smooths syntax and clarifies meaning.
  - **Concise:** Cuts verbosity to deliver short, direct messages.
  - **Professional:** Adjusts tone for workplace communications, emails, and documentation.
  - **Custom Prompts:** Supply custom instructions for specific workflows, such as bulleted action items or structured summaries.

### Personal Dictionary and Snippets
- **Custom Dictionary:** Teach Oto technical jargon, names, and industry terms (e.g., *PostgreSQL*, *Kubernetes*, *GraphQL*) so they always transcribe with exact spelling and casing.
- **Snippets:** Instant expansion for frequently spoken boilerplate and templates.
- **Local History:** Private, searchable, on-device history log to retrieve past dictations at any time.

### The Flow Bar
- A minimalist frosted-glass indicator that reflects your voice wave in real time.
- Snaps cleanly to the top (under the notch) or bottom of your display with smooth drag-and-drop.
- Five distinct glass color palettes: Graphite, Crimson, Pink, Violet, and Ocean.

### The Catcher
- Dictating while reading or browsing without a text field selected? Oto catches the transcript into a non-intrusive floating surface with an instant copy action and full history retention.

---

## Technical Overview

```
Oto/
├── App/            # Application lifecycle and dependencies
├── Coordinator/    # DictationCoordinator (actor-isolated session management)
├── Services/       # Speech, on-device AI polish, accessibility capture, text insertion
├── UI/
│   ├── FlowBar/    # Floating liquid glass indicator and live audio visualizer
│   ├── Scratchpad/ # Non-activating Catcher card & recovery surface
│   └── Theme/      # Native macOS controls, typography, and palette shaders
├── Settings/       # Pure macOS Settings scenes with full keyboard customization
└── Onboarding/     # Permissions and setup workflow
```

- **Actor-Isolated Architecture:** `DictationCoordinator` owns session state transitions with idempotent finish/cancel handling and reentrancy safety.
- **Native Frameworks:** Built exclusively on Apple's standard frameworks (`Speech`, `FoundationModels`, `AVFoundation`, `CoreGraphics`).

---

## Requirements

- macOS 15.0 or later (Apple Silicon required for on-device Foundation Models)
- Xcode 16.0+ (to build from source)

---

## Building from Source

```bash
git clone https://github.com/dan-squared/oto.git
cd oto

# Build the project
xcodebuild -scheme Oto -destination 'platform=macOS' build

# Run unit tests
xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests
```

---

## License

Created by [Daniel Girma](https://github.com/dan-squared).
