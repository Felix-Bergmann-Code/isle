# Security Policy

## Reporting a vulnerability

Please **don't** open a public issue. Report it privately through GitHub instead:
**[Security → Report a vulnerability](https://github.com/Felix-Bergmann-Code/isle/security/advisories/new)**.

You'll get a reply as soon as possible. Once a fix ships, you'll be credited unless you'd rather not be.

## What Isle touches

So you know what to look at:

- **Local hook server**: Isle listens on `127.0.0.1:47823`, loopback only, for agent status events, held approval requests and finished terminal commands. It accepts unauthenticated POSTs from local processes, so any program running as you can show a status or a banner in the island. Requests from web pages (with `Origin` or `Sec-Fetch-Site` headers) are rejected. A dev build started with `ISLE_INSTANCE` listens on 47824 instead.
- **`~/.claude/settings.json`**: only when you click *Settings → Hooks & Scripts → Install*. Isle adds `curl` hook entries and saves a backup as `settings.json.isle-backup`. *Uninstall* removes exactly those entries.
- **`~/.zshrc` and `~/.config/isle/isle.zsh`**: only when you click *Settings → Hooks & Scripts → Terminal commands → Install*. Isle writes the hook script and adds one `source` line (with a backup); *Remove* takes out only that line. The hook posts each finished command line, exit code, duration and folder to the loopback server.
- **Read-only**: Claude Code transcripts in `~/.claude/projects/` (status, context fill, token counts), Codex session files, the process list and listening ports, `git diff --numstat` in the repos your agents work in (without taking locks), the file names and sizes in `~/Downloads` (download progress), and whether the microphone or camera is in use (never the audio or video).
- **Clipboard**: with clipboard history on, what you copy is kept in memory only (never on disk) and cleared on quit. Items marked concealed or transient, and anything copied from a password manager, are skipped.
- **Writes**: the Shelf note to `~/Library/Application Support/Isle/note.txt`. Dev builds also log to `~/Library/Logs/Isle-<instance>.log`.
- **Input on your behalf**: a reply you send from the island is typed into iTerm2 with AppleScript, or pasted into Terminal / the Claude app (Accessibility). In other terminals it's pasted without pressing Return.
- **Network**:
  - the album cover of the current Spotify track, from the artwork URL Spotify provides
  - the weather from [Open-Meteo](https://open-meteo.com): only the city name (to look up its coordinates) and those coordinates are sent
  - with *Checks, pull requests and deploys* on: the GitHub CLI (`gh`) you've signed in to asks GitHub about the branches your agents work on (read-only)
  - health checks to your own dev servers on `127.0.0.1`
- **Camera**: only while the mirror is on screen; it stops when the mirror closes.
- **In the app**: Settings → Privacy & Permissions lists all of the above with the live state of each permission.
- **Permissions**: Automation (Spotify/Music, and Terminal/iTerm2 for replies), Calendar, Bluetooth, Downloads folder, Camera, and optionally Accessibility.
