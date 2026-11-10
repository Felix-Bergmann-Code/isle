# Security Policy

## Reporting a vulnerability

Please **don't** open a public issue. Report it privately through GitHub instead:
**[Security → Report a vulnerability](https://github.com/Felix-Bergmann-Code/isle/security/advisories/new)**.

You'll get a reply as soon as possible. Once a fix ships, you'll be credited unless you'd rather not be.

## What Isle touches

So you know what to look at:

- **Local hook server**: Isle listens on `127.0.0.1:47823`, loopback only, for agent status events. It accepts unauthenticated POSTs from local processes, so any program running as you can show a status in the island. Requests from web pages (with `Origin` or `Sec-Fetch-Site` headers) are rejected.
- **`~/.claude/settings.json`**: only when you click *Settings → Agents → Install*. Isle adds `curl` hook entries and saves a backup as `settings.json.isle-backup`. *Uninstall* removes exactly those entries.
- **Read-only**: Claude Code transcripts in `~/.claude/projects/`, Codex session files, the process list and listening ports, all to show agent status. None of this leaves your Mac.
- **Network**: the only outgoing request downloads the album cover of the current Spotify track from the artwork URL that Spotify itself provides (Spotify's CDN). Everything else stays on loopback.
- **Permissions**: Automation (Spotify/Music), Calendar, Bluetooth, and optionally Accessibility.
