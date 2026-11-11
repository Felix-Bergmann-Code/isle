import AppKit
import Observation
import SwiftUI

/// Uncommitted changes in a git repo: tracked edits against HEAD (staged or not) plus new files.
struct RepoDiff: Equatable {
    struct File: Equatable {
        let path: String
        let added: Int
        let removed: Int
        let binary: Bool
    }

    var added = 0
    var removed = 0
    /// Tracked files, most-changed first.
    var files: [File] = []
    /// Untracked, not ignored.
    var newCount = 0
    /// The first few untracked paths (enough for the tooltip), in git's order.
    var newFiles: [String] = []

    var isEmpty: Bool { files.isEmpty && newCount == 0 }
}

/// How much each visible agent has changed in its repo, so you can tell at a glance before
/// switching to it. One entry per repo (agents sharing a checkout share the numbers).
///
/// Refreshes when a session in the repo appears or changes phase, every 20 s while one of them
/// is working, and when the Agents tab opens; never for repos without a visible session. git runs
/// on a background queue with a timeout and `GIT_OPTIONAL_LOCKS=0`, so it never takes the index
/// lock while the agent itself is committing.
@Observable
final class DiffService {
    static let shared = DiffService()

    /// Keyed by repo top level.
    private(set) var diffs: [String: RepoDiff] = [:]

    /// cwd → repo top level (nil: not a repo). Main thread only.
    @ObservationIgnored private var repoOfCwd: [String: (repo: String?, at: Date)] = [:]
    @ObservationIgnored private var resolving = Set<String>()
    @ObservationIgnored private var signature: [String: String] = [:]
    @ObservationIgnored private var lastRefresh: [String: Date] = [:]
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var visibleRepos = Set<String>()
    @ObservationIgnored private var workingRepos = Set<String>()
    @ObservationIgnored private var current: (enabled: Bool, sessions: [AgentSession], lookingAtAgents: Bool) = (false, [], false)
    @ObservationIgnored private var wasLooking = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var agents: AgentMonitor?
    @ObservationIgnored private weak var vm: IslandViewModel?
    @ObservationIgnored private let queue = DispatchQueue(label: "isle.diffs", qos: .utility)

    private static let workingInterval: TimeInterval = 20
    /// A folder that wasn't a repo is checked again after this long (agents run `git init`).
    private static let notRepoRetry: TimeInterval = 60

    func start(agents: AgentMonitor, vm: IslandViewModel) {
        self.agents = agents
        self.vm = vm
        observe()
    }

    /// The diff for a session's repo, or nil when there's nothing uncommitted.
    func diff(for s: AgentSession) -> RepoDiff? {
        guard let repo = repo(for: s), let d = diffs[repo], !d.isEmpty else { return nil }
        return d
    }

    func repo(for s: AgentSession) -> String? { repoOfCwd[s.cwd]?.repo ?? nil }

    // MARK: Scheduling (main thread)

    /// Re-runs `sync` whenever the sessions, the setting or the open tab change.
    /// Only the inputs are read under tracking, so publishing `diffs` doesn't re-trigger it.
    private func observe() {
        guard let agents, let vm else { return }
        current = withObservationTracking {
            (AppSettings.shared.showAgentDiffs, agents.visibleSessions, vm.isOpen && vm.tab == .agents)
        } onChange: {
            DispatchQueue.main.async { DiffService.shared.observe() }
        }
        sync()
    }

    private func sync() {
        let (enabled, sessions, lookingAtAgents) = current
        guard enabled else {
            timer?.invalidate(); timer = nil
            signature = [:]; visibleRepos = []; workingRepos = []
            if !diffs.isEmpty { diffs = [:] }
            return
        }

        let now = Date()
        var byRepo: [String: [AgentSession]] = [:]
        for s in sessions where !s.cwd.isEmpty {
            if let known = repoOfCwd[s.cwd], known.repo != nil || now.timeIntervalSince(known.at) < Self.notRepoRetry {
                if let repo = known.repo { byRepo[repo, default: []].append(s) }
            } else {
                resolve(s.cwd)
            }
        }

        visibleRepos = Set(byRepo.keys)
        workingRepos = Set(byRepo.filter { $0.value.contains { $0.phase == .working } }.keys)
        for repo in signature.keys where !visibleRepos.contains(repo) { signature[repo] = nil; lastRefresh[repo] = nil }
        if diffs.keys.contains(where: { !visibleRepos.contains($0) }) {
            diffs = diffs.filter { visibleRepos.contains($0.key) }
        }

        // Opening the Agents tab catches commits made while nothing changed phase.
        let justOpened = lookingAtAgents && !wasLooking
        wasLooking = lookingAtAgents
        for (repo, list) in byRepo {
            let sig = list.map { "\($0.id):\($0.phase.rawValue)" }.sorted().joined(separator: ",")
            let fresh = lastRefresh[repo].map { now.timeIntervalSince($0) < 10 } ?? false
            if signature[repo] != sig || (justOpened && !fresh) {
                signature[repo] = sig
                refresh(repo)
            }
        }

        if workingRepos.isEmpty {
            timer?.invalidate(); timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: Self.workingInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                for repo in self.workingRepos { self.refresh(repo) }
            }
            t.tolerance = 4
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func resolve(_ cwd: String) {
        guard resolving.insert(cwd).inserted else { return }
        queue.async { [weak self] in
            let top = Git.run(["rev-parse", "--show-toplevel"], in: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolving.remove(cwd)
                self.repoOfCwd[cwd] = (top.flatMap { $0.isEmpty ? nil : $0 }, Date())
                self.sync()
            }
        }
    }

    private func refresh(_ repo: String) {
        guard visibleRepos.contains(repo), inFlight.insert(repo).inserted else { return }
        lastRefresh[repo] = Date()
        queue.async { [weak self] in
            let d = Self.read(repo)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(repo)
                guard self.visibleRepos.contains(repo), AppSettings.shared.showAgentDiffs else { return }
                if let d, self.diffs[repo] != d { self.diffs[repo] = d }
            }
        }
    }

    // MARK: git (background queue)

    private static func read(_ repo: String) -> RepoDiff? {
        let flags = ["-c", "core.quotepath=off", "diff", "--numstat", "--no-renames", "--ignore-submodules", "--no-ext-diff"]
        // A repo without commits has no HEAD; compare the index against the empty tree instead.
        guard let numstat = Git.run(flags + ["HEAD"], in: repo) ?? Git.run(flags + ["--cached"], in: repo) else { return nil }
        var d = RepoDiff()
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let a = Int(parts[0]), r = Int(parts[1])
            d.files.append(.init(path: String(parts[2]), added: a ?? 0, removed: r ?? 0, binary: a == nil))
            d.added += a ?? 0
            d.removed += r ?? 0
        }
        d.files.sort { ($0.added + $0.removed) > ($1.added + $1.removed) }
        if let others = Git.run(["-c", "core.quotepath=off", "ls-files", "--others", "--exclude-standard"], in: repo) {
            let lines = others.split(separator: "\n")
            d.newCount = lines.count
            d.newFiles = lines.prefix(AgentDiffLabel.maxRows).map(String.init)
        }
        return d
    }

    // MARK: Opening

    /// Git clients that open a repo folder handed to them, in order of preference.
    private static let gitClients = [
        "com.DanPristupov.Fork", "com.fournova.Tower3", "com.github.GitHubClient",
        "com.torusknot.SourceTreeNotMAS", "co.gitup.mac", "com.sublimemerge",
    ]

    /// Opens the session's repo in an installed git client, else in the editor.
    func review(_ s: AgentSession, monitor: AgentMonitor) {
        if let repo = repo(for: s),
           let app = Self.gitClients.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.open([URL(fileURLWithPath: repo)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            monitor.openInEditor(s)
        }
    }
}

/// Runs git without ever triggering the "install command line tools" prompt.
enum Git {
    /// Homebrew's git, else the developer tools' own copy if they're installed. Never
    /// `/usr/bin/git`: it's a shim that asks to install the tools when they're missing.
    static let path: String? = {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: p) { return p }
        guard let dev = capture("/usr/bin/xcode-select", ["-p"], in: nil, timeout: 2)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dev.isEmpty else { return nil }
        return [dev + "/usr/bin/git", dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/git"]
            .first(where: fm.isExecutableFile(atPath:))
    }()

    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 3) -> String? {
        guard let path else { return nil }
        return capture(path, args, in: dir, timeout: timeout)
    }

    private static func capture(_ exe: String, _ args: [String], in dir: String?, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Views

/// "+142 −37" after the branch chip of an agent row; "+3 new" when only new files.
/// Absent when the repo is clean, the folder isn't a repo, or the setting is off.
struct AgentDiffLabel: View {
    let session: AgentSession

    var body: some View {
        if let d = DiffService.shared.diff(for: session) {
            HStack(spacing: 3) {
                if d.files.isEmpty {
                    Text("+\(d.newCount) new").foregroundStyle(AgentPhase.done.color.opacity(0.85))
                } else if d.added == 0 && d.removed == 0 {
                    // Only binary or mode changes: no line counts to show.
                    Text("\(d.files.count + d.newCount) changed").foregroundStyle(Color.islandSecondary)
                } else {
                    if d.added > 0 {
                        Text("+\(d.added)").foregroundStyle(AgentPhase.done.color.opacity(0.85))
                    }
                    if d.removed > 0 {
                        Text("\u{2212}\(d.removed)").foregroundStyle(Color.red.opacity(0.8))
                    }
                }
            }
            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .help(Self.summary(d))
            .transition(.opacity)
        }
    }

    static let maxRows = 8

    /// Up to 8 files with their counts, most-changed first, then new files.
    static func summary(_ d: RepoDiff) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var head: [String] = []
        if !d.files.isEmpty { head.append("+\(d.added) \u{2212}\(d.removed) in \(plural(d.files.count, "file"))") }
        if d.newCount > 0 { head.append(plural(d.newCount, "new file")) }
        var lines = [head.joined(separator: ", ")]
        lines += d.files.prefix(maxRows).map { f in
            "\(f.path)  " + (f.binary ? "binary" : "+\(f.added) \u{2212}\(f.removed)")
        }
        lines += d.newFiles.prefix(max(0, maxRows - d.files.count)).map { "\($0)  new" }
        let more = d.files.count + d.newCount - (lines.count - 1)
        if more > 0 { lines.append("and \(more) more") }
        return lines.joined(separator: "\n")
    }
}

/// Hover button that opens the repo in a git client (Fork, Tower…), shown only with changes.
struct AgentDiffButton: View {
    let session: AgentSession
    let monitor: AgentMonitor

    var body: some View {
        if DiffService.shared.diff(for: session) != nil {
            IslandIconButton(systemName: "plusminus", size: 11, padding: 5) {
                DiffService.shared.review(session, monitor: monitor)
            }
            .help("Review changes")
        }
    }
}
