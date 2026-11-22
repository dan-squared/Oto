# Oto

A fast, private dictation app for macOS. Hold a key, speak, and release — your words are typed directly into whatever app you are using.

No cloud servers. No subscriptions. No battery drain. Everything runs completely on your Mac.

---

## What makes it nice

- **Fast and lightweight:** Starts listening immediately when you press the key and types your text the moment you let go. No lag, no heavy background processes.
- **100% private and offline:** Built on Apple's native speech recognition. Your voice never leaves your Mac and it works without an internet connection.
- **Never loses your words:** If you speak without clicking inside a text box first, Oto doesn't lose what you said. It shows a small card with your text and a Copy button.
- **Custom dictionary:** Add names, acronyms, or technical terms (like *PostgreSQL* or *Kubernetes*) so they are always spelled and capitalized correctly.
- **Clean floating indicator:** A small, minimal pill on your screen shows when Oto is listening and fades away when you're done.
- **Audio ducking:** Automatically lowers background music or podcasts while you talk so you don't have to pause them.

---

## How it works

### Hold to talk
Press and hold your shortcut (default: `Right Option`), speak what you want to type, and let go. Your text is inserted right at your cursor.

### Hands-free
If you have a longer thought or note, tap the shortcut once to start recording, speak as long as you need, and tap it again when you are finished.

---

## Optional on-device AI cleanup

Oto includes an optional cleanup tool powered by Apple's built-in Foundation Models. When turned on, it cleans up your spoken words before pasting them:

- **Auto-cleanup:** Removes filler words ("um", "ah", "like"), accidental repeats, and verbal stumbles so your sentences read clearly.
- **Quick transforms:** Map a shortcut to automatically format what you say — such as making text more concise, polishing tone for emails, or turning your thoughts into a bulleted list.

It runs 100% on your Apple Silicon chip, meaning your thoughts never get sent to OpenAI, Anthropic, or any third-party cloud.

---

## Extra tools

- **Snippets:** Save text shortcuts for things you say or type often.
- **Local history:** A simple, private history of your recent dictations in case you ever need to copy something again.

---

## Requirements

- macOS 15.0 or later
- Apple Silicon Mac (M1/M2/M3/M4) recommended for the optional AI cleanup

---

## Building

```bash
git clone https://github.com/dan-squared/oto.git
cd oto

# Build in Xcode
xcodebuild -scheme Oto -destination 'platform=macOS' build

# Run tests
xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests
```

---

## License

Created by [Daniel Girma](https://github.com/dan-squared).
