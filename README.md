<div align="center">

# Isle

**A native Dynamic Island for your Mac's notch.**
Now playing, meetings, AirPods, file shelf, and a live view of every AI coding agent you have running.

[![Build](https://github.com/Felix-Bergmann-Code/isle/actions/workflows/build.yml/badge.svg)](https://github.com/Felix-Bergmann-Code/isle/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

[Website](https://felix-bergmann-code.github.io/isle/) · [Contributing](CONTRIBUTING.md) · [Sister app: Gauge](https://github.com/Felix-Bergmann-Code/gauge)

<br>

<img src="docs/screenshots/agents.png" alt="Isle's Agents tab: three coding agents with their project, branch and status, plus running dev servers" width="100%">

</div>

---

Built with SwiftUI, AppKit and Core Animation. **No dependencies, no network, no telemetry.** The closed island idles at roughly 0% CPU.

## Install

Build from source (takes about a minute):

```bash
git clone https://github.com/Felix-Bergmann-Code/isle.git
cd isle
./scripts/build.sh --install --run   # builds, copies to /Applications and launches
```

Requires **macOS 15+** and **Xcode 16+** (or a Swift 6 toolchain). The script signs with your Apple Development identity if you have one, so macOS remembers permissions across rebuilds. Without one it signs ad-hoc. Drop `--install` to run from `./build` instead.

## What's in the island

| State | What you see |
| --- | --- |
| **Closed** | Blends into the hardware notch (a pill on displays without one). Grows slightly on hover. |
| **Live activity** | Album art + visualizer while music plays, and running agents (avatars + thinking dots + count). When both are active it shows the art and the agents. |
| **HUD** | Volume / brightness level beside the notch. |
| **Banner** | Drops down when an agent finishes or needs you, 5 min before a meeting, and when AirPods or other devices connect. Also shows charging and low battery. |
| **Open** (hover) | Tabs: **Home** (player + calendar), **Agents**, **Shelf**. |

**Gestures:** hover to open, click the notch to open instantly, swipe left/right with two fingers to change tabs, drag files onto the notch to shelve them.

<img src="docs/screenshots/home.png" alt="Home tab: now playing with album art and controls next to today's calendar" width="100%">
<img src="docs/screenshots/shelf.png" alt="Shelf tab: files parked in the notch, with an AirDrop drop zone" width="100%">

**Live activities and banners** while the island is closed:

<img src="docs/screenshots/live-activities.png" alt="Compact music and agent activity, agent done and needs-you banners, a meeting reminder, AirPods connected and the volume HUD" width="100%">

### Agents tab

Detects **Claude Code** (terminal and desktop sessions), **Codex**, **Gemini CLI**, **Cursor Agent**, **Aider**, **opencode**, **Copilot CLI**, **Amp** and **Goose**. For each one you get:

- an animated avatar: bouncing = working, wiggling "!" = needs you, check = done, sleeping = idle
- project, git branch and current activity ("Running a command", "Editing files", "Waiting for approval · Bash")
- click to jump to the hosting app (Ghostty, Cursor, Claude…); hover for "open in editor" and "reveal"
- **Dev servers**: every localhost port started from a project folder, with open/stop buttons

How status is detected, from most to least precise:

1. **Claude Code hooks** (optional, exact and instant): *Settings → Agents → Install*. This adds a silent `curl` to `127.0.0.1:47823` for each hook event in `~/.claude/settings.json` and saves a backup next to it.
2. Claude transcripts in `~/.claude/projects/…/*.jsonl`, tail-parsed.
3. CPU activity of the agent's process tree. This works for every CLI, and Codex adds its session-file activity.

Anything can report itself:

```bash
curl -s -X POST localhost:47823/hook/custom \
  -d '{"id":"deploy","name":"Deploy","phase":"working","detail":"Uploading…"}'
# phase: working | waiting | done | idle | end
```

### Shell control

```bash
scripts/isle open:agents   # open | open:home | open:shelf | toggle | close
```

### Demo mode

`--demo` fills the island with made-up music, meetings, agents, dev servers and shelf files, and doesn't read anything from your Mac. Use it for screenshots and screen recordings (all screenshots here were made with it):

```bash
open build/Isle.app --args --demo
scripts/isle demo:agent    # demo:agent | demo:waiting | demo:meeting | demo:airpods | demo:volume | demo:charging
```

## Performance

- The window is never resized. Only SwiftUI shapes animate, using springs.
- Animations that stay on screen while closed (visualizer, thinking dots, avatar motion) are Core Animation layer animations. They run in the render server, so the closed island uses roughly 0% CPU.
- Agent scanning uses one `sysctl` per tick plus cached classification, and tail-parses transcripts only when their mtime changes. Measured at about 1% CPU with a live activity showing.
- Now Playing uses Spotify's and Music's distributed notifications (push, no polling). The position re-syncs only while the player is visible.

## Permissions

Automation for Spotify/Music (controls and artwork), Calendar, and Bluetooth (connect banners). Accessibility is needed only if you turn on *Replace the system volume & brightness HUD*. See [SECURITY.md](SECURITY.md) for exactly what Isle reads and writes.

## Known limits

- Now Playing covers Spotify and Apple Music. Since macOS 15.4, browser and other media aren't readable without private-API workarounds.
- No lock-screen widgets yet. They need private SkyLight APIs.

## Contributing

PRs are very welcome! Good places to start:

- support for another AI agent or terminal in the Agents tab
- more Now Playing sources
- an app icon 🙂
- testing on notch-less and external displays

Read [CONTRIBUTING.md](CONTRIBUTING.md) to get set up. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Project layout

```
Sources/Isle/
  App/        app entry, settings, island state machine
  Window/     the borderless notch window
  Views/      SwiftUI views (closed, compact, open tabs, settings)
  Services/   media, calendar, system (volume, battery, Bluetooth), shelf
  Agents/     agent detection, process info, ports, the hook server
scripts/      build.sh, isle (shell control)
```

## License

[MIT](LICENSE) © Felix Bergmann and contributors
