<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="FlowCue">
</p>

<h1 align="center">FlowCue</h1>

<p align="center"><strong>Your voice, your flow.</strong></p>

A native macOS teleprompter for presenters, streamers, and content creators. Real-time speech tracking, AI-powered script preparation, and multiple display modes — from a sleek notch overlay to fullscreen teleprompter rigs.

> Built by **GCRYPTON LABS** — engineered with [OpenClaw](https://github.com/openclaw/openclaw) + **Claude Code Opus 4.6**

---

## Features

### Speech Modes

| Mode | Description |
|------|-------------|
| **Smart Follow** | Speech recognition highlights each word as you speak. Choose from three recognition engines. |
| **Auto-Scroll** | Steady scroll at your chosen speed. No microphone needed. |
| **Voice Pace** | Moves when you speak, pauses when you're silent. |

### Recognition Engines

| Engine | Description |
|--------|-------------|
| **Apple** | Built-in macOS speech recognition. Auto-detect language from script text, on-device Neural Engine mode. |
| **Whisper (Local)** | Local AI via [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Multilingual (99 languages), fully offline, auto-detects language from speech. |
| **OpenAI (Cloud)** | OpenAI Whisper API. Best accuracy, requires API key. Configure in Settings → Voice. |

- **Auto-detect language** — NLLanguageRecognizer identifies your script's language and configures Apple speech recognition automatically.
- **On-device recognition** — Force Apple Neural Engine for private, offline processing on Apple Silicon.
- **Local Whisper** — Requires `whisper-stream` binary and a GGML model (auto-detected from homebrew and superwhisper paths).

### Display Modes

| Mode | Description |
|------|-------------|
| **Top Bar** | Dynamic Island-style overlay anchored below the MacBook notch. Always on top. |
| **Floating** | Draggable window with frosted glass effect. Position anywhere on screen. |
| **Full Screen** | Fullscreen teleprompter on any display or Sidecar iPad. |

### AI Script Expansion

Write bullet points or rough notes, tap the AI button — get a polished, ready-to-read teleprompter script.

- Powered by Claude API (bring your own key)
- Expands notes into natural, conversational speech with `[pause]` markers
- Configure in Settings → AI

### AI Conference Copilot

Real-time AI assistant for live video calls. When someone asks you a question during a Zoom, Meet, or Teams call, press `⌘⇧A` — AI generates a natural-sounding answer that appears in a floating overlay, invisible to screen share. Read the answer while maintaining eye contact with the camera.

- **Streaming responses** — answers appear word-by-word as they're generated
- **Natural speech** — built-in system prompt makes responses sound human, not robotic
- **Dual provider support** — Claude (Anthropic) or OpenAI GPT-4o
- **Context hint** — tell the AI your role and topic for better answers
- **Rolling transcript** — configurable buffer (30-120 seconds) of conversation context
- **Invisible overlay** — hidden from screen sharing (Zoom, Meet, Teams can't see it)
- **Hotkeys** — `⌘⇧C` toggle conference mode, `⌘⇧A` generate/dismiss answer
- Configure in Settings → AI → Conference Copilot

### Script Library

- Save, rename, and organize scripts
- Auto-save when starting playback
- Quick-load from the sidebar

### Pages & Sections

- Multi-page scripts with sidebar navigation
- **Split** — auto-splits text by `---` separators or `# Headers`
- Page titles shown in sidebar for easy navigation
- Page counter (e.g. "2/5") in overlay during playback
- Auto-advance to next page when current page finishes

### Import

| Format | Details |
|--------|---------|
| **Files** | `.txt`, `.md`, `.rtf`, `.pptx`, `.flowcue` — open or drag-and-drop |
| **PowerPoint** | Extracts speaker notes from `.pptx` files |
| **URL** | `⌘⇧I` — fetch text from any web page, Notion, or Google Docs |

### Global Hotkeys

| Shortcut | Action |
|----------|--------|
| `⌘⇧Space` | Play / Pause (works from any app) |
| `⌘⇧R` | Reset to beginning |
| `⌘⇧←` | Jump back |
| `⌘⇧A` | Generate AI answer / dismiss (Conference mode) |
| `⌘⇧C` | Toggle Conference mode on/off |

### Live Stats

- Estimated time remaining
- Words per minute (WPM) indicator
- Elapsed time counter

### External Display & Sidecar

- Teleprompter mode on external displays
- Mirror mode for physical prompter rigs (horizontal, vertical, or both axes)
- Hide from screen share (invisible in Zoom / Meet)

### Remote Control

- Control from any device via browser on the same Wi-Fi
- QR code for quick connection
- WebSocket-based real-time sync with full teleprompter view

### Settings Sidebar

- Integrated settings panel — slides out from the left edge of the main window
- Compact icon tab strip with 7 categories: Style, Voice, Display, Screens, Connect, AI, Scripts
- Toggle with the gear button or `⌘,`
- Live preview of overlay changes while adjusting settings

### Customization

- **Font**: Sans, Serif, Mono, OpenDyslexic
- **Size**: XS / SM / LG / XL
- **Highlight color**: White, Yellow, Green, Blue, Pink, Orange
- Adjustable overlay width and height
- Glass effect with opacity control

---

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon or Intel Mac
- Xcode 16+ (to build from source)

## Install

### Download

Grab the latest DMG from [Releases](https://github.com/gcryptonlabs/FlowCue/releases).

### Build from Source

```bash
git clone https://github.com/gcryptonlabs/FlowCue.git
cd FlowCue
open FlowCue.xcodeproj
# ⌘B to build, ⌘R to run
```

### First Launch

If macOS blocks the app:
```bash
xattr -cr /Applications/FlowCue.app
```

---

## Tech Stack

- Swift + SwiftUI + AppKit
- Apple Speech Framework (on-device recognition via Neural Engine)
- whisper.cpp integration (local Whisper model via `whisper-stream`)
- OpenAI Whisper API (cloud transcription)
- NaturalLanguage framework (auto language detection)
- Claude API (AI script expansion + Conference Copilot)
- OpenAI API (Conference Copilot, GPT-4o support)
- AVFoundation (audio capture, format conversion)
- Zero external dependencies
- Sandboxed with minimal permissions

---

## License

MIT

---

**GCRYPTON LABS** — engineered with [OpenClaw](https://github.com/openclaw/openclaw) and Claude Code Opus 4.6 by Anthropic
