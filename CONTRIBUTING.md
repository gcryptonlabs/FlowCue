# Contributing to FlowCue

Thanks for your interest in contributing to FlowCue! Here's how to get started.

## Getting Started

### Prerequisites

- macOS 15 Sequoia or later
- Xcode 16+
- Apple Silicon or Intel Mac

### Build from Source

```bash
git clone https://github.com/gcryptonlabs/FlowCue.git
cd FlowCue
open FlowCue.xcodeproj
```

Press `Cmd+B` to build, `Cmd+R` to run.

## How to Contribute

### Reporting Bugs

Open an [issue](https://github.com/gcryptonlabs/FlowCue/issues/new?template=bug_report.md) with:

- macOS version and Mac model
- Steps to reproduce
- Expected vs actual behavior
- Screenshots or screen recordings if applicable

### Suggesting Features

Open an [issue](https://github.com/gcryptonlabs/FlowCue/issues/new?template=feature_request.md) describing:

- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

### Submitting Code

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Make your changes
4. Test thoroughly on your Mac
5. Commit with a descriptive message: `feat: add dark mode support`
6. Push to your fork and open a Pull Request

### Commit Messages

We use conventional commit prefixes:

| Prefix | Usage |
|--------|-------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `chore:` | Maintenance, config, dependencies |
| `refactor:` | Code restructuring without behavior change |

### Code Style

- Follow existing Swift conventions in the codebase
- Use SwiftUI for new views
- Keep AppKit usage minimal (only where SwiftUI can't do the job)
- No external dependencies unless absolutely necessary

## Project Structure

```
FlowCue/
  FlowCueApp.swift          # App entry point
  ContentView.swift          # Main editor view
  NotchSettings.swift        # Settings model + enums
  SettingsView.swift         # Settings UI
  SpeechRecognizer.swift     # Speech recognition engine
  NotchOverlayController.swift  # Overlay views (Top Bar, Floating)
  ExternalDisplayController.swift  # External display output
  MarqueeTextView.swift      # Teleprompter text rendering
  FlowCueService.swift       # App services (file import, browser server)
  AIScriptExpander.swift     # Claude API integration
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
