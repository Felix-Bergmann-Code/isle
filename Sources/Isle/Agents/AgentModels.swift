import SwiftUI

enum AgentKind: String, CaseIterable, Codable {
    case claude, codex, cursor, gemini, aider, opencode, copilot, amp, goose, custom

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor Agent"
        case .gemini: return "Gemini CLI"
        case .aider: return "Aider"
        case .opencode: return "opencode"
        case .copilot: return "Copilot CLI"
        case .amp: return "Amp"
        case .goose: return "Goose"
        case .custom: return "Agent"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.90, green: 0.52, blue: 0.38)
        case .codex: return Color(red: 0.38, green: 0.82, blue: 0.72)
        case .cursor: return Color(red: 0.62, green: 0.66, blue: 0.98)
        case .gemini: return Color(red: 0.40, green: 0.60, blue: 1.00)
        case .aider: return Color(red: 0.45, green: 0.84, blue: 0.42)
        case .opencode: return Color(red: 0.98, green: 0.80, blue: 0.32)
        case .copilot: return Color(red: 0.74, green: 0.52, blue: 0.98)
        case .amp: return Color(red: 0.98, green: 0.45, blue: 0.62)
        case .goose: return Color(red: 0.70, green: 0.76, blue: 0.84)
        case .custom: return Color(red: 0.85, green: 0.85, blue: 0.85)
        }
    }

    /// Little accessory each creature wears on its head.
    var accessory: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "hexagon.fill"
        case .cursor: return "triangle.fill"
        case .gemini: return "star.fill"
        case .aider: return "leaf.fill"
        case .opencode: return "circle.fill"
        case .copilot: return "airplane"
        case .amp: return "bolt.fill"
        case .goose: return "feather"
        case .custom: return "circle.fill"
        }
    }
}

enum AgentPhase: String, Equatable {
    case working, waiting, done, idle

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .working: return Color(red: 0.45, green: 0.78, blue: 1.0)
        case .waiting: return Color(red: 1.0, green: 0.65, blue: 0.25)
        case .done: return Color(red: 0.40, green: 0.85, blue: 0.50)
        case .idle: return Color.white.opacity(0.4)
        }
    }

    var isActive: Bool { self == .working || self == .waiting }
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let kind: AgentKind
    var cwd: String
    var project: String
    var branch: String?
    var hostName: String?
    var hostPID: pid_t?
    var startedAt: Date
    var phase: AgentPhase
    var phaseSince: Date
    var detail: String
    /// Last thing the agent said (for "done" banners).
    var lastMessage: String?
    var isBackground: Bool
    var source: String // "hooks", "transcript", "cpu"
    /// Session title (Claude Code names sessions), disambiguates sessions in one folder.
    var title: String?
    /// Claude Code session id (the transcript's file name), used to deep-link into the chat.
    var sessionID: String? = nil
    /// How full a Claude session's context window is (last assistant usage), when known.
    var context: ContextFill? = nil

    /// Subagents this session spawned that are running or just finished, oldest first.
    var subagents: [Subagent] = []

    var runningSubagents: Int { subagents.filter(\.isRunning).count }
}

/// A subagent (Agent tool worker) inside a Claude Code session, tracked from hooks that carry `agent_id`.
struct Subagent: Identifiable, Equatable {
    let id: String
    /// Agent type, e.g. "Explore" or "general-purpose".
    var type: String
    /// The task description the parent gave it, when known.
    var label: String?
    var detail: String
    var started: Date
    var lastEvent: Date
    var finishedAt: Date?
    /// Still running after the parent's turn ended.
    var isBackground = false

    var isRunning: Bool { finishedAt == nil }
}

/// A tool call waiting for approval, held open by Isle's PermissionRequest hook.
struct PermissionPrompt: Identifiable, Equatable {
    let id: UUID
    let agentPID: pid_t?
    let sessionID: String?
    /// Set when a subagent, not the main thread, wants the tool.
    var agentID: String? = nil
    var agentType: String? = nil
    let cwd: String
    let tool: String
    /// What the tool is about to do, e.g. the shell command or the file it edits.
    let summary: String
    let created: Date

    var toolLabel: String { AgentScanner.toolShort(tool) }

    /// `deferToApp` hands the decision back to Claude Code's own prompt.
    enum Decision { case allow, deny, deferToApp }

    static func summarize(tool: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let raw: String
        switch tool {
        case "Bash", "PowerShell": raw = str("command") ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            raw = (str("file_path") ?? str("notebook_path")).map { ($0 as NSString).lastPathComponent } ?? ""
        case "WebFetch": raw = str("url") ?? ""
        case "WebSearch": raw = str("query") ?? ""
        default:
            raw = ["command", "url", "path", "file_path", "query", "description", "prompt"]
                .lazy.compactMap(str).first ?? ""
        }
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 220 ? String(collapsed.prefix(220)) + "…" : collapsed
    }
}
