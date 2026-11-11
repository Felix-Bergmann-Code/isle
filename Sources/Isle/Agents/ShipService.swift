import AppKit
import Observation
import SwiftUI

/// One branch of one checkout, the unit GitHub is asked about.
struct ShipKey: Hashable {
    /// Toplevel of the working tree (a linked worktree is its own toplevel).
    let repo: String
    let branch: String
}

/// What GitHub says about a branch: its checks, its pull request and a preview deployment.
struct ShipStatus: Equatable {
    enum Checks: Equatable { case none, running, passed, failed }
    enum PRState: String { case open, draft, merged, closed }
    enum Review: Equatable { case none, required, approved, changesRequested }

    var checks: Checks = .none
    var prNumber: Int?
    var prState: PRState?
    var review: Review = .none
    /// The pull request, else the newest workflow run.
    var url: URL?
    /// A successful preview deployment of the head commit (Vercel, Netlify…).
    var previewURL: URL?
    /// Workflow or check that failed, for the banner.
    var failedWorkflow: String?
    /// GitHub's name for the repository (worktree folders are often named after the branch).
    var repoName: String?
    var headSha: String?

    static let mergedTint = Color(red: 0.68, green: 0.52, blue: 1.0)
    static let failedTint = Color(red: 1.0, green: 0.42, blue: 0.40)

    var hasNews: Bool { checks != .none || prNumber != nil }

    /// One plain sentence for `.help`, e.g. "Checks passed · PR #123 open · review requested".
    var summary: String {
        var parts: [String] = []
        switch checks {
        case .none: break
        case .running: parts.append("Checks running")
        case .passed: parts.append("Checks passed")
        case .failed: parts.append(failedWorkflow.map { "\($0) failed" } ?? "Checks failed")
        }
        if let n = prNumber, let s = prState {
            parts.append("PR #\(n) \(s.rawValue)")
            if s == .open || s == .draft {
                switch review {
                case .none: break
                case .required: parts.append("review requested")
                case .approved: parts.append("approved")
                case .changesRequested: parts.append("changes requested")
                }
            }
        }
        if parts.isEmpty { return "" }
        parts[0] = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        return parts.joined(separator: " · ")
    }
}

/// CI, pull request and deploy status for the branches agents work on, from the GitHub CLI.
///
/// Asks `gh` about each distinct (checkout, branch) of the visible agent sessions: every 45 s
/// while checks run, every 3 min otherwise, and a few seconds after an agent finishes a turn
/// (it may just have pushed). Default branches are skipped; they'd only add noise. Everything
/// runs off the main thread with a timeout. Without `gh`, or signed out, the feature is silent.
///
/// Unchecked Sendable: published and scheduling state lives on the main thread, the caches
/// below are each owned by one serial queue (marked).
@Observable
final class ShipService: @unchecked Sendable {
    static let shared = ShipService()

    enum CLI { case unknown, ready, missing, signedOut }
    private(set) var cli: CLI = .unknown
    private(set) var statuses: [ShipKey: ShipStatus] = [:]
    /// Session cwd → toplevel of its checkout, resolved off the main thread.
    private(set) var roots: [String: String] = [:]

    func status(for s: AgentSession) -> ShipStatus? {
        guard AppSettings.shared.showShipStatus, let b = s.branch, let root = roots[s.cwd] else { return nil }
        return statuses[ShipKey(repo: root, branch: b)]
    }

    // Main-thread state.
    @ObservationIgnored private weak var agents: AgentMonitor?
    @ObservationIgnored private weak var vm: IslandViewModel?
    @ObservationIgnored private var tracked: Set<ShipKey> = []
    @ObservationIgnored private var due: [ShipKey: Date] = [:]
    @ObservationIgnored private var inFlight: Set<ShipKey> = []
    @ObservationIgnored private var phases: [String: AgentPhase] = [:]
    @ObservationIgnored private var lastPairs: Set<Pair>?
    @ObservationIgnored private var wake: DispatchWorkItem?

    /// Resolving checkouts (local, fast) and asking GitHub (slow) don't wait on each other.
    @ObservationIgnored private let resolveQueue = DispatchQueue(label: "isle.ship.resolve", qos: .utility)
    @ObservationIgnored private let fetchQueue = DispatchQueue(label: "isle.ship.fetch", qos: .utility)
    // resolveQueue-owned.
    @ObservationIgnored private var rootCache: [String: String?] = [:]
    @ObservationIgnored private var defaultBranchCache: [String: String?] = [:]
    // fetchQueue-owned.
    @ObservationIgnored private var gh: String?
    @ObservationIgnored private var cliCheckedAt: Date = .distantPast
    @ObservationIgnored private var cliReady = false
    @ObservationIgnored private var previews: [String: (url: URL?, tries: Int)] = [:]

    private struct Pair: Hashable { let cwd: String; let branch: String }

    private static let runningInterval: TimeInterval = 45
    private static let idleInterval: TimeInterval = 180
    private static let errorInterval: TimeInterval = 600
    /// After an agent finishes, give the push a moment to reach GitHub.
    private static let afterDone: TimeInterval = 6

    func start(agents: AgentMonitor, vm: IslandViewModel) {
        self.agents = agents
        self.vm = vm
        observe()
    }

    /// Ask again whether `gh` is installed and signed in (Settings shows a hint until it is).
    func recheckCLI() {
        guard AppSettings.shared.showShipStatus else { return }
        fetchQueue.async { [weak self] in
            guard let self else { return }
            self.cliCheckedAt = .distantPast
            _ = self.ensureCLI()
        }
    }

    // MARK: Sessions

    private func observe() {
        withObservationTracking { sync() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }

    /// Reads only the setting while off, so session churn costs nothing then.
    private func sync() {
        guard AppSettings.shared.showShipStatus, let agents else { stopAll(); return }
        let sessions = agents.visibleSessions
        var finished = Set<String>()
        var seen: [String: AgentPhase] = [:]
        for s in sessions {
            seen[s.id] = s.phase
            if s.phase == .done, let old = phases[s.id], old != .done { finished.insert(s.cwd) }
        }
        phases = seen
        let pairs = Set(sessions.compactMap { s in s.branch.map { Pair(cwd: s.cwd, branch: $0) } })
        guard pairs != lastPairs || !finished.isEmpty else { return }
        lastPairs = pairs
        resolveQueue.async { [weak self] in
            guard let self else { return }
            var resolved: [String: ShipKey] = [:]
            for p in pairs {
                guard let root = self.root(for: p.cwd), self.isFeatureBranch(p.branch, root: root) else { continue }
                resolved[p.cwd] = ShipKey(repo: root, branch: p.branch)
            }
            DispatchQueue.main.async { self.track(resolved, finished: finished) }
        }
    }

    private func track(_ resolved: [String: ShipKey], finished: Set<String>) {
        guard AppSettings.shared.showShipStatus else { return }
        var r = roots
        for (cwd, key) in resolved { r[cwd] = key.repo }
        if r != roots { roots = r }

        let keys = Set(resolved.values)
        let now = Date()
        for gone in tracked.subtracting(keys) {
            due[gone] = nil
            if statuses[gone] != nil { statuses[gone] = nil }
        }
        for new in keys.subtracting(tracked) { due[new] = now }
        tracked = keys
        for cwd in finished { if let k = resolved[cwd] { due[k] = now.addingTimeInterval(Self.afterDone) } }
        reschedule()
    }

    private func stopAll() {
        wake?.cancel()
        wake = nil
        tracked = []
        due = [:]
        phases = [:]
        lastPairs = nil
        if !statuses.isEmpty { statuses = [:] }
    }

    // MARK: Scheduling

    /// One pending wake-up for the earliest due branch, instead of a ticking timer.
    private func reschedule() {
        wake?.cancel()
        guard let next = due.values.min() else { wake = nil; return }
        let work = DispatchWorkItem { [weak self] in self?.pollDue() }
        wake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next.timeIntervalSinceNow), execute: work)
    }

    private func pollDue() {
        let cutoff = Date().addingTimeInterval(1)
        let ready = due.filter { $0.value <= cutoff && !inFlight.contains($0.key) }.map(\.key)
        for k in ready { due[k] = nil; inFlight.insert(k) }
        if !ready.isEmpty { fetch(ready) }
        reschedule()
    }

    private func fetch(_ keys: [ShipKey]) {
        fetchQueue.async { [weak self] in
            guard let self else { return }
            guard let gh = self.ensureCLI() else {
                DispatchQueue.main.async { for k in keys { self.receive(k, nil) } }
                return
            }
            for k in keys {
                let result = self.query(k, gh: gh)
                DispatchQueue.main.async { self.receive(k, result) }
            }
        }
    }

    /// `nil` = couldn't ask (no gh, not a GitHub repo, offline): keep what we had, retry later.
    private func receive(_ k: ShipKey, _ new: ShipStatus?) {
        inFlight.remove(k)
        guard tracked.contains(k), AppSettings.shared.showShipStatus else { return }
        if let new {
            if let old = statuses[k] { announce(k, from: old, to: new) }
            if statuses[k] != new { statuses[k] = new }
        }
        if due[k] == nil {
            let wait = new == nil ? Self.errorInterval : new?.checks == .running ? Self.runningInterval : Self.idleInterval
            due[k] = Date().addingTimeInterval(wait)
        }
        reschedule()
    }

    private func cliChanged(ready: Bool) {
        guard ready else { return }
        // Signed in since the last try: ask about everything now instead of in 10 minutes.
        let now = Date()
        for k in tracked where statuses[k] == nil && !inFlight.contains(k) { due[k] = now }
        reschedule()
    }

    // MARK: Notices

    /// Banners only for changes seen while running; the first answer for a branch is silent.
    private func announce(_ k: ShipKey, from old: ShipStatus, to new: ShipStatus) {
        guard let vm else { return }
        let repo = new.repoName ?? (k.repo as NSString).lastPathComponent
        let pr = new.prNumber.map { "PR #\($0)" }
        let newCommit = old.headSha != new.headSha
        let notice: Notice
        if new.checks == .failed, old.checks != .failed || newCommit {
            notice = Notice(icon: "xmark", tint: ShipStatus.failedTint, title: "\(repo) checks failed",
                            subtitle: new.failedWorkflow ?? pr ?? k.branch, tab: .agents)
        } else if new.prState == .merged, old.prState != .merged, let pr {
            notice = Notice(icon: "arrow.triangle.merge", tint: ShipStatus.mergedTint, title: "\(pr) merged",
                            subtitle: repo, tab: .agents)
        } else if new.review != old.review, new.prNumber == old.prNumber, let pr, new.review == .approved {
            notice = Notice(icon: "person.crop.circle.badge.checkmark", tint: AgentPhase.done.color,
                            title: "\(pr) approved", subtitle: repo, tab: .agents)
        } else if new.review != old.review, new.prNumber == old.prNumber, let pr, new.review == .changesRequested {
            notice = Notice(icon: "person.crop.circle.badge.exclamationmark", tint: AgentPhase.waiting.color,
                            title: "Changes requested on \(pr)", subtitle: repo, tab: .agents)
        } else if let url = new.previewURL, url != old.previewURL {
            notice = Notice(icon: "safari", tint: AgentPhase.working.color, title: "Preview ready",
                            subtitle: url.host ?? repo, tab: .agents)
        } else if new.checks == .passed, old.checks == .running || newCommit {
            notice = Notice(icon: "checkmark", tint: AgentPhase.done.color, title: "\(repo) checks passed",
                            subtitle: pr ?? k.branch, tab: .agents)
        } else {
            return
        }
        vm.notify(notice, duration: new.checks == .failed ? 6 : 4.5)
    }

    // MARK: Checkouts (resolveQueue)

    private func root(for cwd: String) -> String? {
        if let c = rootCache[cwd] { return c }
        var dir = URL(fileURLWithPath: cwd)
        var found: String?
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { found = dir.path; break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        rootCache[cwd] = .some(found)
        return found
    }

    /// False for detached heads and the repo's default branch (its CI isn't the agent's work).
    private func isFeatureBranch(_ branch: String, root: String) -> Bool {
        if branch.count == 7, branch.allSatisfy(\.isHexDigit) { return false } // detached HEAD
        if ["main", "master", "develop", "trunk"].contains(branch) { return false }
        let def: String?
        if let c = defaultBranchCache[root] { def = c } else {
            let out = Self.run("/usr/bin/git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: root, timeout: 5)
            def = out.flatMap { $0.status == 0 ? String(decoding: $0.out, as: UTF8.self) : nil }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
            defaultBranchCache[root] = .some(def)
        }
        return branch != def
    }

    // MARK: GitHub (fetchQueue)

    /// Path to a signed-in `gh`, rechecked at most every 10 minutes while unavailable.
    private func ensureCLI() -> String? {
        if cliReady, let gh { return gh }
        guard Date().timeIntervalSince(cliCheckedAt) > Self.errorInterval else { return nil }
        cliCheckedAt = Date()
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        gh = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let state: CLI
        if let gh {
            state = Self.run(gh, ["auth", "status"], cwd: nil, timeout: 10)?.status == 0 ? .ready : .signedOut
        } else {
            state = .missing
        }
        cliReady = state == .ready
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.cli != state { self.cli = state }
            self.cliChanged(ready: state == .ready)
        }
        return cliReady ? gh : nil
    }

    private func query(_ k: ShipKey, gh: String) -> ShipStatus? {
        guard let pr = Self.run(gh, ["pr", "view", k.branch, "--json",
                                     "number,state,url,isDraft,reviewDecision,statusCheckRollup,headRefName,headRefOid"],
                                cwd: k.repo) else { return nil }
        if pr.status == 0, let json = try? JSONSerialization.jsonObject(with: pr.out) as? [String: Any],
           json["headRefName"] as? String == k.branch {
            return parsePR(json, gh: gh, repo: k.repo)
        }
        guard pr.status == 0 || pr.err.localizedCaseInsensitiveContains("no pull requests found") else { return nil }

        guard let runs = Self.run(gh, ["run", "list", "--branch", k.branch, "--limit", "3", "--json",
                                       "status,conclusion,url,workflowName,headSha"], cwd: k.repo),
              runs.status == 0, let list = try? JSONSerialization.jsonObject(with: runs.out) as? [[String: Any]]
        else { return nil }
        return parseRuns(list)
    }

    private enum Outcome { case running, passed, failed, ignored }

    private static let failing: Set<String> = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR"]

    private func parsePR(_ j: [String: Any], gh: String, repo: String) -> ShipStatus {
        var s = ShipStatus()
        s.prNumber = j["number"] as? Int
        s.url = (j["url"] as? String).flatMap(URL.init(string:))
        s.repoName = s.url.flatMap(Self.repoName)
        s.headSha = j["headRefOid"] as? String
        switch j["state"] as? String {
        case "MERGED": s.prState = .merged
        case "CLOSED": s.prState = .closed
        default: s.prState = (j["isDraft"] as? Bool ?? false) ? .draft : .open
        }
        switch j["reviewDecision"] as? String {
        case "APPROVED": s.review = .approved
        case "CHANGES_REQUESTED": s.review = .changesRequested
        case "REVIEW_REQUIRED": s.review = .required
        default: s.review = .none
        }

        var outcomes: [Outcome] = []
        var direct: URL?
        var deployed = false
        for e in j["statusCheckRollup"] as? [[String: Any]] ?? [] {
            let name = (e["name"] as? String) ?? (e["context"] as? String) ?? ""
            let outcome: Outcome
            if e["__typename"] as? String == "StatusContext" {
                let state = e["state"] as? String ?? ""
                outcome = state == "SUCCESS" ? .passed : Self.failing.contains(state) ? .failed : .running
            } else if e["status"] as? String != "COMPLETED" {
                outcome = .running
            } else {
                let c = e["conclusion"] as? String ?? ""
                outcome = Self.failing.contains(c) ? .failed : (c == "CANCELLED" || c == "STALE") ? .ignored : .passed
            }
            outcomes.append(outcome)
            if outcome == .failed, s.failedWorkflow == nil {
                let wf = e["workflowName"] as? String ?? ""
                s.failedWorkflow = wf.isEmpty ? (name.isEmpty ? nil : name) : wf
            }
            if outcome == .passed, Self.looksLikeDeploy(name) {
                deployed = true
                let link = (e["targetUrl"] as? String) ?? (e["detailsUrl"] as? String)
                if direct == nil, let u = link.flatMap(URL.init(string:)), Self.isPreviewHost(u) { direct = u }
            }
        }
        s.checks = Self.combine(outcomes)
        if s.checks != .failed { s.failedWorkflow = nil }
        if s.prState == .open || s.prState == .draft {
            s.previewURL = direct ?? (deployed ? deploymentURL(sha: s.headSha, prURL: s.url, gh: gh, repo: repo) : nil)
        }
        return s
    }

    private func parseRuns(_ runs: [[String: Any]]) -> ShipStatus {
        var s = ShipStatus()
        guard let newest = runs.first else { return s }
        s.headSha = newest["headSha"] as? String
        s.url = (newest["url"] as? String).flatMap(URL.init(string:))
        s.repoName = s.url.flatMap(Self.repoName)
        var outcomes: [Outcome] = []
        for r in runs where r["headSha"] as? String == s.headSha {
            let outcome: Outcome
            if r["status"] as? String != "completed" { outcome = .running } else {
                let c = (r["conclusion"] as? String ?? "").uppercased()
                outcome = Self.failing.contains(c) ? .failed : (c == "CANCELLED" || c == "STALE") ? .ignored : .passed
            }
            outcomes.append(outcome)
            if outcome == .failed, s.failedWorkflow == nil, let wf = r["workflowName"] as? String, !wf.isEmpty {
                s.failedWorkflow = wf
            }
        }
        s.checks = Self.combine(outcomes)
        if s.checks != .failed { s.failedWorkflow = nil }
        return s
    }

    /// Any failure shows at once; otherwise running until everything has finished.
    private static func combine(_ outcomes: [Outcome]) -> ShipStatus.Checks {
        if outcomes.contains(.failed) { return .failed }
        if outcomes.contains(.running) { return .running }
        return outcomes.contains(.passed) ? .passed : .none
    }

    private static func looksLikeDeploy(_ name: String) -> Bool {
        let n = name.lowercased()
        // Vercel's review bots are checks, not deployments.
        if n.contains(" review") || n.contains("security") { return false }
        return ["vercel", "netlify", "deploy", "preview"].contains { n.contains($0) }
    }

    /// Netlify links straight to the preview; Vercel and Actions link to dashboards and logs.
    private static func isPreviewHost(_ u: URL) -> Bool {
        guard u.scheme == "https", let host = u.host?.lowercased() else { return false }
        let dashboards = ["github.com", "vercel.com", "netlify.com", "app.netlify.com", "www.netlify.com"]
        return !dashboards.contains(host) && !host.hasSuffix(".github.com")
    }

    /// Vercel's checks point at its dashboard; the preview URL is on the GitHub deployment it
    /// creates for the commit. Looked up once per commit (a few tries while it settles).
    private func deploymentURL(sha: String?, prURL: URL?, gh: String, repo: String) -> URL? {
        guard let sha, let prURL, let host = prURL.host else { return nil }
        if let c = previews[sha], c.url != nil || c.tries >= 3 { return c.url }
        let parts = prURL.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let base = "repos/\(parts[0])/\(parts[1])/deployments"
        let hostArgs = host == "github.com" ? [] : ["--hostname", host]
        var found: URL?
        if let r = Self.run(gh, ["api", "\(base)?sha=\(sha)&per_page=10"] + hostArgs, cwd: repo), r.status == 0,
           let list = try? JSONSerialization.jsonObject(with: r.out) as? [[String: Any]],
           let d = list.first(where: { !(($0["environment"] as? String ?? "").lowercased().contains("production")) }),
           let id = d["id"] as? Int,
           let st = Self.run(gh, ["api", "\(base)/\(id)/statuses?per_page=1"] + hostArgs, cwd: repo), st.status == 0,
           let latest = (try? JSONSerialization.jsonObject(with: st.out) as? [[String: Any]])?.first,
           latest["state"] as? String == "success",
           let env = latest["environment_url"] as? String, let u = URL(string: env), u.host != nil {
            found = u
        }
        previews[sha] = (found, (previews[sha]?.tries ?? 0) + 1)
        return found
    }

    /// "https://github.com/owner/repo/pull/1" → "repo".
    private static func repoName(_ u: URL) -> String? {
        let parts = u.path.split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    // MARK: Process

    /// Runs a command with a timeout; `nil` when it couldn't start.
    private static func run(_ exe: String, _ args: [String], cwd: String?,
                            timeout: TimeInterval = 20) -> (status: Int32, out: Data, err: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a bare PATH; gh needs git.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" + (env["PATH"].map { ":" + $0 } ?? "")
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_SPINNER_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain stderr alongside stdout so neither pipe can fill up and stall the process.
        var errData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
    }
}
