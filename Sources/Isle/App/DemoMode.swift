import AppKit
import SwiftUI

/// `Isle --demo` fills the island with made-up data instead of starting the real services,
/// so screenshots and screen recordings never show your music, calendar, projects or files.
/// Nothing is read from or written to your system in this mode (no AppleScript, EventKit,
/// process scanning, hook server or saved shelf).
///
/// Trigger states from the shell while it runs:
///   scripts/isle open:home | open:agents | open:shelf | close
///   scripts/isle demo:agent | demo:waiting | demo:meeting | demo:airpods | demo:volume | demo:charging
enum Demo {
    static let isEnabled = CommandLine.arguments.contains("--demo")

    static func populate(_ env: AppEnvironment) {
        let now = Date()

        env.media.now = NowPlaying(source: .spotify, title: "Midnight Drive", artist: "Neon Coast", album: "Afterglow",
                                   duration: 214, position: 71, positionDate: now, isPlaying: true, trackID: "demo")
        let art = artwork()
        env.media.artwork = art
        env.media.accent = art.vibrantAverageColor().map { Color(nsColor: $0) } ?? .pink

        env.calendar.access = .granted
        let cal = Calendar.current
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        env.calendar.events = [
            CalEvent(id: "d1", title: "Design review", start: at(12), end: at(42), isAllDay: false,
                     color: Color(red: 0.38, green: 0.65, blue: 1), meetingURL: URL(string: "https://example.com/meet")),
            CalEvent(id: "d2", title: "Lunch with Sam", start: at(95), end: at(155), isAllDay: false,
                     color: Color(red: 0.98, green: 0.62, blue: 0.3), meetingURL: nil),
            CalEvent(id: "d3", title: "Ship v1.2", start: cal.startOfDay(for: now), end: cal.startOfDay(for: at(1440)),
                     isAllDay: true, color: Color(red: 0.4, green: 0.85, blue: 0.5), meetingURL: nil),
        ]

        env.agents.sessions = [
            session(1, .claude, "api-server", branch: "feat/auth", phase: .working, detail: "Editing files", host: "Ghostty", age: 14, phaseAge: 3),
            session(2, .codex, "web-app", branch: "main", phase: .waiting, detail: "Waiting for approval · Bash", host: "Cursor", age: 31, phaseAge: 1),
            session(3, .gemini, "docs", branch: "update-guides", phase: .working, detail: "Running a command", host: "Terminal", age: 8, phaseAge: 1),
            session(4, .aider, "ml-pipeline", branch: nil, phase: .done, detail: "Finished", host: "iTerm2", age: 52, phaseAge: 6),
        ]

        env.ports.ports = [
            DevPort(port: 3000, pid: 0, command: "node", project: "web-app"),
            DevPort(port: 5173, pid: 0, command: "vite", project: "docs"),
            DevPort(port: 8000, pid: 0, command: "python3", project: "api-server"),
        ]

        env.shelf.add(urls: shelfFiles())
    }

    static func perform(_ what: String, env: AppEnvironment) {
        switch what {
        case "agent":
            env.vm.flash(.agent(AgentBanner(kind: .claude, phase: .done, title: "api-server is done",
                                            subtitle: "Added OAuth login and tests, all 42 passing")), duration: 8)
        case "waiting":
            env.vm.flash(.agent(AgentBanner(kind: .codex, phase: .waiting, title: "web-app needs you",
                                            subtitle: "Waiting for approval · Bash")), duration: 8)
        case "meeting": env.vm.flash(.meeting(title: "Design review", minutes: 5), duration: 8)
        case "airpods": env.vm.flash(.bluetooth(name: "AirPods Pro", icon: "airpodspro", connected: true), duration: 8)
        case "volume": env.vm.flash(.volume(level: 0.62, muted: false), duration: 8)
        case "charging": env.vm.flash(.charging(level: 78, pluggedIn: true), duration: 8)
        default: break
        }
    }

    private static func session(_ n: Int32, _ kind: AgentKind, _ project: String, branch: String?, phase: AgentPhase,
                                detail: String, host: String, age: Double, phaseAge: Double) -> AgentSession {
        let now = Date()
        return AgentSession(id: "demo-\(n)", pid: 90_000 + n * 7, kind: kind, cwd: "/tmp/\(project)", project: project,
                            branch: branch, hostName: host, hostPID: nil, startedAt: now.addingTimeInterval(-age * 60),
                            phase: phase, phaseSince: now.addingTimeInterval(-phaseAge * 60), detail: detail,
                            lastMessage: nil, isBackground: false, source: "demo", title: nil)
    }

    /// A generated "album cover".
    private static func artwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.62, alpha: 1),
                                NSColor(red: 0.45, green: 0.28, blue: 0.95, alpha: 1)])?.draw(in: r, angle: -55)
            NSColor(white: 1, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 150, width: 90, height: 90)).fill()
            NSColor(red: 0.12, green: 0.06, blue: 0.25, alpha: 0.55).setFill()
            let hills = NSBezierPath()
            hills.move(to: .zero)
            hills.line(to: NSPoint(x: 0, y: 80))
            hills.curve(to: NSPoint(x: 300, y: 110), controlPoint1: NSPoint(x: 90, y: 160), controlPoint2: NSPoint(x: 200, y: 40))
            hills.line(to: NSPoint(x: 300, y: 0))
            hills.close()
            hills.fill()
            return true
        }
    }

    /// Sample files for the shelf, written to a temporary folder.
    private static func shelfFiles() -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("isle-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        let images: [(String, NSColor, NSColor)] = [
            ("Moodboard.png", NSColor(red: 0.2, green: 0.8, blue: 0.7, alpha: 1), NSColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)),
            ("Hero banner.png", NSColor(red: 1, green: 0.6, blue: 0.2, alpha: 1), NSColor(red: 0.9, green: 0.2, blue: 0.5, alpha: 1)),
        ]
        for (name, a, b) in images {
            let url = dir.appendingPathComponent(name)
            let img = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { r in
                NSGradient(colors: [a, b])?.draw(in: r, angle: 35); return true
            }
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                urls.append(url)
            }
        }
        let folder = dir.appendingPathComponent("Brand assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        urls.append(folder)
        return urls
    }
}
