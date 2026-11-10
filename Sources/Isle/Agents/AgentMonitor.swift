import AppKit
import Observation

/// Publishes the list of coding agents running on this Mac.
///
/// Three signal sources, most to least precise:
///  1. Claude Code hooks posted to the local HookServer (exact, instant)
///  2. Claude Code transcripts (~/.claude/projects/…/*.jsonl), tail-parsed
///  3. CPU activity of the agent process tree (works for every CLI agent)
@Observable
final class AgentMonitor {
    var sessions: [AgentSession] = []

    var visibleSessions: [AgentSession] {
        let showBG = AppSettings.shared.showBackgroundAgents
        return sessions.filter { !$0.isBackground || showBG || $0.phase.isActive }
    }
    var activeSessions: [AgentSession] { visibleSessions.filter { $0.phase.isActive } }
    var activeCount: Int { activeSessions.count }
    var needsAttention: Bool { sessions.contains { $0.phase == .waiting } }
    var hooksSeen = false

    @ObservationIgnored var onTransition: ((AgentSession, AgentPhase) -> Void)?
    @ObservationIgnored private let queue = DispatchQueue(label: "isle.agents", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private let scanner = AgentScanner()
    @ObservationIgnored private var workingSince: [String: Date] = [:]

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 1.5, leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func ingestHook(source: String, pid: pid_t?, payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.scanner.ingest(source: source, pid: pid, payload: payload)
            self.tick()
            DispatchQueue.main.async { self.hooksSeen = true }
        }
    }

    private func tick() {
        let result = scanner.scan()
        DispatchQueue.main.async { [weak self] in self?.apply(result) }
    }

    private func apply(_ new: [AgentSession]) {
        let old = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in new {
            if s.phase == .working, workingSince[s.id] == nil { workingSince[s.id] = s.phaseSince }
            guard let o = old[s.id], o.phase != s.phase else { continue }
            if s.phase == .waiting {
                onTransition?(s, .waiting)
            } else if s.phase == .done, o.phase == .working || o.phase == .waiting {
                let since = workingSince[s.id] ?? o.phaseSince
                if Date().timeIntervalSince(since) >= 6 { onTransition?(s, .done) }
            }
            if s.phase != .working { workingSince[s.id] = nil }
        }
        if new != sessions { sessions = new }
    }

    // MARK: Actions

    func focus(_ s: AgentSession) {
        if let pid = s.hostPID, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    func openInEditor(_ s: AgentSession) {
        let url = URL(fileURLWithPath: s.cwd)
        let editors = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed"] // Cursor, VS Code, Zed
        for id in editors {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ s: AgentSession) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd)
    }
}

// MARK: - Scanner (runs on the agents queue only)

final class AgentScanner {
    private struct Classified {
        let start: UInt64
        let kind: AgentKind?
        let background: Bool
        let args: [String]
    }

    private struct Track {
        var lastCPU: UInt64 = 0
        var lastSample: UInt64 = 0
        var lastActive: Date?
        var phase: AgentPhase = .idle
        var phaseSince = Date()
        var cwd = ""
        var cwdChecked = Date.distantPast
        var hostName: String?
        var hostPID: pid_t?
        var hostResolved = false
        var lastMessage: String?
    }

    struct HookState {
        var phase: AgentPhase
        var detail: String
        var date: Date
        var message: String?
    }

    private struct CustomAgent {
        var name: String
        var cwd: String
        var state: HookState
        var started: Date
    }

    private struct TranscriptTail {
        var mtime: Date
        var lastType: String
        var toolName: String?
        var text: String?
        var stopReason: String?
        var interrupted: Bool
        var pendingRequest: Bool
        var title: String?
    }

    private var classified: [pid_t: Classified] = [:]
    private var tracks: [pid_t: Track] = [:]
    private var hookByPID: [pid_t: HookState] = [:]
    private var hookByCwd: [String: HookState] = [:]
    private var hookTranscript: [pid_t: URL] = [:]
    private var custom: [String: CustomAgent] = [:]
    private var branchCache: [String: (branch: String?, at: Date)] = [:]
    private var tailCache: [URL: TranscriptTail] = [:]
    private var knownTitles: [URL: String] = [:]
    private var transcriptFor: [pid_t: URL] = [:]
    private var lastInfos: [pid_t: ProcInfo.BSD] = [:]
    private var codexCache: (at: Date, cwds: [String: Date]) = (.distantPast, [:])
    private var codexCwdOfFile: [URL: String] = [:]

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private lazy var claudeProjects = home.appendingPathComponent(".claude/projects")

    // MARK: Scan

    func scan() -> [AgentSession] {
        let now = Date()
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let uid = getuid()

        var infos: [pid_t: ProcInfo.BSD] = [:]
        infos.reserveCapacity(800)
        for b in ProcInfo.userProcesses(uid: uid) where b.pid > 1 { infos[b.pid] = b }
        lastInfos = infos

        var agentPIDs: [pid_t: (AgentKind, Bool)] = [:]
        for (pid, b) in infos {
            if let c = classified[pid], c.start == b.startSec {
                if let k = c.kind { agentPIDs[pid] = (k, c.background) }
                continue
            }
            var args: [String] = []
            var result: (AgentKind, Bool)?
            if let path = ProcInfo.path(pid) {
                result = Self.classify(path: path) {
                    if args.isEmpty { args = ProcInfo.arguments(pid) }
                    return args
                }
            }
            if result != nil, args.isEmpty { args = ProcInfo.arguments(pid) }
            classified[pid] = Classified(start: b.startSec, kind: result?.0, background: result?.1 ?? false, args: args)
            if let r = result { agentPIDs[pid] = r }
        }
        classified = classified.filter { infos[$0.key] != nil }
        tracks = tracks.filter { infos[$0.key] != nil }
        transcriptFor = transcriptFor.filter { infos[$0.key] != nil }
        hookByPID = hookByPID.filter { infos[$0.key] != nil }
        hookTranscript = hookTranscript.filter { infos[$0.key] != nil }

        var children: [pid_t: [pid_t]] = [:]
        for (pid, b) in infos { children[b.ppid, default: []].append(pid) }

        func hasAgentAncestor(_ pid: pid_t, _ kind: AgentKind) -> Bool {
            var p = infos[pid]?.ppid ?? 0
            var depth = 0
            while p > 1 && depth < 16 {
                if agentPIDs[p]?.0 == kind { return true }
                p = infos[p]?.ppid ?? 0
                depth += 1
            }
            return false
        }

        let roots = agentPIDs
            .filter { !hasAgentAncestor($0.key, $0.value.0) }
            .sorted { (infos[$0.key]?.startSec ?? 0) < (infos[$1.key]?.startSec ?? 0) }

        let codexActivity = roots.contains { $0.value.0 == .codex } ? codexActiveCwds(now) : [:]
        var out: [AgentSession] = []

        // Refresh working directories first: transcript assignment needs them.
        for (pid, _) in roots {
            var t = tracks[pid] ?? Track()
            if now.timeIntervalSince(t.cwdChecked) > 8 || t.cwd.isEmpty {
                t.cwd = ProcInfo.cwd(pid) ?? t.cwd
                t.cwdChecked = now
            }
            tracks[pid] = t
        }

        // Assign each Claude process its own transcript. Exact matches (hook-reported
        // transcript_path, --resume/--session-id) win; the rest go newest-process-first,
        // so a stale process in the same folder can't steal the active session.
        var claimed = Set<String>() // standardized paths
        var assigned: [pid_t: URL] = [:]
        let claudeRoots = roots.filter { $0.value.0 == .claude }.map(\.key)
        for pid in claudeRoots {
            if let u = exactTranscript(pid: pid, cwd: tracks[pid]?.cwd ?? ""), !claimed.contains(u.standardizedFileURL.path) {
                assigned[pid] = u
                claimed.insert(u.standardizedFileURL.path)
            }
        }
        // A session file belongs to the process that started most recently before the
        // file was created. Matching on creation time keeps two sessions in one folder apart.
        let byCwd = Dictionary(grouping: claudeRoots.filter { assigned[$0] == nil }, by: { tracks[$0]?.cwd ?? "" })
        for (cwd, pids) in byCwd where !cwd.isEmpty {
            let starts = Dictionary(uniqueKeysWithValues: pids.map { ($0, Date(timeIntervalSince1970: TimeInterval(infos[$0]?.startSec ?? 0))) })
            let earliest = starts.values.min() ?? now
            var free = Set(pids)
            for f in transcripts(in: cwd, modifiedSince: earliest.addingTimeInterval(-5))
            where !claimed.contains(f.url.standardizedFileURL.path) {
                guard let owner = free
                    .filter({ starts[$0]! <= f.created.addingTimeInterval(5) })
                    .max(by: { starts[$0]! < starts[$1]! }) else { continue }
                assigned[owner] = f.url
                claimed.insert(f.url.standardizedFileURL.path)
                free.remove(owner)
            }
            // Resumed sessions (file older than the process): newest unclaimed file written since start.
            for pid in free.sorted(by: { starts[$0]! > starts[$1]! }) {
                if let u = transcriptURL(pid: pid, cwd: cwd, started: starts[pid]!, claimed: &claimed) { assigned[pid] = u }
            }
        }
        let cwdsWithActiveClaude = Set(claudeRoots.compactMap { pid in
            assigned[pid] != nil || hookByPID[pid] != nil ? tracks[pid]?.cwd : nil
        })

        for (pid, value) in roots {
            let (kind, background) = value
            guard let info = infos[pid] else { continue }
            var t = tracks[pid] ?? Track()
            let started = Date(timeIntervalSince1970: TimeInterval(info.startSec))

            // CPU of the whole process tree (tools run as children).
            var total: UInt64 = 0
            var stack = [pid]
            var visited = 0
            while let p = stack.popLast(), visited < 256 {
                visited += 1
                total &+= ProcInfo.cpuNanos(p) ?? 0
                stack.append(contentsOf: children[p] ?? [])
            }
            var cpuPct = 0.0
            if t.lastSample > 0, total >= t.lastCPU, nowNs > t.lastSample {
                cpuPct = Double(total - t.lastCPU) / Double(nowNs - t.lastSample) * 100
            }
            t.lastCPU = total
            t.lastSample = nowNs
            if cpuPct > 2.5 { t.lastActive = now }

            if !t.hostResolved {
                (t.hostName, t.hostPID) = hostApp(for: pid, infos: infos)
                t.hostResolved = true
            }

            // --- Phase resolution ---
            let recentCPU = t.lastActive.map { now.timeIntervalSince($0) < 4 } ?? false
            var phase: AgentPhase
            var detail: String
            var source = "cpu"
            var message = t.lastMessage

            // CPU heuristic: tolerate quiet gaps (waiting on the model) before calling it done.
            var lastActive = t.lastActive
            if kind == .codex, let d = codexActivity[t.cwd] { lastActive = max(lastActive ?? d, d) }
            let quiet = lastActive.map { now.timeIntervalSince($0) } ?? .infinity
            if quiet < 15 {
                phase = .working; detail = "Working…"
            } else if t.phase == .working || (t.phase == .done && now.timeIntervalSince(t.phaseSince) < 120) {
                phase = .done; detail = "Finished"
            } else {
                phase = .idle; detail = "Ready"
            }

            var tailDate = Date.distantPast
            var title: String?
            let hook = kind == .claude ? (hookByPID[pid] ?? hookByCwd[t.cwd]) : nil
            if kind == .claude, assigned[pid] == nil, hook == nil {
                // A working Claude session always writes its transcript. No transcript of its
                // own means this process is idle — and if another Claude process owns this
                // folder's session, it's a stale duplicate: hide it.
                if cwdsWithActiveClaude.contains(t.cwd) { tracks[pid] = t; continue }
                phase = .idle; detail = "Ready"
            }
            if kind == .claude,
               let url = assigned[pid],
               let tail = tail(of: url) {
                tailDate = tail.mtime
                title = tail.title
                let sub = subActivity(for: url)
                (phase, detail, message) = interpret(tail, recentCPU: recentCPU, subagentActive: sub.map { now.timeIntervalSince($0) < 8 } ?? false, now: now)
                if phase == .done, t.phase == .done { /* keep phaseSince */ }
                source = "transcript"
            }

            if let h = hook, h.date >= tailDate.addingTimeInterval(-1.5) {
                phase = h.phase
                detail = h.detail
                if let m = h.message { message = m }
                source = "hooks"
                if phase == .waiting, recentCPU, now.timeIntervalSince(h.date) > 3 {
                    phase = .working; detail = "Running a tool"
                }
                if phase == .done, now.timeIntervalSince(h.date) > 120 { phase = .idle; detail = "Ready" }
            }

            if phase != t.phase {
                t.phase = phase
                t.phaseSince = now
            }
            t.lastMessage = message
            tracks[pid] = t

            out.append(AgentSession(
                id: "\(pid)-\(info.startSec)",
                pid: pid,
                kind: kind,
                cwd: t.cwd,
                project: (t.cwd.isEmpty || t.cwd == "/") ? (t.hostName.map { "\(kind.name) · \($0)" } ?? kind.name)
                    : (t.cwd as NSString).lastPathComponent,
                branch: t.cwd == "/" ? nil : branch(for: t.cwd, now: now),
                hostName: t.hostName,
                hostPID: t.hostPID,
                startedAt: started,
                phase: phase,
                phaseSince: t.phaseSince,
                detail: detail,
                lastMessage: phase == .done ? message : nil,
                isBackground: background,
                source: source,
                title: title
            ))
        }

        // Agents that report themselves via POST /hook/custom
        custom = custom.filter { now.timeIntervalSince($0.value.state.date) < 15 * 60 }
        for (id, c) in custom {
            out.append(AgentSession(id: "custom-\(id)", pid: 0, kind: .custom, cwd: c.cwd,
                                    project: c.name, branch: branch(for: c.cwd, now: now), hostName: nil, hostPID: nil,
                                    startedAt: c.started, phase: c.state.phase, phaseSince: c.state.date,
                                    detail: c.state.detail, lastMessage: c.state.message, isBackground: false, source: "hooks", title: nil))
        }

        let order: [AgentPhase: Int] = [.waiting: 0, .working: 1, .done: 2, .idle: 3]
        return out.sorted {
            let a = order[$0.phase] ?? 9, b = order[$1.phase] ?? 9
            return a != b ? a < b : $0.startedAt > $1.startedAt
        }
    }

    // MARK: Hooks

    func ingest(source: String, pid: pid_t?, payload: [String: Any]) {
        let now = Date()
        if source == "custom" {
            let id = payload["id"] as? String ?? "default"
            let phase = AgentPhase(rawValue: payload["phase"] as? String ?? "working") ?? .working
            if payload["phase"] as? String == "end" { custom[id] = nil; return }
            let state = HookState(phase: phase, detail: payload["detail"] as? String ?? phase.label, date: now,
                                  message: payload["message"] as? String)
            let started = custom[id]?.started ?? now
            custom[id] = CustomAgent(name: payload["name"] as? String ?? "Agent",
                                     cwd: payload["cwd"] as? String ?? "", state: state, started: started)
            return
        }

        let event = payload["hook_event_name"] as? String ?? ""
        let cwd = payload["cwd"] as? String
        var state: HookState
        switch event {
        case "UserPromptSubmit":
            state = HookState(phase: .working, detail: "Thinking…", date: now)
        case "PreToolUse":
            let tool = payload["tool_name"] as? String ?? "tool"
            if tool == "AskUserQuestion" {
                state = HookState(phase: .waiting, detail: "Has a question for you", date: now)
            } else if tool == "ExitPlanMode" {
                state = HookState(phase: .waiting, detail: "Plan ready for review", date: now)
            } else {
                state = HookState(phase: .working, detail: Self.toolPhrase(tool), date: now)
            }
        case "PostToolUse", "SubagentStop", "PreCompact":
            state = HookState(phase: .working, detail: event == "PreCompact" ? "Compacting context" : "Thinking…", date: now)
        case "Notification":
            let msg = payload["message"] as? String ?? "Needs your attention"
            let lower = msg.lowercased()
            if lower.contains("waiting for your input") {
                state = HookState(phase: .idle, detail: "Ready", date: now)
            } else {
                state = HookState(phase: .waiting, detail: msg, date: now)
            }
        case "Stop":
            state = HookState(phase: .done, detail: "Finished", date: now)
        case "SessionStart":
            state = HookState(phase: .idle, detail: "Ready", date: now)
        case "SessionEnd":
            if let pid { hookByPID[pid] = nil }
            if let cwd { hookByCwd[cwd] = nil }
            return
        default:
            return
        }

        if let pid, let root = agentRoot(from: pid) {
            hookByPID[root] = state
            if let tp = payload["transcript_path"] as? String, !tp.isEmpty {
                hookTranscript[root] = URL(fileURLWithPath: (tp as NSString).expandingTildeInPath)
            }
        } else if let cwd {
            hookByCwd[cwd] = state
        }
    }

    /// Hooks report `$PPID` of the hook shell; walk up to the agent process.
    private func agentRoot(from pid: pid_t) -> pid_t? {
        var p = pid
        for _ in 0..<6 {
            if classified[p]?.kind == .claude { return p }
            guard let b = lastInfos[p] ?? ProcInfo.bsd(p), b.ppid > 1 else { return nil }
            p = b.ppid
        }
        return nil
    }

    // MARK: Classification

    static func classify(path: String, args: () -> [String]) -> (AgentKind, Bool)? {
        let lower = path.lowercased()
        if lower.hasPrefix("/applications/claude.app/") || lower.hasPrefix("/system/") || lower.hasPrefix("/usr/libexec/") {
            return nil
        }
        let name = (lower as NSString).lastPathComponent
        if name == "claude" || lower.contains("/.local/share/claude/versions/") { return (.claude, false) }
        switch name {
        case "codex":
            let a = args()
            return (.codex, a.contains("app-server") || a.contains("mcp-server"))
        case "cursor-agent": return (.cursor, false)
        case "gemini": return (.gemini, false)
        case "aider": return (.aider, false)
        case "opencode": return (.opencode, false)
        case "amp": return (.amp, false)
        case "goose": return (.goose, false)
        case "copilot": return (.copilot, false)
        default: break
        }
        guard ["node", "bun", "deno"].contains(name) || name.hasPrefix("python") else { return nil }
        let a = args().dropFirst().prefix(2).joined(separator: " ").lowercased()
        if a.contains("claude-code") || a.hasSuffix("/bin/claude") { return (.claude, false) }
        if a.contains("@openai/codex") || a.hasSuffix("/bin/codex") { return (.codex, false) }
        if a.contains("gemini-cli") || a.hasSuffix("/bin/gemini") { return (.gemini, false) }
        if a.contains("cursor-agent") { return (.cursor, false) }
        if a.contains("opencode") { return (.opencode, false) }
        if a.contains("@sourcegraph/amp") || a.hasSuffix("/bin/amp") { return (.amp, false) }
        if a.contains("@github/copilot") || a.hasSuffix("/bin/copilot") { return (.copilot, false) }
        if a.contains("/bin/aider") || a.hasSuffix(" -m aider") { return (.aider, false) }
        return nil
    }

    private func hostApp(for pid: pid_t, infos: [pid_t: ProcInfo.BSD]) -> (String?, pid_t?) {
        var p = infos[pid]?.ppid ?? 0
        for _ in 0..<24 {
            guard p > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return (app.localizedName, p)
            }
            p = infos[p]?.ppid ?? 0
        }
        return (nil, nil)
    }

    private func branch(for cwd: String, now: Date) -> String? {
        guard !cwd.isEmpty else { return nil }
        if let c = branchCache[cwd], now.timeIntervalSince(c.at) < 10 { return c.branch }
        var dir = URL(fileURLWithPath: cwd)
        var result: String?
        for _ in 0..<8 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                var headURL = git.appendingPathComponent("HEAD")
                if !isDir.boolValue, let s = try? String(contentsOf: git, encoding: .utf8),
                   let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    let gd = String(line.dropFirst(8))
                    headURL = URL(fileURLWithPath: gd, relativeTo: dir).appendingPathComponent("HEAD")
                }
                if let head = try? String(contentsOf: headURL, encoding: .utf8) {
                    let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst(16)) : String(h.prefix(7))
                }
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        branchCache[cwd] = (result, now)
        return result
    }

    // MARK: Claude transcripts

    private func projectDir(for cwd: String) -> URL {
        let name = String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        return claudeProjects.appendingPathComponent(name)
    }

    /// Transcript known for certain: reported by a hook, or named on the command line.
    private func exactTranscript(pid: pid_t, cwd: String) -> URL? {
        if let u = hookTranscript[pid] { return u }
        guard !cwd.isEmpty else { return nil }
        let args = classified[pid]?.args ?? []
        for (i, a) in args.enumerated() {
            var id: String?
            for flag in ["--session-id", "--resume", "-r"] {
                if a == flag, i + 1 < args.count { id = args[i + 1] }
                else if a.hasPrefix(flag + "=") { id = String(a.dropFirst(flag.count + 1)) }
            }
            if let id, !id.hasPrefix("-") {
                let u = projectDir(for: cwd).appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    private func transcriptURL(pid: pid_t, cwd: String, started: Date, claimed: inout Set<String>) -> URL? {
        guard !cwd.isEmpty else { return nil }
        let dir = projectDir(for: cwd)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        let candidates = files
            .filter { $0.pathExtension == "jsonl" && !claimed.contains($0.standardizedFileURL.path) }
            .compactMap { u -> (URL, Date)? in
                guard let d = try? u.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
                return (u, d)
            }
            .filter { $0.1 >= started.addingTimeInterval(-5) }
            .sorted { $0.1 > $1.1 }
        guard let pick = candidates.first?.0 else { return nil }
        claimed.insert(pick.standardizedFileURL.path)
        transcriptFor[pid] = pick
        return pick
    }

    private struct TranscriptFile { let url: URL; let modified: Date; let created: Date }

    /// Session files in a project folder written since `since`, newest first.
    private func transcripts(in cwd: String, modifiedSince since: Date) -> [TranscriptFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: projectDir(for: cwd),
                                                                        includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { u -> TranscriptFile? in
            guard u.pathExtension == "jsonl", let v = try? u.resourceValues(forKeys: keys),
                  let m = v.contentModificationDate, m >= since else { return nil }
            return TranscriptFile(url: u, modified: m, created: v.creationDate ?? m)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Newest mtime among a session's side files (subagent transcripts, tool output).
    private func subActivity(for transcript: URL) -> Date? {
        let dir = transcript.deletingPathExtension()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return nil }
        var newest: Date?
        var n = 0
        for case let u as URL in e {
            n += 1
            if n > 200 { break }
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                newest = max(newest ?? d, d)
            }
        }
        return newest
    }

    private func tail(of url: URL) -> TranscriptTail? {
        guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        if let c = tailCache[url], c.mtime == mtime { return c }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        for chunk: UInt64 in [64 * 1024, 512 * 1024] {
            let offset = size > chunk ? size - chunk : 0
            try? fh.seek(toOffset: offset)
            guard let data = try? fh.readToEnd() else { return nil }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            if var t = parseTail(lines: lines, mtime: mtime) {
                if t.title == nil { t.title = tailCache[url]?.title ?? knownTitles[url] }
                if let title = t.title { knownTitles[url] = title }
                tailCache[url] = t
                if tailCache.count > 64 { tailCache.removeAll() }
                return t
            }
            if offset == 0 { break }
        }
        return nil
    }

    private func parseTail(lines: [Data.SubSequence], mtime: Date) -> TranscriptTail? {

        var pending = false
        // Session title: latest custom-title/agent-name entry anywhere in the chunk.
        var title: String?
        for line in lines.reversed() where line.count < 4096 {
            let small = String(decoding: line, as: UTF8.self)
            guard small.contains("\"type\":\"custom-title\"") || small.contains("\"type\":\"agent-name\""),
                  let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let t = (o["customTitle"] ?? o["agentName"]) as? String, !t.isEmpty else { continue }
            title = t
            break
        }
        for line in lines.reversed() {
            // Cheap prefilter before JSON-parsing (lines can be hundreds of KB).
            // The top-level "type" key sits near the start for user lines and near the
            // end (after the message body) for assistant lines, so look at both ends.
            if line.count >= 4096 {
                let ends = String(decoding: line.prefix(600), as: UTF8.self) + String(decoding: line.suffix(800), as: UTF8.self)
                guard ends.contains("\"type\":\"user\"") || ends.contains("\"type\":\"assistant\"")
                        || ends.contains("\"type\":\"api-request\"") else { continue }
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "api-request" { pending = true; continue }
            guard type == "user" || type == "assistant" else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            let msg = obj["message"] as? [String: Any] ?? [:]
            var tool: String?
            var text: String?
            var interrupted = false
            if let s = msg["content"] as? String {
                text = s
            } else if let arr = msg["content"] as? [[String: Any]] {
                for item in arr {
                    switch item["type"] as? String {
                    case "tool_use": tool = item["name"] as? String
                    case "text": text = item["text"] as? String
                    default: break
                    }
                }
                if type == "assistant", let last = arr.last, last["type"] as? String == "text" { tool = nil }
            }
            if type == "user", let t = text, t.contains("[Request interrupted") { interrupted = true }
            return TranscriptTail(mtime: mtime, lastType: type, toolName: tool,
                                  text: text.map(Self.snippet), stopReason: msg["stop_reason"] as? String,
                                  interrupted: interrupted, pendingRequest: pending, title: title)
        }
        return nil
    }

    private func interpret(_ t: TranscriptTail, recentCPU: Bool, subagentActive: Bool, now: Date) -> (AgentPhase, String, String?) {
        let age = now.timeIntervalSince(t.mtime)
        if t.interrupted { return (.idle, "Interrupted", nil) }
        switch t.lastType {
        case "user":
            return age < 600 || recentCPU ? (.working, "Thinking…", nil) : (.idle, "Ready", nil)
        case "assistant":
            if t.pendingRequest && age < 600 { return (.working, "Thinking…", nil) }
            if let tool = t.toolName {
                if tool == "AskUserQuestion" { return (.waiting, "Has a question for you", nil) }
                if tool == "ExitPlanMode" { return (.waiting, "Plan ready for review", nil) }
                // A pending tool call is either running or waiting for permission; the transcript
                // can't tell which (quiet commands look identical). The Notification hook reports
                // real permission prompts, so the transcript alone never claims "needs you".
                if recentCPU || subagentActive || age < 1800 { return (.working, Self.toolPhrase(tool), nil) }
                return (.idle, "Ready", nil)
            }
            if t.stopReason == nil && age < 4 { return (.working, "Writing…", nil) }
            return age < 120 ? (.done, "Finished", t.text) : (.idle, "Ready", nil)
        default:
            return (.idle, "Ready", nil)
        }
    }

    static func toolShort(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") { return tool.split(separator: "_").last.map(String.init) ?? tool }
        return tool
    }

    static func toolPhrase(_ tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "PowerShell": return "Running a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing files"
        case "Read": return "Reading files"
        case "Grep", "Glob", "LS": return "Searching the codebase"
        case "WebFetch", "WebSearch": return "Browsing the web"
        case "Task", "Agent": return "Running subagents"
        case "TodoWrite": return "Planning"
        default:
            if tool.hasPrefix("mcp__") { return "Using \(toolShort(tool))" }
            return "Using \(tool)"
        }
    }

    private static func snippet(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 160 ? String(collapsed.prefix(160)) + "…" : collapsed
    }

    // MARK: Codex

    /// cwd → last write time of Codex rollout files touched recently.
    private func codexActiveCwds(_ now: Date) -> [String: Date] {
        if now.timeIntervalSince(codexCache.at) < 1.2 { return codexCache.cwds }
        var result: [String: Date] = [:]
        let cal = Calendar.current
        for dayOffset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(d) < 60 else { continue }
                let cwd = codexCwdOfFile[f] ?? Self.codexCwd(f)
                codexCwdOfFile[f] = cwd
                if let cwd { result[cwd] = max(result[cwd] ?? d, d) }
            }
        }
        codexCache = (now, result)
        return result
    }

    private static func codexCwd(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 64 * 1024),
              let line = data.split(separator: 0x0A).first,
              let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return nil }
        let payload = obj["payload"] as? [String: Any]
        return payload?["cwd"] as? String ?? obj["cwd"] as? String
    }
}
