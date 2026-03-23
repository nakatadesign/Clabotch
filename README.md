# Clabotch

**A tiny macOS menu bar mascot that watches over your Claude Code sessions.**

[日本語版 README はこちら](README.ja.md)

Clabotch (クラボッチ) lives in your menu bar as a pixel-art character and reflects the real-time state of [Claude Code](https://claude.ai/code) — thinking, running tools, responding, done, or sleeping. No PNGs. Every frame is drawn in pure Swift. The character itself is 20×14 px, centered within the menu bar slot.

Inspired by two icons from different eras: the dot-art look and color palette of Clawd, Claude Code's terminal-native mascot, and the gaze of Eyeballs, the beloved 68K Classic Macintosh desk accessory that watched from the Apple menu. Clabotch carries both forward — a tiny pair of eyes that knows what you're building.

![Clabotch in menu bar](screenshot.gif)

---

## What it does

| Claude Code state | Clabotch                                                  |
| ----------------- | --------------------------------------------------------- |
| Idle              | Eyes resting, gaze down-right                             |
| Thinking          | Still face, gentle nod                                    |
| Responding        | Eyes scanning, _"Working…"_ bubble                        |
| Running a tool    | Tool-specific bubble (e.g. _"Running command…"_ for Bash) |
| Done              | Rainbow spin + jump + _"Done! (3 min 42 sec)"_            |
| Error             | Shake animation + _"An error occurred…"_                  |
| Sleeping          | Eyes closed                                               |

> 💬 Bubble text is localised. English and Japanese are supported out of the box; English is the fallback.

Events arrive via Claude Code hooks → Unix domain socket → `HookServer` → `StateMachine`. No polling of Claude Code internals, no network calls.

---

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ / Swift 5.9+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- `jq` (`brew install jq`) — used by the hook scripts
- [Claude Code](https://claude.ai/code) with hooks support

---

## Quick Start

### 1. Build

```bash
git clone https://github.com/nakatadesign/clabotch.git
cd clabotch/src
xcodegen generate
xcodebuild build \
  -project Clabotch.xcodeproj \
  -scheme Clabotch \
  -destination 'platform=macOS' \
  -derivedDataPath build
```

### 2. Install

```bash
cp -R build/Build/Products/Debug/Clabotch.app /Applications/
open /Applications/Clabotch.app
```

On first launch, Clabotch will ask for **Accessibility permission** (required for the gaze-tracking feature that follows your terminal window). The mascot works without it — you'll just get a fixed gaze.

### 3. Connect Claude Code hooks

Copy the hook scripts to your global Claude Code hooks directory:

```bash
mkdir -p ~/.claude/hooks
cp hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

Then add the following entries to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_pre_tool.sh" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_post_tool.sh" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_post_tool_failure.sh" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_stop.sh" }] }]
  }
}
```

Restart Claude Code. Clabotch should spring to life the next time Claude starts working.

---

## How it works

```
Claude Code hooks (stdin JSON)
  └─ Unix domain socket  ($TMPDIR/clabotch/clabotch.sock)
       └─ HookServer
            └─ LineBufferedEventDecoder  (per-connection)
                 └─ EventParser  (pure function)
                      └─ DispatchQueue.main
                           ├─ EventDeduplicator
                           └─ StateMachine
                                ├─ ClabotchEyeView   — pixel-art face, drawn in Swift
                                ├─ BlinkController   — randomised blink timer
                                ├─ GazeController    — tracks your terminal window via AX API
                                └─ BubbleWindow      — speech-bubble overlay
```

Zero PNG assets. The 14-frame animation is rendered entirely with Core Graphics at runtime.  
Thread model: all UI and state updates are confined to the main thread; `LineBufferedEventDecoder` runs on a per-connection serial queue.

---

## Running tests

```bash
# Kill any running instance first (HookServer socket conflict)
pkill -9 -f Clabotch; sleep 2

cd src
xcodebuild test \
  -project Clabotch.xcodeproj \
  -scheme Clabotch \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  2>&1 | tail -30
```

Expected: **361 tests — 360 passed, 1 skipped**.

---

## Project layout

```
clabotch/
├── src/                    # Xcode project (Swift, AppKit)
│   └── Clabotch/           # App source
│       ├── ClabotchEyeView.swift    # Core pixel-art renderer
│       ├── StateMachine.swift       # Phase transitions
│       ├── HookServer.swift         # Unix domain socket server
│       ├── GazeController.swift     # AX-based terminal tracking
│       └── CoordinatorBinder.swift  # Wires StateMachine → UI
├── hooks/                  # Claude Code hook scripts (copy to ~/.claude/hooks/)
└── docs/                   # Screenshots and documentation
```

---

## Settings

Launch the app's **Settings** panel (⌘,) to configure:

- **Animation speed** — adjust the playback rate of all animations
- **Launch at login** — start Clabotch automatically on login
- **Accessibility status** — shows whether gaze-tracking is active

---

## Troubleshooting

**Clabotch doesn't react to Claude Code**  
Check that the hooks are installed and executable (`ls -la ~/.claude/hooks/`), and that the four entries appear in `~/.claude/settings.json`.

**Gaze tracking not working**  
Open _System Settings → Privacy & Security → Accessibility_ and make sure Clabotch is listed and checked. If it appears greyed out or missing, remove the entry and re-grant permission from the onboarding dialog.

**Tests failing with "address already in use"**  
Run `pkill -9 -f Clabotch` before the test command. A running instance holds the socket.

---

## Contributing

Issues and pull requests are welcome.  
Please open an issue to discuss significant changes before submitting a PR.

```bash
# Recommended pre-commit check
cd src && pkill -9 -f Clabotch; sleep 1 && \
  xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch \
    -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -10
```

---

## License

MIT — see [LICENSE](LICENSE).
